#!/usr/bin/env bash
# Backup MikroTik router configuration
# Creates both text export (.rsc) and binary backup (.backup)
set -euo pipefail

SECRETS_FILE="/home/aarzner/.secrets/mikrotik.env"
BACKUP_DIR="/mnt/backup/mikrotik"
DATE=$(date +%Y-%m-%d)
RETENTION=30

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Load secrets
if [[ ! -f "$SECRETS_FILE" ]]; then
    log "ERROR: $SECRETS_FILE not found"
    exit 1
fi
source "$SECRETS_FILE"

SSH_CMD="ssh $SSH_OPTS -p ${MIKROTIK_PORT} ${MIKROTIK_USER}@${MIKROTIK_HOST}"
SCP_CMD="scp $SSH_OPTS -P ${MIKROTIK_PORT}"

# Check backup mount
if ! mountpoint -q /mnt/backup; then
    log "ERROR: /mnt/backup is not mounted"
    exit 1
fi

mkdir -p "${BACKUP_DIR}/${DATE}"

# ─── Text export (.rsc) ──────────────────────────────────────────────────────

log "Exporting text config..."
$SSH_CMD "/export" > "${BACKUP_DIR}/${DATE}/mikrotik-export.rsc" 2>/dev/null
log "Text export saved ($(wc -c < "${BACKUP_DIR}/${DATE}/mikrotik-export.rsc") bytes)"

# ─── Binary backup (.backup) ─────────────────────────────────────────────────

log "Creating binary backup on router..."
$SSH_CMD "/system backup save name=pi-control-backup dont-encrypt=yes" 2>/dev/null
sleep 2

log "Downloading binary backup..."
$SCP_CMD "${MIKROTIK_USER}@${MIKROTIK_HOST}:pi-control-backup.backup" \
    "${BACKUP_DIR}/${DATE}/mikrotik.backup" 2>/dev/null
log "Binary backup saved ($(wc -c < "${BACKUP_DIR}/${DATE}/mikrotik.backup") bytes)"

# Clean up on router
$SSH_CMD "/file remove pi-control-backup.backup" 2>/dev/null || true

# ─── Also keep latest export in git repo for tracking changes ─────────────────

REPO_DIR="/home/aarzner/home-infra/pi-control/mikrotik"
cp "${BACKUP_DIR}/${DATE}/mikrotik-export.rsc" "${REPO_DIR}/latest-export.rsc"
log "Latest export copied to repo for diff tracking"

# ─── Rotate old backups ──────────────────────────────────────────────────────

mapfile -t old_backups < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort -r | tail -n +$((RETENTION + 1)))
for old in "${old_backups[@]}"; do
    rm -rf "$old"
    log "Removed old backup: ${old}"
done

log "MikroTik backup complete"
