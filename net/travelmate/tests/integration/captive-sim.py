#!/usr/bin/env python3
"""
captive-sim.py — minimal captive portal simulator for travelmate Tier-2 tests.

Runs an HTTP server inside the QEMU guest that answers travelmate's captive
probe with the configured response type, so captive-detection code paths can
be exercised without a real AP or live portal.

Usage: captive-sim.py [--port N] [--mode MODE]
  --port N     listen port (default: 8080)
  --mode MODE  response type (default: meta-refresh)

Modes:
  meta-refresh  200 OK + <meta http-equiv="refresh"> redirect (most common)
  redirect-302  302 Found to the login URL
  rfc8910       200 OK with application/captive+json body (RFC 8910 / CAPPORT)
  open          200 OK with plain text — simulates a portal that already passed
"""

import argparse
import http.server
import sys

REDIRECT_TARGET = "http://captive.example.com/login"

_RESPONSES = {
    "meta-refresh": (
        200,
        "text/html",
        (
            "<html><head>"
            f'<meta http-equiv="refresh" content="0; url={REDIRECT_TARGET}">'
            "</head><body>"
            f'Please <a href="{REDIRECT_TARGET}">log in</a>.'
            "</body></html>"
        ),
    ),
    "rfc8910": (
        200,
        "application/captive+json",
        f'{{"captive": true, "user-portal-url": "{REDIRECT_TARGET}"}}',
    ),
    "open": (200, "text/plain", "online"),
}


class CaptiveHandler(http.server.BaseHTTPRequestHandler):
    mode = "meta-refresh"

    def log_message(self, fmt, *args):
        pass  # silence per-request access log; use --verbose if needed

    def do_GET(self):
        if self.mode == "redirect-302":
            self.send_response(302)
            self.send_header("Location", REDIRECT_TARGET)
            self.end_headers()
            return

        code, ctype, body = _RESPONSES.get(self.mode, _RESPONSES["meta-refresh"])
        encoded = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def main():
    parser = argparse.ArgumentParser(description="Travelmate captive portal simulator")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument(
        "--mode",
        default="meta-refresh",
        choices=list(_RESPONSES) + ["redirect-302"],
    )
    args = parser.parse_args()

    CaptiveHandler.mode = args.mode
    server = http.server.HTTPServer(("0.0.0.0", args.port), CaptiveHandler)
    print(f"captive-sim: :{args.port} mode={args.mode}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
