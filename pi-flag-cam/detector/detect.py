#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["ultralytics>=8.3.0"]
# ///
"""Pi Flag Cam — local cat detector (fswebcam per-frame).

Grabs ONE frame from the Pi via SSH + fswebcam (opens the camera, captures a
single JPEG, then closes it) so the camera/USB bus is FREE between polls — this
is what keeps the Zero W stable (a persistently open camera triggers the
brcmfmac udp_fail_queue_rcv_skb oops). Runs YOLO11 Nano locally and sends a
desktop notification on a cat. Runs on the workstation; the Pi is too weak for ML.

Env (set by scripts/cat-detect):
  CAT_DETECT_PI_HOST   Pi host/IP (default 192.168.86.7)
  CAT_DETECT_PI_USER   SSH user (default aarzner)
  CAT_DETECT_INTERVAL  poll seconds (default 5, floored at 3)
  CAT_DETECT_CONF      min confidence (default 0.5)
  CAT_DETECT_DEBOUNCE  seconds between notifications (default 30)
  CAT_DETECT_MODEL     YOLO weights (default yolo11n.pt)
"""

import io
import os
import shutil
import subprocess
import sys
import time

from PIL import Image
from ultralytics import YOLO

PI_HOST = os.environ.get("CAT_DETECT_PI_HOST", "192.168.86.7")
PI_USER = os.environ.get("CAT_DETECT_PI_USER", "aarzner")
INTERVAL = max(float(os.environ.get("CAT_DETECT_INTERVAL", "5")), 3.0)
CONF = float(os.environ.get("CAT_DETECT_CONF", "0.5"))
DEBOUNCE = float(os.environ.get("CAT_DETECT_DEBOUNCE", "30"))
MODEL = os.environ.get("CAT_DETECT_MODEL", "yolo11n.pt")
CAT_CLASS = 15  # COCO class id for "cat"

SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
# One frame to stdout, then exit -> camera + USB bus released between polls.
FSWEBCAM = "fswebcam -r 640x480 --no-banner -q --jpeg 85 -"


def grab_frame():
    proc = subprocess.run(
        SSH + [f"{PI_USER}@{PI_HOST}", FSWEBCAM],
        capture_output=True, timeout=25,
    )
    if proc.returncode != 0 or not proc.stdout:
        err = proc.stderr.decode(errors="replace").strip()[:200]
        raise RuntimeError(f"fswebcam rc={proc.returncode}: {err}")
    return proc.stdout


NOTIFY_TITLE = "Pi Flag Cam"


def notify(message):
    """Show a centered "плашка" popup (same style/mechanism as the dotfiles
    mk321/yubikey popups: a yad window floated dead-center by the sway rule
    for app_id=yad, no focus steal, auto-closing on --timeout). Falls back to
    notify-send -> dunst (top-right) when yad is unavailable.

    yad is launched fire-and-forget (Popen, no wait): --timeout blocks yad for
    its whole lifetime, so waiting here would stall the poll loop. It closes
    itself; the 30s debounce keeps popups from stacking.
    """
    if shutil.which("yad"):
        markup = (
            "<span font='JetBrainsMono Nerd Font 11' foreground='#928374'>"
            f"{NOTIFY_TITLE}</span>\n"
            "<span font='JetBrainsMono Nerd Font 22' weight='bold' "
            f"foreground='#fabd2f'>{message}</span>"
        )
        try:
            subprocess.Popen(
                ["yad", "--undecorated", "--no-buttons", "--skip-taskbar",
                 "--center", "--borders=16", "--timeout=6", "--width=520",
                 "--text-align=center", "--text", markup],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return
        except (FileNotFoundError, OSError) as e:
            print(f"yad failed, falling back to notify-send: {e}", file=sys.stderr)
    try:
        subprocess.run(
            ["notify-send", "-i", "camera-web", NOTIFY_TITLE, message],
            timeout=5, check=False,
        )
    except (FileNotFoundError, subprocess.SubprocessError) as e:
        print(f"notify-send failed: {e}", file=sys.stderr)


def main():
    print(f"cat-detect: fswebcam via {PI_USER}@{PI_HOST} every {INTERVAL:g}s "
          f"(conf>={CONF}, debounce {DEBOUNCE:g}s)")
    model = YOLO(MODEL)
    last_notify = 0.0

    while True:
        start = time.monotonic()
        try:
            frame = Image.open(io.BytesIO(grab_frame()))
            result = model.predict(frame, classes=[CAT_CLASS], conf=CONF, verbose=False)[0]
            boxes = result.boxes
            if boxes is not None and len(boxes) > 0:
                best = float(boxes.conf.max())
                stamp = time.strftime("%H:%M:%S")
                if time.monotonic() - last_notify >= DEBOUNCE:
                    notify(f"\U0001F431 Cat detected ({best:.0%})")
                    last_notify = time.monotonic()
                    print(f"[{stamp}] CAT {best:.2f} -> notified")
                else:
                    print(f"[{stamp}] CAT {best:.2f} (debounced)")
        except subprocess.TimeoutExpired:
            print(f"[{time.strftime('%H:%M:%S')}] grab timeout", file=sys.stderr)
        except Exception as e:
            print(f"[{time.strftime('%H:%M:%S')}] error: {e}", file=sys.stderr)

        time.sleep(max(0.0, INTERVAL - (time.monotonic() - start)))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\ncat-detect stopped")
