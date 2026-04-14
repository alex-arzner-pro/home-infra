#!/usr/bin/env bash
# Pi Flag Cam — WiFi watchdog
# Checks if WiFi is connected by pinging the gateway.
# If unreachable, restarts the wlan0 interface.
# Run via cron every 2 minutes.

GATEWAY=$(ip route | awk '/default/{print $3; exit}')

if [ -z "$GATEWAY" ]; then
    logger -t wifi-watchdog "No default gateway found, restarting wlan0"
    ip link set wlan0 down
    sleep 2
    ip link set wlan0 up
    exit 1
fi

if ! ping -c 2 -W 5 "$GATEWAY" > /dev/null 2>&1; then
    logger -t wifi-watchdog "Gateway $GATEWAY unreachable, restarting wlan0"
    ip link set wlan0 down
    sleep 2
    ip link set wlan0 up
else
    # WiFi is fine, nothing to do
    exit 0
fi
