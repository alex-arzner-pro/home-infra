#!/usr/bin/env bash
# Pi Flag Cam — Automated smoke tests
# Run from the local machine: ./scripts/test.sh

PI_HOST="${PI_FLAG_CAM_HOST:-pi-flag-cam.local}"
PI_USER="${PI_FLAG_CAM_USER:-aarzner}"
PI_PORT="${PI_FLAG_CAM_PORT:-8080}"
PI_CAM_PORT="${PI_FLAG_CAM_CAM_PORT:-8081}"
BASE="http://${PI_HOST}:${PI_PORT}"
CAM_BASE="http://${PI_HOST}:${PI_CAM_PORT}"

PASS=0
FAIL=0
TOTAL=0

check() {
    local name="$1"
    local result="$2"
    TOTAL=$((TOTAL + 1))
    if [ "$result" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "[PASS] $name"
    else
        FAIL=$((FAIL + 1))
        echo "[FAIL] $name"
    fi
}

echo "=== Pi Flag Cam — Smoke Tests ==="
echo "Target: ${PI_HOST}:${PI_PORT}"
echo

# 1. Pi connectivity
ping -c 1 -W 3 "$PI_HOST" > /dev/null 2>&1
check "Pi connectivity (ping)" $?

# 2. SSH access
ssh -o ConnectTimeout=5 "${PI_USER}@${PI_HOST}" 'echo ok' > /dev/null 2>&1
check "SSH access" $?

# 3. Service running
ssh -o ConnectTimeout=5 "${PI_USER}@${PI_HOST}" 'systemctl is-active pi-flag-cam' > /dev/null 2>&1
check "Service running (systemctl)" $?

# 4. Health endpoint
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "${BASE}/health" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Health endpoint (GET /health -> 200)" $?

# 5. Health JSON valid
HEALTH=$(curl -sf "${BASE}/health" 2>/dev/null)
echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='ok'" 2>/dev/null
check "Health JSON valid (status=ok)" $?

# 6. Luxafor off
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "${BASE}/lux/color/off" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Luxafor off" $?

# 7. Luxafor red
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "${BASE}/lux/color/red" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Luxafor red (check LED visually!)" $?
sleep 1

# 8. Luxafor RGB green
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "${BASE}/lux/rgb/0/255/0" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Luxafor RGB green (GET /lux/rgb/0/255/0)" $?
sleep 1

# 9. Luxafor off again
curl -sf "${BASE}/lux/color/off" > /dev/null 2>&1
check "Luxafor off (cleanup)" $?

# 10. ustreamer service running
ssh -o ConnectTimeout=5 "${PI_USER}@${PI_HOST}" 'systemctl is-active ustreamer' > /dev/null 2>&1
check "ustreamer service running" $?

# 11. Camera snapshot via ustreamer
TMP_IMG="/tmp/pi-flag-cam-test-snapshot.jpg"
rm -f "$TMP_IMG"
HTTP_CODE=$(curl -sf -o "$TMP_IMG" -w '%{http_code}' "${CAM_BASE}/?action=snapshot" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Camera snapshot (ustreamer -> 200)" $?

# 12. Snapshot is valid JPEG
if [ -f "$TMP_IMG" ]; then
    SIZE=$(stat -c%s "$TMP_IMG" 2>/dev/null || echo 0)
    MAGIC=$(xxd -l 2 -p "$TMP_IMG" 2>/dev/null)
    [ "$SIZE" -gt 1024 ] && [ "$MAGIC" = "ffd8" ]
    check "Snapshot valid JPEG (${SIZE} bytes, magic=${MAGIC})" $?
else
    check "Snapshot valid JPEG (file missing)" 1
fi

# 13. Stream endpoint responds (check first bytes of MJPEG stream)
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 3 "${CAM_BASE}/?action=stream" 2>/dev/null || true)
[ "$HTTP_CODE" = "200" ]
check "Video stream responds (ustreamer)" $?

# 14. Invalid endpoint returns 404
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/nonexistent" 2>/dev/null)
[ "$HTTP_CODE" = "404" ]
check "404 for unknown endpoint" $?

echo
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || echo "Some tests failed."

# Cleanup
rm -f "$TMP_IMG"

exit "$FAIL"
