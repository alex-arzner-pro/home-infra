#!/usr/bin/env bash
# pi-control initial setup and optimization
# Idempotent — safe to run multiple times
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_MOUNT="/mnt/backup"
SD_DEVICE="/dev/mmcblk0"
SD_PARTITION="${SD_DEVICE}p1"

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

# ─── 1. Disable unnecessary services ─────────────────────────────────────────

disable_services() {
    echo ""
    echo "=== Disabling unnecessary services ==="

    local services=(
        bluetooth.service
        ModemManager.service
        cloud-init-local.service
        cloud-init-main.service
        cloud-init-network.service
        cloud-config.service
        cloud-final.service
        udisks2.service
    )

    for svc in "${services[@]}"; do
        if systemctl is-enabled "$svc" &>/dev/null; then
            systemctl disable --now "$svc" 2>/dev/null && log "Disabled $svc" || warn "Could not disable $svc"
        else
            log "$svc already disabled"
        fi
    done
}

# ─── 2. Optimize boot config for headless server ─────────────────────────────

optimize_boot_config() {
    echo ""
    echo "=== Optimizing boot config ==="

    local boot_config="/boot/firmware/config.txt"
    local ref_config="${SCRIPT_DIR}/config/boot-config.txt"

    if [[ ! -f "$boot_config" ]]; then
        warn "Boot config not found at $boot_config — skipping"
        return
    fi

    # Backup original
    if [[ ! -f "${boot_config}.orig" ]]; then
        cp "$boot_config" "${boot_config}.orig"
        log "Original boot config backed up to ${boot_config}.orig"
    fi

    # Apply optimizations
    local changed=false

    # gpu_mem
    if ! grep -q "^gpu_mem=" "$boot_config"; then
        echo "gpu_mem=16" >> "$boot_config"
        changed=true
    fi

    # audio off
    if grep -q "^dtparam=audio=on" "$boot_config"; then
        sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$boot_config"
        changed=true
    fi

    # camera off
    if grep -q "^camera_auto_detect=1" "$boot_config"; then
        sed -i 's/^camera_auto_detect=1/camera_auto_detect=0/' "$boot_config"
        changed=true
    fi

    # display off
    if grep -q "^display_auto_detect=1" "$boot_config"; then
        sed -i 's/^display_auto_detect=1/display_auto_detect=0/' "$boot_config"
        changed=true
    fi

    # framebuffers
    if grep -q "^max_framebuffers=2" "$boot_config"; then
        sed -i 's/^max_framebuffers=2/max_framebuffers=0/' "$boot_config"
        changed=true
    fi

    if $changed; then
        log "Boot config optimized (reboot required to apply)"
    else
        log "Boot config already optimized"
    fi
}

# ─── 3. Prepare SD card for backups ──────────────────────────────────────────

prepare_sd_card() {
    echo ""
    echo "=== Preparing SD card for backups ==="

    if [[ ! -b "$SD_DEVICE" ]]; then
        warn "SD card device $SD_DEVICE not found — skipping"
        return
    fi

    # Check if already formatted with label "backup"
    if lsblk -no LABEL "$SD_PARTITION" 2>/dev/null | grep -q "^backup$"; then
        log "SD card already formatted with label 'backup'"
    else
        echo ""
        warn "SD card will be REFORMATTED. All data will be lost!"
        echo "  Device: $SD_DEVICE"
        echo "  Current partitions:"
        lsblk -o NAME,SIZE,FSTYPE,LABEL "$SD_DEVICE" | sed 's/^/    /'
        echo ""
        read -rp "Continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            warn "SD card formatting skipped"
            return
        fi

        # Unmount any mounted partitions
        for part in "${SD_DEVICE}"p*; do
            umount "$part" 2>/dev/null || true
        done

        # Wipe and create single partition
        wipefs -a "$SD_DEVICE" 2>/dev/null
        echo "type=83" | sfdisk "$SD_DEVICE"

        # Format
        mkfs.ext4 -L backup "${SD_PARTITION}"
        log "SD card formatted as ext4 with label 'backup'"
    fi

    # Create mount point
    mkdir -p "$BACKUP_MOUNT"

    # Add to fstab if not present
    if ! grep -q "LABEL=backup" /etc/fstab; then
        echo "" >> /etc/fstab
        cat "${SCRIPT_DIR}/config/fstab.entry" >> /etc/fstab
        log "Added backup mount to /etc/fstab"
    else
        log "Backup mount already in /etc/fstab"
    fi

    # Mount
    if ! mountpoint -q "$BACKUP_MOUNT"; then
        mount "$BACKUP_MOUNT"
        log "SD card mounted at $BACKUP_MOUNT"
    else
        log "SD card already mounted at $BACKUP_MOUNT"
    fi

    # Create backup directory structure
    mkdir -p "${BACKUP_MOUNT}/daily"
    log "Backup directory structure ready"
}

# ─── 4. SSH security check ───────────────────────────────────────────────────

check_ssh() {
    echo ""
    echo "=== SSH security check ==="

    local sshd_config="/etc/ssh/sshd_config"
    local auth_keys="/home/aarzner/.ssh/authorized_keys"

    # Check if keys are set up
    if [[ -f "$auth_keys" ]] && [[ -s "$auth_keys" ]]; then
        local key_count
        key_count=$(grep -c "^ssh-" "$auth_keys" 2>/dev/null || echo 0)
        log "Found $key_count SSH key(s) in authorized_keys"
    else
        warn "No SSH keys found!"
        echo ""
        echo "  To set up SSH key authentication:"
        echo "  1. On your LOCAL machine, generate a key (if you don't have one):"
        echo "       ssh-keygen -t ed25519"
        echo "  2. Copy it to this server:"
        echo "       ssh-copy-id aarzner@$(hostname -I | awk '{print $1}')"
        echo "  3. Test that key-based login works"
        echo "  4. Then run: sudo ${SCRIPT_DIR}/setup.sh --harden-ssh"
        echo ""
        return
    fi

    # Check if password auth is still enabled
    if grep -q "^PasswordAuthentication yes" "$sshd_config" 2>/dev/null || \
       ! grep -q "^PasswordAuthentication no" "$sshd_config" 2>/dev/null; then
        warn "Password authentication is still enabled"
        echo "  Run 'sudo ${SCRIPT_DIR}/setup.sh --harden-ssh' after verifying key access"
    else
        log "Password authentication already disabled"
    fi
}

harden_ssh() {
    echo ""
    echo "=== Hardening SSH ==="

    local sshd_config="/etc/ssh/sshd_config"
    local auth_keys="/home/aarzner/.ssh/authorized_keys"

    if [[ ! -f "$auth_keys" ]] || [[ ! -s "$auth_keys" ]]; then
        err "No SSH keys found! Set up keys first before disabling password auth."
        exit 1
    fi

    # Backup
    if [[ ! -f "${sshd_config}.orig" ]]; then
        cp "$sshd_config" "${sshd_config}.orig"
    fi

    # Disable password auth
    if grep -q "^#*PasswordAuthentication" "$sshd_config"; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
    else
        echo "PasswordAuthentication no" >> "$sshd_config"
    fi

    # Disable root login
    if grep -q "^#*PermitRootLogin" "$sshd_config"; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$sshd_config"
    else
        echo "PermitRootLogin no" >> "$sshd_config"
    fi

    systemctl reload sshd
    log "SSH hardened: password auth disabled, root login disabled"
    warn "Keep your current session open and test a new SSH connection before closing!"
}

# ─── 5. Unattended upgrades ──────────────────────────────────────────────────

setup_unattended_upgrades() {
    echo ""
    echo "=== Setting up unattended security upgrades ==="

    if dpkg -l | grep -q unattended-upgrades; then
        log "unattended-upgrades already installed"
    else
        apt-get update -qq
        apt-get install -y unattended-upgrades
        log "unattended-upgrades installed"
    fi

    # Enable automatic security updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    log "Automatic security upgrades enabled"
}

# ─── 6. Install backup cron ──────────────────────────────────────────────────

install_backup_cron() {
    echo ""
    echo "=== Setting up backup cron ==="

    local cron_dest="/etc/cron.d/home-infra-backup"
    local cron_src="${SCRIPT_DIR}/backup/backup.cron"

    cp "$cron_src" "$cron_dest"
    chmod 644 "$cron_dest"
    log "Backup cron installed ($cron_dest)"
}

# ─── 7. Install extra packages ──────────────────────────────────────────────

install_packages() {
    echo ""
    echo "=== Installing extra packages ==="

    local packages=(tmux nodejs npm bubblewrap)

    for pkg in "${packages[@]}"; do
        if dpkg -l "$pkg" &>/dev/null; then
            log "$pkg already installed"
        else
            apt-get install -y "$pkg"
            log "$pkg installed"
        fi
    done

    # Install Codex CLI via npm
    if command -v codex &>/dev/null; then
        log "@openai/codex already installed ($(codex --version 2>&1))"
    else
        npm i -g @openai/codex
        log "@openai/codex installed"
    fi
}

# ─── 8. Shell configuration ─────────────────────────────────────────────────

configure_shell() {
    echo ""
    echo "=== Configuring shell ==="

    local bashrc="/home/aarzner/.bashrc"
    local fix='[[ "$TERM" == "xterm-kitty" ]] && export TERM=xterm-256color'

    if grep -qF 'xterm-kitty' "$bashrc"; then
        log "Kitty terminal fix already in .bashrc"
    else
        sed -i "/# If not running interactively/i # Fix kitty terminal type for tmux compatibility\n${fix}\n" "$bashrc"
        log "Added kitty terminal fix to .bashrc"
    fi

    # OpenAI API key for Codex CLI
    local openai_line='[[ -f ~/.secrets/openai.env ]] && source ~/.secrets/openai.env'
    if grep -qF 'openai.env' "$bashrc"; then
        log "OpenAI env loader already in .bashrc"
    else
        echo "" >> "$bashrc"
        echo "# Load OpenAI API key for Codex CLI" >> "$bashrc"
        echo "$openai_line" >> "$bashrc"
        log "Added OpenAI env loader to .bashrc"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "============================================"
    echo "  pi-control setup"
    echo "  $(date)"
    echo "============================================"

    need_root

    if [[ "${1:-}" == "--harden-ssh" ]]; then
        harden_ssh
        exit 0
    fi

    disable_services
    optimize_boot_config
    prepare_sd_card
    check_ssh
    setup_unattended_upgrades
    install_backup_cron
    install_packages
    configure_shell

    echo ""
    echo "============================================"
    echo "  Setup complete!"
    echo "============================================"
    echo ""
    echo "Next steps:"
    echo "  1. Set up SSH keys (see instructions above if needed)"
    echo "  2. Reboot to apply boot config changes: sudo reboot"
    echo ""
}

main "$@"
