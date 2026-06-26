#!/usr/bin/env bash
# Pi Flag Cam — Update Pi system packages
# Temporarily switches to rw mode, runs apt upgrade, then re-enables ro mode.
#
# The kernel/bootloader are held (apt-mark hold) so an upgrade can never install
# a new kernel that would desync from the overlay initramfs and fail to boot a
# headless device. To intentionally move the kernel: unhold, then rebuild the
# overlay initramfs for the new kernel and copy it to /boot/firmware/initramfs
# (see optimize-pi.sh Phase 1.8 and README).
#
# Usage: ./scripts/pi-update.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "=== Pi Flag Cam — System Update ==="

# Step 1: Switch to rw mode (pi-rw.sh now asserts root is actually writable).
"${SCRIPT_DIR}/pi-rw.sh"

# Step 2: Assert RW before touching apt (defense in depth — a read-only root
# would let apt fail silently / half-apply).
echo
echo "--- Verifying root is writable ---"
if ! ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" 'findmnt -no OPTIONS / | grep -qw rw'; then
    echo "ERROR: root is not writable after pi-rw; aborting before apt." >&2
    exit 1
fi

# Step 3: Hold the kernel/bootloader, then upgrade.
echo
echo "--- Running apt upgrade (kernel held) ---"
ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" '
    set -e
    # Pin kernel + bootloader so the overlay initramfs never silently desyncs.
    # Package names vary across RPi OS releases; hold all plausible ones.
    sudo apt-mark hold raspberrypi-kernel raspberrypi-bootloader linux-image-rpi-v6 linux-image-rpi-v7 2>/dev/null || true
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    sudo apt-get -y autoremove
    echo "Update complete"
'

# Step 4: Switch back to ro mode (pi-ro.sh verifies overlay re-engaged).
echo
"${SCRIPT_DIR}/pi-ro.sh"

echo
echo "=== Update complete ==="
