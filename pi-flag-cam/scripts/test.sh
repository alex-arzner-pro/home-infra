#!/usr/bin/env bash
# Pi Flag Cam — Automated smoke tests
# Run from the local machine: ./scripts/test.sh
# Camera tests are skipped automatically if no camera is connected (on-demand).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
BASE="http://${PI_HOST}:${PI_PORT}"
CAM_BASE="http://${PI_HOST}:${PI_CAM_PORT}"

PASS=0; FAIL=0; SKIP=0; TOTAL=0
check() {
    TOTAL=$((TOTAL + 1))
    if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); echo "[PASS] $1"; else FAIL=$((FAIL + 1)); echo "[FAIL] $1"; fi
}
skip() { SKIP=$((SKIP + 1)); echo "[SKIP] $1"; }
ssh_pi() { ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" "$@"; }

echo "=== Pi Flag Cam — Smoke Tests ==="
echo "Target: ${PI_HOST}:${PI_PORT}"
echo

ping -c 1 -W 3 "$PI_HOST" > /dev/null 2>&1
check "Pi connectivity (ping)" $?

ssh_pi 'echo ok' > /dev/null 2>&1
check "SSH access" $?

ssh_pi 'systemctl is-active pi-flag-cam' > /dev/null 2>&1
check "pi-flag-cam service active" $?

HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "${BASE}/health" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Health endpoint (GET /health -> 200)" $?

HEALTH=$(curl -sf "${BASE}/health" 2>/dev/null)
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin)['status']=='ok'" 2>/dev/null
check "Health JSON valid (status=ok)" $?

HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "${BASE}/lux/color/off" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Luxafor off" $?

HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "${BASE}/lux/color/red" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Luxafor red (check LED visually!)" $?
sleep 1

HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' "${BASE}/lux/rgb/0/255/0" 2>/dev/null)
[ "$HTTP_CODE" = "200" ]
check "Luxafor RGB green (GET /lux/rgb/0/255/0)" $?
sleep 1

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/lux/rgb/0/0/999" 2>/dev/null)
[ "$HTTP_CODE" = "400" ]
check "Out-of-range RGB rejected (-> 400)" $?

curl -sf "${BASE}/lux/color/off" > /dev/null 2>&1
check "Luxafor off (cleanup)" $?

# --- Camera (on-demand): only exercise it if a camera is actually connected ---
CAM_CONNECTED=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('camera_connected'))" 2>/dev/null)
if [ "$CAM_CONNECTED" = "True" ]; then
    ssh_pi 'systemctl is-active ustreamer.socket' > /dev/null 2>&1
    check "ustreamer.socket listening" $?

    TMP_IMG="/tmp/pi-flag-cam-test-snapshot.jpg"
    rm -f "$TMP_IMG"
    # Allow for on-demand cold start (camera enumeration ~1-3s).
    HTTP_CODE=$(curl -sf -o "$TMP_IMG" -w '%{http_code}' --max-time 10 "${CAM_BASE}/?action=snapshot" 2>/dev/null)
    [ "$HTTP_CODE" = "200" ]
    check "Camera snapshot (ustreamer -> 200)" $?

    if [ -f "$TMP_IMG" ]; then
        SIZE=$(stat -c%s "$TMP_IMG" 2>/dev/null || echo 0)
        MAGIC=$(xxd -l 2 -p "$TMP_IMG" 2>/dev/null)
        [ "$SIZE" -gt 1024 ] && [ "$MAGIC" = "ffd8" ]
        check "Snapshot valid JPEG (${SIZE} bytes, magic=${MAGIC})" $?
    else
        check "Snapshot valid JPEG (file missing)" 1
    fi

    HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 5 "${CAM_BASE}/?action=stream" 2>/dev/null || true)
    [ "$HTTP_CODE" = "200" ]
    check "Video stream responds (ustreamer)" $?
    rm -f "$TMP_IMG"
else
    skip "Camera tests (no camera connected — on-demand)"
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/cam/snapshot" 2>/dev/null)
    [ "$HTTP_CODE" = "503" ]
    check "/cam/snapshot -> 503 when camera absent" $?
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/nonexistent" 2>/dev/null)
[ "$HTTP_CODE" = "404" ]
check "404 for unknown endpoint" $?

echo
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed, ${SKIP} skipped ==="
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || echo "Some tests failed."
exit "$FAIL"
