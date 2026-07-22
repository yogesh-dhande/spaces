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
    parser = argparse.ArgumentParser(description="Serve the permanent Spaces e2e demo project.")
    subparsers = parser.add_subparsers(dest="role", required=True)

    frontend = subparsers.add_parser("frontend", help="Serve demo browser pages and proxy backend API data.")
    frontend.add_argument("--port", type=int, required=True)
    frontend.add_argument("--site-dir", type=Path, required=True)
    frontend.add_argument("--backend-url", required=True)

    backend = subparsers.add_parser("backend", help="Serve demo backend API responses.")
    backend.add_argument("--port", type=int, required=True)
    backend.add_argument("--data-dir", type=Path, required=True)

    subparsers.add_parser("agent", help="Run a scripted coding agent that prints output and then waits on stdin.")

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.role == "frontend":
        serve_frontend(port=args.port, site_dir=args.site_dir, backend_url=args.backend_url.rstrip("/"))
        return 0
    if args.role == "backend":
        serve_backend(port=args.port, data_dir=args.data_dir)
        return 0
    if args.role == "agent":
        run_agent()
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

    # Deterministic, port-free startup banner so the dev-server terminal renders
    # realistic, non-empty content in the App Store demo recording. The concrete
    # port is workspace-assigned (nondeterministic across runs) and is deliberately
    # omitted so the recorded terminal frame is byte-stable.
    for line in FRONTEND_BANNER:
        print(line, flush=True)
    with ThreadingHTTPServer(("127.0.0.1", port), Handler) as server:
        server.serve_forever()


# Port-free dev-server banners printed once at startup. See serve_frontend for why
# the assigned port is intentionally excluded (deterministic recorded terminal frame).
FRONTEND_BANNER = (
    "Lighthouse web · frontend",
    "  serving   .spaces-e2e-demo/site",
    "  proxying  /api → backend",
    "  routes    /  /docs  /admin  /healthz",
    "  ready — watching for requests",
)

BACKEND_BANNER = (
    "Lighthouse web · backend",
    "  serving   .spaces-e2e-demo/api",
    "  routes    /api/launch-status  /healthz",
    "  ready — watching for requests",
)


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

    for line in BACKEND_BANNER:
        print(line, flush=True)
    with ThreadingHTTPServer(("127.0.0.1", port), Handler) as server:
        server.serve_forever()


# Scripted transcript for the demo coding agent. It reads like a real agent
# triaging the Harbor checkout incident from the lantern-api workspace, ending on
# a yes/no question so the terminal settles into an "agent waiting on input"
# state for the App Store demo recording and the macOS E2E suite.
AGENT_TRANSCRIPT = (
    "Lighthouse coding agent · lantern-api",
    "Reading workspace context...",
    "  branch          redesign-hero",
    "  open incident   Harbor checkout returning 500s (~340 users)",
    "",
    "Analyzing the /api/checkout route...",
    "  reproduced  TypeError: cannot read property 'token' of null",
    "  located     src/routes/checkout.py:82",
    "  cause       payment session expires mid-request and is dereferenced unguarded",
    "",
    "Ran checkout suite (3 tests):",
    "  PASS  tests/test_auth.py::test_signed_session",
    "  PASS  tests/test_cart.py::test_add_item",
    "  FAIL  tests/test_checkout.py::test_expired_session  (expected 409, got 500)",
    "",
    "Proposed fix:",
    "  1. Guard the expired-session case in checkout.py and return 409 with a retry hint",
    "  2. Add a regression test covering the expired-token path",
    "  3. Re-run the checkout integration suite",
    "",
    "Apply this fix to src/routes/checkout.py and add the regression test? [y/N] ",
)

AGENT_APPLIED = (
    "",
    "Applying fix...",
    "  edited  src/routes/checkout.py  (+7 -1)",
    "  added   tests/test_checkout.py::test_expired_session_returns_409",
    "Re-running checkout suite (4 tests):",
    "  PASS  tests/test_checkout.py::test_expired_session_returns_409",
    "  4 passed in 1.9s",
    "Fix ready to commit. Review the diff, then commit when you're happy. Anything else? [y/N] ",
)


def run_agent() -> None:
    """Print the scripted agent transcript, then block on stdin so the session
    stays alive as a coding-agent row waiting on the developer's answer.

    Reading stdin never returns in a live Spaces terminal (the PTY stays open),
    which is exactly the "waiting on input" state the demo wants. When run with a
    closed stdin (EOF), the loop ends and the process exits cleanly."""
    for line in AGENT_TRANSCRIPT:
        print(line, flush=True)

    while True:
        answer = sys.stdin.readline()
        if answer == "":
            return
        if answer.strip().lower() in {"y", "yes"}:
            for line in AGENT_APPLIED:
                print(line, flush=True)
        else:
            print("Leaving the checkout handler unchanged. Anything else? [y/N] ", flush=True)


if __name__ == "__main__":
    sys.exit(main())
