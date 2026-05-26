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
export SPACES_RUNTIME_DIR="$temp_root/runtime"
export SPACES_TERMINAL_SERVICE_EXECUTABLE="$terminal_service"
mkdir -p "$SPACES_RUNTIME_DIR"
service_log="$temp_root/terminal-service.log"
bridge_log="$temp_root/mobile-bridge.log"
trap 'pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$temp_root"' EXIT

"$terminal_service" >"$service_log" 2>&1 &
service_pid=$!
service_socket="$(python3 - <<'PY'
import os
import pathlib

terminal_root = str(pathlib.Path(os.environ["SPACES_RUNTIME_DIR"]) / "terminal")
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

"$spaces_cli" mobile serve --host 127.0.0.1 --port 0 >"$bridge_log" 2>&1 &
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

parsed_bridge="$(
python3 - "$bridge_log" <<'PY'
import pathlib
import re
import shlex
import sys
from urllib.parse import parse_qs, urlparse

log_path = pathlib.Path(sys.argv[1])
content = log_path.read_text()
port_match = re.search(r"port=(\d+)", content)
link_match = re.search(r"pairing_link=([^\t\n]+)", content)
if not port_match or not link_match:
    raise SystemExit(1)
link = link_match.group(1)
values = parse_qs(urlparse(link).query)
print(f"bridge_port={shlex.quote(port_match.group(1))}")
print(f"pairing_link={shlex.quote(link)}")
print(f"transport_key={shlex.quote(values['psk'][0])}")
print(f"pairing_code={shlex.quote(values['code'][0])}")
print(f"pairing_nonce={shlex.quote(values['nonce'][0])}")
PY
)"
eval "$parsed_bridge"

SESSION_ID="$session_id" \
PAIRING_LINK="$pairing_link" \
PAIRING_CODE="$pairing_code" \
PAIRING_NONCE="$pairing_nonce" \
BRIDGE_PORT="$bridge_port" \
TRANSPORT_KEY="$transport_key" \
SPACES_CLI="$spaces_cli" \
python3 - <<'PY'
import json
import os
import select
import subprocess
import time
import uuid
import base64
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ["BRIDGE_PORT"])
SESSION_ID = os.environ["SESSION_ID"]
PAIRING_LINK = os.environ["PAIRING_LINK"]
PAIRING_CODE = os.environ["PAIRING_CODE"]
PAIRING_NONCE = os.environ["PAIRING_NONCE"]
TRANSPORT_KEY = os.environ["TRANSPORT_KEY"]
SPACES_CLI = os.environ["SPACES_CLI"]
SPACES_DB_PATH = Path(os.environ["SPACES_DB_PATH"])


def request(payload: dict) -> tuple[dict, float]:
    started = time.perf_counter()
    command = [
        SPACES_CLI,
        "mobile",
        "request",
        "--host",
        HOST,
        "--port",
        str(PORT),
        "--transport-key",
        TRANSPORT_KEY,
        "--request-json",
        json.dumps(payload),
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=True)
    elapsed_ms = (time.perf_counter() - started) * 1000
    return json.loads(completed.stdout), elapsed_ms


def connect_stream(payload: dict) -> subprocess.Popen:
    return subprocess.Popen(
        [
            SPACES_CLI,
            "mobile",
            "request",
            "--host",
            HOST,
            "--port",
            str(PORT),
            "--transport-key",
            TRANSPORT_KEY,
            "--request-json",
            json.dumps(payload),
            "--stream",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def plain_text(payload: dict) -> str:
    if payload.get("snapshotText"):
        return payload["snapshotText"]
    if payload.get("transcriptTail"):
        return payload["transcriptTail"]
    if payload.get("outputData"):
        return base64.b64decode(payload["outputData"]).decode("utf-8", errors="replace")

    snapshot = payload.get("snapshot") or {}
    columns = int(snapshot.get("columns") or 0)
    rows = int(snapshot.get("rows") or 0)
    cells = snapshot.get("cells") or []
    if columns <= 0 or rows <= 0 or len(cells) < columns * rows:
        return ""

    lines: list[str] = []
    for row in range(rows):
        start = row * columns
        row_cells = cells[start : start + columns]
        characters = []
        for cell in row_cells:
            codepoint = int(cell.get("codepoint") or 0)
            characters.append(chr(codepoint) if codepoint > 0 else " ")
        lines.append("".join(characters).rstrip())
    return "\n".join(lines)


def wait_for_line(stream: subprocess.Popen, predicate, timeout: float = 10) -> tuple[dict, float, int]:
    if stream.stdout is None:
        raise RuntimeError("Stream stdout was not captured.")
    deadline = time.perf_counter() + timeout
    started = time.perf_counter()
    while time.perf_counter() < deadline:
        ready, _, _ = select.select([stream.stdout], [], [], max(0.0, deadline - time.perf_counter()))
        if not ready:
            continue
        line = stream.stdout.readline()
        if not line:
            break
        payload = json.loads(line)
        if predicate(payload):
            return payload, (time.perf_counter() - started) * 1000, len(line.encode("utf-8"))
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

pair_response, pair_ms = request({
    "command": "pair",
    "pairingCode": PAIRING_CODE,
    "pairingNonce": PAIRING_NONCE,
    "clientApp": client_app,
})
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
initial_state, initial_state_ms, initial_state_bytes = wait_for_line(stream, lambda payload: payload.get("sessionID") == SESSION_ID)

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


_, ios_takeover_visible_ms, ios_takeover_visible_bytes = wait_for_line(stream, owner_is(mobile_client_id))

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
_, ios_input_visible_ms, ios_input_visible_bytes = wait_for_line(stream, lambda payload: "ios-ownership" in plain_text(payload))

desktop_takeover, mac_takeover_rpc_ms = request({
    "command": "takeover",
    "authToken": auth_token,
    "clientApp": client_app,
    "sessionID": SESSION_ID,
    "clientID": desktop_owner_client_id,
})
assert desktop_takeover["ok"], desktop_takeover
_, mac_takeover_visible_ms, mac_takeover_visible_bytes = wait_for_line(stream, owner_is(desktop_owner_client_id))

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
_, mac_input_visible_ms, mac_input_visible_bytes = wait_for_line(stream, lambda payload: "desktop-return" in plain_text(payload))

stream.terminate()
try:
    stream.wait(timeout=5)
except subprocess.TimeoutExpired:
    stream.kill()

metrics = {
    "session_id": SESSION_ID,
    "pair_ms": round(pair_ms, 1),
    "overview_ms": round(overview_ms, 1),
    "desktop_attach_ms": round(desktop_attach_ms, 1),
    "ios_attach_ms": round(attach_ms, 1),
    "initial_state_ms": round(initial_state_ms, 1),
    "initial_state_bytes": initial_state_bytes,
    "ios_takeover_rpc_ms": round(ios_takeover_rpc_ms, 1),
    "ios_takeover_visible_ms": round(ios_takeover_visible_ms, 1),
    "ios_takeover_visible_bytes": ios_takeover_visible_bytes,
    "ios_send_rpc_ms": round(ios_send_rpc_ms, 1),
    "ios_enter_rpc_ms": round(ios_enter_rpc_ms, 1),
    "ios_input_visible_ms": round(ios_input_visible_ms, 1),
    "ios_input_visible_bytes": ios_input_visible_bytes,
    "mac_takeover_rpc_ms": round(mac_takeover_rpc_ms, 1),
    "mac_takeover_visible_ms": round(mac_takeover_visible_ms, 1),
    "mac_takeover_visible_bytes": mac_takeover_visible_bytes,
    "mac_send_rpc_ms": round(mac_send_rpc_ms, 1),
    "mac_enter_rpc_ms": round(mac_enter_rpc_ms, 1),
    "mac_input_visible_ms": round(mac_input_visible_ms, 1),
    "mac_input_visible_bytes": mac_input_visible_bytes,
}
print(json.dumps(metrics, indent=2, sort_keys=True))
PY

kill "$bridge_pid" >/dev/null 2>&1 || true
kill "$service_pid" >/dev/null 2>&1 || true
wait "$bridge_pid" >/dev/null 2>&1 || true
wait "$service_pid" >/dev/null 2>&1 || true
