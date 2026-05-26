#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

DEMO_SCRIPT="$ROOT_DIR/apps/macos/Tests/run_mobile_terminal_demo.sh"
REQUESTED_KEEP_ROOT="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
DEFAULT_UI_TEST_CONFIG="/tmp/spaces-mobile-ui-test-config.json"
DEMO_PORT="${SPACES_MOBILE_DEMO_PORT:-}"

DEMO_STDOUT_LOG="$(mktemp "${TMPDIR:-/tmp}/spaces-mobile-two-session-standalone.XXXXXX")"
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
  UI_TEST_CONFIG="$DEMO_ROOT/two-session-standalone-ui-test-config.json"
  ACTIVE_UI_TEST_CONFIG="$DEFAULT_UI_TEST_CONFIG"
  UI_TEST_LOG="$DEMO_ROOT/two-session-standalone-ui-test.log"
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

write_ui_test_config() {
  python3 - "$DEMO_ROOT" "$SESSION_ID" "$SECONDARY_SESSION_ID" "$BRIDGE_HOST" "$BRIDGE_PORT" "$IPAD_UDID" "$UI_TEST_CONFIG" "$ACTIVE_UI_TEST_CONFIG" <<'PY'
import json
import sys
from pathlib import Path

demo_root = Path(sys.argv[1])
session_id = sys.argv[2]
secondary_session_id = sys.argv[3]
bridge_host = sys.argv[4]
bridge_port = int(sys.argv[5])
ipad_udid = sys.argv[6]
config_paths = [Path(sys.argv[7]), Path(sys.argv[8])]

pairing = json.loads((demo_root / "pairing.json").read_text())
ipad_pairing = pairing["ipad"]

payload = {
    "sessionID": session_id,
    "secondarySessionID": secondary_session_id,
    "host": bridge_host,
    "port": bridge_port,
    "authToken": ipad_pairing["authToken"],
    "transportKey": ipad_pairing["transportKey"],
    "installationID": ipad_pairing["installationID"],
    "renderDumpPath": str(demo_root / "two-session-standalone-ipad-render.json"),
    "eventLogPath": str(demo_root / "two-session-standalone-ipad-events.jsonl"),
    "immediateScreenshotPath": str(demo_root / "two-session-standalone-ipad-post-first-takeover.png"),
    "shortDelayScreenshotPath": str(demo_root / "two-session-standalone-ipad-post-first-takeover-plus-2s.png"),
    "longDelayScreenshotPath": str(demo_root / "two-session-standalone-ipad-post-first-takeover-plus-6s.png"),
    "finalScreenshotPath": str(demo_root / "two-session-standalone-ipad-post-second-takeover.png"),
    "firstCommandText": "pwd",
    "manualRetakeoverAttempts": 0,
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

run_ui_test() {
  printf 'Running two-session iPad takeover UI test...\n'
  if ! SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" xcodebuild \
    -project apps/ios/SpacesMobile.xcodeproj \
    -scheme SpacesMobile \
    -destination "platform=iOS Simulator,id=$IPAD_UDID" \
    -derivedDataPath "$DEMO_ROOT/TwoSessionAttachUITestDerivedData" \
    -only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverAcrossTwoSessionsFromList \
    test >"$UI_TEST_LOG" 2>&1; then
    fail "Two-session iPad takeover UI test failed."
  fi
}

start_demo
write_ui_test_config
run_ui_test

printf 'Two-session mobile takeover standalone test passed.\n'
