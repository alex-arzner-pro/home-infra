# Local Cat Detection via Pi Snapshots

## Context

User wants to detect when a cat appears on the Pi Zero W camera and get a desktop notification. Image recognition runs **locally** on the main workstation (Pi too weak for ML). Simple MVP — no zone calibration, no Luxafor action, no logs.

Pi's `ustreamer` already provides instant JPEG snapshots at `http://pi-flag-cam.local:8081/?action=snapshot`. Pi crashes when ustreamer runs continuously (~every 15-30 min) but watchdog + wifi-watchdog already handle recovery, so continuous polling is acceptable.

## Requirements (from user)

- Poll every **1 second**
- Detect **cat** only (COCO class 15)
- **Whole frame** — no zone filtering
- Action: **desktop notification only** (no Luxafor, no saving images, no logging)

## Architecture

```
[Local Ubuntu workstation]             [Pi Zero W]
  cat-detect (Python)
    ├── loop every 1s:
    │    fetch snapshot ─── HTTP ────►  ustreamer:8081
    │    YOLO11 Nano inference (~56ms CPU)
    │    if cat.confidence >= 0.5:
    │       debounce 30s
    │       notify-send "🐱 Cat detected"
```

## Technology Choices

- **YOLO11 Nano** (Ultralytics) — CPU inference ~56ms/frame on modern laptop, 50MB RAM, COCO `cat` class pretrained. Install via pip.
- **`requests`** — fetch JPEG from Pi
- **`notify-send`** (libnotify) — desktop notification (already on Ubuntu)
- **Python stdlib venv** — isolate ML deps

## Files to Create (in repo)

| Path | Purpose |
|------|---------|
| `detector/detect.py` | Single Python file: poll loop + YOLO + notify (~60 lines) |
| `detector/requirements.txt` | `ultralytics`, `requests` |
| `scripts/cat-detect-setup.sh` | One-time: create venv, install deps, download model, test |
| `scripts/cat-detect` | `exec venv/bin/python -m detector.detect` |

### `detector/detect.py` — essentials

```python
import time
import subprocess
import requests
from ultralytics import YOLO

SNAPSHOT_URL = "http://pi-flag-cam.local:8081/?action=snapshot"
POLL_INTERVAL = 1.0
CONFIDENCE = 0.5
CAT_CLASS_ID = 15
DEBOUNCE_SEC = 30

def notify(msg):
    subprocess.run(["notify-send", "-i", "camera", "Pi Cam", msg])

def main():
    model = YOLO("yolo11n.pt")
    last_detection = 0

    while True:
        try:
            r = requests.get(SNAPSHOT_URL, timeout=5)
            r.raise_for_status()
            # YOLO accepts bytes via numpy or PIL
            import io
            from PIL import Image
            img = Image.open(io.BytesIO(r.content))
            results = model.predict(img, conf=CONFIDENCE, verbose=False)

            for result in results:
                for box in result.boxes:
                    if int(box.cls[0]) == CAT_CLASS_ID:
                        now = time.time()
                        if now - last_detection > DEBOUNCE_SEC:
                            conf = float(box.conf[0])
                            notify(f"🐱 Cat detected! (confidence: {conf:.0%})")
                            last_detection = now
                        break
        except Exception as e:
            print(f"Error: {e}")

        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
```

### `scripts/cat-detect-setup.sh`

1. Create `detector/venv/` with Python 3.12
2. `pip install -r detector/requirements.txt`
3. Preload YOLO11 nano model (`python -c "from ultralytics import YOLO; YOLO('yolo11n.pt')"`)
4. Print success message

### `scripts/cat-detect`

```bash
#!/usr/bin/env bash
cd "$(dirname "$0")/.."
exec detector/venv/bin/python -m detector.detect
```

## Verification

1. **Setup**: run `./scripts/cat-detect-setup.sh` → venv created, ~300MB deps installed, `yolo11n.pt` (~6MB) downloaded, test inference on blank image succeeds
2. **Smoke test**: run `./scripts/cat-detect` → poll loop starts, snapshots fetched, `"Error: ..."` if Pi unreachable, clean exit on Ctrl-C
3. **Detection test**: show phone with cat image to camera → within 1-2 sec see desktop notification "🐱 Cat detected! (confidence: XX%)"
4. **Debounce test**: keep showing cat → only one notification per 30s window
5. **Stability**: let detector run 1 hour — verify no memory leak, auto-recovers when Pi reboots (Pi unreachable → error → continues)

## Out of Scope (for MVP)

Can add later if needed:
- Luxafor flash on detection
- Save annotated images
- Log file
- Zone filtering ("near door")
- Multiple classes (dog, person)
- Config file (TOML) — current version has constants at top of `detect.py`
- systemd user service for always-on

## Pi-side notes

No changes required on Pi. `ustreamer` already running and delivering snapshots on port 8081. Expected crashes every 15-30 min during active monitoring are handled by existing watchdog + wifi-watchdog.
