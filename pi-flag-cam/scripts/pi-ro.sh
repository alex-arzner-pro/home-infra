#!/usr/bin/env bash
# Pi Flag Cam — Switch Pi to read-only mode (enable overlayfs)
# Re-enables overlayfs protection and reboots.
#
# Usage: ./scripts/pi-ro.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if ! ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" true 2>/dev/null; then
    echo "ERROR: Pi unreachable at ${PI_USER}@${PI_HOST}" >&2
    exit 1
fi

echo "=== Switching Pi to read-only mode ==="

if ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'grep -q "overlayroot=tmpfs" /proc/cmdline'; then
    if ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'findmnt -no FSTYPE / | grep -q overlay'; then
        echo "Already in read-only (overlay) mode. Nothing to do."
        exit 0
    fi
    echo "cmdline has overlayroot but root is not overlay yet; rebooting to apply."
else
    echo "Enabling overlay (cmdline + fstab + mask remount-fs)..."
    ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" '
        set -e
        sudo mount -o remount,rw /boot/firmware
        if grep -q "overlayroot=tmpfs" /boot/firmware/cmdline.txt; then
            echo "overlayroot=tmpfs already in cmdline.txt"
        else
            sudo sed -i "s/^/overlayroot=tmpfs /" /boot/firmware/cmdline.txt
            echo "Added overlayroot=tmpfs to cmdline.txt"
        fi
        if grep -q "/boot/firmware.*defaults,ro" /etc/fstab; then
            echo "Boot partition already ro in fstab"
        else
            sudo sed -i "s|\(.*/boot/firmware.*\)defaults\(.*\)|\1defaults,ro\2|" /etc/fstab
            echo "Boot partition set to ro in fstab"
        fi
        # Mask systemd-remount-fs: it cannot remount an overlayfs root and its
        # failure cascades. Overlay is currently OFF, so this symlink lands in
        # the real (lower) fs — pi-rw.sh removes it from the SAME layer, keeping
        # mask/unmask symmetric and reversible.
        sudo systemctl mask systemd-remount-fs.service
        echo "Masked systemd-remount-fs (incompatible with overlayfs)"
        sudo mount -o remount,ro /boot/firmware 2>/dev/null || true
    '
fi

echo "Rebooting into read-only mode..."
ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'sudo reboot' 2>/dev/null || true

sleep 5
up=""
for i in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${PI_USER}@${PI_HOST}" true 2>/dev/null; then up=1; break; fi
    echo "  waiting for reboot... ($i)"
    sleep 5
done
if [ -z "$up" ]; then
    echo "ERROR: Pi did not come back after reboot" >&2
    exit 1
fi

echo "Verifying overlay is active..."
if ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'grep -q "overlayroot=tmpfs" /proc/cmdline && findmnt -no FSTYPE / | grep -q overlay'; then
    echo "SUCCESS: overlayfs is active (root is overlay; writes go to tmpfs)."
    ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'findmnt -no SOURCE,FSTYPE,OPTIONS /' || true
else
    echo "WARNING: overlayfs NOT active — check boot config." >&2
    exit 1
fi
