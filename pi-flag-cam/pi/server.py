#!/usr/bin/env python3
"""Pi Flag Cam — HTTP API server for Luxafor Flag LED control.

Runs on Raspberry Pi Zero W. Provides REST-like endpoints for:
- Luxafor Flag LED control (named colors, RGB)
- Redirects to ustreamer for camera (stream + snapshot on port 8081)

Uses only Python stdlib + system python3-hid. No pip dependencies.
Network exposure is restricted by systemd IPAddressAllow (see pi-flag-cam.service).
"""

import json
import os
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

import hid

# --- Luxafor configuration ---

LUXAFOR_VID = 0x04D8
LUXAFOR_PID = 0xF372

COLORS = {
    "red": (255, 0, 0),
    "green": (0, 255, 0),
    "blue": (0, 0, 255),
    "yellow": (255, 255, 0),
    "cyan": (0, 255, 255),
    "magenta": (255, 0, 255),
    "white": (255, 255, 255),
    "orange": (255, 165, 0),
    "off": (0, 0, 0),
}

# --- Camera configuration ---

USTREAMER_PORT = 8081
CAMERA_DEVICE = "/dev/video0"

start_time = time.time()

# --- Luxafor HID access ---
# hidapi is NOT thread-safe and ThreadingHTTPServer serves requests
# concurrently, so we keep ONE long-lived handle guarded by a lock and reopen
# it on error (resilient to replug). The old code opened/closed on every
# request, which races the exclusive hidraw open ("open failed").

_hid_lock = threading.Lock()
_hid_dev = None


def _open_hid_locked():
    """(Re)open the Luxafor HID handle. Caller must hold _hid_lock."""
    global _hid_dev
    if _hid_dev is None:
        d = hid.device()
        d.open(LUXAFOR_VID, LUXAFOR_PID)
        _hid_dev = d
    return _hid_dev


def _close_hid_locked():
    global _hid_dev
    if _hid_dev is not None:
        try:
            _hid_dev.close()
        except Exception:
            pass
        _hid_dev = None


def set_luxafor_color(r, g, b, zone=0xFF):
    """Set the Luxafor LED color, serialized and reopen-on-error.

    Report: [report_id=0x00, command=0x01 (static color), zone, r, g, b],
    padded to the device's full 9-byte report length.
    """
    report = [0x00, 0x01, zone, r, g, b, 0, 0, 0]
    with _hid_lock:
        try:
            _open_hid_locked().write(report)
        except (OSError, ValueError):
            # Likely replug/reset — reopen once and retry; surface a 2nd failure.
            _close_hid_locked()
            _open_hid_locked().write(report)


def luxafor_present():
    return bool(hid.enumerate(LUXAFOR_VID, LUXAFOR_PID))


class RequestHandler(BaseHTTPRequestHandler):
    # Don't let a slow/half-open client on flaky WiFi pin a worker thread.
    timeout = 5

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")

        if path.startswith("/lux/color/"):
            name = path.split("/lux/color/", 1)[1].lower()
            if name not in COLORS:
                self._json(400, {"error": f"Unknown color: {name}", "available": list(COLORS)})
                return
            self._set_color(*COLORS[name], extra={"color": name})

        elif path.startswith("/lux/rgb/"):
            parts = path.split("/lux/rgb/", 1)[1].split("/")
            if len(parts) != 3:
                self._json(400, {"error": "Expected /lux/rgb/<r>/<g>/<b>"})
                return
            try:
                vals = [int(x) for x in parts]
            except ValueError:
                self._json(400, {"error": "RGB values must be integers"})
                return
            if any(v < 0 or v > 255 for v in vals):
                self._json(400, {"error": "RGB values must be 0-255"})
                return
            self._set_color(*vals)

        elif path == "/lux/off":
            self._set_color(0, 0, 0, extra={"color": "off"})

        elif path in ("/cam/snapshot", "/cam/stream"):
            # On-demand camera: if it isn't plugged in, say so instead of
            # redirecting to a port that would just refuse the connection.
            if not os.path.exists(CAMERA_DEVICE):
                self._json(503, {"error": "camera not connected", "device": CAMERA_DEVICE})
                return
            action = "snapshot" if path.endswith("snapshot") else "stream"
            host = self.headers.get("Host", "").split(":")[0]
            self.send_response(302)
            self.send_header("Location", f"http://{host}:{USTREAMER_PORT}/?action={action}")
            self.end_headers()

        elif path == "/health":
            self._json(200, {
                "status": "ok",
                "uptime_seconds": int(time.time() - start_time),
                "luxafor_connected": luxafor_present(),
                "camera_connected": os.path.exists(CAMERA_DEVICE),
                "ustreamer_port": USTREAMER_PORT,
                "available_colors": list(COLORS),
            })

        else:
            self._json(404, {"error": "Not found", "endpoints": [
                "GET /lux/color/<name>", "GET /lux/rgb/<r>/<g>/<b>", "GET /lux/off",
                "GET /cam/snapshot", "GET /cam/stream", "GET /health",
            ]})

    def _set_color(self, r, g, b, extra=None):
        try:
            set_luxafor_color(r, g, b)
        except Exception as e:
            self._json(500, {"error": str(e)})
            return
        body = {"status": "ok", "rgb": [r, g, b]}
        if extra:
            body.update(extra)
        self._json(200, body)

    def _json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {fmt % args}")


def main():
    server = ThreadingHTTPServer(("0.0.0.0", 8080), RequestHandler)
    # Reset Luxafor to off on startup (hardware retains color across reboots).
    try:
        set_luxafor_color(0, 0, 0)
    except Exception as e:
        print(f"WARNING: could not reset Luxafor on startup: {e}")
    print("Pi Flag Cam server starting on 0.0.0.0:8080")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
