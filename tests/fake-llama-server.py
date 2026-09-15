#!/usr/bin/env python3
"""Throwaway llama-server stand-in for the monitor.sh tests.

/health  -> 200 {"status":"ok"} when the file 'up' exists, else 503
/metrics -> prometheus counters read live from 'counters' ("<tokens> <seconds>")
"""
import http.server
import os
import sys

ROOT = sys.argv[1]
PORT = int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        up = os.path.exists(os.path.join(ROOT, "up"))
        if self.path == "/health":
            if up:
                body = b'{"status":"ok"}'
                self.send_response(200)
            else:
                body = b'{"error":"loading model"}'
                self.send_response(503)
        elif self.path == "/metrics":
            try:
                tok, psec = open(os.path.join(ROOT, "counters")).read().split()
            except Exception:
                tok, psec = "0", "0"
            body = ("llamacpp:tokens_predicted_total " + tok + "\n"
                    "llamacpp:tokens_predicted_seconds_total " + psec + "\n").encode()
            self.send_response(200)
        else:
            body = b"nope"
            self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
