#!/usr/bin/env bash
# Daily backup to SD card
# Keeps last 7 daily backups with rotation
set -euo pipefail

BACKUP_ROOT="/mnt/backup/daily"
RETENTION=7
DATE=$(date +%Y-%m-%d)
BACKUP_DIR="${BACKUP_ROOT}/${DATE}"

# Sources to back up
SOURCES=(
    /etc
    /home/aarzner
)

# Excludes
EXCLUDES=(
    --exclude='.cache'
    --exclude='.local/share/Trash'
    --exclude='node_modules'
    --exclude='.npm'
    --exclude='__pycache__'
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Check backup mount
if ! mountpoint -q /mnt/backup; then
    log "ERROR: /mnt/backup is not mounted"
    exit 1
fi

# Find previous backup for hardlinks (saves space)
LATEST=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" | sort -r | head -1)
LINK_DEST=""
if [[ -n "$LATEST" && "$LATEST" != "$BACKUP_DIR" ]]; then
    LINK_DEST="--link-dest=${LATEST}"
fi

log "Starting backup to ${BACKUP_DIR}"

mkdir -p "$BACKUP_DIR"

for src in "${SOURCES[@]}"; do
    dest="${BACKUP_DIR}${src}"
    mkdir -p "$(dirname "$dest")"
    rsync -a --delete "${EXCLUDES[@]}" $LINK_DEST "$src/" "$dest/" 2>/dev/null || {
        log "WARNING: rsync had issues with ${src} (exit code $?)"
    }
    log "Backed up ${src}"
done

# Rotate: remove old backups
mapfile -t old_backups < <(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" | sort -r | tail -n +$((RETENTION + 1)))
for old in "${old_backups[@]}"; do
    rm -rf "$old"
    log "Removed old backup: ${old}"
done

# Write stats
du -sh "$BACKUP_DIR" | awk '{print $1}' > "${BACKUP_DIR}/.size"
log "Backup complete ($(cat "${BACKUP_DIR}/.size"))"
