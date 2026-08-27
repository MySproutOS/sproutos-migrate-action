#!/usr/bin/env python3
"""A dependency-free API double for the workflow's composite-action smoke test."""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        return

    def send_json(self, status, body):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            self.send_json(200, {"ok": True})
            return
        self.send_json(404, {"message": "not found"})

    def do_PUT(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path != "/upload" or not body.startswith(b"PK"):
            self.send_json(400, {"message": "expected a zip archive"})
            return
        self.send_response(200)
        self.end_headers()

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")

        if self.path == "/v1/deploy/upload-url":
            if body.get("preset") != "migration" or body.get("project") != "test-project":
                self.send_json(400, {"message": "wrong upload request"})
                return
            self.send_json(
                200,
                {
                    "url": "http://127.0.0.1:18765/upload",
                    "key": "migrations/test.zip",
                },
            )
            return

        if self.path == "/v1/deploy/migrate":
            if body.get("migration_key") != "migrations/test.zip":
                self.send_json(400, {"message": "wrong migration key"})
                return
            request_log = os.path.join(os.environ["RUNNER_TEMP"], "mock-api.requests")
            with open(request_log, "a", encoding="utf-8") as requests:
                requests.write("migrate\n")
            self.send_json(200, {"ok": True, "output": "migration complete"})
            return

        self.send_json(404, {"message": "not found"})


ThreadingHTTPServer(("127.0.0.1", 18765), Handler).serve_forever()
