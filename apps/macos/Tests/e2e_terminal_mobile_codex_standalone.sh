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

DEMO_STDOUT_LOG="$(mktemp "${TMPDIR:-/tmp}/spaces-mobile-codex-standalone.XXXXXX")"
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
TAKEOVER_STARTED_AT=""

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
  UI_TEST_CONFIG="$DEMO_ROOT/codex-standalone-ui-test-config.json"
  ACTIVE_UI_TEST_CONFIG="$DEFAULT_UI_TEST_CONFIG"
  UI_TEST_LOG="$DEMO_ROOT/codex-standalone-ui-test.log"
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

launch_codex_on_mac_owner() {
  python3 - "$DEMO_ROOT" "$SESSION_ID" "$SPACES_E2E_BIN" <<'PY'
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

demo_root = Path(sys.argv[1])
session_id = sys.argv[2]
spacese2e = Path(sys.argv[3])
runtime_root = demo_root / "runtime"
attachments_path = runtime_root / "terminal" / "sessions" / session_id / "attachments.json"
owner_dump_path = demo_root / "codex-standalone-owner-dump.json"

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}

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
    {"command": "send", "text": "codex", "clientID": owner_client_id},
    {"command": "key", "key": "enter", "clientID": owner_client_id},
):
    response = send_request(request)
    if not response.get("ok"):
        raise RuntimeError(f"Codex launch request failed: {response}")

trust_prompt_confirmed = False
deadline = time.time() + 30
while time.time() < deadline:
    rendered_output = (dump_owner_window().get("renderedOutput") or "")
    if "Do you trust the contents of this directory?" in rendered_output:
        if trust_prompt_confirmed:
            time.sleep(0.2)
            continue
        response = send_request({"command": "key", "key": "enter", "clientID": owner_client_id})
        if not response.get("ok"):
            raise RuntimeError(f"Failed to confirm the Codex trust prompt: {response}")
        trust_prompt_confirmed = True
        time.sleep(0.2)
        continue
    if "OpenAI Codex" in rendered_output or "gpt-" in rendered_output:
        raise SystemExit(0)
    time.sleep(0.2)

raise RuntimeError("Timed out waiting for Codex startup output in the standalone demo session.")
PY
}

write_ui_test_config() {
  python3 - "$DEMO_ROOT" "$SESSION_ID" "$BRIDGE_HOST" "$BRIDGE_PORT" "$IPAD_UDID" "$UI_TEST_CONFIG" "$ACTIVE_UI_TEST_CONFIG" <<'PY'
import json
import sys
from pathlib import Path

demo_root = Path(sys.argv[1])
session_id = sys.argv[2]
bridge_host = sys.argv[3]
bridge_port = int(sys.argv[4])
ipad_udid = sys.argv[5]
config_paths = [Path(sys.argv[6]), Path(sys.argv[7])]

pairing = json.loads((demo_root / "pairing.json").read_text())
ipad_pairing = pairing["ipad"]

payload = {
    "sessionID": session_id,
    "host": bridge_host,
    "port": bridge_port,
    "authToken": ipad_pairing["authToken"],
    "installationID": ipad_pairing["installationID"],
    "renderDumpPath": str(demo_root / "codex-standalone-ipad-render.json"),
    "eventLogPath": str(demo_root / "codex-standalone-ipad-events.jsonl"),
    "immediateScreenshotPath": str(demo_root / "codex-standalone-ipad-post-takeover-immediate.png"),
    "shortDelayScreenshotPath": str(demo_root / "codex-standalone-ipad-post-takeover-plus-2s.png"),
    "longDelayScreenshotPath": str(demo_root / "codex-standalone-ipad-post-takeover-plus-6s.png"),
    "proceedTakeOverPath": None,
    "firstCommandRequestPath": None,
    "firstCommandFocusedPath": None,
    "firstCommandCompletedPath": None,
    "firstCommandObservedPath": None,
    "secondCommandRequestPath": None,
    "secondCommandFocusedPath": None,
    "secondCommandCompletedPath": None,
    "secondCommandObservedPath": None,
    "proceedFinishPath": None,
    "firstCommandText": "",
    "secondCommandText": None,
    "manualRetakeoverAttempts": 0,
    "postFirstCommandScreenshotPath": None,
    "postSecondCommandScreenshotPath": None,
    "finalScreenshotPath": str(demo_root / "codex-standalone-ipad-final.png"),
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

run_codex_standalone_ui_test() {
  printf 'Running standalone iPad takeover UI test...\n'
  TAKEOVER_STARTED_AT="$(
    python3 <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"))
PY
  )"
  if ! SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
    xcodebuild \
      -project apps/ios/SpacesMobile.xcodeproj \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$IPAD_UDID" \
      -derivedDataPath "$DEMO_ROOT/AttachUITestDerivedData" \
      -only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList \
      test >"$UI_TEST_LOG" 2>&1; then
    fail "Standalone Codex takeover repro failed."
  fi
  printf 'Standalone Codex takeover passed.\n'
}

assert_ipad_terminal_text_rendered() {
  local screenshot_path="$DEMO_ROOT/codex-standalone-ipad-post-takeover-plus-2s.png"
  printf 'Validating rendered iPad terminal text...\n'
  local recognized_text
  if ! recognized_text="$(swift - "$screenshot_path" <<'SWIFT'
import AppKit
import Foundation
import Vision

let screenshotPath = CommandLine.arguments[1]
let screenshotURL = URL(fileURLWithPath: screenshotPath)
guard let image = NSImage(contentsOf: screenshotURL) else {
    fputs("Unable to load screenshot at \(screenshotPath)\n", stderr)
    exit(1)
}
var proposedRect = NSRect(origin: .zero, size: image.size)
guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
    fputs("Unable to decode screenshot at \(screenshotPath)\n", stderr)
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])

let recognizedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
print(recognizedText)

let normalizedText = recognizedText.lowercased()
let requiredMarkers = [
    "openai codex",
    "find and fix a bug",
    "/model to change",
    "/mcp to list configured mcp tools",
]
if requiredMarkers.contains(where: { normalizedText.contains($0) }) {
    exit(0)
}
fputs("OCR did not find expected Codex terminal markers in \(screenshotPath)\n", stderr)
exit(1)
SWIFT
  )"; then
    printf '\nOCR output:\n%s\n' "$recognized_text" >&2
    fail "Standalone Codex takeover rendered a blank or unreadable iPad terminal surface."
  fi
}

assert_takeover_metrics() {
  python3 - "$DEMO_ROOT" "$SESSION_ID" "$TAKEOVER_STARTED_AT" <<'PY'
import json
import sys
from pathlib import Path
from datetime import datetime, timezone

demo_root = Path(sys.argv[1])
session_id = sys.argv[2]
takeover_started_at_raw = sys.argv[3]
render_dump_path = demo_root / "codex-standalone-ipad-render.json"
event_log_path = demo_root / "codex-standalone-ipad-events.jsonl"
performance_log_path = demo_root / "mobile-terminal-performance.jsonl"

def parse_timestamp(raw: str | None):
    if not raw:
        return None
    normalized = raw.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized).astimezone(timezone.utc)

render_dump = json.loads(render_dump_path.read_text())
event_payloads = [
    json.loads(line)
    for line in event_log_path.read_text().splitlines()
    if line.strip()
]
performance_events = []
if performance_log_path.exists():
    performance_events = [
        json.loads(line)
        for line in performance_log_path.read_text().splitlines()
        if line.strip()
    ]

session_events = [
    event for event in performance_events
    if event.get("sessionID") == session_id
]
takeover_started_at = parse_timestamp(takeover_started_at_raw)

if render_dump.get("renderMode") not in {"ownerBootstrapping", "ownerLive"}:
    raise SystemExit(f"Unexpected render mode after takeover: {render_dump.get('renderMode')!r}")
if not (render_dump.get("renderedText") or "").strip():
    raise SystemExit("The standalone iPad render dump was blank after takeover.")
if not render_dump.get("isInputSurfaceReady"):
    raise SystemExit("The standalone iPad owner path never reached input-ready state.")
if not any(event.get("kind") == "input_readiness" and event.get("detail") == "ready" for event in event_payloads):
    raise SystemExit("The standalone iPad event log never recorded input readiness.")

bootstrap_receipts = [event for event in session_events if event.get("name") == "owner_bootstrap_state_received"]
local_bootstraps = [event for event in session_events if event.get("name") == "local_owner_bootstrap_begin"]
first_nonblank = [event for event in session_events if event.get("name") == "owner_first_nonblank_render"]
first_input_ready = [event for event in session_events if event.get("name") == "owner_first_input_ready"]
initial_snapshot_exports = [
    event for event in session_events
    if event.get("name") == "snapshot_export_begin" and event.get("attributes", {}).get("reason") == "initial"
    and (
        takeover_started_at is None
        or (
            (event_time := parse_timestamp(event.get("emittedAt"))) is not None
            and event_time >= takeover_started_at
        )
    )
]
post_ready_snapshot_exports = [
    event for event in session_events
    if event.get("name") == "snapshot_export_begin"
    and event.get("attributes", {}).get("reason") in {"initial", "input", "input_output"}
    and first_input_ready
    and (
        (event_time := parse_timestamp(event.get("emittedAt"))) is not None
        and event_time > parse_timestamp(first_input_ready[0].get("emittedAt"))
    )
]

if len(bootstrap_receipts) != 1:
    raise SystemExit(f"Expected exactly one owner bootstrap receipt, found {len(bootstrap_receipts)}")
if len(local_bootstraps) != 1:
    raise SystemExit(f"Expected exactly one local owner bootstrap, found {len(local_bootstraps)}")
if len(first_nonblank) != 1:
    raise SystemExit(f"Expected exactly one first non-blank render event, found {len(first_nonblank)}")
if len(first_input_ready) != 1:
    raise SystemExit(f"Expected exactly one first input-ready event, found {len(first_input_ready)}")
if len(initial_snapshot_exports) != 1:
    raise SystemExit(f"Expected exactly one initial snapshot export, found {len(initial_snapshot_exports)}")
if post_ready_snapshot_exports:
    raise SystemExit(
        "Found unexpected snapshot exports after takeover became interactive: "
        + ", ".join(event.get("attributes", {}).get("reason", "?") for event in post_ready_snapshot_exports)
    )
PY
}

start_demo
launch_codex_on_mac_owner
write_ui_test_config
run_codex_standalone_ui_test
assert_ipad_terminal_text_rendered
assert_takeover_metrics
