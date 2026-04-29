from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve the permanent Muxy e2e demo project.")
    subparsers = parser.add_subparsers(dest="role", required=True)

    frontend = subparsers.add_parser("frontend", help="Serve demo browser pages and proxy backend API data.")
    frontend.add_argument("--port", type=int, required=True)
    frontend.add_argument("--site-dir", type=Path, required=True)
    frontend.add_argument("--backend-url", required=True)

    backend = subparsers.add_parser("backend", help="Serve demo backend API responses.")
    backend.add_argument("--port", type=int, required=True)
    backend.add_argument("--data-dir", type=Path, required=True)

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.role == "frontend":
        serve_frontend(port=args.port, site_dir=args.site_dir, backend_url=args.backend_url.rstrip("/"))
        return 0
    if args.role == "backend":
        serve_backend(port=args.port, data_dir=args.data_dir)
        return 0
    raise AssertionError(f"Unsupported role: {args.role}")


def serve_frontend(*, port: int, site_dir: Path, backend_url: str) -> None:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            route = self.path.split("?", 1)[0]
            if route in {"/healthz", "/health"}:
                self._send_bytes(200, b"ok\n", "text/plain; charset=utf-8")
                return
            if route == "/api/launch-status":
                self._proxy_json(f"{backend_url}/api/launch-status")
                return
            if route in {"/", "/docs", "/docs/"}:
                self._send_file(site_dir / "docs" / "index.html")
                return
            if route in {"/admin", "/admin/"}:
                self._send_file(site_dir / "admin" / "index.html")
                return
            self._send_bytes(404, b"not found\n", "text/plain; charset=utf-8")

        def log_message(self, fmt: str, *args: object) -> None:
            print(f"frontend[{port}] " + fmt % args)

        def _proxy_json(self, url: str) -> None:
            try:
                with urllib.request.urlopen(url, timeout=2) as response:
                    body = response.read()
            except urllib.error.URLError as error:
                payload = json.dumps({"status": "backend-unavailable", "detail": str(error)}).encode("utf-8")
                self._send_bytes(502, payload, "application/json; charset=utf-8")
                return
            self._send_bytes(200, body, "application/json; charset=utf-8")

        def _send_file(self, path: Path) -> None:
            body = path.read_bytes()
            mime, _ = mimetypes.guess_type(path.name)
            self._send_bytes(200, body, mime or "text/html; charset=utf-8")

        def _send_bytes(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    with ThreadingHTTPServer(("127.0.0.1", port), Handler) as server:
        server.serve_forever()


def serve_backend(*, port: int, data_dir: Path) -> None:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            route = self.path.split("?", 1)[0]
            if route in {"/healthz", "/health"}:
                self._send_bytes(200, b"ok\n", "text/plain; charset=utf-8")
                return
            if route == "/api/launch-status":
                self._send_file(data_dir / "launch-status.json")
                return
            self._send_bytes(404, b"not found\n", "text/plain; charset=utf-8")

        def log_message(self, fmt: str, *args: object) -> None:
            print(f"backend[{port}] " + fmt % args)

        def _send_file(self, path: Path) -> None:
            body = path.read_bytes()
            self._send_bytes(200, body, "application/json; charset=utf-8")

        def _send_bytes(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    with ThreadingHTTPServer(("127.0.0.1", port), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
