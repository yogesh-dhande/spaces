#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

DEMO_SCRIPT="$ROOT_DIR/apps/macos/Tests/run_mobile_terminal_demo.sh"
SPACES_E2E_BIN="${SPACES_E2E:-$ROOT_DIR/apps/macos/.build/debug/spacese2e}"
REQUESTED_KEEP_ROOT="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
DEFAULT_UI_TEST_CONFIG="/tmp/spaces-mobile-ui-test-config.json"
DEMO_PORT="${SPACES_MOBILE_DEMO_PORT:-}"
FIXTURE_LINE_COUNT=520
SCROLLBACK_SWIPE_COUNT=2

DEMO_STDOUT_LOG="$(mktemp "${TMPDIR:-/tmp}/spaces-mobile-scrollback-standalone.XXXXXX")"
DEMO_PID=""
APP_PID=""
BRIDGE_PID=""
DEMO_ROOT=""
SESSION_ID=""
SECONDARY_SESSION_ID=""
BRIDGE_HOST=""
BRIDGE_PORT=""
IPAD_UDID=""
UI_TEST_CONFIG=""
ACTIVE_UI_TEST_CONFIG=""
UI_TEST_LOG=""

cleanup() {
  local exit_code=$?
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" >/dev/null 2>&1; then
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
    wait "$BRIDGE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$DEMO_PID" ]] && kill -0 "$DEMO_PID" >/dev/null 2>&1; then
    kill "$DEMO_PID" >/dev/null 2>&1 || true
    wait "$DEMO_PID" >/dev/null 2>&1 || true
  elif [[ -n "$DEMO_PID" ]]; then
    wait "$DEMO_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$DEMO_ROOT" && -d "$DEMO_ROOT" ]]; then
    if [[ "$REQUESTED_KEEP_ROOT" == "1" || $exit_code -ne 0 ]]; then
      printf 'Preserved demo root: %s\n' "$DEMO_ROOT" >&2
    else
      rm -rf "$DEMO_ROOT" || true
    fi
  fi

  rm -f "$DEMO_STDOUT_LOG"
  if [[ -n "$ACTIVE_UI_TEST_CONFIG" ]]; then
    rm -f "$ACTIVE_UI_TEST_CONFIG"
  fi
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  if [[ -f "$DEMO_STDOUT_LOG" ]]; then
    printf '\nDemo output tail:\n' >&2
    tail -n 80 "$DEMO_STDOUT_LOG" >&2 || true
  fi
  if [[ -n "$UI_TEST_LOG" && -f "$UI_TEST_LOG" ]]; then
    printf '\nUI test output tail:\n' >&2
    tail -n 120 "$UI_TEST_LOG" >&2 || true
  fi
  if [[ -n "$DEMO_ROOT" ]]; then
    if [[ -f "$DEMO_ROOT/app.log" ]]; then
      printf '\nMac app log tail:\n' >&2
      tail -n 120 "$DEMO_ROOT/app.log" >&2 || true
    fi
    if [[ -f "$DEMO_ROOT/bridge.log" ]]; then
      printf '\nBridge log tail:\n' >&2
      tail -n 120 "$DEMO_ROOT/bridge.log" >&2 || true
    fi
  fi
  exit 1
}

resolve_demo_port() {
  if [[ -n "$DEMO_PORT" ]]; then
    return
  fi

  DEMO_PORT="$(
    python3 <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
  )"
}

wait_for_demo_metadata() {
  local metadata
  while true; do
    if metadata="$(python3 - "$DEMO_STDOUT_LOG" <<'PY'
import json
import pathlib
import shlex
import sys

log_path = pathlib.Path(sys.argv[1])
decoder = json.JSONDecoder()

text = log_path.read_text(errors="replace") if log_path.exists() else ""
index = 0
while True:
    start = text.find("{", index)
    if start < 0:
        raise SystemExit(1)
    try:
        payload, _ = decoder.raw_decode(text[start:])
    except json.JSONDecodeError:
        index = start + 1
        continue
    if isinstance(payload, dict) and payload.get("root") and payload.get("sessionID"):
        fields = {
            "DEMO_ROOT": payload["root"],
            "APP_PID": str(payload["appPID"]),
            "BRIDGE_PID": str(payload["bridgePID"]),
            "SESSION_ID": payload["sessionID"],
            "SECONDARY_SESSION_ID": payload.get("secondarySessionID") or "",
            "BRIDGE_HOST": payload["bridgeHost"],
            "BRIDGE_PORT": str(payload["bridgePort"]),
            "IPAD_UDID": payload["ipadSimulatorUDID"],
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(value)}")
        raise SystemExit(0)
    index = start + 1
PY
    )"; then
      break
    fi
    if [[ -n "$DEMO_PID" ]] && ! kill -0 "$DEMO_PID" >/dev/null 2>&1; then
      fail "Standalone demo exited before printing metadata."
    fi
    sleep 0.25
  done
  eval "$metadata"
  UI_TEST_CONFIG="$DEMO_ROOT/scrollback-standalone-ui-test-config.json"
  ACTIVE_UI_TEST_CONFIG="$DEFAULT_UI_TEST_CONFIG"
  UI_TEST_LOG="$DEMO_ROOT/scrollback-standalone-ui-test.log"
}

start_demo() {
  resolve_demo_port
  printf 'Launching standalone mobile demo...\n'
  SPACES_MOBILE_DEMO_KEEP_ROOT=1 SPACES_MOBILE_DEMO_PORT="$DEMO_PORT" "$DEMO_SCRIPT" >"$DEMO_STDOUT_LOG" 2>&1 &
  DEMO_PID=$!
  wait_for_demo_metadata
  [[ -n "$SECONDARY_SESSION_ID" ]] || fail "Standalone demo did not provision a secondary terminal session."
  printf 'Demo root: %s\n' "$DEMO_ROOT"
  printf 'Primary session: %s\n' "$SESSION_ID"
  printf 'Secondary session: %s\n' "$SECONDARY_SESSION_ID"
  printf 'Bridge port: %s\n' "$DEMO_PORT"
}

launch_scrollback_fixture_on_mac_owner() {
  python3 - "$ROOT_DIR" "$DEMO_ROOT" "$SESSION_ID" "$SPACES_E2E_BIN" "$FIXTURE_LINE_COUNT" <<'PY'
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
from pathlib import Path

repo_root = Path(sys.argv[1])
demo_root = Path(sys.argv[2])
session_id = sys.argv[3]
spacese2e = Path(sys.argv[4])
line_count = int(sys.argv[5])
runtime_root = demo_root / "runtime"
attachments_path = runtime_root / "terminal" / "sessions" / session_id / "attachments.json"
owner_dump_path = demo_root / "scrollback-standalone-owner-dump.json"

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}

fixture_command = (
    f"python3 {shlex.quote(str(repo_root / 'apps/macos/Tests/terminal_stress_fixture.py'))} "
    f"--mode lines --lines {line_count} --width 32"
)

def socket_path(root: Path, session_id: str) -> Path:
    hash_value = 5381
    for byte in f"{root}|{session_id}".encode("utf-8"):
        hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
    return Path("/tmp/spaces-terminal-sockets") / f"{hash_value:016x}.sock"

def current_owner_client_id() -> str:
    payload = json.loads(attachments_path.read_text())
    for attachment in payload:
        if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None:
            client_id = attachment.get("clientID")
            if client_id:
                return client_id
    raise RuntimeError("No active owner attachment was found for the demo session.")

def send_request(request: dict) -> dict:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(str(socket_path(demo_root, session_id)))
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

def dump_owner_window() -> dict:
    if owner_dump_path.exists():
        owner_dump_path.unlink()
    result = subprocess.run(
        [str(spacese2e), "dump-terminal-session-window-state", "--session-id", session_id, "--output-path", str(owner_dump_path)],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    deadline = time.time() + 5
    while time.time() < deadline:
        if owner_dump_path.exists():
            return json.loads(owner_dump_path.read_text())
        time.sleep(0.05)
    raise RuntimeError(
        "Timed out waiting for owner window dump output. "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )

owner_client_id = current_owner_client_id()
for request in (
    {"command": "send", "text": fixture_command, "clientID": owner_client_id},
    {"command": "key", "key": "enter", "clientID": owner_client_id},
):
    response = send_request(request)
    if not response.get("ok"):
        raise RuntimeError(f"Fixture launch request failed: {response}")

deadline = time.time() + 60
while time.time() < deadline:
    rendered_output = dump_owner_window().get("renderedOutput") or ""
    if f"FIXTURE_DONE mode=lines emitted={line_count}" in rendered_output and f"SEQ {line_count:08d}" in rendered_output:
        raise SystemExit(0)
    time.sleep(0.25)

raise RuntimeError("Timed out waiting for the standalone scrollback fixture to complete.")
PY
}

write_ui_test_config() {
  python3 - "$DEMO_ROOT" "$SESSION_ID" "$BRIDGE_HOST" "$BRIDGE_PORT" "$IPAD_UDID" "$UI_TEST_CONFIG" "$ACTIVE_UI_TEST_CONFIG" "$SCROLLBACK_SWIPE_COUNT" <<'PY'
import json
import sys
from pathlib import Path

demo_root = Path(sys.argv[1])
session_id = sys.argv[2]
bridge_host = sys.argv[3]
bridge_port = int(sys.argv[4])
ipad_udid = sys.argv[5]
config_paths = [Path(sys.argv[6]), Path(sys.argv[7])]
scrollback_swipe_count = int(sys.argv[8])

pairing = json.loads((demo_root / "pairing.json").read_text())
ipad_pairing = pairing["ipad"]

payload = {
    "sessionID": session_id,
    "host": bridge_host,
    "port": bridge_port,
    "authToken": ipad_pairing["authToken"],
    "installationID": ipad_pairing["installationID"],
    "renderDumpPath": str(demo_root / "scrollback-standalone-ipad-render.json"),
    "eventLogPath": str(demo_root / "scrollback-standalone-ipad-events.jsonl"),
    "immediateScreenshotPath": str(demo_root / "scrollback-standalone-ipad-post-takeover-immediate.png"),
    "shortDelayScreenshotPath": str(demo_root / "scrollback-standalone-ipad-post-takeover-plus-2s.png"),
    "longDelayScreenshotPath": str(demo_root / "scrollback-standalone-ipad-post-takeover-plus-6s.png"),
    "proceedTakeOverPath": None,
    "firstCommandRequestPath": str(demo_root / "scrollback-standalone-ipad-first-command-request"),
    "firstCommandFocusedPath": str(demo_root / "scrollback-standalone-ipad-first-command-focused"),
    "firstCommandCompletedPath": str(demo_root / "scrollback-standalone-ipad-first-command-completed"),
    "firstCommandObservedPath": str(demo_root / "scrollback-standalone-ipad-first-command-observed"),
    "secondCommandRequestPath": None,
    "secondCommandFocusedPath": None,
    "secondCommandCompletedPath": None,
    "secondCommandObservedPath": None,
    "proceedFinishPath": None,
    "firstCommandText": "",
    "secondCommandText": None,
    "manualRetakeoverAttempts": 0,
    "postFirstCommandScreenshotPath": str(demo_root / "scrollback-standalone-ipad-post-command-while-scrolled.png"),
    "postSecondCommandScreenshotPath": None,
    "finalScreenshotPath": str(demo_root / "scrollback-standalone-ipad-post-scrollback.png"),
    "scrollbackSwipeCount": scrollback_swipe_count,
    "attachToExistingApp": True,
    "bundleID": "com.yogeshdhande.spacesmobile",
    "ipadUDID": ipad_udid,
}

encoded = json.dumps(payload, indent=2, sort_keys=True)
for config_path in config_paths:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(encoded)
PY
}

run_scrollback_ui_test() {
  printf 'Running standalone iPad scrollback UI test...\n'
  SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
    xcodebuild \
      -project apps/ios/SpacesMobile.xcodeproj \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$IPAD_UDID" \
      -derivedDataPath "$DEMO_ROOT/ScrollbackAttachUITestDerivedData" \
      -only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList \
      test >"$UI_TEST_LOG" 2>&1 &
  local ui_test_pid=$!

  if ! python3 - "$DEMO_ROOT" <<'PY'
import json
import sys
import time
from pathlib import Path

demo_root = Path(sys.argv[1])
event_log_path = demo_root / "scrollback-standalone-ipad-events.jsonl"
performance_log_path = demo_root / "mobile-terminal-performance.jsonl"
command_request_path = Path(f"{event_log_path}.command-request.json")
first_command_request_path = demo_root / "scrollback-standalone-ipad-first-command-request"
first_command_completed_path = demo_root / "scrollback-standalone-ipad-first-command-completed"
first_command_observed_path = demo_root / "scrollback-standalone-ipad-first-command-observed"
command_text = "printf '__scrollback_after_output__\\n'"

def read_json_lines(path: Path):
    if not path.exists():
        return []
    payloads = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        payloads.append(json.loads(line))
    return payloads

def read_performance_events(path: Path):
    return read_json_lines(path)

deadline = time.time() + 90
while time.time() < deadline:
    events = read_json_lines(event_log_path)
    kinds = {event.get("kind") for event in events if event.get("kind")}
    performance_events = read_performance_events(performance_log_path)
    if (
        "e2e_scroll_gesture_applied" in kinds
        and any(event.get("name") == "owner_history_seed_apply_end" for event in performance_events)
    ):
        break
    time.sleep(0.2)
else:
    raise SystemExit("Timed out waiting for the iPad app to apply the scrollback history seed.")

command_request_path.write_text(json.dumps({
    "id": "scrollback-after-output",
    "text": command_text,
    "sendEnter": True,
}, sort_keys=True))
first_command_request_path.write_text("ready\n")

deadline = time.time() + 60
while time.time() < deadline:
    events = read_json_lines(event_log_path)
    if any(event.get("kind") == "e2e_command_request_consumed" for event in events):
        break
    time.sleep(0.2)
else:
    raise SystemExit("Timed out waiting for the iPad app to consume the post-scrollback command request.")

deadline = time.time() + 60
while time.time() < deadline:
    events = read_json_lines(event_log_path)
    send_text_success = any(event.get("kind") == "send_text_success" and command_text in (event.get("detail") or "") for event in events)
    send_key_success = any(event.get("kind") == "send_key_success" and event.get("detail") == "enter" for event in events)
    if send_text_success and send_key_success:
        break
    time.sleep(0.2)
else:
    raise SystemExit("Timed out waiting for the iPad owner command to complete while scrolled up.")

time.sleep(1.0)
first_command_completed_path.write_text("ready\n")

deadline = time.time() + 30
while time.time() < deadline:
    if first_command_observed_path.exists():
        raise SystemExit(0)
    time.sleep(0.2)

raise SystemExit("Timed out waiting for the UI test to observe the post-scrollback owner command.")
PY
  then
    kill "$ui_test_pid" >/dev/null 2>&1 || true
    wait "$ui_test_pid" >/dev/null 2>&1 || true
    fail "Standalone scrollback command orchestration failed."
  fi

  if ! wait "$ui_test_pid"; then
    fail "Standalone scrollback repro failed."
  fi
  printf 'Standalone scrollback takeover passed.\n'
}

assert_ipad_scrollback_rendered() {
  python3 - "$DEMO_ROOT" "$FIXTURE_LINE_COUNT" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

demo_root = Path(sys.argv[1])
fixture_line_count = int(sys.argv[2])
owner_dump_path = demo_root / "scrollback-standalone-owner-dump.json"
ipad_dump_path = demo_root / "scrollback-standalone-ipad-render.json"
event_log_path = demo_root / "scrollback-standalone-ipad-events.jsonl"
performance_log_path = demo_root / "mobile-terminal-performance.jsonl"

owner_payload = json.loads(owner_dump_path.read_text())
ipad_payload = json.loads(ipad_dump_path.read_text())
event_payloads = []
if event_log_path.exists():
    event_payloads = [
        json.loads(line)
        for line in event_log_path.read_text().splitlines()
        if line.strip()
    ]
owner_render_dumps = [
    payload for payload in event_payloads
    if payload.get("kind") is None and payload.get("isOwner") and (payload.get("renderedText") or "").strip()
]
performance_events = []
if performance_log_path.exists():
    performance_events = [
        json.loads(line)
        for line in performance_log_path.read_text().splitlines()
        if line.strip()
    ]

owner_text = owner_payload.get("renderedOutput") or ""
ipad_text = ipad_payload.get("renderedText") or ipad_payload.get("snapshotText") or ""
session_id = ipad_payload.get("sessionID")
session_performance_events = [
    event for event in performance_events
    if event.get("sessionID") == session_id
]


def parse_timestamp(raw_value: str | None) -> datetime | None:
    if not raw_value:
        return None
    try:
        return datetime.fromisoformat(raw_value.replace("Z", "+00:00"))
    except ValueError:
        return None

if not any(event.get("kind") == "e2e_scroll_gesture_applied" for event in event_payloads):
    raise SystemExit("The standalone iPad app never applied the scrollback drag gesture.")
if not any(event.get("kind") == "e2e_command_request_consumed" for event in event_payloads):
    raise SystemExit("The standalone iPad app never consumed the post-scrollback owner command.")
if f"FIXTURE_DONE mode=lines emitted={fixture_line_count}" not in owner_text:
    raise SystemExit("Owner baseline did not reach the bottom of the long-output fixture.")
if not ipad_text.strip():
    raise SystemExit("iPad render dump was blank after scrollback.")
for dump in owner_render_dumps:
    dump_text = dump.get("renderedText") or ""
    if any(line.strip() == "%" for line in dump_text.splitlines()):
        raise SystemExit(
            "iPad owner render contained a stray percent prompt row during scrollback.\n"
            f"replay_state={dump.get('replayStateKey')}\n"
            f"rendered_text={dump_text}"
        )

local_bootstraps = [event for event in session_performance_events if event.get("name") == "local_owner_bootstrap_begin"]
first_nonblank = [event for event in session_performance_events if event.get("name") == "owner_first_nonblank_render"]
first_input_ready = [event for event in session_performance_events if event.get("name") == "owner_first_input_ready"]
history_seed_apply_begin = [event for event in session_performance_events if event.get("name") == "owner_history_seed_apply_begin"]
history_seed_apply_end = [event for event in session_performance_events if event.get("name") == "owner_history_seed_apply_end"]
post_ready_snapshot_exports = [
    event for event in session_performance_events
    if event.get("name") == "snapshot_export_begin"
    and event.get("attributes", {}).get("reason") in {"initial", "input", "input_output"}
    and first_input_ready
    and (
        (event_time := parse_timestamp(event.get("emittedAt"))) is not None
        and event_time > parse_timestamp(first_input_ready[0].get("emittedAt"))
    )
]

if len(local_bootstraps) != 1:
    raise SystemExit(f"Expected exactly one local owner bootstrap during scrollback, found {len(local_bootstraps)}")
if len(first_nonblank) != 1:
    raise SystemExit(f"Expected exactly one first non-blank render during scrollback, found {len(first_nonblank)}")
if len(first_input_ready) != 1:
    raise SystemExit(f"Expected exactly one first input-ready event during scrollback, found {len(first_input_ready)}")
if len(history_seed_apply_begin) != 1 or len(history_seed_apply_end) != 1:
    raise SystemExit(
        "Expected exactly one lazy history seed apply during scrollback, "
        f"found begin={len(history_seed_apply_begin)} end={len(history_seed_apply_end)}"
    )
if post_ready_snapshot_exports:
    raise SystemExit(
        "Found unexpected snapshot exports after takeover became interactive during scrollback: "
        + ", ".join(event.get("attributes", {}).get("reason", "?") for event in post_ready_snapshot_exports)
    )
PY
}

start_demo
launch_scrollback_fixture_on_mac_owner
write_ui_test_config
run_scrollback_ui_test
assert_ipad_scrollback_rendered
