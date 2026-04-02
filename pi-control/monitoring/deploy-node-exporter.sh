#!/usr/bin/env bash
# Deploy node_exporter to all Proxmox nodes via SSH
# Idempotent — safe to run multiple times
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_EXPORTER_VERSION="1.10.2"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
SERVICE_FILE="${SCRIPT_DIR}/config/node_exporter.service"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; }

# Load Proxmox node IPs
source "$HOME/.secrets/proxmox.env"

NODES=(
    "${PVE_IP_0}:home-pve-0"
    "${PVE_IP_1}:home-pve-1"
    "${PVE_IP_2}:home-pve-2"
    "${PVE_IP_3}:home-pve-3"
    "${PVE_IP_4}:home-pve-4"
)

deploy_to_node() {
    local ip="${1%%:*}"
    local name="${1##*:}"

    echo ""
    echo "=== Deploying to ${name} (${ip}) ==="

    # Check connectivity
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${ip}" "true" 2>/dev/null; then
        err "${name}: unreachable"
        return 1
    fi

    # Check if already installed and at correct version
    local current_version
    current_version=$(ssh "root@${ip}" "/usr/local/bin/node_exporter --version 2>&1 | head -1 | grep -oP 'version \K[0-9.]+'" 2>/dev/null || echo "none")

    if [[ "$current_version" == "$NODE_EXPORTER_VERSION" ]]; then
        log "${name}: node_exporter ${NODE_EXPORTER_VERSION} already installed"

        # Ensure service is running
        ssh "root@${ip}" "systemctl is-active node_exporter &>/dev/null || systemctl start node_exporter"
        return 0
    fi

    # Download and install
    ssh "root@${ip}" bash <<REMOTE
set -euo pipefail
cd /tmp
curl -sLO "${NODE_EXPORTER_URL}"
tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
REMOTE

    # Deploy systemd unit
    scp -q "${SERVICE_FILE}" "root@${ip}:/etc/systemd/system/node_exporter.service"

    # Enable and start
    ssh "root@${ip}" "systemctl daemon-reload && systemctl enable --now node_exporter"

    # Verify (give it a moment to start)
    sleep 2
    if curl -sf "http://${ip}:9100/metrics" > /dev/null 2>&1; then
        log "${name}: node_exporter ${NODE_EXPORTER_VERSION} deployed and running"
    else
        err "${name}: deployed but port 9100 not responding"
        return 1
    fi
}

echo "============================================"
echo "  Deploy node_exporter v${NODE_EXPORTER_VERSION}"
echo "  $(date)"
echo "============================================"

failed=0
for node in "${NODES[@]}"; do
    deploy_to_node "$node" || ((failed++))
done

echo ""
if [[ $failed -eq 0 ]]; then
    log "All nodes deployed successfully"
else
    err "${failed} node(s) failed"
    exit 1
fi
