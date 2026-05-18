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
    client.sendall(json.dumps(request).encode("utf-8") + b"\n")
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    return json.loads(response.decode("utf-8"))


def connect_stream(host: str, port: int, request: dict) -> socket.socket:
    stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    stream.settimeout(10)
    stream.connect((host, port))
    stream.sendall(json.dumps(request).encode("utf-8") + b"\n")
    stream.shutdown(socket.SHUT_WR)
    return stream


def wait_for_proxy_ready(process: subprocess.Popen[str], timeout: float = 10) -> tuple[str, int]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = process.stdout.readline().strip()
        if not line:
            continue
        match = re.search(r"host=([0-9.]+)\tport=(\d+)", line)
        if match:
            return match.group(1), int(match.group(2))
    raise RuntimeError("Timed out waiting for mobile bridge to become ready.")


def wait_for_stream_condition(stream: socket.socket, predicate, timeout: float = 10) -> dict:
    deadline = time.time() + timeout
    buffer = bytearray()
    last_payload = None
    while time.time() < deadline:
        chunk = stream.recv(65536)
        if not chunk:
            break
        buffer.extend(chunk)
        while b"\n" in buffer:
            line, _, remainder = buffer.partition(b"\n")
            buffer[:] = remainder
            if not line:
                continue
            payload = json.loads(line.decode("utf-8"))
            last_payload = payload
            if predicate(payload):
                return payload
    raise RuntimeError(f"Timed out waiting for streamed terminal state. Last payload: {json.dumps(last_payload or {}, indent=2)}")


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


def socket_path(spaces_root: Path, session_id: str) -> Path:
    hash_value = 5381
    for byte in f"{spaces_root}|{session_id}".encode("utf-8"):
        hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
    return Path("/tmp/spaces-terminal-sockets") / f"{hash_value:016x}.sock"


def send_unix_control_request(control_socket: Path, request: dict) -> dict:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(str(control_socket))
    client.sendall(json.dumps(request).encode("utf-8"))
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    return json.loads(response.decode("utf-8"))


def active_owner_is(client_id: str):
    def predicate(payload: dict) -> bool:
        snapshot = payload.get("attachmentSnapshot") or {}
        attachments = snapshot.get("attachments") or []
        return any(
            attachment.get("mode") == "owner"
            and attachment.get("detachedAt") is None
            and attachment.get("clientID") == client_id
            for attachment in attachments
        )

    return predicate


def snapshot_contains(needle: str):
    return lambda payload: needle in (payload.get("snapshotText") or "")


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
    bridge_process = None
    session_id = None
    mobile_client = None
    service_pid = None
    stream = None
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
        control_socket = socket_path(temp_root, session_id)

        pairing_code = "246810"
        bridge_process = subprocess.Popen(
            [
                str(spaces_cli),
                "mobile",
                "serve",
                "--host",
                "127.0.0.1",
                "--port",
                "0",
                "--pairing-code",
                pairing_code,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        bridge_host, bridge_port = wait_for_proxy_ready(bridge_process)

        client_app = {
            "installationID": str(uuid.uuid4()).upper(),
            "bundleID": "com.yogeshdhande.spacesmobile",
            "platform": "ios",
            "deviceName": "iPhone Simulator",
            "appVersion": "1.0",
        }
        paired = send_tcp_control_request(
            bridge_host, bridge_port, {"command": "pair", "pairingCode": pairing_code, "clientApp": client_app}
        )
        if not paired.get("ok"):
            raise RuntimeError(f"Pairing failed: {paired}")
        auth_token = paired.get("issuedAuthToken")
        if not auth_token:
            raise RuntimeError(f"Mobile bridge did not return an auth token: {paired}")

        def send_request(request: dict) -> dict:
            return send_tcp_control_request(
                bridge_host, bridge_port, {"authToken": auth_token, "clientApp": client_app, **request}
            )

        mobile_client = {
            "id": str(uuid.uuid4()).upper(),
            "kind": "remoteViewer",
            "identity": {"label": "iphone-viewer", "deviceName": "iPhone", "networkAddress": "10.0.0.24"},
            "connectedAt": iso_now(),
            "disconnectedAt": None,
        }

        response = send_request(
            {"command": "attach", "sessionID": session_id, "client": mobile_client, "attachmentMode": "viewer"}
        )
        if not response.get("ok"):
            raise RuntimeError(f"Attach failed: {response}")

        stream = connect_stream(
            bridge_host,
            bridge_port,
            {"authToken": auth_token, "clientApp": client_app, "command": "subscribe", "sessionID": session_id, "clientID": mobile_client["id"]},
        )
        wait_for_stream_condition(stream, snapshot_contains("ready"))
        initial_owner_client_id = wait_for_active_owner(temp_root, session_id, excluded_client_ids={mobile_client["id"]})

        blocked = send_request(
            {"command": "send", "sessionID": session_id, "text": "blocked", "appendNewline": True, "clientID": mobile_client["id"]}
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

        takeover = send_request({"command": "takeover", "sessionID": session_id, "clientID": mobile_client["id"]})
        if not takeover.get("ok"):
            raise RuntimeError(f"Takeover failed: {takeover}")
        wait_for_stream_condition(stream, active_owner_is(mobile_client["id"]))

        sent = send_request({"command": "send", "sessionID": session_id, "text": "mobile-hello", "clientID": mobile_client["id"]})
        if not sent.get("ok"):
            raise RuntimeError(f"Mobile send failed: {sent}")
        key = send_request({"command": "key", "sessionID": session_id, "key": "enter", "clientID": mobile_client["id"]})
        if not key.get("ok"):
            raise RuntimeError(f"Mobile key failed: {key}")
        wait_for_stream_condition(stream, snapshot_contains("line0:mobile-hello"))

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
        wait_for_stream_condition(stream, active_owner_is(reopened_owner_client_id))

        blocked_after_retake = send_request(
            {"command": "send", "sessionID": session_id, "text": "blocked-again", "appendNewline": True, "clientID": mobile_client["id"]}
        )
        if blocked_after_retake.get("ok"):
            raise RuntimeError(f"Mobile client should have lost ownership: {blocked_after_retake}")

        owner_sent = send_unix_control_request(
            control_socket, {"command": "send", "text": "desktop-return", "clientID": reopened_owner_client_id}
        )
        if not owner_sent.get("ok"):
            raise RuntimeError(f"Reopened owner send failed: {owner_sent}")
        owner_key = send_unix_control_request(control_socket, {"command": "key", "key": "enter", "clientID": reopened_owner_client_id})
        if not owner_key.get("ok"):
            raise RuntimeError(f"Reopened owner key failed: {owner_key}")
        wait_for_stream_condition(stream, snapshot_contains("line1:desktop-return"))

        print(f"Mobile terminal client POC passed session={session_id} owner={reopened_owner_client_id} mobile={mobile_client['id']}")
        return 0
    finally:
        if stream is not None:
            try:
                stream.close()
            except Exception:
                pass
        if bridge_process is not None:
            bridge_process.terminate()
            try:
                bridge_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge_process.kill()
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
