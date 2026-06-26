#!/usr/bin/env bash
# Pi Flag Cam — one-time setup for the local cat detector (workstation, via uv).
# uv resolves the PEP 723 deps in detect.py on first `uv run`; this script just
# warms that env and pre-downloads the YOLO11n weights. Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DETECTOR="${PROJECT_DIR}/detector"

echo "=== Cat detector setup (uv) ==="
command -v uv >/dev/null || { echo "ERROR: uv not found. Install: https://docs.astral.sh/uv/" >&2; exit 1; }
command -v notify-send >/dev/null || echo "WARNING: notify-send missing — install libnotify-bin for desktop notifications"

echo "--- resolving deps (ultralytics + requests via uv; pulls torch, a few minutes) ---"
echo "--- and pre-downloading YOLO11n into ${DETECTOR} ---"
( cd "$DETECTOR" && uv run --with ultralytics \
    python -c "from ultralytics import YOLO; YOLO('yolo11n.pt'); print('deps + model ready')" )

echo
echo "Setup complete. Start the detector with:"
echo "  ./scripts/cat-detect"
