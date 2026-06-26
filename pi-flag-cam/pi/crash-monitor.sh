#!/bin/sh
# Pi Flag Cam — Crash monitor
# Keeps a live status log in tmpfs (/run) and flushes a snapshot to the boot
# partition ONLY when a new dmesg error/oops appears (or hourly as a heartbeat).
# This avoids leaving the FAT /boot partition writable 24/7, which would defeat
# the SD-wear/corruption protection. The boot log survives reboots (journald
# here is volatile), so it remains the cross-reboot post-mortem record.

BOOT_LOG="/boot/firmware/crash-monitor.log"
RUN_LOG="/run/crash-monitor.log"
INTERVAL=300            # sample every 5 minutes
HEARTBEAT_EVERY=12      # force a boot-log flush every ~1h even without errors
MAX_BOOT_LOG=102400     # rotate boot log past 100KB

LAST_DMESG_LINE=0
HB=0

flush_to_boot() {
    # $1 = line to persist. remount rw -> (rotate) -> append -> sync -> remount ro.
    if ! mount -o remount,rw /boot/firmware; then
        logger -t crash-monitor "WARN: could not remount /boot/firmware rw — crash log not persisted"
        return 1
    fi
    if [ -f "$BOOT_LOG" ] && [ "$(stat -c%s "$BOOT_LOG" 2>/dev/null || echo 0)" -gt "$MAX_BOOT_LOG" ]; then
        tail -200 "$BOOT_LOG" > "${BOOT_LOG}.tmp" && mv "${BOOT_LOG}.tmp" "$BOOT_LOG"
    fi
    printf '%s\n' "$1" >> "$BOOT_LOG"
    sync
    mount -o remount,ro /boot/firmware 2>/dev/null || true
}

while true; do
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    UPTIME=$(awk '{printf "%.0f", $1}' /proc/uptime)
    LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg)
    MEM=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
    SWAP=$(awk '/SwapFree/{printf "%d", $2/1024}' /proc/meminfo)
    TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "?")
    THROTTLE=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "?")
    WIFI_QUAL=$(awk '/wlan0/{print $3}' /proc/net/wireless 2>/dev/null | tr -d '.')
    WIFI_RSSI=$(awk '/wlan0/{print $4}' /proc/net/wireless 2>/dev/null | tr -d '.')
    if ip link show wlan0 2>/dev/null | grep -q "state UP"; then WIFI_STATE="UP"; else WIFI_STATE="DOWN"; fi
    FAILED=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')

    # New dmesg errors since last sample.
    CUR=$(dmesg 2>/dev/null | wc -l)
    NEW_ERRORS=""
    if [ "$CUR" -gt "$LAST_DMESG_LINE" ]; then
        NEW_ERRORS=$(dmesg 2>/dev/null | tail -n +"$((LAST_DMESG_LINE + 1))" \
            | grep -iE "error|fail|oom|panic|killed|watchdog|oops|brcm.*err|usb.*err" | tail -5)
    fi
    LAST_DMESG_LINE=$CUR

    LINE="[$NOW] up=${UPTIME}s load=$LOAD mem=${MEM}Mi swap=${SWAP}Mi temp=${TEMP}C throttle=$THROTTLE wifi=$WIFI_STATE/$WIFI_QUAL/${WIFI_RSSI}dBm failed=${FAILED:-none}"
    [ -n "$NEW_ERRORS" ] && LINE="$LINE ERRORS: $(echo "$NEW_ERRORS" | tr '\n' '|')"

    # Live log in tmpfs is always current (read it for a quick health check).
    printf '%s\n' "$LINE" > "$RUN_LOG"

    HB=$((HB + 1))
    if [ -n "$NEW_ERRORS" ] || [ "$HB" -ge "$HEARTBEAT_EVERY" ]; then
        flush_to_boot "$LINE"
        HB=0
    fi

    sleep "$INTERVAL"
done
