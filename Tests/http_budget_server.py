#!/usr/bin/env python3
"""Loopback-only bounded HTTP regression fixtures. Contains no production data."""
import argparse
import gzip
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from pathlib import Path
from urllib.parse import urlsplit

LOCK = threading.Lock()
STATS = {"requests": 0, "body_bytes_written": 0, "active": 0, "maximum_active": 0, "routes": {}}


class LoopbackServer(ThreadingHTTPServer):
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/stats":
            with LOCK:
                data = json.dumps(STATS).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True
            return
        with LOCK:
            STATS["requests"] += 1
            STATS["active"] += 1
            STATS["maximum_active"] = max(STATS["maximum_active"], STATS["active"])
            row = STATS["routes"].setdefault(path, {"requests": 0, "body_bytes_written": 0, "completed": 0, "disconnects": 0})
            row["requests"] += 1
        try:
            if path.startswith("/stream/"):
                self.headers_for(200)
                for _ in range(1024):
                    self.write_counted(b"s" * 512, row)
                    time.sleep(0.002)
            elif path.startswith("/slow/"):
                self.headers_for(200)
                for _ in range(60):
                    self.write_counted(b"z" * 64, row)
                    time.sleep(0.15)
            elif path.startswith("/gzip/"):
                payload = gzip.compress(b"g" * 131072)
                self.headers_for(200, None, {"Content-Encoding": "gzip"})
                self.write_counted(payload, row)
            elif path == "/redirect":
                self.headers_for(302, 0, {"Location": f"http://127.0.0.1:{self.server.server_port}/redirect-target"})
            else:
                payload = b"ok"
                self.headers_for(200, len(payload))
                self.write_counted(payload, row)
            with LOCK:
                row["completed"] += 1
        except (BrokenPipeError, ConnectionResetError, OSError):
            with LOCK:
                row["disconnects"] += 1
        finally:
            self.close_connection = True
            with LOCK:
                STATS["active"] -= 1

    def headers_for(self, status, length=None, extra=None):
        self.send_response(status)
        if length is not None:
            self.send_header("Content-Length", str(length))
        self.send_header("Connection", "close")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()

    def write_counted(self, payload, row):
        self.wfile.write(payload)
        self.wfile.flush()
        with LOCK:
            row["body_bytes_written"] += len(payload)
            STATS["body_bytes_written"] += len(payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    server = LoopbackServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    Path(args.port_file).write_text(str(server.server_port))
    print(json.dumps({"listening": "127.0.0.1", "port": server.server_port}), flush=True)
    try:
        server.serve_forever(poll_interval=0.05)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
