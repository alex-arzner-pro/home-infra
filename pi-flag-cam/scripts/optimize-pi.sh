#!/usr/bin/env bash
# Pi Flag Cam — One-time system optimization for Raspberry Pi Zero W
# Run from the local machine: ./scripts/optimize-pi.sh
# Requires SSH access to pi-flag-cam.local
#
# Idempotent: safe to re-run. Already-applied steps are skipped.

set -euo pipefail

PI_HOST="${PI_FLAG_CAM_HOST:-pi-flag-cam.local}"
PI_USER="${PI_FLAG_CAM_USER:-aarzner}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ssh_pi() {
    ssh -o ConnectTimeout=10 "${PI_USER}@${PI_HOST}" "$@"
}

echo "=== Pi Flag Cam — System Optimization ==="
echo "Target: ${PI_USER}@${PI_HOST}"
echo

# --- Baseline ---
echo "--- Collecting baseline metrics ---"
ssh_pi 'echo "Boot time: $(systemd-analyze 2>/dev/null | head -1)"
echo "RAM: $(free -h | awk "/Mem:/{printf \"used=%s available=%s\", \$3, \$NF}")"
echo "Kernel modules: $(lsmod | wc -l)"'
echo

# --- Phase 0: Cleanup old remnants ---
echo "--- Phase 0: Cleaning up old remnants ---"
# Only remove the known-bad empty 10-luxafor.rules file.
# 99-luxafor.rules is managed by deploy.sh and should not be touched here.
ssh_pi '
f="/etc/udev/rules.d/10-luxafor.rules"
if [ -f "$f" ]; then
    sudo rm -f "$f" && echo "Removed $f"
else
    echo "No old remnants to clean"
fi
'
echo

# --- Phase 1.1: Disable unnecessary services ---
echo "--- Phase 1.1: Disabling unnecessary services ---"
# Each service is disabled individually; failures are OK (service may not exist)
ssh_pi '
SERVICES="
  cloud-config cloud-final cloud-init-local cloud-init-main cloud-init-network
  udisks2 console-setup keyboard-setup
  rpi-eeprom-update regenerate_ssh_host_keys
  NetworkManager-wait-online
"
TIMERS="man-db.timer"

for svc in $SERVICES; do
    if systemctl is-enabled "${svc}.service" >/dev/null 2>&1; then
        sudo systemctl disable --now "${svc}.service" 2>/dev/null && echo "Disabled ${svc}" || true
    else
        echo "Already disabled: ${svc}"
    fi
done

for tmr in $TIMERS; do
    if systemctl is-enabled "$tmr" >/dev/null 2>&1; then
        sudo systemctl disable --now "$tmr" 2>/dev/null && echo "Disabled ${tmr}" || true
    else
        echo "Already disabled: ${tmr}"
    fi
done
'
echo

# --- Phase 1.2: Boot config ---
echo "--- Phase 1.2: Updating boot config ---"
if ssh_pi 'grep -q "^# Pi Flag Cam" /boot/firmware/config.txt 2>/dev/null'; then
    echo "Boot config already optimized, skipping"
else
    ssh_pi 'sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak'
    echo "Backed up config.txt"

    cat <<'CONFIG_EOF' | ssh_pi 'sudo tee /boot/firmware/config.txt > /dev/null'
# Pi Flag Cam — optimized boot config
# Original backed up as config.txt.bak

# Disable audio (not needed)
dtparam=audio=off

# Disable Bluetooth hardware
dtoverlay=disable-bt

# Reduce GPU memory to minimum (USB webcam uses uvcvideo, not GPU)
gpu_mem=16

# Disable CSI camera auto-detect (we use USB webcam)
camera_auto_detect=0

# Disable display auto-detect (headless)
display_auto_detect=0

# Auto-load initramfs
auto_initramfs=1

# Enable hardware watchdog
dtparam=watchdog=on

# Run as fast as firmware allows
arm_boost=1

[cm4]
otg_mode=1

[cm5]
dtoverlay=dwc2,dr_mode=host

[all]
CONFIG_EOF
    echo "Updated config.txt"
fi
echo

# --- Phase 1.3: Blacklist kernel modules + WiFi stability ---
echo "--- Phase 1.3: Deploying modprobe configs ---"
scp -q "${PROJECT_DIR}/pi/config/modprobe-blacklist.conf" "${PI_USER}@${PI_HOST}:/tmp/pi-flag-cam-blacklist.conf"
scp -q "${PROJECT_DIR}/pi/config/brcmfmac.conf" "${PI_USER}@${PI_HOST}:/tmp/brcmfmac.conf"
ssh_pi '
sudo mv /tmp/pi-flag-cam-blacklist.conf /etc/modprobe.d/pi-flag-cam-blacklist.conf
sudo mv /tmp/brcmfmac.conf /etc/modprobe.d/brcmfmac.conf
'
echo "Deployed modprobe blacklist + brcmfmac stability (roamoff=1)"
echo

# --- Phase 1.4: Journald volatile logging ---
echo "--- Phase 1.4: Configuring volatile journald ---"
ssh_pi 'sudo mkdir -p /etc/systemd/journald.conf.d'
scp -q "${PROJECT_DIR}/pi/config/journald-pi-flag-cam.conf" "${PI_USER}@${PI_HOST}:/tmp/journald-pi-flag-cam.conf"
ssh_pi 'sudo mv /tmp/journald-pi-flag-cam.conf /etc/systemd/journald.conf.d/pi-flag-cam.conf'
echo "Deployed journald config"
echo

# --- Phase 1.5: Watchdog ---
echo "--- Phase 1.5: Enabling watchdog ---"
if ssh_pi 'grep -q "^RuntimeWatchdogSec=10s" /etc/systemd/system.conf 2>/dev/null'; then
    echo "Watchdog already configured"
else
    ssh_pi 'sudo sed -i "s/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=10s/" /etc/systemd/system.conf'
    # Verify the change took effect
    if ssh_pi 'grep -q "^RuntimeWatchdogSec=10s" /etc/systemd/system.conf'; then
        echo "Enabled RuntimeWatchdogSec=10s"
    else
        echo "WARNING: Failed to set watchdog — check /etc/systemd/system.conf manually"
    fi
fi
echo

# --- Phase 1.6: Disable Bluetooth UART + useless services/timers ---
echo "--- Phase 1.6: Disabling unnecessary services and timers ---"
ssh_pi '
# Bluetooth UART
sudo systemctl disable --now hciuart.service 2>/dev/null

# Serial console (not needed without UART debugging)
sudo systemctl disable --now serial-getty@ttyAMA0.service 2>/dev/null

# Timers useless with overlayfs (changes lost on reboot)
for t in apt-daily.timer apt-daily-upgrade.timer fstrim.timer e2scrub_all.timer logrotate.timer dpkg-db-backup.timer; do
    sudo systemctl disable --now "$t" 2>/dev/null
done

echo "Disabled: hciuart, serial-getty, apt-daily, fstrim, e2scrub, logrotate, dpkg-db-backup timers"
'
echo

# --- Phase 1.7: Install required software ---
echo "--- Phase 1.7: Installing required packages ---"
PACKAGES_TO_INSTALL=""
ssh_pi 'which fswebcam > /dev/null 2>&1' || PACKAGES_TO_INSTALL="fswebcam"
ssh_pi 'which ustreamer > /dev/null 2>&1' || PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL ustreamer"
ssh_pi 'dpkg -l overlayroot > /dev/null 2>&1' || PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL overlayroot"

if [ -n "$PACKAGES_TO_INSTALL" ]; then
    echo "Installing: $PACKAGES_TO_INSTALL (may take a few minutes on Pi Zero W)..."
    ssh_pi "sudo apt-get update -qq && sudo apt-get install -y -qq $PACKAGES_TO_INSTALL"
    echo "Installed: $PACKAGES_TO_INSTALL"
else
    echo "All packages already installed"
fi
echo

# --- Phase 1.8: Build initramfs with overlayroot ---
echo "--- Phase 1.8: Building initramfs with overlayroot ---"
ssh_pi '
KVER=$(uname -r)
if lsinitramfs /boot/initrd.img-$KVER 2>/dev/null | grep -q overlayroot; then
    echo "initramfs already has overlayroot for $KVER"
else
    echo "Building initramfs for $KVER (slow on Pi Zero W)..."
    sudo update-initramfs -c -k $KVER 2>&1 | tail -3
    sudo cp /boot/initrd.img-$KVER /boot/firmware/initramfs
    echo "initramfs built and installed"
fi
'
echo

# --- Phase 1.9: WiFi watchdog cron ---
echo "--- Phase 1.9: Setting up WiFi watchdog ---"
scp -q "${PROJECT_DIR}/pi/wifi-watchdog.sh" "${PI_USER}@${PI_HOST}:/tmp/wifi-watchdog.sh"
ssh_pi '
sudo mv /tmp/wifi-watchdog.sh /home/aarzner/pi-flag-cam/wifi-watchdog.sh 2>/dev/null || true
chmod +x /home/aarzner/pi-flag-cam/wifi-watchdog.sh
CRON_LINE="*/2 * * * * /home/aarzner/pi-flag-cam/wifi-watchdog.sh"
(sudo crontab -l 2>/dev/null | grep -v wifi-watchdog; echo "$CRON_LINE") | sudo crontab -
echo "WiFi watchdog cron installed"
'
echo

# --- Phase 1.10: Deploy zram-swap service ---
echo "--- Phase 1.10: Deploying zram-swap service ---"
scp -q "${PROJECT_DIR}/pi/config/zram-swap.service" "${PI_USER}@${PI_HOST}:/tmp/zram-swap.service"
ssh_pi '
sudo mv /tmp/zram-swap.service /etc/systemd/system/zram-swap.service
sudo systemctl daemon-reload
sudo systemctl enable zram-swap.service
echo "zram-swap service installed"
'
echo

# --- Phase 1.11: Deploy crash monitor ---
echo "--- Phase 1.11: Deploying crash monitor ---"
scp -q "${PROJECT_DIR}/pi/crash-monitor.sh" "${PI_USER}@${PI_HOST}:/tmp/crash-monitor.sh"
scp -q "${PROJECT_DIR}/pi/config/crash-monitor.service" "${PI_USER}@${PI_HOST}:/tmp/crash-monitor.service"
ssh_pi '
sudo mv /tmp/crash-monitor.sh /home/aarzner/pi-flag-cam/crash-monitor.sh
chmod +x /home/aarzner/pi-flag-cam/crash-monitor.sh
sudo mv /tmp/crash-monitor.service /etc/systemd/system/crash-monitor.service
sudo systemctl daemon-reload
sudo systemctl enable crash-monitor.service
echo "Crash monitor service installed"
'
echo

echo "=== Optimization complete ==="
echo "Reboot required to apply boot config and module changes."
echo "  ssh ${PI_USER}@${PI_HOST} sudo reboot"
echo "After reboot, verify:"
echo "  ssh ${PI_USER}@${PI_HOST} 'systemd-analyze; free -h; lsmod | wc -l'"
