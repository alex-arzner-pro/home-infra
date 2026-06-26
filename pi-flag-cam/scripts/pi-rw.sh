#!/usr/bin/env bash
# Pi Flag Cam — Switch Pi to read-write mode
# Temporarily disables overlayfs and reboots into rw mode.
# Use this for maintenance, then run pi-ro.sh to re-enable protection.
#
# Usage: ./scripts/pi-rw.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Fail fast if the Pi is unreachable, so we never mistake "unreachable" for
# "overlay inactive" (the old code conflated ssh-failure with grep-no-match).
if ! ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" true 2>/dev/null; then
    echo "ERROR: Pi unreachable at ${PI_USER}@${PI_HOST}" >&2
    exit 1
fi

echo "=== Switching Pi to read-write mode ==="

if ! ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'grep -q "overlayroot=tmpfs" /proc/cmdline'; then
    echo "Overlay is not active. Verifying root is actually writable..."
    if ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'findmnt -no OPTIONS / | grep -qw rw'; then
        echo "Pi is already in rw mode."
        exit 0
    fi
    echo "Overlay off but root is read-only; remounting / rw..."
    ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'sudo mount -o remount,rw /' \
        || { echo "ERROR: failed to remount / rw" >&2; exit 1; }
    echo "SUCCESS: root remounted rw."
    exit 0
fi

echo "Overlay is active. Disabling overlay + persistently unmasking remount-fs..."
ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" '
    set -e
    # 1) Remove overlayroot=tmpfs from cmdline (boot partition is persistent).
    sudo mount -o remount,rw /boot/firmware
    sudo sed -i "s/overlayroot=tmpfs *//" /boot/firmware/cmdline.txt
    sudo mount -o remount,ro /boot/firmware 2>/dev/null || true
    # 2) Unmask systemd-remount-fs in the LOWER (persistent) fs, NOT the live
    #    overlay tmpfs. A "systemctl unmask" here would only write a whiteout
    #    to the upper tmpfs and be discarded on reboot, leaving root read-only
    #    (this was the core RO-after-pi-rw bug). Editing the lower layer makes
    #    the unmask survive the reboot. Mirrors deploy.sh overlay handling.
    sudo mount -o remount,rw /media/root-ro
    sudo rm -f /media/root-ro/etc/systemd/system/systemd-remount-fs.service
    sudo mount -o remount,ro /media/root-ro 2>/dev/null || true
'

echo "Rebooting into rw mode..."
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

# The whole point of this script: prove root is actually writable now.
if ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'findmnt -no OPTIONS / | grep -qw rw'; then
    echo "SUCCESS: Pi is in rw mode (root is writable)."
else
    echo "ERROR: Pi rebooted but root is still read-only." >&2
    echo "  Recovery: ssh ${PI_USER}@${PI_HOST} 'sudo mount -o remount,rw /'" >&2
    exit 1
fi
