#!/usr/bin/env bash
# Install and configure NUT for Eaton Ellipse ECO UPS
# Idempotent — safe to run multiple times
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
NUT_CONF_DIR="/etc/nut"
SECRETS_FILE="/home/aarzner/.secrets/nut.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use sudo)"
        exit 1
    fi
}

# ─── 1. Load secrets ─────────────────────────────────────────────────────────

load_secrets() {
    echo ""
    echo "=== Loading NUT secrets ==="

    if [[ ! -f "$SECRETS_FILE" ]]; then
        err "Secrets file not found: $SECRETS_FILE"
        err "Create it with NUT_ADMIN_PASS and NUT_UPSMON_PASS"
        exit 1
    fi

    source "$SECRETS_FILE"

    if [[ "${NUT_ADMIN_PASS:-changeme}" == "changeme" ]] || [[ "${NUT_UPSMON_PASS:-changeme}" == "changeme" ]]; then
        err "Passwords in $SECRETS_FILE are still set to 'changeme'"
        err "Please set real passwords before running this script"
        exit 1
    fi

    log "Secrets loaded"
}

# ─── 2. Install NUT ──────────────────────────────────────────────────────────

install_nut() {
    echo ""
    echo "=== Installing NUT ==="

    if dpkg -l | grep -q "^ii  nut "; then
        log "NUT already installed"
    else
        apt-get update -qq
        apt-get install -y nut
        log "NUT installed"
    fi
}

# ─── 3. Set up udev rules ────────────────────────────────────────────────────

setup_udev() {
    echo ""
    echo "=== Setting up udev rules ==="

    local rule_src="${CONFIG_DIR}/62-nut-usbhid.rules"
    local rule_dst="/etc/udev/rules.d/62-nut-usbhid.rules"

    if [[ -f "$rule_dst" ]] && diff -q "$rule_src" "$rule_dst" &>/dev/null; then
        log "Udev rules already in place"
    else
        cp "$rule_src" "$rule_dst"
        udevadm control --reload-rules
        udevadm trigger
        log "Udev rules installed and reloaded"
    fi
}

# ─── 4. Deploy NUT configs ───────────────────────────────────────────────────

deploy_configs() {
    echo ""
    echo "=== Deploying NUT configuration ==="

    # Simple configs (no secrets substitution)
    for conf in nut.conf ups.conf upsd.conf; do
        cp "${CONFIG_DIR}/${conf}" "${NUT_CONF_DIR}/${conf}"
        chown root:nut "${NUT_CONF_DIR}/${conf}"
        chmod 640 "${NUT_CONF_DIR}/${conf}"
        log "Deployed ${conf}"
    done

    # Configs with secrets substitution
    for conf in upsd.users upsmon.conf; do
        sed \
            -e "s/%%NUT_ADMIN_PASS%%/${NUT_ADMIN_PASS}/g" \
            -e "s/%%NUT_UPSMON_PASS%%/${NUT_UPSMON_PASS}/g" \
            "${CONFIG_DIR}/${conf}" > "${NUT_CONF_DIR}/${conf}"
        chown root:nut "${NUT_CONF_DIR}/${conf}"
        chmod 640 "${NUT_CONF_DIR}/${conf}"
        log "Deployed ${conf} (with secrets)"
    done
}

# ─── 5. Start services ───────────────────────────────────────────────────────

start_services() {
    echo ""
    echo "=== Starting NUT services ==="

    # Restart to pick up new configs
    # nut-driver@ is a template unit — trigger via enumerator or target
    systemctl restart nut-driver-enumerator.service 2>/dev/null || true
    systemctl restart nut-driver.target 2>/dev/null || true
    log "nut-driver started"

    systemctl restart nut-server 2>/dev/null || systemctl start nut-server
    log "nut-server started"

    systemctl restart nut-monitor 2>/dev/null || systemctl start nut-monitor
    log "nut-monitor started"

    # Enable on boot
    systemctl enable nut-driver-enumerator.path nut-driver.target nut-server nut-monitor 2>/dev/null
    log "NUT services enabled on boot"
}

# ─── 6. Verify ───────────────────────────────────────────────────────────────

verify() {
    echo ""
    echo "=== Verifying UPS connection ==="

    sleep 2

    if upsc eaton &>/dev/null; then
        log "UPS is accessible!"
        echo ""
        echo "  Key readings:"
        echo "    Status:       $(upsc eaton ups.status 2>/dev/null || echo 'N/A')"
        echo "    Battery:      $(upsc eaton battery.charge 2>/dev/null || echo 'N/A')%"
        echo "    Load:         $(upsc eaton ups.load 2>/dev/null || echo 'N/A')%"
        echo "    Input voltage:$(upsc eaton input.voltage 2>/dev/null || echo 'N/A')V"
        echo "    Runtime:      $(upsc eaton battery.runtime 2>/dev/null || echo 'N/A')s"
        echo ""
    else
        err "Cannot reach UPS via upsc"
        err "Check: journalctl -u nut-driver -n 20"
        exit 1
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "============================================"
    echo "  NUT setup for Eaton Ellipse ECO"
    echo "  $(date)"
    echo "============================================"

    need_root
    load_secrets
    install_nut
    setup_udev
    deploy_configs
    start_services
    verify

    echo "============================================"
    echo "  NUT setup complete!"
    echo "============================================"
    echo ""
    echo "Useful commands:"
    echo "  upsc eaton              — full UPS status"
    echo "  upsc eaton ups.status   — OL=online, OB=on battery"
    echo "  upsc eaton battery.charge — battery %"
    echo ""
}

main "$@"
