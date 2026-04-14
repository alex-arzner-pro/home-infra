#!/usr/bin/env bash
# Pi Flag Cam — Switch Pi to read-write mode
# Temporarily disables overlayfs and reboots into rw mode.
# Use this for maintenance, then run pi-ro.sh to re-enable protection.
#
# Usage: ./scripts/pi-rw.sh

set -euo pipefail

PI_HOST="${PI_FLAG_CAM_HOST:-pi-flag-cam.local}"
PI_USER="${PI_FLAG_CAM_USER:-aarzner}"

echo "=== Switching Pi to read-write mode ==="

# Check if overlay is active
if ssh -o ConnectTimeout=10 "${PI_USER}@${PI_HOST}" 'grep -q "overlayroot=tmpfs" /proc/cmdline'; then
    echo "Overlay is active. Removing overlayroot=tmpfs from cmdline and rebooting..."
    ssh "${PI_USER}@${PI_HOST}" '
        sudo mount -o remount,rw /boot/firmware
        sudo sed -i "s/overlayroot=tmpfs *//" /boot/firmware/cmdline.txt
        sudo mount -o remount,ro /boot/firmware 2>/dev/null || true
        # Unmask remount-fs (needed in RW mode for swap/zram setup)
        sudo systemctl unmask systemd-remount-fs.service 2>/dev/null || true
    '
    ssh "${PI_USER}@${PI_HOST}" 'sudo reboot' 2>/dev/null || true
    echo "Rebooting into rw mode. Waiting..."
    sleep 5
    for i in $(seq 1 24); do
        ssh -o ConnectTimeout=5 "${PI_USER}@${PI_HOST}" 'echo "Pi is up in rw mode"' 2>/dev/null && break
        echo "  waiting... ($i)"
        sleep 5
    done
else
    echo "Overlay is not active. Pi is already in rw mode."
fi
