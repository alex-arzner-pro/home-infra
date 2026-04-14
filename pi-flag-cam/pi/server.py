#!/usr/bin/env python3
"""Pi Flag Cam — HTTP API server for Luxafor Flag LED control.

Runs on Raspberry Pi Zero W. Provides REST-like endpoints for:
- Luxafor Flag LED control (named colors, RGB)
- Redirects to ustreamer for camera (stream + snapshot on port 8081)

Uses only Python stdlib + system python3-hid. No pip dependencies.
"""

import json
import time
from http.server import HTTPServer, ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

import hid

# --- Luxafor Configuration ---

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

# --- Camera Configuration ---

USTREAMER_HOST = "localhost"
USTREAMER_PORT = 8081

start_time = time.time()


def set_luxafor_color(r, g, b, zone=0xFF):
    """Set Luxafor Flag LED color via HID.

    Protocol: [report_id, command, zone, r, g, b]
    - report_id: 0x00
    - command: 0x01 = static color
    - zone: 0xFF = all LEDs, 0x01 = front
    """
    h = hid.device()
    h.open(LUXAFOR_VID, LUXAFOR_PID)
    h.write([0x00, 0x01, zone, r, g, b])
    h.close()



class RequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        # --- Luxafor endpoints ---
        if path.startswith("/lux/color/"):
            name = path.split("/lux/color/", 1)[1].lower()
            if name not in COLORS:
                self._json_response(
                    400, {"error": f"Unknown color: {name}", "available": list(COLORS.keys())}
                )
                return
            r, g, b = COLORS[name]
            try:
                set_luxafor_color(r, g, b)
                self._json_response(200, {"status": "ok", "color": name, "rgb": [r, g, b]})
            except Exception as e:
                self._json_response(500, {"error": str(e)})

        elif path.startswith("/lux/rgb/"):
            parts = path.split("/lux/rgb/", 1)[1].split("/")
            if len(parts) != 3:
                self._json_response(400, {"error": "Expected /lux/rgb/<r>/<g>/<b>"})
                return
            try:
                r, g, b = [max(0, min(255, int(x))) for x in parts]
                set_luxafor_color(r, g, b)
                self._json_response(200, {"status": "ok", "rgb": [r, g, b]})
            except ValueError:
                self._json_response(400, {"error": "RGB values must be integers 0-255"})

        elif path == "/lux/off":
            try:
                set_luxafor_color(0, 0, 0)
                self._json_response(200, {"status": "ok", "color": "off"})
            except Exception as e:
                self._json_response(500, {"error": str(e)})

        # --- Camera endpoints (redirect to ustreamer on port 8081) ---
        elif path == "/cam/snapshot":
            self.send_response(302)
            self.send_header("Location", f"http://{self.headers.get('Host', '').split(':')[0]}:{USTREAMER_PORT}/?action=snapshot")
            self.end_headers()

        elif path == "/cam/stream":
            self.send_response(302)
            self.send_header("Location", f"http://{self.headers.get('Host', '').split(':')[0]}:{USTREAMER_PORT}/?action=stream")
            self.end_headers()

        # --- Health endpoint ---
        elif path == "/health":
            uptime = int(time.time() - start_time)
            luxafor_ok = bool(hid.enumerate(LUXAFOR_VID, LUXAFOR_PID))
            self._json_response(200, {
                "status": "ok",
                "uptime_seconds": uptime,
                "luxafor_connected": luxafor_ok,
                "ustreamer_port": USTREAMER_PORT,
                "available_colors": list(COLORS.keys()),
            })

        else:
            self._json_response(404, {
                "error": "Not found",
                "endpoints": [
                    "GET /lux/color/<name>",
                    "GET /lux/rgb/<r>/<g>/<b>",
                    "GET /lux/off",
                    "GET /cam/snapshot (redirect to ustreamer)",
                    "GET /cam/stream (redirect to ustreamer)",
                    "GET /health",
                ],
            })

    def _json_response(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[{self.log_date_time_string()}] {format % args}")


def main():
    host = "0.0.0.0"
    port = 8080
    server = ThreadingHTTPServer((host, port), RequestHandler)
    # Reset Luxafor to off on startup (it retains color in hardware across reboots)
    try:
        set_luxafor_color(0, 0, 0)
    except Exception:
        pass
    print(f"Pi Flag Cam server starting on {host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
