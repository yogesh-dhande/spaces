#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
spaces_cli="${SPACES_CLI:-$repo_root/apps/macos/.build/debug/spaces}"
terminal_service="${SPACES_TERMINAL_SERVICE_EXECUTABLE:-$repo_root/apps/macos/.build/debug/SpacesTerminalService}"

if [[ ! -x "$spaces_cli" ]]; then
  echo "spaces CLI not found at $spaces_cli" >&2
  exit 1
fi

if [[ ! -x "$terminal_service" ]]; then
  echo "SpacesTerminalService not found at $terminal_service" >&2
  exit 1
fi

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/spaces-mobile-bridge-profile.XXXXXX")"
export SPACES_DB_PATH="$temp_root/spaces.db"
export SPACES_TERMINAL_SERVICE_EXECUTABLE="$terminal_service"
service_log="$temp_root/terminal-service.log"
bridge_log="$temp_root/mobile-bridge.log"
pairing_code="246810"
trap 'pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$temp_root"' EXIT

"$terminal_service" >"$service_log" 2>&1 &
service_pid=$!
service_socket="$(python3 - <<'PY'
import os

root = os.path.dirname(os.environ["SPACES_DB_PATH"])
terminal_root = os.path.join(root, "terminal")
hash_value = 5381
for byte in terminal_root.encode("utf-8"):
    hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
print(f"/tmp/spaces-terminal-sockets/service-{hash_value:016x}.sock")
PY
)"
service_deadline=$((SECONDS + 10))
while [[ $SECONDS -lt $service_deadline ]]; do
  if [[ -S "$service_socket" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -S "$service_socket" ]]; then
  echo "Timed out waiting for SpacesTerminalService socket." >&2
  cat "$service_log" >&2 || true
  exit 1
fi

session_output="$("$spaces_cli" terminal command --command 'echo ready; cat' --title 'mobile-bridge-profile')"
session_id="$(awk '/Started terminal session/ { print $4 }' <<<"$session_output")"
if [[ -z "$session_id" ]]; then
  echo "Failed to parse session id from: $session_output" >&2
  exit 1
fi

"$spaces_cli" mobile serve --host 127.0.0.1 --port 0 --pairing-code "$pairing_code" >"$bridge_log" 2>&1 &
bridge_pid=$!

ready_deadline=$((SECONDS + 10))
while [[ $SECONDS -lt $ready_deadline ]]; do
  if grep -q 'Spaces mobile bridge ready' "$bridge_log"; then
    break
  fi
  sleep 0.1
done

if ! grep -q 'Spaces mobile bridge ready' "$bridge_log"; then
  echo "Timed out waiting for mobile bridge readiness." >&2
  cat "$bridge_log" >&2 || true
  exit 1
fi

bridge_port="$(python3 - "$bridge_log" <<'PY'
import pathlib
import re
import sys

log_path = pathlib.Path(sys.argv[1])
content = log_path.read_text()
match = re.search(r"port=(\d+)", content)
if not match:
    raise SystemExit(1)
print(match.group(1))
PY
)"

SESSION_ID="$session_id" PAIRING_CODE="$pairing_code" BRIDGE_PORT="$bridge_port" python3 - <<'PY'
import json
import os
import socket
import time
import uuid
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ["BRIDGE_PORT"])
SESSION_ID = os.environ["SESSION_ID"]
PAIRING_CODE = os.environ["PAIRING_CODE"]
SPACES_DB_PATH = Path(os.environ["SPACES_DB_PATH"])


def request(payload: dict) -> tuple[dict, float]:
    started = time.perf_counter()
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect((HOST, PORT))
    client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    elapsed_ms = (time.perf_counter() - started) * 1000
    return json.loads(response.decode("utf-8")), elapsed_ms


def connect_stream(payload: dict) -> socket.socket:
    stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    stream.settimeout(10)
    stream.connect((HOST, PORT))
    stream.sendall(json.dumps(payload).encode("utf-8") + b"\n")
    stream.shutdown(socket.SHUT_WR)
    return stream


def wait_for_line(stream: socket.socket, predicate, timeout: float = 10) -> tuple[dict, float]:
    deadline = time.perf_counter() + timeout
    started = time.perf_counter()
    buffer = bytearray()
    while time.perf_counter() < deadline:
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
            if predicate(payload):
                return payload, (time.perf_counter() - started) * 1000
    raise RuntimeError("Timed out waiting for streamed terminal state.")


client_app = {
    "installationID": str(uuid.uuid4()).upper(),
    "bundleID": "com.yogeshdhande.spacesmobile",
    "platform": "ios",
    "deviceName": "iPad Pro Simulator",
    "appVersion": "1.0",
}

desktop_owner_client_id = str(uuid.uuid4()).upper()
desktop_owner = {
    "id": desktop_owner_client_id,
    "kind": "localWindow",
    "identity": {
        "label": "Spaces window",
        "hostName": "localhost",
        "deviceName": "Mac",
        "networkAddress": "127.0.0.1",
    },
    "connectedAt": "2026-05-18T10:00:00Z",
    "disconnectedAt": None,
}

pair_response, pair_ms = request({"command": "pair", "pairingCode": PAIRING_CODE, "clientApp": client_app})
assert pair_response["ok"], pair_response
auth_token = pair_response["issuedAuthToken"]
assert auth_token, pair_response

overview, overview_ms = request({"command": "overview", "authToken": auth_token, "clientApp": client_app})
assert overview["ok"], overview
assert any(session["id"] == SESSION_ID for session in overview["overview"]["sessions"]), overview

desktop_attach, desktop_attach_ms = request({
    "command": "attach",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "client": desktop_owner,
    "attachmentMode": "owner",
})
assert desktop_attach["ok"], desktop_attach

mobile_client_id = str(uuid.uuid4()).upper()
mobile_client = {
    "id": mobile_client_id,
    "kind": "remoteViewer",
    "identity": {
        "label": "iPad Pro Simulator",
        "deviceName": "iPad Pro Simulator",
        "networkAddress": "127.0.0.1",
    },
    "connectedAt": "2026-05-18T10:00:00Z",
    "disconnectedAt": None,
}

attach, attach_ms = request({
    "command": "attach",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "client": mobile_client,
    "attachmentMode": "viewer",
})
assert attach["ok"], attach

stream = connect_stream({
    "command": "subscribe",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "clientID": mobile_client_id,
})
initial_state, initial_state_ms = wait_for_line(stream, lambda payload: payload.get("sessionID") == SESSION_ID)
assert initial_state.get("snapshotText") is not None, initial_state

takeover, ios_takeover_rpc_ms = request({
    "command": "takeover",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "clientID": mobile_client_id,
})
assert takeover["ok"], takeover

def owner_is(client_id: str):
    def predicate(payload: dict) -> bool:
        snapshot = payload.get("attachmentSnapshot") or {}
        attachments = snapshot.get("attachments") or []
        return any(
            attachment.get("mode") == "owner" and attachment.get("detachedAt") is None and attachment.get("clientID") == client_id
            for attachment in attachments
        )
    return predicate


_, ios_takeover_visible_ms = wait_for_line(stream, owner_is(mobile_client_id))

send, ios_send_rpc_ms = request({
    "command": "send",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "clientID": mobile_client_id,
    "text": "ios-ownership",
})
assert send["ok"], send
enter, ios_enter_rpc_ms = request({
    "command": "key",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "clientID": mobile_client_id,
    "key": "enter",
})
assert enter["ok"], enter
_, ios_input_visible_ms = wait_for_line(stream, lambda payload: "ios-ownership" in (payload.get("snapshotText") or ""))

desktop_takeover, mac_takeover_rpc_ms = request({
    "command": "takeover",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "clientID": desktop_owner_client_id,
})
assert desktop_takeover["ok"], desktop_takeover
_, mac_takeover_visible_ms = wait_for_line(stream, owner_is(desktop_owner_client_id))

desktop_send, mac_send_rpc_ms = request({
    "command": "send",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "clientID": desktop_owner_client_id,
    "text": "desktop-return",
})
assert desktop_send["ok"], desktop_send
desktop_enter, mac_enter_rpc_ms = request({
    "command": "key",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "clientID": desktop_owner_client_id,
    "key": "enter",
})
assert desktop_enter["ok"], desktop_enter
_, mac_input_visible_ms = wait_for_line(stream, lambda payload: "desktop-return" in (payload.get("snapshotText") or ""))

stream.close()

metrics = {
    "session_id": SESSION_ID,
    "pair_ms": round(pair_ms, 1),
    "overview_ms": round(overview_ms, 1),
    "desktop_attach_ms": round(desktop_attach_ms, 1),
    "ios_attach_ms": round(attach_ms, 1),
    "initial_state_ms": round(initial_state_ms, 1),
    "ios_takeover_rpc_ms": round(ios_takeover_rpc_ms, 1),
    "ios_takeover_visible_ms": round(ios_takeover_visible_ms, 1),
    "ios_send_rpc_ms": round(ios_send_rpc_ms, 1),
    "ios_enter_rpc_ms": round(ios_enter_rpc_ms, 1),
    "ios_input_visible_ms": round(ios_input_visible_ms, 1),
    "mac_takeover_rpc_ms": round(mac_takeover_rpc_ms, 1),
    "mac_takeover_visible_ms": round(mac_takeover_visible_ms, 1),
    "mac_send_rpc_ms": round(mac_send_rpc_ms, 1),
    "mac_enter_rpc_ms": round(mac_enter_rpc_ms, 1),
    "mac_input_visible_ms": round(mac_input_visible_ms, 1),
}
print(json.dumps(metrics, indent=2, sort_keys=True))
PY

kill "$bridge_pid" >/dev/null 2>&1 || true
kill "$service_pid" >/dev/null 2>&1 || true
wait "$bridge_pid" >/dev/null 2>&1 || true
wait "$service_pid" >/dev/null 2>&1 || true
