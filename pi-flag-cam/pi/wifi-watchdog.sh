#!/usr/bin/env bash
# Pi Flag Cam — WiFi watchdog (run via cron every 2 minutes)
# Pings the default gateway. Only recovers wlan0 after N CONSECUTIVE failures,
# and tries a soft NetworkManager reconnect before a hard ip-link bounce (a
# hard bounce can itself provoke a brcmfmac firmware reinit). Verifies L3
# recovered before clearing the failure counter.

STATE=/run/wifi-watchdog.fails
THRESHOLD=2

gw() { ip route | awk '/default/{print $3; exit}'; }
reachable() {
    local g; g=$(gw)
    [ -n "$g" ] && ping -c 2 -W 5 "$g" >/dev/null 2>&1
}

if reachable; then
    rm -f "$STATE"
    exit 0
fi

# Count consecutive failures across cron invocations.
fails=1
[ -f "$STATE" ] && fails=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$STATE"
logger -t wifi-watchdog "Gateway unreachable (failure ${fails}/${THRESHOLD})"
[ "$fails" -lt "$THRESHOLD" ] && exit 0

# Threshold reached — recover. Prefer a soft reconnect; fall back to a bounce.
logger -t wifi-watchdog "Recovering wlan0"
if ! nmcli device reconnect wlan0 >/dev/null 2>&1; then
    ip link set wlan0 down
    sleep 2
    ip link set wlan0 up
fi
# Re-assert power-save off after any reassociation.
iw dev wlan0 set power_save off 2>/dev/null || true

sleep 5
if reachable; then
    rm -f "$STATE"
    logger -t wifi-watchdog "wlan0 recovered"
else
    logger -t wifi-watchdog "wlan0 still down after recovery attempt"
fi
