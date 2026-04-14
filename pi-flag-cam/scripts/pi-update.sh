#!/usr/bin/env bash
# Pi Flag Cam — Update Pi system packages
# Temporarily switches to rw mode, runs apt upgrade, then re-enables ro mode.
#
# Usage: ./scripts/pi-update.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PI_HOST="${PI_FLAG_CAM_HOST:-pi-flag-cam.local}"
PI_USER="${PI_FLAG_CAM_USER:-aarzner}"

echo "=== Pi Flag Cam — System Update ==="

# Step 1: Switch to rw mode
"${SCRIPT_DIR}/pi-rw.sh"

# Step 2: Run updates
echo
echo "--- Running apt upgrade ---"
ssh "${PI_USER}@${PI_HOST}" '
    sudo apt-get update -qq
    sudo apt-get upgrade -y
    sudo apt-get autoremove -y
    echo "Update complete"
'

# Step 3: Switch back to ro mode
echo
"${SCRIPT_DIR}/pi-ro.sh"

echo
echo "=== Update complete ==="
