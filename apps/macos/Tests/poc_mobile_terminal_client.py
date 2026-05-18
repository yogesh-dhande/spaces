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


def wait_for_tail_contains(send_request, needle: str, client_id: str | None = None, timeout: float = 10, line_count: int = 120) -> str:
    deadline = time.time() + timeout
    last_output = ""
    while time.time() < deadline:
        request = {"command": "tail", "lineCount": line_count}
        if client_id:
            request["clientID"] = client_id
        response = send_request(request)
        if not response.get("ok"):
            raise RuntimeError(f"Tail request failed: {response}")
        last_output = response.get("message", "")
        if needle in last_output:
            return last_output
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for output containing {needle!r}. Last tail:\n{last_output}")


def wait_for_active_owner(paths_root: Path, session_id: str, excluded_client_ids: set[str] | None = None, timeout: float = 10) -> str:
    excluded_client_ids = excluded_client_ids or set()
    attachments_path = paths_root / "terminal" / "sessions" / session_id / "attachments.json"
    deadline = time.time() + timeout
    last_snapshot = ""
    while time.time() < deadline:
        if attachments_path.exists():
            payload = json.loads(attachments_path.read_text())
            last_snapshot = json.dumps(payload, indent=2, sort_keys=True)
            for attachment in payload:
                if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None:
                    client_id = attachment.get("clientID")
                    if client_id and client_id not in excluded_client_ids:
                        return client_id
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for active owner attachment. Last snapshot:\n{last_snapshot}")


def read_service_pid(paths_root: Path, session_id: str) -> int | None:
    state_path = paths_root / "terminal" / "sessions" / session_id / "state.json"
    if not state_path.exists():
        return None
    payload = json.loads(state_path.read_text())
    pid = payload.get("servicePID")
    return int(pid) if pid is not None else None


def start_spaces_app(spaces_app: Path, env: dict[str, str]) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [str(spaces_app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def resolve_built_binary(repo_root: Path, env_name: str, default_name: str) -> Path:
    explicit = os.environ.get(env_name)
    if explicit:
        return Path(explicit)

    direct = repo_root / "apps/macos/.build/debug" / default_name
    if direct.exists():
        return direct

    matches = sorted((repo_root / "apps/macos/.build").glob(f"**/{default_name}"))
    for match in matches:
        if match.is_file() and ".dSYM" not in str(match):
            return match

    return direct


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-app", action="store_true", help="Launch an isolated SpacesApp instance for the POC.")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[3]
    spaces_cli = resolve_built_binary(repo_root, "SPACES_CLI", "spaces")
    spaces_app = resolve_built_binary(repo_root, "SPACES_APP", "SpacesApp")
    spacese2e = resolve_built_binary(repo_root, "SPACES_E2E", "spacese2e")
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
        "index = 0\n"
        "for line in sys.stdin:\n"
        "    text = line.rstrip('\\\\n')\n"
        "    print(f'line{index}:{text}', flush=True)\n"
        "    index += 1\""
    )

    app_process = None
    proxy_process = None
    session_id = None
    mobile_client = None
    send_request = None
    service_pid = None
    try:
        if args.start_app:
            app_process = start_spaces_app(spaces_app, env)
            time.sleep(2)

        result = subprocess.run(
            [
                str(spaces_cli),
                "terminal",
                "command",
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
        service_pid = read_service_pid(temp_root, session_id)

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

        mobile_client = {
            "id": str(uuid.uuid4()).upper(),
            "kind": "remoteViewer",
            "identity": {"label": "iphone-viewer", "deviceName": "iPhone", "networkAddress": "10.0.0.24"},
            "connectedAt": iso_now(),
            "disconnectedAt": None,
        }

        response = send_request({"command": "attach", "client": mobile_client, "attachmentMode": "viewer"})
        if not response.get("ok"):
            raise RuntimeError(f"Attach failed: {response}")

        initial_tail = wait_for_tail_contains(send_request, "ready", client_id=mobile_client["id"])
        initial_owner_client_id = wait_for_active_owner(temp_root, session_id, excluded_client_ids={mobile_client["id"]})

        blocked = send_request(
            {"command": "send", "text": "blocked", "appendNewline": True, "clientID": mobile_client["id"]}
        )
        if blocked.get("ok"):
            raise RuntimeError(f"Viewer input should have been rejected: {blocked}")

        subprocess.run(
            [str(spacese2e), "close-terminal-session-window", "--session-id", session_id],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        time.sleep(1)

        takeover = send_request({"command": "takeover", "clientID": mobile_client["id"]})
        if not takeover.get("ok"):
            raise RuntimeError(f"Takeover failed: {takeover}")

        sent = send_request({"command": "send", "text": "mobile-hello", "clientID": mobile_client["id"]})
        if not sent.get("ok"):
            raise RuntimeError(f"Mobile send failed: {sent}")
        key = send_request({"command": "key", "key": "enter", "clientID": mobile_client["id"]})
        if not key.get("ok"):
            raise RuntimeError(f"Mobile key failed: {key}")
        second_tail = wait_for_tail_contains(send_request, "line0:mobile-hello", client_id=mobile_client["id"])

        show_result = subprocess.run(
            [str(spaces_cli), "terminal", "show", session_id],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        if "Requested owner terminal window" not in show_result.stdout:
            raise RuntimeError(f"Owner window reopen did not report success:\n{show_result.stdout}\n{show_result.stderr}")

        reopened_owner_client_id = wait_for_active_owner(
            temp_root, session_id, excluded_client_ids={mobile_client["id"], initial_owner_client_id}
        )

        retake = send_request({"command": "takeover", "clientID": reopened_owner_client_id})
        if not retake.get("ok"):
            raise RuntimeError(f"Retake failed: {retake}")

        blocked_after_retake = send_request(
            {"command": "send", "text": "blocked-again", "appendNewline": True, "clientID": mobile_client["id"]}
        )
        if blocked_after_retake.get("ok"):
            raise RuntimeError(f"Mobile client should have lost ownership: {blocked_after_retake}")

        owner_sent = send_request({"command": "send", "text": "desktop-return", "clientID": reopened_owner_client_id})
        if not owner_sent.get("ok"):
            raise RuntimeError(f"Reopened owner send failed: {owner_sent}")
        owner_key = send_request({"command": "key", "key": "enter", "clientID": reopened_owner_client_id})
        if not owner_key.get("ok"):
            raise RuntimeError(f"Reopened owner key failed: {owner_key}")
        final_tail = wait_for_tail_contains(send_request, "line1:desktop-return", client_id=mobile_client["id"])

        print(
            "Mobile terminal client POC passed "
            f"session={session_id} initial_tail_chars={len(initial_tail)} "
            f"post_takeover_tail_chars={len(second_tail)} final_tail_chars={len(final_tail)}"
        )
        return 0
    finally:
        if send_request is not None and mobile_client is not None:
            try:
                send_request({"command": "detach", "clientID": mobile_client["id"]})
            except Exception:
                pass
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
        if service_pid is not None:
            try:
                os.kill(service_pid, 15)
            except ProcessLookupError:
                pass
        shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
