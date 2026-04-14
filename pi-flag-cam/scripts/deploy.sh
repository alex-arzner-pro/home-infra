#!/usr/bin/env bash
# Pi Flag Cam — Deploy server and configs to Raspberry Pi
# Run from the local machine: ./scripts/deploy.sh
#
# Handles both normal and overlayfs modes:
# - Normal: writes directly to the filesystem
# - Overlayfs active: writes to the lower (real) filesystem via overlayroot-chroot

set -euo pipefail

PI_HOST="${PI_FLAG_CAM_HOST:-pi-flag-cam.local}"
PI_USER="${PI_FLAG_CAM_USER:-aarzner}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PI_DEPLOY_DIR="/home/${PI_USER}/pi-flag-cam"

echo "=== Pi Flag Cam — Deploy ==="
echo "Target: ${PI_USER}@${PI_HOST}"
echo

# Check if overlayfs is active
OVERLAY_ACTIVE=false
if ssh -o ConnectTimeout=10 "${PI_USER}@${PI_HOST}" 'grep -q "overlayroot=tmpfs" /proc/cmdline' 2>/dev/null; then
    OVERLAY_ACTIVE=true
    echo "NOTE: Overlayfs is active — deploying to lower filesystem"
    echo
fi

if [ "$OVERLAY_ACTIVE" = true ]; then
    # --- Overlay mode: write directly to the lower (real) filesystem ---
    # The real root is mounted read-only at /media/root-ro/
    LOWER="/media/root-ro"

    echo "--- Remounting lower filesystem as rw ---"
    ssh "${PI_USER}@${PI_HOST}" 'sudo mount -o remount,rw /media/root-ro'

    echo "--- Syncing files to lower filesystem ---"
    rsync -avz --delete \
        "${PROJECT_DIR}/pi/" \
        "${PI_USER}@${PI_HOST}:${LOWER}${PI_DEPLOY_DIR}/"
    echo

    echo "--- Installing configs to lower filesystem ---"
    ssh "${PI_USER}@${PI_HOST}" "
        # Systemd services
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/pi-flag-cam.service ${LOWER}/etc/systemd/system/pi-flag-cam.service
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/ustreamer.service ${LOWER}/etc/systemd/system/ustreamer.service
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/zram-swap.service ${LOWER}/etc/systemd/system/zram-swap.service
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/crash-monitor.service ${LOWER}/etc/systemd/system/crash-monitor.service
        # Modprobe configs (blacklist + brcmfmac stability)
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/modprobe-blacklist.conf ${LOWER}/etc/modprobe.d/pi-flag-cam-blacklist.conf
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/brcmfmac.conf ${LOWER}/etc/modprobe.d/brcmfmac.conf
        # Udev rules
        sudo rm -f ${LOWER}/etc/udev/rules.d/10-luxafor.rules
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/99-luxafor.rules ${LOWER}/etc/udev/rules.d/99-luxafor.rules
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/70-wifi-powersave.rules ${LOWER}/etc/udev/rules.d/70-wifi-powersave.rules
        # SSH keepalive
        sudo mkdir -p ${LOWER}/etc/ssh/sshd_config.d
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/sshd_keepalive.conf ${LOWER}/etc/ssh/sshd_config.d/pi-flag-cam.conf
        # Journald
        sudo mkdir -p ${LOWER}/etc/systemd/journald.conf.d
        sudo cp ${LOWER}${PI_DEPLOY_DIR}/config/journald-pi-flag-cam.conf ${LOWER}/etc/systemd/journald.conf.d/pi-flag-cam.conf
        # WiFi watchdog + crash monitor
        sudo chmod +x ${LOWER}${PI_DEPLOY_DIR}/wifi-watchdog.sh
        sudo chmod +x ${LOWER}${PI_DEPLOY_DIR}/crash-monitor.sh
        echo 'Configs installed to lower filesystem'
    "

    echo "--- Remounting lower filesystem as ro ---"
    ssh "${PI_USER}@${PI_HOST}" 'sudo mount -o remount,ro /media/root-ro'

    echo
    echo "=== Deploy complete (overlay mode) ==="
    echo "Changes written to lower filesystem. Reboot to apply:"
    echo "  ssh ${PI_USER}@${PI_HOST} sudo reboot"

else
    # --- Normal mode: write directly ---

    echo "--- Syncing files ---"
    rsync -avz --delete \
        "${PROJECT_DIR}/pi/" \
        "${PI_USER}@${PI_HOST}:${PI_DEPLOY_DIR}/"
    echo

    echo "--- Installing systemd services ---"
    ssh "${PI_USER}@${PI_HOST}" "
        sudo cp ${PI_DEPLOY_DIR}/config/pi-flag-cam.service /etc/systemd/system/pi-flag-cam.service
        sudo cp ${PI_DEPLOY_DIR}/config/ustreamer.service /etc/systemd/system/ustreamer.service
        sudo cp ${PI_DEPLOY_DIR}/config/zram-swap.service /etc/systemd/system/zram-swap.service
        sudo systemctl daemon-reload
        echo 'Systemd units installed'
    "

    echo "--- Installing WiFi watchdog ---"
    ssh "${PI_USER}@${PI_HOST}" "
        chmod +x ${PI_DEPLOY_DIR}/wifi-watchdog.sh
        CRON_LINE='*/2 * * * * ${PI_DEPLOY_DIR}/wifi-watchdog.sh'
        (sudo crontab -l 2>/dev/null | grep -v wifi-watchdog; echo \"\$CRON_LINE\") | sudo crontab -
        echo 'WiFi watchdog cron installed'
    "

    echo "--- Installing udev rules ---"
    ssh "${PI_USER}@${PI_HOST}" "
        sudo rm -f /etc/udev/rules.d/10-luxafor.rules
        sudo cp ${PI_DEPLOY_DIR}/config/99-luxafor.rules /etc/udev/rules.d/99-luxafor.rules
        sudo cp ${PI_DEPLOY_DIR}/config/70-wifi-powersave.rules /etc/udev/rules.d/70-wifi-powersave.rules
        sudo udevadm control --reload-rules
        sudo udevadm trigger
        echo 'Udev rules installed'
    "

    echo "--- Installing SSH keepalive + journald ---"
    ssh "${PI_USER}@${PI_HOST}" "
        sudo mkdir -p /etc/ssh/sshd_config.d
        sudo cp ${PI_DEPLOY_DIR}/config/sshd_keepalive.conf /etc/ssh/sshd_config.d/pi-flag-cam.conf
        sudo mkdir -p /etc/systemd/journald.conf.d
        sudo cp ${PI_DEPLOY_DIR}/config/journald-pi-flag-cam.conf /etc/systemd/journald.conf.d/pi-flag-cam.conf
        sudo systemctl reload ssh
        echo 'SSH keepalive configured'
    "

    echo "--- Installing crash monitor ---"
    ssh "${PI_USER}@${PI_HOST}" "
        chmod +x ${PI_DEPLOY_DIR}/crash-monitor.sh
        sudo cp ${PI_DEPLOY_DIR}/config/crash-monitor.service /etc/systemd/system/crash-monitor.service
        sudo systemctl daemon-reload
        echo 'Crash monitor installed'
    "

    echo "--- Installing modprobe configs ---"
    ssh "${PI_USER}@${PI_HOST}" "
        sudo cp ${PI_DEPLOY_DIR}/config/modprobe-blacklist.conf /etc/modprobe.d/pi-flag-cam-blacklist.conf
        sudo cp ${PI_DEPLOY_DIR}/config/brcmfmac.conf /etc/modprobe.d/brcmfmac.conf
        echo 'Modprobe configs installed (blacklist + brcmfmac stability)'
    "

    echo "--- Starting services ---"
    ssh "${PI_USER}@${PI_HOST}" "
        sudo systemctl enable pi-flag-cam.service ustreamer.service zram-swap.service crash-monitor.service
        sudo systemctl restart pi-flag-cam.service ustreamer.service crash-monitor.service
        sleep 2
        systemctl is-active pi-flag-cam.service && echo 'pi-flag-cam: running' || echo 'pi-flag-cam: FAILED'
        systemctl is-active ustreamer.service && echo 'ustreamer: running' || echo 'ustreamer: FAILED'
        systemctl is-active crash-monitor.service && echo 'crash-monitor: running' || echo 'crash-monitor: FAILED'
    "

    echo
    echo "=== Deploy complete ==="
    echo "Test:   curl http://${PI_HOST}:8080/health"
    echo "Stream: http://${PI_HOST}:8081/?action=stream"
fi
