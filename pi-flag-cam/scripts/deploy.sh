#!/usr/bin/env bash
# Pi Flag Cam — Deploy server and configs to Raspberry Pi
# Run from the local machine: ./scripts/deploy.sh
#
# Handles both modes:
# - Normal (rw): install, enable, (re)start, verify.
# - Overlayfs active: write to the lower (real) fs, enable units offline via
#   `systemctl --root`, install the cron into the lower fs, then reboot to apply.
#
# Camera is ON-DEMAND: we enable ustreamer.socket (not ustreamer.service, and
# not ustreamer-proxy.service which the socket activates).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PI_DEPLOY_DIR="/home/${PI_USER}/pi-flag-cam"

pi_ssh() { ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" "$@"; }

echo "=== Pi Flag Cam — Deploy ==="
echo "Target: ${PI_USER}@${PI_HOST}"
echo

if ! pi_ssh true 2>/dev/null; then
    echo "ERROR: Pi unreachable at ${PI_USER}@${PI_HOST}" >&2
    exit 1
fi

OVERLAY=false
if pi_ssh 'grep -q "overlayroot=tmpfs" /proc/cmdline'; then
    OVERLAY=true
    LOWER=/media/root-ro
    echo "NOTE: overlayfs active — writing to lower fs ${LOWER}"
    pi_ssh 'sudo mount -o remount,rw /media/root-ro'
    # Always re-seal the lower fs, even on mid-deploy failure.
    trap 'ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" "sudo mount -o remount,ro /media/root-ro" 2>/dev/null || true' EXIT
else
    LOWER=""
fi
echo

echo "--- Syncing pi/ files ---"
rsync -az --delete -e "ssh ${SSH_OPTS[*]}" \
    "${PROJECT_DIR}/pi/" "${PI_USER}@${PI_HOST}:${LOWER}${PI_DEPLOY_DIR}/"
echo

echo "--- Installing configs, units, cron ---"
pi_ssh "sudo env LOWER='${LOWER}' DEPLOY='${PI_DEPLOY_DIR}' PI_USER='${PI_USER}' OVERLAY='${OVERLAY}' bash -s" <<'REMOTE'
set -e
C="${LOWER}${DEPLOY}/config"

# systemd units
for u in pi-flag-cam.service ustreamer.service ustreamer.socket ustreamer-proxy.service \
         zram-swap.service crash-monitor.service; do
    cp "${C}/${u}" "${LOWER}/etc/systemd/system/${u}"
done
# modprobe (blacklist + brcmfmac stability)
cp "${C}/modprobe-blacklist.conf" "${LOWER}/etc/modprobe.d/pi-flag-cam-blacklist.conf"
cp "${C}/brcmfmac.conf"           "${LOWER}/etc/modprobe.d/brcmfmac.conf"
# udev rules
rm -f "${LOWER}/etc/udev/rules.d/10-luxafor.rules"
cp "${C}/99-luxafor.rules"        "${LOWER}/etc/udev/rules.d/99-luxafor.rules"
cp "${C}/70-wifi-powersave.rules" "${LOWER}/etc/udev/rules.d/70-wifi-powersave.rules"
# ssh keepalive
mkdir -p "${LOWER}/etc/ssh/sshd_config.d"
cp "${C}/sshd_keepalive.conf"     "${LOWER}/etc/ssh/sshd_config.d/pi-flag-cam.conf"
# journald (volatile)
mkdir -p "${LOWER}/etc/systemd/journald.conf.d"
cp "${C}/journald-pi-flag-cam.conf" "${LOWER}/etc/systemd/journald.conf.d/pi-flag-cam.conf"
# NetworkManager: durable wifi power-save off
mkdir -p "${LOWER}/etc/NetworkManager/conf.d"
cp "${C}/wifi-powersave-nm.conf"  "${LOWER}/etc/NetworkManager/conf.d/wifi-powersave.conf"
# sysctl: memory-pressure tuning
cp "${C}/99-pi-flag-cam-sysctl.conf" "${LOWER}/etc/sysctl.d/99-pi-flag-cam.conf"
# executable helper scripts
chmod +x "${LOWER}${DEPLOY}/wifi-watchdog.sh" "${LOWER}${DEPLOY}/crash-monitor.sh"

# wifi-watchdog cron (root) — install identically in both modes
install_cron() {
    local cron="$1"
    { [ -f "$cron" ] && grep -v wifi-watchdog "$cron" || true; \
      echo "*/2 * * * * ${DEPLOY}/wifi-watchdog.sh"; } > "${cron}.tmp"
    mv "${cron}.tmp" "$cron"
    chmod 600 "$cron"
}

# Units to enable. NOT ustreamer.service (on-demand) nor ustreamer-proxy.service
# (socket-activated). ustreamer.socket goes to sockets.target.
ENABLE="pi-flag-cam.service ustreamer.socket zram-swap.service crash-monitor.service"

if [ "$OVERLAY" = true ]; then
    # Migrate off the old always-on ustreamer.service (now socket-activated).
    systemctl --root="${LOWER}" disable ustreamer.service 2>/dev/null || true
    systemctl --root="${LOWER}" enable $ENABLE
    mkdir -p "${LOWER}/var/spool/cron/crontabs"
    install_cron "${LOWER}/var/spool/cron/crontabs/${PI_USER}"
    chown 0:crontab "${LOWER}/var/spool/cron/crontabs/${PI_USER}" 2>/dev/null || true
    echo "Configs, units, cron installed to lower fs."
else
    systemctl daemon-reload
    # Migrate off the old always-on ustreamer.service (now socket-activated).
    systemctl disable --now ustreamer.service 2>/dev/null || true
    systemctl enable $ENABLE
    install_cron "/var/spool/cron/crontabs/${PI_USER}"
    chown 0:crontab "/var/spool/cron/crontabs/${PI_USER}" 2>/dev/null || true
    udevadm control --reload-rules && udevadm trigger || true
    sysctl --system >/dev/null 2>&1 || true
    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    systemctl restart pi-flag-cam.service zram-swap.service crash-monitor.service
    systemctl restart ustreamer.socket
    sleep 2
    rc=0
    for u in pi-flag-cam.service ustreamer.socket zram-swap.service crash-monitor.service; do
        if systemctl is-active --quiet "$u"; then echo "${u}: running"; else echo "${u}: FAILED"; rc=1; fi
    done
    exit $rc
fi
REMOTE

if [ "$OVERLAY" = true ]; then
    pi_ssh 'sudo mount -o remount,ro /media/root-ro' || true
    trap - EXIT
    echo
    echo "=== Deploy complete (overlay mode) ==="
    echo "Reboot to apply:  ssh ${PI_USER}@${PI_HOST} sudo reboot"
else
    echo
    echo "=== Deploy complete ==="
    echo "Verify: ./scripts/test.sh"
fi
