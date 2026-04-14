#!/bin/sh
# Pi Flag Cam — Crash monitor
# Logs system state to boot partition every 30s.
# Boot partition survives overlayfs reboot — we can read what happened before crash.
# Run as: /home/aarzner/pi-flag-cam/crash-monitor.sh &
# Or via systemd service.

LOG="/boot/firmware/crash-monitor.log"
LAST_DMESG_LINE=0
MAX_LOG_SIZE=102400  # 100KB, rotate when exceeded

# Ensure boot partition is writable (may be ro in overlay mode)
mount -o remount,rw /boot/firmware 2>/dev/null

while true; do
    # Rotate log if too large
    if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
        tail -200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi

    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    UPTIME=$(awk '{printf "%.0f", $1}' /proc/uptime)
    LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg)
    MEM=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
    SWAP=$(awk '/SwapFree/{printf "%d", $2/1024}' /proc/meminfo)
    TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "?")
    THROTTLE=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "?")

    # WiFi
    WIFI_QUAL=$(awk '/wlan0/{print $3}' /proc/net/wireless 2>/dev/null | tr -d '.')
    WIFI_RSSI=$(awk '/wlan0/{print $4}' /proc/net/wireless 2>/dev/null | tr -d '.')
    WIFI_STATE="?"
    ip link show wlan0 2>/dev/null | grep -q "state UP" && WIFI_STATE="UP" || WIFI_STATE="DOWN"

    # New dmesg errors since last check
    CURRENT_DMESG_LINES=$(dmesg 2>/dev/null | wc -l)
    NEW_ERRORS=""
    if [ "$CURRENT_DMESG_LINES" -gt "$LAST_DMESG_LINE" ]; then
        NEW_ERRORS=$(dmesg 2>/dev/null | tail -n +"$((LAST_DMESG_LINE + 1))" | grep -iE "error|fail|oom|panic|killed|watchdog|brcm.*err|usb.*err" | tail -5)
    fi
    LAST_DMESG_LINE=$CURRENT_DMESG_LINES

    # Write log line
    {
        printf "[%s] up=%ss load=%s mem=%sMi swap=%sMi temp=%sC throttle=%s wifi=%s/%s/%sdBm" \
            "$NOW" "$UPTIME" "$LOAD" "$MEM" "$SWAP" "$TEMP" "$THROTTLE" "$WIFI_STATE" "$WIFI_QUAL" "$WIFI_RSSI"
        if [ -n "$NEW_ERRORS" ]; then
            printf " ERRORS: %s" "$(echo "$NEW_ERRORS" | tr '\n' '|')"
        fi
        printf "\n"
    } >> "$LOG" 2>/dev/null

    sleep 30
done
