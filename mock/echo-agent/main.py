"""
Occitan Stack — Mock Echo Agent

A Python placeholder for showcase and local development.

All production components of the Occitan stack are written in Rust.
This mock exists so you can bring up the full cluster topology and verify
ArgoCD routing, service discovery, and health checks without needing the
real private images.

Endpoints:
  GET  /health    -> {"status": "ok", "component": "<AGENT_NAME>"}
  POST /invoke    -> echoes the request body with {"mock": true}

Environment variables:
  AGENT_NAME   Name reported in /health  (default: echo-agent)
  PORT         Listening port            (default: 8080)
"""

import json
import logging
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

AGENT_NAME = os.environ.get("AGENT_NAME", "echo-agent")
PORT = int(os.environ.get("PORT", "8080"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silence default access log
        pass

    def _send_json(self, code: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        log.info("%s %s %d", self.command, self.path, code)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {"status": "ok", "component": AGENT_NAME})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path == "/invoke":
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self._send_json(400, {"error": "invalid JSON"})
                return
            self._send_json(200, {
                "echo": body,
                "mock": True,
                "component": AGENT_NAME,
            })
        else:
            self._send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    log.info("echo-agent '%s' listening on :%d", AGENT_NAME, PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
