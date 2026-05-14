#!/usr/bin/env python3

import base64
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


def socket_path_for_session(spaces_root: Path, session_id: str) -> Path:
    seed = f"{spaces_root}|{session_id}".encode("utf-8")
    hash_value = 5381
    for byte in seed:
        hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
    return Path("/tmp/spaces-terminal-sockets") / f"{hash_value:016x}.sock"


def send_control_request(socket_path: Path, request: dict) -> dict:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(str(socket_path))
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


def request_snapshot(send_request, line_count: int = 200) -> dict:
    response = send_request({"command": "snapshot", "recentOutputLineCount": line_count})
    if not response.get("ok"):
        raise RuntimeError(f"Snapshot request failed: {response}")
    return response["snapshot"]


def attach_client(send_request, client: dict, mode: str) -> None:
    response = send_request({"command": "attach", "client": client, "attachmentMode": mode})
    if not response.get("ok"):
        raise RuntimeError(f"Attach failed: {response}")


def active_owner_client_id(snapshot: dict) -> str | None:
    attachments = (snapshot.get("attachmentSnapshot") or {}).get("attachments") or []
    owners = [row for row in attachments if row["mode"] == "owner" and row.get("detachedAt") is None]
    return owners[-1]["clientID"] if owners else None


def current_output_size(send_request) -> int:
    response = send_request({"command": "output_size"})
    if not response.get("ok"):
        raise RuntimeError(f"Output-size request failed: {response}")
    return response.get("outputByteCount") or 0


def read_chunk(send_request, offset: int, maximum_bytes: int = 4096) -> bytes:
    response = send_request({"command": "read_output_chunk", "offset": offset, "maximumBytes": maximum_bytes})
    if not response.get("ok"):
        raise RuntimeError(f"Chunk request failed: {response}")
    chunk = response.get("outputChunk")
    if not chunk:
        return b""
    return base64.b64decode(chunk["bytes"])


def wait_for_session_ready(socket_path: Path, timeout: float = 10) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if socket_path.exists():
            try:
                send_control_request(socket_path, {"command": "snapshot", "recentOutputLineCount": 20})
                return
            except Exception:
                pass
        time.sleep(0.05)
    raise RuntimeError("Timed out waiting for terminal session to become ready.")


def wait_for_output_contains(send_request, needle: str, timeout: float = 10) -> str:
    deadline = time.time() + timeout
    decoded = ""
    while time.time() < deadline:
        decoded = request_snapshot(send_request, line_count=500).get("recentOutput", "")
        if needle in decoded:
            return decoded
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for output containing {needle!r}. Last output:\n{decoded}")


def wait_for_owner(send_request, client_id: str, timeout: float = 5) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if active_owner_client_id(request_snapshot(send_request, line_count=20)) == client_id:
            return
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for client {client_id} to become owner.")


def wait_for_new_bytes(send_request, offset: int, timeout: float = 5) -> bytes:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if current_output_size(send_request) > offset:
            return read_chunk(send_request, offset)
        time.sleep(0.05)
    raise RuntimeError("Timed out waiting for new output bytes.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transport", choices=["unix", "tcp"], default="tcp")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[3]
    spaces_cli = Path(os.environ.get("SPACES_CLI", repo_root / "apps/macos/.build/debug/spaces"))
    temp_root = Path(tempfile.mkdtemp(prefix="spaces-mobile-poc."))
    db_path = temp_root / "spaces.db"
    env = os.environ | {"SPACES_DB_PATH": str(db_path)}

    fixture = (
        "python3 -u -c "
        "\"import sys; print('ready', flush=True); "
        "first = sys.stdin.readline().rstrip('\\\\n'); print(f'echo:{first}', flush=True); "
        "second = sys.stdin.readline().rstrip('\\\\n'); print(f'next:{second}', flush=True); "
        "third = sys.stdin.readline().rstrip('\\\\n'); print(f'final:{third}', flush=True)\""
    )

    session_id = None
    socket_path = None
    attachments_path = None
    output_path = None
    owner_client = None
    mobile_client = None
    proxy_process = None
    send_request = None
    try:
        command = [
            str(spaces_cli),
            "terminal",
            "command",
            "--backend",
            "script-pty",
            "--command",
            fixture,
            "--title",
            "mobile-poc",
        ]
        result = subprocess.run(command, capture_output=True, text=True, env=env, check=True)
        match = re.search(r"Started terminal session ([A-F0-9-]+)", result.stdout, re.IGNORECASE)
        if not match:
            raise RuntimeError(f"Unable to parse session id from:\n{result.stdout}")
        session_id = match.group(1)
        spaces_root = db_path.parent
        session_root = spaces_root / "terminal" / "sessions" / session_id
        socket_path = socket_path_for_session(spaces_root, session_id)
        wait_for_session_ready(socket_path)
        auth_token = None
        if args.transport == "tcp":
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
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            ready_line = proxy_process.stdout.readline().strip()
            match = re.search(r"host=([0-9.]+)\tport=(\d+)", ready_line)
            if not match:
                raise RuntimeError(f"Unable to parse proxy endpoint from:\n{ready_line}")
            proxy_host = match.group(1)
            proxy_port = int(match.group(2))

            def send_request(request: dict) -> dict:
                return send_tcp_control_request(proxy_host, proxy_port, {"authToken": auth_token, **request})
        else:
            def send_request(request: dict) -> dict:
                return send_control_request(socket_path, request)

        initial_output = wait_for_output_contains(send_request, "ready")
        initial_size = current_output_size(send_request)
        if "ready" not in initial_output:
            raise RuntimeError("Initial replay did not include ready banner.")

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
        attach_client(send_request, owner_client, "owner")
        attach_client(send_request, mobile_client, "viewer")

        blocked = send_request(
            {"command": "send", "text": "blocked", "appendNewline": True, "clientID": mobile_client["id"]},
        )
        if blocked.get("ok"):
            raise RuntimeError(f"Viewer input should have been rejected: {blocked}")

        takeover = send_request({"command": "takeover", "clientID": mobile_client["id"]})
        if not takeover.get("ok"):
            raise RuntimeError(f"Takeover failed: {takeover}")
        wait_for_owner(send_request, mobile_client["id"])

        response = send_request({"command": "send", "text": "mobile-hello", "appendNewline": False, "clientID": mobile_client["id"]})
        if not response.get("ok"):
            raise RuntimeError(f"Mobile input failed: {response}")
        response = send_request({"command": "key", "key": "enter", "clientID": mobile_client["id"]})
        if not response.get("ok"):
            raise RuntimeError(f"Mobile enter key failed: {response}")

        new_bytes = wait_for_new_bytes(send_request, initial_size)
        replay = new_bytes.decode("utf-8", errors="replace")
        if "echo:mobile-hello" not in wait_for_output_contains(send_request, "echo:mobile-hello"):
            raise RuntimeError(f"Expected echoed mobile input in replay chunk:\n{replay}")

        second_offset = current_output_size(send_request)
        response = send_request({"command": "send", "text": "follow-up", "appendNewline": True, "clientID": mobile_client["id"]})
        if not response.get("ok"):
            raise RuntimeError(f"Follow-up mobile input failed: {response}")
        follow_up_bytes = wait_for_new_bytes(send_request, second_offset)
        follow_up_output = follow_up_bytes.decode("utf-8", errors="replace")
        if "next:follow-up" not in wait_for_output_contains(send_request, "next:follow-up"):
            raise RuntimeError(f"Expected follow-up output in incremental stream:\n{follow_up_output}")

        takeover_back = send_request({"command": "takeover", "clientID": owner_client["id"]})
        if not takeover_back.get("ok"):
            raise RuntimeError(f"Desktop takeover failed: {takeover_back}")
        wait_for_owner(send_request, owner_client["id"])

        third_offset = current_output_size(send_request)
        response = send_request({"command": "send", "text": "desktop-return", "appendNewline": True, "clientID": owner_client["id"]})
        if not response.get("ok"):
            raise RuntimeError(f"Desktop return input failed: {response}")
        third_bytes = wait_for_new_bytes(send_request, third_offset)
        if "final:desktop-return" not in wait_for_output_contains(send_request, "final:desktop-return"):
            raise RuntimeError(
                "Expected desktop owner input after ownership return in incremental stream:\n"
                + third_bytes.decode("utf-8", errors="replace")
            )

        blocked_again = send_request(
            {"command": "send", "text": "mobile-should-block", "appendNewline": True, "clientID": mobile_client["id"]},
        )
        if blocked_again.get("ok"):
            raise RuntimeError(f"Former mobile owner should have lost input rights: {blocked_again}")

        print(
            f"Mobile terminal client POC passed for session {session_id} transport={args.transport}: "
            f"initial_replay_bytes={initial_size} "
            f"first_incremental_bytes={len(new_bytes)} "
            f"second_incremental_bytes={len(follow_up_bytes)}"
        )
        return 0
    finally:
        if session_id and socket_path and socket_path.exists():
            owner_id = None
            if send_request is not None:
                try:
                    owner_id = active_owner_client_id(request_snapshot(send_request, line_count=20))
                except Exception:
                    owner_id = None
            try:
                send_control_request(socket_path, {"command": "terminate", "clientID": owner_id})
            except Exception:
                pass
        if proxy_process:
            proxy_process.terminate()
            try:
                proxy_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxy_process.kill()
        shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
