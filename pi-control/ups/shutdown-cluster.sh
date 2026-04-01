#!/usr/bin/env bash
# Graceful shutdown of Proxmox cluster on UPS power loss
# Called by NUT upsmon via SHUTDOWNCMD
#
# Shutdown order:
#   1. VMs/CTs on nodes 0-3 (depend on storage)
#   2. VMs on node 4 except VM 105 (storage)
#   3. VM 105 (Synology storage)
#   4. Nodes 0-3
#   5. Node 4
#   6. Pi shuts itself down
set -uo pipefail

SECRETS_FILE="/home/aarzner/.secrets/proxmox.env"
LOG="/var/log/cluster-shutdown.log"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes"
STORAGE_VMID=105
STORAGE_NODE_IP=""  # set from secrets (PVE_IP_4)

# VM shutdown timeout (seconds to wait for graceful stop)
VM_SHUTDOWN_TIMEOUT=120
NODE_SHUTDOWN_TIMEOUT=60

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG"; }

# ─── Load config ──────────────────────────────────────────────────────────────

load_config() {
    if [[ ! -f "$SECRETS_FILE" ]]; then
        err "Secrets file not found: $SECRETS_FILE"
        exit 1
    fi
    source "$SECRETS_FILE"
    STORAGE_NODE_IP="$PVE_IP_4"
}

# ─── SSH helper ───────────────────────────────────────────────────────────────

run_ssh() {
    local host="$1"
    shift
    ssh $SSH_OPTS "${PVE_USER}@${host}" "$@" 2>>"$LOG"
}

# ─── Shutdown VMs on a node ───────────────────────────────────────────────────

shutdown_vms_on_node() {
    local ip="$1"
    local node_name="$2"
    local exclude_vmid="${3:-}"

    log "Shutting down VMs on ${node_name} (${ip})..."

    # Get list of running VMs
    local running_vms
    running_vms=$(run_ssh "$ip" "qm list 2>/dev/null | awk 'NR>1 && \$3==\"running\" {print \$1}'" || true)

    if [[ -z "$running_vms" ]]; then
        log "  No running VMs on ${node_name}"
        return
    fi

    for vmid in $running_vms; do
        if [[ -n "$exclude_vmid" && "$vmid" == "$exclude_vmid" ]]; then
            log "  Skipping VM ${vmid} (storage)"
            continue
        fi
        log "  Shutting down VM ${vmid}..."
        run_ssh "$ip" "qm shutdown ${vmid} --timeout ${VM_SHUTDOWN_TIMEOUT} --forceStop 1" &
    done

    # Also shut down CTs
    local running_cts
    running_cts=$(run_ssh "$ip" "pct list 2>/dev/null | awk 'NR>1 && \$2==\"running\" {print \$1}'" || true)

    for ctid in $running_cts; do
        log "  Shutting down CT ${ctid}..."
        run_ssh "$ip" "pct shutdown ${ctid} --timeout ${VM_SHUTDOWN_TIMEOUT} --forceStop 1" &
    done

    wait
    log "  VMs/CTs on ${node_name} shutdown complete"
}

# ─── Shutdown a node ──────────────────────────────────────────────────────────

shutdown_node() {
    local ip="$1"
    local node_name="$2"

    log "Shutting down node ${node_name} (${ip})..."
    run_ssh "$ip" "shutdown -h now" || err "Failed to shutdown ${node_name}"
}

# ─── Wait for node to go offline ─────────────────────────────────────────────

wait_for_offline() {
    local ip="$1"
    local name="$2"
    local timeout="${3:-$NODE_SHUTDOWN_TIMEOUT}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if ! ping -c1 -W2 "$ip" &>/dev/null; then
            log "  ${name} is offline"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    err "  ${name} still online after ${timeout}s"
}

# ─── Main shutdown sequence ──────────────────────────────────────────────────

main() {
    log "============================================"
    log "CLUSTER SHUTDOWN INITIATED (UPS power loss)"
    log "============================================"

    load_config

    # ── Phase 1: Shutdown VMs/CTs on nodes 0-3 (parallel) ──
    log ""
    log "=== Phase 1: Shutdown VMs on nodes 0-3 ==="
    shutdown_vms_on_node "$PVE_IP_0" "home-pve-0" &
    shutdown_vms_on_node "$PVE_IP_1" "home-pve-1" &
    shutdown_vms_on_node "$PVE_IP_2" "home-pve-2" &
    shutdown_vms_on_node "$PVE_IP_3" "home-pve-3" &
    wait

    # ── Phase 2: Shutdown VMs on node 4 except storage ──
    log ""
    log "=== Phase 2: Shutdown VMs on node 4 (except VM ${STORAGE_VMID}) ==="
    shutdown_vms_on_node "$PVE_IP_4" "home-pve-4" "$STORAGE_VMID"

    # ── Phase 3: Shutdown storage VM ──
    log ""
    log "=== Phase 3: Shutdown VM ${STORAGE_VMID} (Synology storage) ==="
    log "  Shutting down VM ${STORAGE_VMID}..."
    run_ssh "$STORAGE_NODE_IP" "qm shutdown ${STORAGE_VMID} --timeout ${VM_SHUTDOWN_TIMEOUT} --forceStop 1" || err "Failed to shutdown VM ${STORAGE_VMID}"
    log "  Storage VM shutdown complete"

    # ── Phase 4: Shutdown nodes 0-3 (parallel) ──
    log ""
    log "=== Phase 4: Shutdown nodes 0-3 ==="
    for i in 0 1 2 3; do
        local ip_var="PVE_IP_${i}"
        shutdown_node "${!ip_var}" "home-pve-${i}" &
    done
    wait

    # Wait for nodes 0-3 to go offline
    for i in 0 1 2 3; do
        local ip_var="PVE_IP_${i}"
        wait_for_offline "${!ip_var}" "home-pve-${i}" &
    done
    wait

    # ── Phase 5: Shutdown node 4 ──
    log ""
    log "=== Phase 5: Shutdown node 4 (storage host) ==="
    shutdown_node "$PVE_IP_4" "home-pve-4"
    wait_for_offline "$PVE_IP_4" "home-pve-4"

    # ── Phase 6: Shutdown Pi ──
    log ""
    log "=== Phase 6: Shutting down pi-control ==="
    log "============================================"
    log "CLUSTER SHUTDOWN COMPLETE"
    log "============================================"

    /sbin/shutdown -h +0
}

main "$@"
