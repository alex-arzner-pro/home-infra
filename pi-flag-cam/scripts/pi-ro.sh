#!/usr/bin/env bash
# Pi Flag Cam — Switch Pi to read-only mode (enable overlayfs)
# Re-enables overlayfs protection and reboots.
#
# Usage: ./scripts/pi-ro.sh

set -euo pipefail

PI_HOST="${PI_FLAG_CAM_HOST:-pi-flag-cam.local}"
PI_USER="${PI_FLAG_CAM_USER:-aarzner}"

echo "=== Switching Pi to read-only mode ==="

# Check if overlay is already active
if ssh -o ConnectTimeout=10 "${PI_USER}@${PI_HOST}" 'grep -q "overlayroot=tmpfs" /proc/cmdline'; then
    echo "Overlay is already active. Nothing to do."
    exit 0
fi

# Add overlayroot=tmpfs to cmdline
ssh "${PI_USER}@${PI_HOST}" '
    # Ensure boot partition is writable
    sudo mount -o remount,rw /boot/firmware

    if grep -q "overlayroot=tmpfs" /boot/firmware/cmdline.txt; then
        echo "overlayroot=tmpfs already in cmdline.txt"
    else
        sudo sed -i "s/^/overlayroot=tmpfs /" /boot/firmware/cmdline.txt
        echo "Added overlayroot=tmpfs to cmdline.txt"
    fi

    # Also make boot partition read-only in fstab
    if grep -q "/boot/firmware.*defaults,ro" /etc/fstab; then
        echo "Boot partition already ro in fstab"
    else
        sudo sed -i "s|\(.*/boot/firmware.*\)defaults\(.*\)|\1defaults,ro\2|" /etc/fstab
        echo "Boot partition set to ro in fstab"
    fi

    # Mask systemd-remount-fs — it cannot remount overlayfs root and
    # causes cascading failures (no swap, repeated restart loops)
    sudo systemctl mask systemd-remount-fs.service
    echo "Masked systemd-remount-fs (incompatible with overlayfs)"

    sudo mount -o remount,ro /boot/firmware 2>/dev/null || true
'

echo "Rebooting into read-only mode..."
ssh "${PI_USER}@${PI_HOST}" 'sudo reboot' 2>/dev/null || true
sleep 5
for i in $(seq 1 24); do
    ssh -o ConnectTimeout=5 "${PI_USER}@${PI_HOST}" 'echo "Pi is up in ro mode"' 2>/dev/null && break
    echo "  waiting... ($i)"
    sleep 5
done

echo
echo "Verifying overlay is active..."
ssh "${PI_USER}@${PI_HOST}" '
    if grep -q "overlayroot=tmpfs" /proc/cmdline; then
        echo "SUCCESS: overlayfs is active"
        mount | grep "on / " | head -1
    else
        echo "WARNING: overlayfs NOT active — check boot config"
    fi
'
