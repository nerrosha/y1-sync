#!/usr/bin/env python3
"""Development bridge: serve the window in a normal browser and forward its
requests to `y1sync api`, the way the Tauri app does.

    Y1SYNC_BIN=/path/to/y1sync Y1SYNC_DATA=/tmp/y1-data python3 dev/bridge.py 8765
"""
import http.server, json, os, subprocess, sys, threading

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
BIN = os.environ.get("Y1SYNC_BIN", "y1sync")
current = {"proc": None}

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def log_message(self, *a):
        pass

    def do_POST(self):
        if self.path == "/api/stop":
            p = current["proc"]
            if p and p.poll() is None:
                try:
                    p.stdin.write(b"stop\n"); p.stdin.flush()
                except Exception:
                    pass
            self.send_response(204); self.end_headers(); return
        if self.path != "/api":
            self.send_response(404); self.end_headers(); return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        proc = subprocess.Popen([BIN, "api"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        current["proc"] = proc
        proc.stdin.write(body.strip() + b"\n"); proc.stdin.flush()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        for line in proc.stdout:
            self.wfile.write(line); self.wfile.flush()
        proc.terminate()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
