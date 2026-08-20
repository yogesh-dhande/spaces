#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/terminal_harness_lock.sh"
spaces_cli="${SPACES_CLI:-$repo_root/apps/macos/.build/debug/spaces}"
spacese2e="${SPACES_E2E:-$repo_root/apps/macos/.build/debug/spacese2e}"
terminal_service="${SPACESD_EXECUTABLE:-$repo_root/apps/macos/.build/debug/spacesd}"

if [[ ! -x "$spaces_cli" ]]; then
  echo "spaces CLI not found at $spaces_cli" >&2
  exit 1
fi

if [[ ! -x "$spacese2e" ]]; then
  echo "spacese2e not found at $spacese2e" >&2
  exit 1
fi

if [[ ! -x "$terminal_service" ]]; then
  echo "spacesd not found at $terminal_service" >&2
  exit 1
fi

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/spaces-device-api-profile.XXXXXX")"
export SPACES_DB_PATH="$temp_root/spaces.db"
export SPACES_RUNTIME_DIR="$temp_root/runtime"
export SPACESD_EXECUTABLE="$terminal_service"
mkdir -p "$SPACES_RUNTIME_DIR"
service_log="$temp_root/terminal-service.log"
device_api_log="$temp_root/device-api.log"
metrics_path="${METRICS_PATH:-$temp_root/metrics.json}"
trap 'stop_terminal_service_for_runtime_dir "$SPACES_RUNTIME_DIR"; pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$temp_root"' EXIT

"$terminal_service" >"$service_log" 2>&1 &
service_pid=$!
service_socket="$(terminal_service_socket_path_for_runtime_dir "$SPACES_RUNTIME_DIR")"
service_deadline=$((SECONDS + 10))
while [[ $SECONDS -lt $service_deadline ]]; do
  if [[ -S "$service_socket" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -S "$service_socket" ]]; then
  echo "Timed out waiting for spacesd socket." >&2
  cat "$service_log" >&2 || true
  exit 1
fi

# terminal create is workspace-scoped; register a fixture project and use its default workspace. This
# throwaway profile has no workspace of its own, and without an explicit id the command resolves the
# workspace from the current directory and fails outright.
fixture_project_dir="$temp_root/device-api-fixture-project"
mkdir -p "$fixture_project_dir"
fixture_workspace_id="$("$spacese2e" register-project --project-dir "$fixture_project_dir" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

session_output="$("$spaces_cli" terminal create --workspace "$fixture_workspace_id" --command 'echo ready; cat' --title 'device-api-profile')"
session_id="$(awk '/Started terminal session/ { print $4 }' <<<"$session_output")"
if [[ -z "$session_id" ]]; then
  echo "Failed to parse session id from: $session_output" >&2
  exit 1
fi

"$spacese2e" mobile-serve --host 127.0.0.1 --port 0 >"$device_api_log" 2>&1 &
device_api_pid=$!

ready_deadline=$((SECONDS + 10))
while [[ $SECONDS -lt $ready_deadline ]]; do
  if grep -q 'Spaces Device API ready' "$device_api_log"; then
    break
  fi
  sleep 0.1
done

if ! grep -q 'Spaces Device API ready' "$device_api_log"; then
  echo "Timed out waiting for device API readiness." >&2
  cat "$device_api_log" >&2 || true
  exit 1
fi

parsed_device_api="$(
python3 - "$device_api_log" <<'PY'
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
print(f"device_api_port={shlex.quote(port_match.group(1))}")
print(f"pairing_link={shlex.quote(link)}")
print(f"certificate_fingerprint={shlex.quote(values['fp'][0])}")
print(f"pairing_code={shlex.quote(values['code'][0])}")
print(f"pairing_nonce={shlex.quote(values['nonce'][0])}")
print(f"protocol_version={shlex.quote(values['pv'][0])}")
PY
)"
eval "$parsed_device_api"

SESSION_ID="$session_id" \
PAIRING_CODE="$pairing_code" \
PAIRING_NONCE="$pairing_nonce" \
PROTOCOL_VERSION="$protocol_version" \
DEVICE_API_PORT="$device_api_port" \
CERTIFICATE_FINGERPRINT="$certificate_fingerprint" \
SPACES_E2E="$spacese2e" \
METRICS_PATH="$metrics_path" \
python3 - <<'PY'
import base64
import json
import os
import select
import subprocess
import time
import uuid
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ["DEVICE_API_PORT"])
SESSION_ID = os.environ["SESSION_ID"]
PAIRING_CODE = os.environ["PAIRING_CODE"]
PAIRING_NONCE = os.environ["PAIRING_NONCE"]
PROTOCOL_VERSION = int(os.environ["PROTOCOL_VERSION"])
CERTIFICATE_FINGERPRINT = os.environ["CERTIFICATE_FINGERPRINT"]
SPACES_E2E = os.environ["SPACES_E2E"]
SPACES_DB_PATH = Path(os.environ["SPACES_DB_PATH"])


def typed_device_api_payload(payload: dict) -> dict:
    command = payload.get("command")
    if isinstance(command, dict):
        return payload
    command_payload = {key: value for key, value in payload.items() if key not in ("command", "authToken", "clientApp")}
    if command in ("attach", "detach", "heartbeat", "takeover", "send", "key", "clear", "clearScreen", "resize", "scroll"):
        command_payload["action"] = "clearScreen" if command == "clear" else command
        command_payload.setdefault("appendNewline", False)
        command_payload.setdefault("asPaste", False)
        typed_command = {"terminalControl": command_payload}
    else:
        typed_command = {command: command_payload}
    request = {key: value for key, value in payload.items() if key in ("authToken", "clientApp")}
    request["command"] = typed_command
    return request


def device_api_result(response: dict, kind: str) -> dict:
    result = response.get("result")
    assert isinstance(result, dict) and set(result) == {kind}, {"kind": kind, "response": response}
    payload = result[kind]
    assert isinstance(payload, dict), {"kind": kind, "response": response}
    return payload


def request(payload: dict) -> tuple[dict, float]:
    payload = typed_device_api_payload(payload)
    started = time.perf_counter()
    command = [
        SPACES_E2E,
        "mobile-request",
        "--host",
        HOST,
        "--port",
        str(PORT),
        f"--certificate-fingerprint={CERTIFICATE_FINGERPRINT}",
        "--request-json",
        json.dumps(payload),
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=True)
    elapsed_ms = (time.perf_counter() - started) * 1000
    return json.loads(completed.stdout), elapsed_ms


def connect_stream(payload: dict) -> subprocess.Popen:
    payload = typed_device_api_payload(payload)
    return subprocess.Popen(
        [
            SPACES_E2E,
            "mobile-request",
            "--host",
            HOST,
            "--port",
            str(PORT),
            f"--certificate-fingerprint={CERTIFICATE_FINGERPRINT}",
            "--request-json",
            json.dumps(payload),
            "--stream",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


render_update_baselines: dict[str, dict] = {}

# GhosttyRenderUpdate.currentVersion. Bumped in lockstep with the Swift codec; there is deliberately no
# compatibility path for older versions, so a mismatch is rejected rather than misread.
RENDER_UPDATE_VERSION = 5

# The two high bits of a cell's wire flags word are codec-reserved payload markers, not style flags: the
# cell is followed, in its block's sparse text section, by its grapheme cluster (bit 15) and/or its OSC 8
# link URL (bit 14). Style flags occupy bits 0-10 and never reach these, so a decoder strips them off the
# flags value it reports.
CLUSTER_PAYLOAD_FLAG = 1 << 15
LINK_PAYLOAD_FLAG = 1 << 14
PAYLOAD_FLAG_MASK = CLUSTER_PAYLOAD_FLAG | LINK_PAYLOAD_FLAG


class RenderUpdateReader:
    nil_revision = (1 << 64) - 1

    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def read(self, count: int) -> bytes:
        if count < 0 or self.offset + count > len(self.data):
            raise ValueError("truncated render update")
        value = self.data[self.offset : self.offset + count]
        self.offset += count
        return value

    def u8(self) -> int:
        return self.read(1)[0]

    def u16(self) -> int:
        return int.from_bytes(self.read(2), "little", signed=False)

    def u32(self) -> int:
        return int.from_bytes(self.read(4), "little", signed=False)

    def u64(self) -> int:
        return int.from_bytes(self.read(8), "little", signed=False)

    def i32(self) -> int:
        return int.from_bytes(self.read(4), "little", signed=True)

    def revision(self) -> int | None:
        value = self.u64()
        return None if value == self.nil_revision else value

    def string(self) -> str:
        return self.read(self.u16()).decode("utf-8")


def read_render_update_cell_block(reader: RenderUpdateReader, count: int) -> list[dict]:
    """Reads one block of `count` 14-byte cells plus the sparse text section that follows it.

    That section holds one entry per payload flag bit the cells set, in cell order and cluster before link,
    each `(UInt32 offset within the block, UInt16 utf8 byte count, bytes)`; a block whose cells set no
    payload bits is followed by nothing at all. This harness renders base codepoints only, so the payload
    text is read purely to keep the reader aligned with the rest of the frame.
    """
    cells = []
    flagged = []
    for index in range(count):
        codepoint = reader.u32()
        foreground_rgb = reader.u32()
        background_rgb = reader.u32()
        flags = reader.u16()
        if flags & PAYLOAD_FLAG_MASK:
            flagged.append((index, flags))
        cells.append(
            {
                "codepoint": codepoint,
                "foregroundRGB": foreground_rgb,
                "backgroundRGB": background_rgb,
                "flags": flags & ~PAYLOAD_FLAG_MASK,
            }
        )
    for index, flags in flagged:
        for payload_flag in (CLUSTER_PAYLOAD_FLAG, LINK_PAYLOAD_FLAG):
            if not flags & payload_flag:
                continue
            offset = reader.u32()
            if offset != index:
                raise ValueError(f"render update cell payload names offset {offset}, expected {index}")
            reader.read(reader.u16())
    return cells


def read_render_update_snapshot(reader: RenderUpdateReader, columns: int, rows: int) -> dict:
    cursor_column = reader.u16()
    cursor_row = reader.u16()
    cursor_visible = reader.u8() != 0
    default_foreground_rgb = reader.u32()
    default_background_rgb = reader.u32()
    _ = reader.u8()  # mouse reporting active
    _ = reader.u8()  # mouse shift capture
    _ = reader.read(17)  # selection and scrollbar section (flag byte, four coordinates, two scrollbar counters)
    cell_count = reader.u32()
    return {
        "columns": columns,
        "rows": rows,
        "cursorColumn": cursor_column,
        "cursorRow": cursor_row,
        "cursorVisible": cursor_visible,
        "defaultForegroundRGB": default_foreground_rgb,
        "defaultBackgroundRGB": default_background_rgb,
        "cells": read_render_update_cell_block(reader, cell_count),
    }


def read_render_update_delta(
    reader: RenderUpdateReader, base_revision: int | None, target_revision: int | None, owner_epoch: int, columns: int, rows: int
) -> dict:
    cursor_column = reader.u16()
    cursor_row = reader.u16()
    cursor_visible = reader.u8() != 0
    default_foreground_rgb = reader.u32()
    default_background_rgb = reader.u32()
    _ = reader.u8()  # mouse reporting active
    _ = reader.u8()  # mouse shift capture
    _ = reader.read(17)  # selection and scrollbar section (flag byte, four coordinates, two scrollbar counters)
    _ = reader.u8()  # scroll rects overflowed
    changed_cell_count = reader.u32()
    delta = {
        "baseRevision": base_revision,
        "targetRevision": target_revision,
        "ownerEpoch": owner_epoch,
        "columns": columns,
        "rows": rows,
        "cursorColumn": cursor_column,
        "cursorRow": cursor_row,
        "cursorVisible": cursor_visible,
        "defaultForegroundRGB": default_foreground_rgb,
        "defaultBackgroundRGB": default_background_rgb,
        "changedCellCount": changed_cell_count,
        "scrollRects": [],
        "replaceCellRuns": [],
    }
    for _ in range(reader.u32()):
        delta["scrollRects"].append(
            {
                "rowStart": reader.u16(),
                "rowCount": reader.u16(),
                "columnStart": reader.u16(),
                "columnCount": reader.u16(),
                "deltaRows": reader.i32(),
                "deltaColumns": reader.i32(),
            }
        )
    for _ in range(reader.u32()):
        row = reader.u16()
        column = reader.u16()
        cell_count = reader.u16()
        delta["replaceCellRuns"].append(
            {"row": row, "column": column, "cells": read_render_update_cell_block(reader, cell_count)}
        )
    return delta


def decode_render_update(payload: dict) -> dict | None:
    encoded = payload.get("renderUpdate")
    if not encoded:
        return None
    reader = RenderUpdateReader(base64.b64decode(encoded))
    if reader.read(4) != b"GRTU":
        raise ValueError("invalid render update magic")
    version = reader.u8()
    if version != RENDER_UPDATE_VERSION:
        raise ValueError(f"unsupported render update version {version} (expected {RENDER_UPDATE_VERSION})")
    kind_byte = reader.u8()
    _ = reader.u16()
    session_revision = reader.revision()
    base_revision = reader.revision()
    target_revision = reader.revision()
    owner_epoch = reader.u64()
    columns = reader.u16()
    rows = reader.u16()
    _ = reader.string()
    if kind_byte == 1:
        return {
            "kind": "full",
            "sessionRevision": session_revision,
            "ownerEpoch": owner_epoch,
            "snapshot": read_render_update_snapshot(reader, columns, rows),
        }
    if kind_byte == 2:
        return {
            "kind": "delta",
            "delta": read_render_update_delta(reader, base_revision, target_revision, owner_epoch, columns, rows),
        }
    return None


def apply_render_update_delta(delta: dict, snapshot: dict) -> dict:
    columns = int(snapshot.get("columns") or 0)
    rows = int(snapshot.get("rows") or 0)
    if columns != delta["columns"] or rows != delta["rows"]:
        raise ValueError("render update dimension mismatch")
    cells = list(snapshot.get("cells") or [])[: columns * rows]
    if len(cells) < columns * rows:
        raise ValueError("render update baseline grid is incomplete")
    blank = {
        "codepoint": 0,
        "foregroundRGB": delta["defaultForegroundRGB"],
        "backgroundRGB": delta["defaultBackgroundRGB"],
        "flags": 0,
    }
    for operation in delta["scrollRects"]:
        row_start = operation["rowStart"]
        row_count = operation["rowCount"]
        column_start = operation["columnStart"]
        column_count = operation["columnCount"]
        original = list(cells)
        for row in range(row_start, row_start + row_count):
            for column in range(column_start, column_start + column_count):
                cells[row * columns + column] = blank
        for source_row in range(row_start, row_start + row_count):
            for source_column in range(column_start, column_start + column_count):
                destination_row = source_row + operation["deltaRows"]
                destination_column = source_column + operation["deltaColumns"]
                if (
                    destination_row < row_start
                    or destination_row >= row_start + row_count
                    or destination_column < column_start
                    or destination_column >= column_start + column_count
                ):
                    continue
                cells[destination_row * columns + destination_column] = original[source_row * columns + source_column]
    for run in delta["replaceCellRuns"]:
        start = run["row"] * columns + run["column"]
        cells[start : start + len(run["cells"])] = run["cells"]
    return {
        "columns": columns,
        "rows": rows,
        "cursorColumn": delta["cursorColumn"],
        "cursorRow": delta["cursorRow"],
        "cursorVisible": delta["cursorVisible"],
        "defaultForegroundRGB": delta["defaultForegroundRGB"],
        "defaultBackgroundRGB": delta["defaultBackgroundRGB"],
        "cells": cells,
    }


def materialize_render_update(payload: dict) -> dict:
    session_id = payload.get("sessionID")
    if not session_id or not payload.get("renderUpdate"):
        return payload
    # A decode error is raised, not skipped: it means this harness and the codec disagree about the wire
    # format, and swallowing it turns that into the far less useful "timed out waiting for streamed
    # terminal state" further down, with the real cause nowhere in the output.
    update = decode_render_update(payload)
    if not update:
        return payload
    if update["kind"] == "full":
        baseline = {
            "sessionRevision": update["sessionRevision"],
            "ownerEpoch": update["ownerEpoch"],
            "snapshot": update["snapshot"],
        }
    else:
        baseline = render_update_baselines.get(session_id)
        if not baseline:
            return payload
        delta = update["delta"]
        if baseline.get("sessionRevision") != delta["baseRevision"] or baseline.get("ownerEpoch") != delta["ownerEpoch"]:
            return payload
        baseline = {
            "sessionRevision": delta["targetRevision"],
            "ownerEpoch": delta["ownerEpoch"],
            "snapshot": apply_render_update_delta(delta, baseline["snapshot"]),
        }
    render_update_baselines[session_id] = baseline
    materialized = dict(payload)
    materialized["_materializedRenderSnapshot"] = baseline["snapshot"]
    return materialized


def plain_text(payload: dict) -> str:
    snapshot = payload.get("_materializedRenderSnapshot") or {}
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
        payload = materialize_render_update(json.loads(line))
        if predicate(payload):
            return payload, (time.perf_counter() - started) * 1000, len(line.encode("utf-8"))
    raise RuntimeError("Timed out waiting for streamed terminal state.")


client_app = {
    "installationID": str(uuid.uuid4()).upper(),
    "bundleID": "dev.usespaces.spacesmobile",
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
    "clientProtocolVersion": PROTOCOL_VERSION,
    "clientApp": client_app,
})
assert pair_response["ok"], pair_response
auth_token = device_api_result(pair_response, "issuedAuthToken")["authToken"]
assert auth_token, pair_response

overview, overview_ms = request({"command": "overview", "authToken": auth_token, "clientApp": client_app})
assert overview["ok"], overview
assert any(session["id"] == SESSION_ID for session in device_api_result(overview, "overview")["sessions"]), overview

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
metrics_path = os.environ.get("METRICS_PATH")
if metrics_path:
    path = Path(metrics_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
print(json.dumps(metrics, indent=2, sort_keys=True))
PY

kill "$device_api_pid" >/dev/null 2>&1 || true
wait "$device_api_pid" >/dev/null 2>&1 || true
stop_terminal_service_for_runtime_dir "$SPACES_RUNTIME_DIR"
wait "$service_pid" >/dev/null 2>&1 || true
