#!/usr/bin/env bash
# Pi Flag Cam — shared configuration
# Sourced by every script in this directory. Not meant to be executed directly.
#
# Every value can be overridden from the environment, e.g.:
#   PI_FLAG_CAM_HOST=pi-flag-cam.local ./scripts/lux red
#
# PI_FLAG_CAM_HOST defaults to the Pi's LAN IP, which is pinned by a DHCP
# reservation on the MikroTik for the Pi's MAC (the address is outside the
# dynamic pool). The Pi itself stays on DHCP for resilience — there is
# intentionally NO Pi-side static NetworkManager profile (a manual profile
# proved incompatible with the overlayfs RO/RW model). The mDNS name
# pi-flag-cam.local also works — just export PI_FLAG_CAM_HOST.
PI_FLAG_CAM_HOST="${PI_FLAG_CAM_HOST:-192.168.86.7}"   # Pi hostname or IP
PI_FLAG_CAM_PORT="${PI_FLAG_CAM_PORT:-8080}"           # API server port
PI_FLAG_CAM_CAM_PORT="${PI_FLAG_CAM_CAM_PORT:-8081}"   # ustreamer (camera) port
PI_FLAG_CAM_USER="${PI_FLAG_CAM_USER:-aarzner}"        # SSH user on the Pi

# Short aliases used throughout the scripts.
PI_HOST="$PI_FLAG_CAM_HOST"
PI_PORT="$PI_FLAG_CAM_PORT"
PI_CAM_PORT="$PI_FLAG_CAM_CAM_PORT"
PI_USER="$PI_FLAG_CAM_USER"

# Shared SSH options so the repo is self-contained and never hangs on auth
# prompts. Use as: ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" ...
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

# LAN client allowed to reach the HTTP API / camera (systemd IPAddressAllow).
# This is the operator laptop (t14), pinned by its own DHCP reservation.
PI_FLAG_CAM_ALLOW_IP="${PI_FLAG_CAM_ALLOW_IP:-192.168.86.86}"
