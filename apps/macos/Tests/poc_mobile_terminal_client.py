#!/usr/bin/env python3

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def send_tcp_control_request(host: str, port: int, request: dict) -> dict:
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect((host, port))
    payload = json.dumps(request).encode("utf-8")
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    return json.loads(response.decode("utf-8"))


def wait_for_proxy_ready(process: subprocess.Popen[str], timeout: float = 10) -> tuple[str, int]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = process.stdout.readline().strip()
        if not line:
            continue
        match = re.search(r"host=([0-9.]+)\tport=(\d+)", line)
        if match:
            return match.group(1), int(match.group(2))
    raise RuntimeError("Timed out waiting for terminal proxy to become ready.")


def wait_for_tail_contains(send_request, needle: str, timeout: float = 10, line_count: int = 120) -> str:
    deadline = time.time() + timeout
    last_output = ""
    while time.time() < deadline:
        response = send_request({"command": "tail", "lineCount": line_count})
        if not response.get("ok"):
            raise RuntimeError(f"Tail request failed: {response}")
        last_output = response.get("message", "")
        if needle in last_output:
            return last_output
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for output containing {needle!r}. Last tail:\n{last_output}")


def start_spaces_app(spaces_app: Path, env: dict[str, str]) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [str(spaces_app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-app", action="store_true", help="Launch an isolated SpacesApp instance for the POC.")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[3]
    spaces_cli = Path(os.environ.get("SPACES_CLI", repo_root / "apps/macos/.build/debug/spaces"))
    spaces_app = Path(os.environ.get("SPACES_APP", repo_root / "apps/macos/.build/debug/SpacesApp"))
    temp_root = Path(tempfile.mkdtemp(prefix="spaces-mobile-poc."))
    temp_home = temp_root / "home"
    temp_home.mkdir(parents=True, exist_ok=True)
    db_path = temp_root / "spaces.db"
    runtime_dir = temp_root / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ | {
        "HOME": str(temp_home),
        "SPACES_DB_PATH": str(db_path),
        "SPACES_RUNTIME_DIR": str(runtime_dir),
    }

    fixture = (
        "python3 -u -c "
        "\"import sys; print('ready', flush=True); "
        "first = sys.stdin.readline().rstrip('\\\\n'); print(f'echo:{first}', flush=True); "
        "second = sys.stdin.readline().rstrip('\\\\n'); print(f'next:{second}', flush=True)\""
    )

    app_process = None
    proxy_process = None
    session_id = None
    try:
        if args.start_app:
            app_process = start_spaces_app(spaces_app, env)
            time.sleep(2)

        result = subprocess.run(
            [
                str(spaces_cli),
                "terminal",
                "command",
                "--backend",
                "ghostty-embedded",
                "--command",
                fixture,
                "--title",
                "mobile-poc",
            ],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        match = re.search(r"Started terminal session ([A-F0-9-]+)", result.stdout, re.IGNORECASE)
        if not match:
            raise RuntimeError(f"Unable to parse session id from:\n{result.stdout}")
        session_id = match.group(1)

        auth_token = str(uuid.uuid4()).upper()
        proxy_process = subprocess.Popen(
            [
                str(spaces_cli),
                "terminal",
                "proxy",
                session_id,
                "--host",
                "127.0.0.1",
                "--port",
                "0",
                "--auth-token",
                auth_token,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        proxy_host, proxy_port = wait_for_proxy_ready(proxy_process)

        def send_request(request: dict) -> dict:
            return send_tcp_control_request(proxy_host, proxy_port, {"authToken": auth_token, **request})

        owner_client = {
            "id": str(uuid.uuid4()).upper(),
            "kind": "localWindow",
            "identity": {"label": "desktop-owner", "deviceName": "Mac"},
            "connectedAt": iso_now(),
            "disconnectedAt": None,
        }
        mobile_client = {
            "id": str(uuid.uuid4()).upper(),
            "kind": "remoteViewer",
            "identity": {"label": "iphone-viewer", "deviceName": "iPhone", "networkAddress": "10.0.0.24"},
            "connectedAt": iso_now(),
            "disconnectedAt": None,
        }

        for client, mode in ((owner_client, "owner"), (mobile_client, "viewer")):
            response = send_request({"command": "attach", "client": client, "attachmentMode": mode})
            if not response.get("ok"):
                raise RuntimeError(f"Attach failed: {response}")

        initial_tail = wait_for_tail_contains(send_request, "ready")

        blocked = send_request(
            {"command": "send", "text": "blocked", "appendNewline": True, "clientID": mobile_client["id"]}
        )
        if blocked.get("ok"):
            raise RuntimeError(f"Viewer input should have been rejected: {blocked}")

        takeover = send_request({"command": "takeover", "clientID": mobile_client["id"]})
        if not takeover.get("ok"):
            raise RuntimeError(f"Takeover failed: {takeover}")

        sent = send_request({"command": "send", "text": "mobile-hello", "clientID": mobile_client["id"]})
        if not sent.get("ok"):
            raise RuntimeError(f"Mobile send failed: {sent}")
        key = send_request({"command": "key", "key": "enter", "clientID": mobile_client["id"]})
        if not key.get("ok"):
            raise RuntimeError(f"Mobile key failed: {key}")
        second_tail = wait_for_tail_contains(send_request, "echo:mobile-hello")

        retake = send_request({"command": "takeover", "clientID": owner_client["id"]})
        if not retake.get("ok"):
            raise RuntimeError(f"Retake failed: {retake}")

        blocked_after_retake = send_request(
            {"command": "send", "text": "blocked-again", "appendNewline": True, "clientID": mobile_client["id"]}
        )
        if blocked_after_retake.get("ok"):
            raise RuntimeError(f"Mobile client should have lost ownership: {blocked_after_retake}")

        print(
            "Mobile terminal client POC passed "
            f"session={session_id} initial_tail_chars={len(initial_tail)} post_takeover_tail_chars={len(second_tail)}"
        )
        return 0
    finally:
        if proxy_process is not None:
            proxy_process.terminate()
            try:
                proxy_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxy_process.kill()
        if app_process is not None:
            app_process.terminate()
            try:
                app_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app_process.kill()
        shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
