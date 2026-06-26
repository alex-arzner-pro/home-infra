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

# Step 3: Soften the watchdog, hold kernels, then upgrade gently.
# On the single-core Zero W, apt's CPU/IO + WiFi RX burst can (a) make systemd
# miss a watchdog pet -> false hard-reset, and (b) trip udp_fail_queue_rcv_skb
# memory-pressure oopses. Mitigations: watchdog off during apt, a download
# rate-limit, and low CPU/IO priority (coherent_pool=8M + rmem from optimize-pi
# help too). The kernel is held so a new kernel can't desync the overlay
# initramfs (also avoids pulling a cross-arch ARMv7 kernel onto this ARMv6 Pi).
echo
echo "--- Disabling watchdog for the upgrade window ---"
ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" '
    sudo sed -i "s/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=0/" /etc/systemd/system.conf
    sudo systemctl daemon-reexec
'
echo "--- Running apt upgrade (kernel held, rate-limited, low priority) ---"
ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" '
    set -e
    sudo apt-mark hold raspberrypi-kernel raspberrypi-bootloader linux-image-rpi-v6 linux-image-rpi-v7 2>/dev/null || true
    sudo apt-get update -qq
    # Upgrade glibc + dpkg FIRST, in their own tiny batch: replacing libc under a
    # running dpkg is the segfault-prone step. If dpkg segfaults here, reboot the
    # Pi (fresh libc) and re-run this script — dpkg --configure -a then succeeds.
    sudo nice -n19 ionice -c3 sh -c "DEBIAN_FRONTEND=noninteractive apt-get -y -o Acquire::http::Dl-Limit=450 -o Dpkg::Use-Pty=0 install --only-upgrade libc6 dpkg" || true
    # Then the rest of the upgrade.
    sudo nice -n19 ionice -c3 sh -c "DEBIAN_FRONTEND=noninteractive apt-get -y -o Acquire::http::Dl-Limit=450 -o Dpkg::Use-Pty=0 upgrade"
    sudo apt-get -y autoremove
    echo "Update complete"
'
echo "--- Restoring watchdog (30s) ---"
ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" '
    sudo sed -i "s/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=30s/" /etc/systemd/system.conf
'

# Step 4: Switch back to ro mode (pi-ro.sh verifies overlay re-engaged).
echo
"${SCRIPT_DIR}/pi-ro.sh"

echo
echo "=== Update complete ==="
