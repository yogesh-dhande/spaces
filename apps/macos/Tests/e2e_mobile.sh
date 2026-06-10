#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

DEMO_SCRIPT="$ROOT_DIR/apps/macos/Tests/run_mobile_terminal_demo.sh"
SPACES_CLI_BIN="${SPACES_CLI:-$ROOT_DIR/apps/macos/.build/debug/spaces}"
SPACES_E2E_BIN="${SPACES_E2E:-$ROOT_DIR/apps/macos/.build/debug/spacese2e}"
TERMINAL_SERVICE_BIN="${SPACESD_EXECUTABLE:-$ROOT_DIR/apps/macos/.build/debug/spacesd}"
TERMINAL_CREATE_TIMEOUT="${SPACES_MOBILE_E2E_TERMINAL_CREATE_TIMEOUT:-60}"
DEFAULT_UI_TEST_CONFIG="/tmp/spaces-mobile-ui-test-config.json"
BUNDLE_ID="dev.usespaces.spacesmobile"
MOBILE_DEVICE_KEY="${SPACES_MOBILE_E2E_DEVICE_KEY:-iphone}"
if [[ "$MOBILE_DEVICE_KEY" == "ipad" ]]; then
  MOBILE_DEVICE_NAME="${SPACES_MOBILE_E2E_DEVICE_NAME:-${SPACES_MOBILE_DEMO_IPAD_NAME:-iPad Pro 13-inch (M5)}}"
  MOBILE_DEVICE_LABEL="${SPACES_MOBILE_E2E_DEVICE_LABEL:-iPad}"
else
  MOBILE_DEVICE_NAME="${SPACES_MOBILE_E2E_DEVICE_NAME:-${SPACES_MOBILE_DEMO_IPHONE_NAME:-iPhone 17 Pro}}"
  MOBILE_DEVICE_LABEL="${SPACES_MOBILE_E2E_DEVICE_LABEL:-iPhone}"
fi
MOBILE_ARTIFACT_NAME="${SPACES_MOBILE_E2E_ARTIFACT_NAME:-$MOBILE_DEVICE_KEY}"
CODEX_RESUME_THREAD_ID="${SPACES_MOBILE_CODEX_RESUME_THREAD_ID:-019e380a-9def-7852-9834-74c67b2da894}"
USER_HOME="${HOME:?}"
SOURCE_CODEX_HOME="${SPACES_MOBILE_CODEX_HOME:-${CODEX_HOME:-$USER_HOME/.codex}}"
E2E_CODEX_HOME="$SOURCE_CODEX_HOME"
USER_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$USER_HOME/.config}"
E2E_GHOSTTY_XDG_CONFIG_HOME="${SPACES_MOBILE_GHOSTTY_XDG_CONFIG_HOME:-$USER_XDG_CONFIG_HOME}"
FIXTURE_LINE_COUNT=520
SCROLLBACK_SWIPE_COUNT=2
TERMINAL_LINK_PREVIEW_IMAGE_NAME="${SPACES_MOBILE_E2E_LINK_PREVIEW_IMAGE_NAME:-Screen Recording 2026-03-20 at 11.17.57 AM.png}"
TERMINAL_LINK_PREVIEW_PATH="${SPACES_MOBILE_E2E_LINK_PREVIEW_PATH:-/tmp/$TERMINAL_LINK_PREVIEW_IMAGE_NAME}"

SCENARIOS=(codex codex-resume-reopen roundtrip scrollback terminal-link-preview two-session ctrl-c-final-frame ctrl-c-final-frame-codex-survivor ownership-guard app-recovery)
SELECTED_SCENARIOS=()
REQUESTED_KEEP_ROOT="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
DEMO_PORT="${SPACES_MOBILE_DEMO_PORT:-}"

SUITE_ROOT=""
IOS_DERIVED_DATA=""
IOS_APP_PATH=""
IOS_BUILD_LOG=""
DEMO_STDOUT_LOG=""
DEMO_PID=""
DEMO_APP_PID=""
DEMO_BRIDGE_PID=""
DEMO_TERMINAL_SERVICE_PID=""
DEMO_ROOT=""
PROJECT_DIR=""
DB_PATH=""
RUNTIME_DIR=""
BRIDGE_HOST=""
BRIDGE_PORT=""
IPAD_UDID=""
IPHONE_UDID=""
MOBILE_UDID=""
PERFORMANCE_LOG_PATH=""
CURRENT_SCENARIO=""
SCENARIO_DIR=""
SCENARIO_LOG=""
UI_TEST_CONFIG=""
UI_TEST_LOG=""
PRESERVE_ROOT=0
declare -a SCENARIO_CREATED_SESSIONS=()

print_usage() {
  cat <<'EOF'
Usage: apps/macos/Tests/e2e_mobile.sh [options]

Options:
  --list                 List available mobile E2E scenarios.
  --scenario NAME        Run only one scenario. May be passed multiple times.
  --keep-root            Preserve the shared demo root after a successful run.
  --port PORT            Use a specific daemon mobile bridge port.
  --help                 Show this help text.

Scenarios:
  codex
  codex-resume-reopen
  roundtrip
  scrollback
  terminal-link-preview
  two-session
  ctrl-c-final-frame
  ctrl-c-final-frame-codex-survivor
  ownership-guard
  app-recovery
EOF
}

scenario_exists() {
  local requested="$1"
  local scenario
  for scenario in "${SCENARIOS[@]}"; do
    [[ "$scenario" == "$requested" ]] && return 0
  done
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)
        printf '%s\n' "${SCENARIOS[@]}"
        exit 0
        ;;
      --scenario)
        [[ $# -ge 2 ]] || fail "missing value for --scenario"
        scenario_exists "$2" || fail "unknown scenario: $2"
        SELECTED_SCENARIOS+=("$2")
        shift 2
        ;;
      --keep-root)
        REQUESTED_KEEP_ROOT=1
        shift
        ;;
      --port)
        [[ $# -ge 2 ]] || fail "missing value for --port"
        DEMO_PORT="$2"
        shift 2
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done

  if [[ ${#SELECTED_SCENARIOS[@]} -eq 0 ]]; then
    SELECTED_SCENARIOS=("${SCENARIOS[@]}")
  fi
}

run_demo_env() {
  env \
    -u NO_COLOR \
    -u CLICOLOR \
    -u CLICOLOR_FORCE \
    -u CI \
    -u CODEX_CI \
    -u CODEX_MANAGED_BY_NPM \
    -u CODEX_MANAGED_PACKAGE_ROOT \
    -u CODEX_THREAD_ID \
    "$@"
}

demo_env() {
  run_demo_env \
    HOME="$DEMO_ROOT/home" \
    CODEX_HOME="$E2E_CODEX_HOME" \
    XDG_CONFIG_HOME="$E2E_GHOSTTY_XDG_CONFIG_HOME" \
    SPACES_DB_PATH="$DB_PATH" \
    SPACES_RUNTIME_DIR="$RUNTIME_DIR" \
    SPACESD_EXECUTABLE="$TERMINAL_SERVICE_BIN" \
    SPACESD_CREATE_TIMEOUT="$TERMINAL_CREATE_TIMEOUT" \
    SPACES_MOBILE_BRIDGE_HOST="${SPACES_MOBILE_DEMO_BIND_HOST:-0.0.0.0}" \
    SPACES_MOBILE_BRIDGE_PORT="$BRIDGE_PORT" \
    "$@"
}

tail_if_present() {
  local label="$1"
  local path="$2"
  local lines="${3:-120}"
  if [[ -f "$path" ]]; then
    printf '\n%s:\n' "$label" >&2
    tail -n "$lines" "$path" >&2 || true
  fi
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  PRESERVE_ROOT=1
  tail_if_present "Scenario log tail" "$SCENARIO_LOG" 160
  tail_if_present "UI test output tail" "$UI_TEST_LOG" 160
  tail_if_present "Demo output tail" "$DEMO_STDOUT_LOG" 120
  tail_if_present "iOS build-for-testing output tail" "$IOS_BUILD_LOG" 120
  if [[ -n "$DEMO_ROOT" ]]; then
    tail_if_present "Mac app log tail" "$DEMO_ROOT/app.log" 160
    tail_if_present "Bridge log tail" "$DEMO_ROOT/bridge.log" 160
    tail_if_present "$MOBILE_DEVICE_LABEL app stderr tail" "$DEMO_ROOT/$MOBILE_ARTIFACT_NAME-app.stderr.log" 160
  fi
  exit 1
}

terminate_pid_if_command_matches() {
  local pid="$1"
  local label="$2"
  local command_pattern="$3"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0

  local command
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$command" ]] || return 0
  if [[ "$command" != *"$command_pattern"* ]]; then
    printf 'Skipping %s cleanup for pid %s because command did not match %s: %s\n' \
      "$label" "$pid" "$command_pattern" "$command" >&2
    return
  fi

  kill "$pid" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! ps -p "$pid" >/dev/null 2>&1; then
      return
    fi
    sleep 0.25
  done
  kill -9 "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  local exit_code=$?
  if [[ -n "$DEMO_PID" ]]; then
    if kill -0 "$DEMO_PID" >/dev/null 2>&1; then
      kill "$DEMO_PID" >/dev/null 2>&1 || true
      wait "$DEMO_PID" >/dev/null 2>&1 || true
    else
      wait "$DEMO_PID" >/dev/null 2>&1 || true
    fi
  fi
  terminate_pid_if_command_matches "$DEMO_APP_PID" "demo app" "SpacesApp"
  if [[ "$DEMO_BRIDGE_PID" != "$DEMO_TERMINAL_SERVICE_PID" ]]; then
    terminate_pid_if_command_matches "$DEMO_BRIDGE_PID" "demo bridge" "spacesd"
  fi
  terminate_pid_if_command_matches "$DEMO_TERMINAL_SERVICE_PID" "spacesd" "spacesd"
  if [[ -n "$IPAD_UDID" ]]; then
    xcrun simctl terminate "$IPAD_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$IPHONE_UDID" ]]; then
    xcrun simctl terminate "$IPHONE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$DEMO_ROOT" && -d "$DEMO_ROOT" ]]; then
    if [[ -f "$IOS_BUILD_LOG" ]]; then
      cp "$IOS_BUILD_LOG" "$DEMO_ROOT/ios-build-for-testing.log" >/dev/null 2>&1 || true
    fi
    if [[ "$REQUESTED_KEEP_ROOT" == "1" || "$PRESERVE_ROOT" == "1" || $exit_code -ne 0 ]]; then
      printf 'Preserved demo root: %s\n' "$DEMO_ROOT" >&2
    else
      rm -rf "$DEMO_ROOT" || true
    fi
  fi

  rm -f "$DEFAULT_UI_TEST_CONFIG"
  if [[ -n "$SUITE_ROOT" && -d "$SUITE_ROOT" ]]; then
    if [[ "$PRESERVE_ROOT" == "1" || $exit_code -ne 0 ]]; then
      printf 'Preserved mobile E2E build root: %s\n' "$SUITE_ROOT" >&2
    else
      rm -rf "$SUITE_ROOT" || true
    fi
  fi
  return "$exit_code"
}
trap cleanup EXIT

handle_interrupt() {
  PRESERVE_ROOT=1
  exit 130
}
trap handle_interrupt INT TERM

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

resolve_simulator_udid() {
  local name="$1"
  python3 - "$name" <<'PY'
import json
import subprocess
import sys

target_name = sys.argv[1]
payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
for runtime_devices in payload.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("name") == target_name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(f"Simulator not found: {target_name}")
PY
}

build_macos_debug_products() {
  printf 'Building macOS debug products...\n'
  run_demo_env "$ROOT_DIR/scripts/swiftpm.sh" build
}

build_ios_for_testing() {
  local destination_udid="$1"
  IOS_DERIVED_DATA="$SUITE_ROOT/ios-derived-data"
  IOS_BUILD_LOG="$SUITE_ROOT/ios-build-for-testing.log"
  mkdir -p "$IOS_DERIVED_DATA"

  printf 'Building iOS app and UI tests for testing...\n'
  if ! xcodebuild \
    -project "$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj" \
    -scheme SpacesMobile \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$destination_udid" \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    build-for-testing >"$IOS_BUILD_LOG" 2>&1; then
    fail "Failed to build SpacesMobile for testing."
  fi

  IOS_APP_PATH="$IOS_DERIVED_DATA/Build/Products/Debug-iphonesimulator/SpacesMobile.app"
  [[ -d "$IOS_APP_PATH" ]] || fail "SpacesMobile.app was not produced at $IOS_APP_PATH"
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
            "PROJECT_DIR": payload["projectDir"],
            "DB_PATH": payload["dbPath"],
            "RUNTIME_DIR": payload.get("runtimeDir") or str(pathlib.Path(payload["root"]) / "runtime"),
            "BRIDGE_HOST": payload["bridgeHost"],
            "BRIDGE_PORT": str(payload["bridgePort"]),
            "IPAD_UDID": payload["ipadSimulatorUDID"],
            "IPHONE_UDID": payload["iphoneSimulatorUDID"],
            "DEMO_APP_PID": str(payload.get("appPID") or ""),
            "DEMO_BRIDGE_PID": str(payload.get("bridgePID") or ""),
            "DEMO_TERMINAL_SERVICE_PID": str(payload.get("terminalServicePID") or ""),
            "PERFORMANCE_LOG_PATH": payload.get("performanceLogPath") or str(pathlib.Path(payload["root"]) / "mobile-terminal-performance.jsonl"),
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
      fail "Mobile demo exited before printing metadata."
    fi
    sleep 0.25
  done
  eval "$metadata"
}

start_demo() {
  resolve_demo_port
  DEMO_STDOUT_LOG="$SUITE_ROOT/mobile-demo.stdout.log"
  local demo_iphone_name="${SPACES_MOBILE_DEMO_IPHONE_NAME:-iPhone 17 Pro}"
  local demo_ipad_name="${SPACES_MOBILE_DEMO_IPAD_NAME:-iPad Pro 13-inch (M5)}"
  if [[ "$MOBILE_DEVICE_KEY" == "iphone" ]]; then
    demo_iphone_name="$MOBILE_DEVICE_NAME"
  else
    demo_ipad_name="$MOBILE_DEVICE_NAME"
  fi
  printf 'Launching shared mobile demo on port %s...\n' "$DEMO_PORT"
  SPACES_MOBILE_DEMO_KEEP_ROOT=1 \
    SPACES_MOBILE_DEMO_PROFILE_MODE=isolated \
    SPACES_MOBILE_DEMO_BUILD_MACOS=0 \
    SPACES_MOBILE_DEMO_APP_PATH="$IOS_APP_PATH" \
    SPACES_MOBILE_DEMO_IPHONE_NAME="$demo_iphone_name" \
    SPACES_MOBILE_DEMO_IPAD_NAME="$demo_ipad_name" \
    SPACES_MOBILE_DEMO_PORT="$DEMO_PORT" \
    SPACESD_CREATE_TIMEOUT="$TERMINAL_CREATE_TIMEOUT" \
    CODEX_HOME="$E2E_CODEX_HOME" \
    XDG_CONFIG_HOME="$E2E_GHOSTTY_XDG_CONFIG_HOME" \
    "$DEMO_SCRIPT" >"$DEMO_STDOUT_LOG" 2>&1 &
  DEMO_PID=$!
  wait_for_demo_metadata
  printf 'Shared demo root: %s\n' "$DEMO_ROOT"
}

begin_scenario() {
  CURRENT_SCENARIO="$1"
  SCENARIO_CREATED_SESSIONS=()
  SCENARIO_DIR="$DEMO_ROOT/mobile-e2e/$CURRENT_SCENARIO"
  SCENARIO_LOG="$SCENARIO_DIR/scenario.log"
  UI_TEST_CONFIG="$SCENARIO_DIR/ui-test-config.json"
  UI_TEST_LOG="$SCENARIO_DIR/ui-test.log"
  mkdir -p "$SCENARIO_DIR"
  : >"$SCENARIO_LOG"
  printf '\n[%s] Running mobile scenario: %s\n' "$(date +%H:%M:%S)" "$CURRENT_SCENARIO"
}

discover_session_ids() {
  python3 - "$RUNTIME_DIR" <<'PY'
import pathlib
import sys

sessions_root = pathlib.Path(sys.argv[1]) / "terminal" / "sessions"
if sessions_root.exists():
    for path in sorted(sessions_root.iterdir()):
        if path.is_dir():
            print(path.name)
PY
}

wait_for_session_owner() {
  local session_id="$1"
  python3 - "$DB_PATH" "$RUNTIME_DIR" "$session_id" <<'PY'
import os
import sqlite3
import sys
import time

db_path = sys.argv[1]
root_directory = os.path.normpath(os.path.join(sys.argv[2], "terminal", "sessions", sys.argv[3]))
session_id = sys.argv[3]
deadline = time.time() + 30
last_snapshot = ""
while time.time() < deadline:
    with sqlite3.connect(db_path) as db:
        rows = db.execute(
            """
            SELECT client_id, mode, COALESCE(detached_at, '')
            FROM terminal_attachments
            WHERE root_directory = ?
            ORDER BY attached_at, id
            """,
            (root_directory,),
        ).fetchall()
    last_snapshot = repr(rows)
    if any(mode == "owner" and not detached_at and client_id for client_id, mode, detached_at in rows):
        raise SystemExit(0)
    time.sleep(0.1)
raise SystemExit(f"Timed out waiting for active owner attachment for {session_id}.\n{last_snapshot}")
PY
}

new_terminal_session() {
  local title="${1:-e2e-$CURRENT_SCENARIO}"
  local command_text="${2:-}"
  local create_log="$SCENARIO_DIR/start-terminal-session.log"
  local show_log="$SCENARIO_DIR/show-terminal.log"
  local session_id
  : >"$create_log"
  for attempt in 1 2 3 4 5; do
    local attempt_log="$SCENARIO_DIR/start-terminal-session-attempt-$attempt.log"
    local create_args=(start-terminal-session --cwd "$PROJECT_DIR" --title "$title")
    if [[ -n "$command_text" ]]; then
      create_args+=(--command "$command_text")
    fi
    if demo_env "$SPACES_E2E_BIN" "${create_args[@]}" >"$attempt_log" 2>&1; then
      {
        printf -- '--- create attempt %s ---\n' "$attempt"
        cat "$attempt_log"
      } >>"$create_log" || true
      cat "$attempt_log" >>"$SCENARIO_LOG" || true
      break
    fi
    {
      printf -- '--- create attempt %s failed ---\n' "$attempt"
      cat "$attempt_log"
    } >>"$create_log" || true
    if [[ "$attempt" == "5" ]]; then
      cat "$create_log" >>"$SCENARIO_LOG" || true
      fail "Failed to create a fresh service terminal session for $CURRENT_SCENARIO."
    fi
    sleep 1
  done
  if ! session_id="$(python3 - "$create_log" <<'PY'
import json
import pathlib
import sys

decoder = json.JSONDecoder()
text = pathlib.Path(sys.argv[1]).read_text()
payload = None
index = 0
while True:
    start = text.find("{", index)
    if start < 0:
        break
    try:
        decoded, end = decoder.raw_decode(text[start:])
    except json.JSONDecodeError:
        index = start + 1
        continue
    if isinstance(decoded, dict) and (decoded.get("id") or decoded.get("sessionID")):
        payload = decoded
    index = start + max(end, 1)
if payload is None:
    raise SystemExit(f"Terminal create response did not include a session payload: {text}")
session_id = payload.get("id") or payload.get("sessionID")
print(session_id)
PY
  )"; then
    fail "Unable to parse fresh service terminal session ID for $CURRENT_SCENARIO."
  fi
  : >"$show_log"
  for attempt in 1 2 3; do
    local show_attempt_log="$SCENARIO_DIR/show-terminal-attempt-$attempt.log"
    if ! demo_env "$SPACES_CLI_BIN" terminal show "$session_id" >"$show_attempt_log" 2>&1; then
      cat "$show_attempt_log" >>"$SCENARIO_LOG" || true
      fail "Failed to open Mac owner window for fresh service terminal session $session_id."
    fi
    {
      printf -- '--- show attempt %s ---\n' "$attempt"
      cat "$show_attempt_log"
    } >>"$show_log" || true
    cat "$show_attempt_log" >>"$SCENARIO_LOG" || true
    if wait_for_session_owner "$session_id" >>"$show_log" 2>&1; then
      printf '%s\n' "$session_id"
      return
    fi
    sleep 1
  done
  fail "Fresh terminal session did not become owner-ready: $session_id"
}

track_current_scenario_session() {
  local session_id="$1"
  [[ -n "$session_id" ]] || return
  SCENARIO_CREATED_SESSIONS+=("$session_id")
}

cleanup_current_scenario_sessions() {
  if (( ${#SCENARIO_CREATED_SESSIONS[@]} == 0 )); then
    return
  fi
  local session_id
  local seen=" "
  for session_id in "${SCENARIO_CREATED_SESSIONS[@]}"; do
    [[ -n "$session_id" ]] || continue
    if [[ "$seen" == *" $session_id "* ]]; then
      continue
    fi
    seen+=" $session_id "
    if [[ -n "$SCENARIO_LOG" ]]; then
      {
        printf -- '--- terminate session %s ---\n' "$session_id"
        demo_env "$SPACES_E2E_BIN" terminate-terminal-session "$session_id"
      } >>"$SCENARIO_LOG" 2>&1 || true
    else
      demo_env "$SPACES_E2E_BIN" terminate-terminal-session "$session_id" >/dev/null 2>&1 || true
    fi
  done
  SCENARIO_CREATED_SESSIONS=()
}

reset_mobile_app() {
  xcrun simctl terminate "$MOBILE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  env \
    SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_TRACE=1 \
    SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$PERFORMANCE_LOG_PATH" \
    xcrun simctl launch "$MOBILE_UDID" "$BUNDLE_ID" >>"$SCENARIO_LOG" 2>&1 || fail "Failed to launch SpacesMobile on the $MOBILE_DEVICE_LABEL simulator."
  sleep 2
}

write_ui_test_config() {
  local scenario="$1"
  local session_id="$2"
  local secondary_session_id="${3:-}"
  python3 - "$DEMO_ROOT" "$scenario" "$session_id" "$secondary_session_id" "$BRIDGE_HOST" "$BRIDGE_PORT" "$MOBILE_UDID" "$MOBILE_DEVICE_KEY" "$MOBILE_ARTIFACT_NAME" "$UI_TEST_CONFIG" "$DEFAULT_UI_TEST_CONFIG" "$BUNDLE_ID" "$SCROLLBACK_SWIPE_COUNT" "$TERMINAL_LINK_PREVIEW_IMAGE_NAME" "$TERMINAL_LINK_PREVIEW_PATH" <<'PY'
import json
import sys
from pathlib import Path

(
    demo_root_raw,
    scenario,
    session_id,
    secondary_session_id,
    bridge_host,
    bridge_port_raw,
    mobile_udid,
    mobile_device_key,
    mobile_artifact_name,
    scenario_config_raw,
    default_config_raw,
    bundle_id,
    scrollback_swipe_count_raw,
    terminal_link_preview_image_name,
    terminal_link_preview_path,
) = sys.argv[1:]

demo_root = Path(demo_root_raw)
bridge_port = int(bridge_port_raw)
scrollback_swipe_count = int(scrollback_swipe_count_raw)
config_paths = [Path(scenario_config_raw), Path(default_config_raw)]
pairing = json.loads((demo_root / "pairing.json").read_text())
mobile_pairing = pairing[mobile_device_key]
prefix = scenario
artifact_prefix = f"{prefix}-{mobile_artifact_name}"

payload = {
    "sessionID": session_id,
    "secondarySessionID": None,
    "host": bridge_host,
    "port": bridge_port,
    "authToken": mobile_pairing["authToken"],
    "transportKey": mobile_pairing["transportKey"],
    "certificateFingerprint": mobile_pairing["certificateFingerprint"],
    "installationID": mobile_pairing["installationID"],
    "renderDumpPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-render.json"),
    "eventLogPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-events.jsonl"),
    "immediateScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-takeover-immediate.png"),
    "shortDelayScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-takeover-plus-2s.png"),
    "longDelayScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-takeover-plus-6s.png"),
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
    "manualRetakeoverObservedPrefix": None,
    "manualRetakeoverContinuePrefix": None,
    "postFirstCommandScreenshotPath": None,
    "postSecondCommandScreenshotPath": None,
    "interruptedRenderDumpPath": None,
    "postInterruptScreenshotPath": None,
    "finalMacRetakeoverRequestPath": None,
    "finalMacRetakeoverObservedPath": None,
    "postFinalMacRetakeoverScreenshotPath": None,
    "finalScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-final.png"),
    "terminalLinkText": "",
    "expectedLinkPreviewTitle": "",
    "linkPreviewScreenshotPath": None,
    "expectedInterruptedText": "",
    "expectedSecondaryText": "",
    "scrollbackSwipeCount": 0,
    "minimumVisibleTerminalInkBands": 0,
    "maximumTerminalTopBlankRatio": 0,
    "attachToExistingApp": True,
    "bundleID": bundle_id,
    "mobileUDID": mobile_udid,
}

if scenario in ("codex", "codex-resume-reopen"):
    payload.update({
        "minimumVisibleTerminalInkBands": 3,
        "maximumTerminalTopBlankRatio": 0.20,
    })

if scenario == "codex-resume-reopen":
    payload["secondarySessionID"] = session_id
elif scenario == "roundtrip":
    payload.update({
        "proceedTakeOverPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-proceed-takeover"),
        "firstCommandRequestPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-first-command-request"),
        "firstCommandFocusedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-first-command-focused"),
        "firstCommandCompletedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-first-command-completed"),
        "firstCommandObservedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-first-command-observed"),
        "secondCommandRequestPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-second-command-request"),
        "secondCommandFocusedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-second-command-focused"),
        "secondCommandCompletedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-second-command-completed"),
        "secondCommandObservedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-second-command-observed"),
        "proceedFinishPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-proceed-finish"),
        "firstCommandText": f"echo __roundtrip_{mobile_artifact_name}_one__",
        "secondCommandText": f"echo __roundtrip_{mobile_artifact_name}_two__",
        "manualRetakeoverAttempts": 2,
        "manualRetakeoverObservedPrefix": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-manual-retakeover-observed"),
        "manualRetakeoverContinuePrefix": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-manual-retakeover-continue"),
        "postFirstCommandScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-first-command.png"),
        "postSecondCommandScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-second-command.png"),
        "finalMacRetakeoverRequestPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-final-mac-retakeover-request"),
        "finalMacRetakeoverObservedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-final-mac-retakeover-observed"),
        "postFinalMacRetakeoverScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-final-mac-retakeover.png"),
        "minimumVisibleTerminalInkBands": 3,
        "maximumTerminalTopBlankRatio": 0.20,
    })
elif scenario == "scrollback":
    payload.update({
        "firstCommandRequestPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-first-command-request"),
        "firstCommandFocusedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-first-command-focused"),
        "firstCommandCompletedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-first-command-completed"),
        "firstCommandObservedPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-first-command-observed"),
        "postFirstCommandScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-command-while-scrolled.png"),
        "scrollbackSwipeCount": scrollback_swipe_count,
        "minimumVisibleTerminalInkBands": 3,
        "maximumTerminalTopBlankRatio": 0.20,
    })
elif scenario == "terminal-link-preview":
    payload.update({
        "terminalLinkText": terminal_link_preview_path,
        "expectedLinkPreviewTitle": terminal_link_preview_image_name,
        "linkPreviewScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-preview.png"),
        "minimumVisibleTerminalInkBands": 2,
        "maximumTerminalTopBlankRatio": 0.30,
    })
elif scenario == "two-session":
    payload.update({
        "secondarySessionID": secondary_session_id,
        "immediateScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-first-takeover.png"),
        "shortDelayScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-first-takeover-plus-2s.png"),
        "longDelayScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-first-takeover-plus-6s.png"),
        "finalScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-post-second-takeover.png"),
        "firstCommandText": "pwd",
    })
elif scenario in ("ctrl-c-final-frame", "ctrl-c-final-frame-codex-survivor"):
    expected_secondary_text = "" if scenario == "ctrl-c-final-frame-codex-survivor" else "__spaces_survivor_peer_ready__"
    payload.update({
        "secondarySessionID": secondary_session_id,
        "interruptedRenderDumpPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-interrupted-render.json"),
        "postInterruptScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-interrupted-final-frame.png"),
        "finalScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{artifact_prefix}-secondary-live-after-interrupt.png"),
        "expectedInterruptedText": "__spaces_ctrl_c_target_ready__",
        "expectedSecondaryText": expected_secondary_text,
        "minimumVisibleTerminalInkBands": 1,
        "maximumTerminalTopBlankRatio": 0.45,
    })

encoded = json.dumps(payload, indent=2, sort_keys=True)
for config_path in config_paths:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(encoded)
PY
}

run_ui_test() {
  local test_name="$1"
  printf 'Running %s UI test: %s\n' "$MOBILE_DEVICE_LABEL" "$test_name"
  reset_mobile_app
  if ! SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
    xcodebuild \
      -project "$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj" \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$MOBILE_UDID" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      -only-testing:"$test_name" \
      test-without-building >"$UI_TEST_LOG" 2>&1; then
    fail "UI test failed: $test_name"
  fi
}

launch_codex_on_mac_owner() {
  local session_id="$1"
  local command_text="$2"
  python3 - "$DEMO_ROOT" "$session_id" "$SPACES_E2E_BIN" "$command_text" "$SCENARIO_DIR" <<'PY'
import json
import os
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

demo_root = Path(sys.argv[1])
session_id = sys.argv[2]
spacese2e = Path(sys.argv[3])
command_text = sys.argv[4]
scenario_dir = Path(sys.argv[5])
runtime_root = demo_root / "runtime"
owner_dump_path = scenario_dir / "codex-mac-owner-dump.json"
output_log_path = runtime_root / "terminal" / "sessions" / session_id / "output.log"

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "CODEX_HOME": os.environ.get("CODEX_HOME", str(Path.home() / ".codex")),
    "XDG_CONFIG_HOME": os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}

def socket_path(root: Path, session_id: str) -> Path:
    hash_value = 5381
    for byte in f"{root}|{session_id}".encode("utf-8"):
        hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
    return Path("/tmp/spaces-terminal-sockets") / f"{hash_value:016x}.sock"

def current_owner_client_id() -> str:
    root_directory = os.path.normpath(str(runtime_root / "terminal" / "sessions" / session_id))
    with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
        row = db.execute(
            """
            SELECT client_id
            FROM terminal_attachments
            WHERE root_directory = ?
              AND mode = 'owner'
              AND detached_at IS NULL
            ORDER BY attached_at DESC
            LIMIT 1
            """,
            (root_directory,),
        ).fetchone()
    if row:
        return row[0]
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
    deadline = time.time() + 15
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
    {"command": "send", "text": command_text, "clientID": owner_client_id},
    {"command": "key", "key": "enter", "clientID": owner_client_id},
):
    response = send_request(request)
    if not response.get("ok"):
        raise RuntimeError(f"Codex launch request failed: {response}")

def send_owner_key(key: str, label: str) -> None:
    response = send_request({"command": "key", "key": key, "clientID": owner_client_id})
    if not response.get("ok"):
        raise RuntimeError(f"Failed to {label}: {response}")

def is_codex_update_prompt(text: str) -> bool:
    normalized = " ".join(text.lower().split())
    return (
        "update available" in normalized
        and "update now" in normalized
        and "skip" in normalized
        and "press enter to continue" in normalized
    )

update_prompt_skipped = False
trust_prompt_confirmed = False
resume_directory_prompt_confirmed = False
deadline = time.time() + 30
while time.time() < deadline:
    rendered_output = (dump_owner_window().get("renderedOutput") or "")
    output_log_text = output_log_path.read_text(errors="replace") if output_log_path.exists() else ""
    if is_codex_update_prompt(rendered_output):
        if update_prompt_skipped:
            time.sleep(0.2)
            continue
        send_owner_key("down", "select Skip in the Codex update prompt")
        send_owner_key("enter", "confirm Skip in the Codex update prompt")
        update_prompt_skipped = True
        time.sleep(0.2)
        continue
    if "Choose working directory to resume this session" in rendered_output:
        if resume_directory_prompt_confirmed:
            time.sleep(0.2)
            continue
        send_owner_key("enter", "confirm the Codex resume directory prompt")
        resume_directory_prompt_confirmed = True
        time.sleep(0.2)
        continue
    if "Do you trust the contents of this directory?" in rendered_output:
        if trust_prompt_confirmed:
            time.sleep(0.2)
            continue
        send_owner_key("enter", "confirm the Codex trust prompt")
        trust_prompt_confirmed = True
        time.sleep(0.2)
        continue
    normalized_rendered_output = rendered_output.lower()
    normalized_output_log = output_log_text.lower()
    if (
        "sign in with chatgpt" in normalized_rendered_output
        or "provide your own api key" in normalized_rendered_output
        or "sign in with chatgpt" in normalized_output_log
        or "provide your own api key" in normalized_output_log
    ):
        raise RuntimeError(
            "Codex started without a signed-in user. "
            "Set SPACES_MOBILE_CODEX_HOME or CODEX_HOME to a Codex home containing auth.json."
        )
    if (
        "gpt-" in normalized_rendered_output
        or "/review on my current changes" in normalized_rendered_output
        or "/model to change" in normalized_rendered_output
        or "/mcp to list configured mcp tools" in normalized_rendered_output
    ):
        raise SystemExit(0)
    time.sleep(0.2)

raise RuntimeError(f"Timed out waiting for Codex startup output in the demo session for {command_text!r}.")
PY
}

assert_mobile_terminal_text_rendered() {
  local screenshot_path="$SCENARIO_DIR/$CURRENT_SCENARIO-$MOBILE_ARTIFACT_NAME-post-takeover-plus-2s.png"
  printf 'Validating rendered %s terminal text...\n' "$MOBILE_DEVICE_LABEL"
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
let cropTop = Int(Double(cgImage.height) * 0.14)
let cropRect = CGRect(x: 0, y: cropTop, width: cgImage.width, height: max(cgImage.height - cropTop, 1))
let terminalImage = cgImage.cropping(to: cropRect) ?? cgImage

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
let handler = VNImageRequestHandler(cgImage: terminalImage, options: [:])
try handler.perform([request])

let recognizedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
print(recognizedText)

let nonWhitespaceCount = recognizedText.filter { !$0.isWhitespace }.count
if nonWhitespaceCount >= 12 {
    exit(0)
}
fputs("OCR did not find enough terminal text in \(screenshotPath)\n", stderr)
exit(1)
SWIFT
  )"; then
    printf '\nOCR output:\n%s\n' "$recognized_text" >&2
    fail "Codex takeover rendered a blank or unreadable $MOBILE_DEVICE_LABEL terminal surface."
  fi
}

assert_codex_takeover_metrics() {
  local session_id="$1"
  local takeover_started_at="$2"
  local reopen_same_session="$3"
  python3 - "$SCENARIO_DIR" "$CURRENT_SCENARIO" "$DEMO_ROOT" "$session_id" "$takeover_started_at" "$reopen_same_session" "$MOBILE_ARTIFACT_NAME" "$MOBILE_DEVICE_LABEL" <<'PY'
import json
import sys
from pathlib import Path
from datetime import datetime, timezone

scenario_dir = Path(sys.argv[1])
scenario = sys.argv[2]
demo_root = Path(sys.argv[3])
session_id = sys.argv[4]
takeover_started_at_raw = sys.argv[5]
reopen_same_session = sys.argv[6] == "1"
mobile_artifact_name = sys.argv[7]
mobile_device_label = sys.argv[8]
render_dump_path = scenario_dir / f"{scenario}-{mobile_artifact_name}-render.json"
event_log_path = scenario_dir / f"{scenario}-{mobile_artifact_name}-events.jsonl"
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

if render_dump.get("renderMode") != "ghostty-mirror":
    raise SystemExit(f"Unexpected render mode after takeover: {render_dump.get('renderMode')!r}")
if render_dump.get("errorMessage"):
    raise SystemExit(f"Unexpected {mobile_device_label} error after takeover: {render_dump.get('errorMessage')!r}")
if not render_dump.get("isInputSurfaceReady"):
    raise SystemExit(f"The {mobile_device_label} owner path never reached input-ready state.")
if not any(event.get("kind") == "input_readiness" and event.get("detail") == "ready" for event in event_payloads):
    raise SystemExit(f"The {mobile_device_label} event log never recorded input readiness.")
rendered_terminal_text = "\n".join(
    str(render_dump.get(key) or "")
    for key in ("renderedText", "snapshotText", "visibleText")
).lower()
if "codex resume" in rendered_terminal_text and not any(
    marker in rendered_terminal_text
    for marker in (
        "gpt-",
        "/model to change",
        "/mcp to list configured mcp tools",
        "conversation interrupted",
        "›",
    )
):
    raise SystemExit(f"The {mobile_device_label} owner bootstrap appears to be the stale pre-takeover shell prompt.")

bootstrap_receipts = [event for event in session_events if event.get("name") == "owner_bootstrap_state_received"]
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

if reopen_same_session:
    expected_bootstraps = 4
    if len(first_nonblank) != expected_bootstraps:
        raise SystemExit(
            f"Expected {expected_bootstraps} first non-blank render events across reopen cycles, "
            f"found {len(first_nonblank)}"
        )
    if len(first_input_ready) != expected_bootstraps:
        raise SystemExit(
            f"Expected {expected_bootstraps} first input-ready events across reopen cycles, "
            f"found {len(first_input_ready)}"
        )
    if len(bootstrap_receipts) < expected_bootstraps:
        raise SystemExit(
            f"Expected at least {expected_bootstraps} owner bootstrap receipts across reopen cycles, "
            f"found {len(bootstrap_receipts)}"
        )
    if not initial_snapshot_exports:
        raise SystemExit("Expected at least one initial snapshot export across reopen cycles.")
else:
    if len(bootstrap_receipts) != 1:
        raise SystemExit(f"Expected exactly one owner bootstrap receipt, found {len(bootstrap_receipts)}")
    if len(first_nonblank) != 1:
        raise SystemExit(f"Expected exactly one first non-blank render event, found {len(first_nonblank)}")
    if len(first_input_ready) != 1:
        raise SystemExit(f"Expected exactly one first input-ready event, found {len(first_input_ready)}")
    if not initial_snapshot_exports:
        raise SystemExit("Expected at least one initial snapshot export.")
    if post_ready_snapshot_exports:
        raise SystemExit(
            "Found unexpected snapshot exports after takeover became interactive: "
            + ", ".join(event.get("attributes", {}).get("reason", "?") for event in post_ready_snapshot_exports)
        )
PY
}

codex_demo_command_prefix() {
  local codex_command
  codex_command="$(resolve_codex_command_for_e2e)"
  printf 'CODEX_HOME=%q %s' "$E2E_CODEX_HOME" "$codex_command"
}

resolve_codex_command_for_e2e() {
  if [[ -n "${SPACES_MOBILE_CODEX_BIN:-}" ]]; then
    [[ -x "$SPACES_MOBILE_CODEX_BIN" ]] || fail "SPACES_MOBILE_CODEX_BIN is not executable: $SPACES_MOBILE_CODEX_BIN"
    printf '%q' "$SPACES_MOBILE_CODEX_BIN"
    return
  fi

  local path_codex
  path_codex="$(command -v codex || true)"
  if [[ -n "$path_codex" ]]; then
    printf '%q' "$path_codex"
    return
  fi

  local candidate
  while IFS= read -r candidate; do
    [[ -x "$candidate" ]] || continue
    printf '%q' "$candidate"
    return
  done < <(
    find "$USER_HOME/.local/share/fnm/node-versions" -path '*/installation/bin/codex' \( -type f -o -type l \) -print 2>/dev/null | sort -Vr
  )

  fail "Unable to find a Codex executable. Set SPACES_MOBILE_CODEX_BIN to the codex CLI path."
}

require_codex_auth_for_e2e() {
  if [[ ! -f "$SOURCE_CODEX_HOME/auth.json" ]]; then
    fail "Codex E2E scenarios require signed-in Codex credentials at CODEX_HOME=$SOURCE_CODEX_HOME. Set SPACES_MOBILE_CODEX_HOME or run codex login."
  fi
}

prepare_codex_home_for_e2e() {
  local trusted_project_dir="$1"
  local generated_home="$DEMO_ROOT/codex-home"
  rm -rf "$generated_home"
  mkdir -p "$generated_home"

  if [[ -f "$SOURCE_CODEX_HOME/config.toml" ]]; then
    cp "$SOURCE_CODEX_HOME/config.toml" "$generated_home/config.toml"
  else
    : >"$generated_home/config.toml"
  fi

  local auth_file
  for auth_file in "$SOURCE_CODEX_HOME"/auth.json "$SOURCE_CODEX_HOME"/auth.*.json; do
    [[ -f "$auth_file" ]] || continue
    ln -s "$auth_file" "$generated_home/$(basename "$auth_file")"
  done

  local escaped_project_dir="$trusted_project_dir"
  escaped_project_dir="${escaped_project_dir//\\/\\\\}"
  escaped_project_dir="${escaped_project_dir//\"/\\\"}"
  if ! grep -F "[projects.\"$escaped_project_dir\"]" "$generated_home/config.toml" >/dev/null 2>&1; then
    printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$escaped_project_dir" >>"$generated_home/config.toml"
  fi

  E2E_CODEX_HOME="$generated_home"
}

copy_codex_resume_session_for_e2e() {
  local generated_home="$1"
  local source_sessions_dir="$SOURCE_CODEX_HOME/sessions"
  [[ -d "$source_sessions_dir" ]] || return 1

  local source_session_path
  source_session_path="$(find "$source_sessions_dir" -type f -name "*$CODEX_RESUME_THREAD_ID*.jsonl" -print -quit)"
  [[ -n "$source_session_path" ]] || return 1

  local relative_session_path
  relative_session_path="${source_session_path#$source_sessions_dir/}"
  mkdir -p "$generated_home/sessions/$(dirname "$relative_session_path")"
  cp "$source_session_path" "$generated_home/sessions/$relative_session_path"
}

run_codex_scenario() {
  local scenario="$1"
  begin_scenario "$scenario"
  require_codex_auth_for_e2e
  local trusted_project_dir
  trusted_project_dir="$(cd "$PROJECT_DIR" && pwd -P)"
  prepare_codex_home_for_e2e "$trusted_project_dir"
  if [[ "$scenario" == "codex-resume-reopen" ]]; then
    copy_codex_resume_session_for_e2e "$E2E_CODEX_HOME" || fail "Codex resume E2E requires saved session $CODEX_RESUME_THREAD_ID under CODEX_HOME=$SOURCE_CODEX_HOME."
  fi
  local session_id
  session_id="$(new_terminal_session)"
  track_current_scenario_session "$session_id"
  local command_text
  local reopen_same_session=0
  local ui_test_name="SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList"
  local codex_command_prefix
  codex_command_prefix="$(codex_demo_command_prefix)"
  if [[ "$scenario" == "codex-resume-reopen" ]]; then
    command_text="$codex_command_prefix resume $CODEX_RESUME_THREAD_ID"
    reopen_same_session=1
    ui_test_name="SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverReopenSameSessionFromList"
  else
    command_text="${SPACES_MOBILE_CODEX_COMMAND:-$codex_command_prefix}"
  fi

  launch_codex_on_mac_owner "$session_id" "$command_text" >>"$SCENARIO_LOG" 2>&1 || fail "Failed to launch Codex in $session_id."
  write_ui_test_config "$scenario" "$session_id"
  local takeover_started_at
  takeover_started_at="$(
    python3 <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"))
PY
  )"
  run_ui_test "$ui_test_name"
  assert_mobile_terminal_text_rendered
  assert_codex_takeover_metrics "$session_id" "$takeover_started_at" "$reopen_same_session"
  printf 'Mobile scenario passed: %s\n' "$scenario"
}

run_roundtrip_scenario() {
  begin_scenario "roundtrip"
  local session_id
  session_id="$(new_terminal_session)"
  track_current_scenario_session "$session_id"
  write_ui_test_config "roundtrip" "$session_id"
  reset_mobile_app
  python3 - "$ROOT_DIR" "$DEMO_ROOT" "$session_id" "$BRIDGE_HOST" "$BRIDGE_PORT" "$MOBILE_UDID" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$UI_TEST_CONFIG" "$UI_TEST_LOG" "$IOS_DERIVED_DATA" "$SCENARIO_DIR" "$MOBILE_DEVICE_LABEL" "$MOBILE_ARTIFACT_NAME" <<'PY'
import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

repo_root = Path(sys.argv[1])
demo_root = Path(sys.argv[2])
session_id = sys.argv[3]
bridge_host = sys.argv[4]
bridge_port = int(sys.argv[5])
mobile_udid = sys.argv[6]
spaces_cli = Path(sys.argv[7])
spacese2e = Path(sys.argv[8])
ui_test_config = Path(sys.argv[9])
ui_test_log = Path(sys.argv[10])
ios_derived_data = Path(sys.argv[11])
scenario_dir = Path(sys.argv[12])
mobile_device_label = sys.argv[13]
mobile_artifact_name = sys.argv[14]
runtime_root = demo_root / "runtime"
output_log_path = runtime_root / "terminal" / "sessions" / session_id / "output.log"

config = json.loads(ui_test_config.read_text())
render_dump_path = Path(config["renderDumpPath"])
event_log_path = Path(config["eventLogPath"])
command_request_path = Path(f"{event_log_path}.command-request.json")
proceed_takeover_path = Path(config["proceedTakeOverPath"])
first_command_request = Path(config["firstCommandRequestPath"])
first_command_focused = Path(config["firstCommandFocusedPath"])
first_command_completed = Path(config["firstCommandCompletedPath"])
first_command_observed = Path(config["firstCommandObservedPath"])
second_command_request = Path(config["secondCommandRequestPath"])
second_command_focused = Path(config["secondCommandFocusedPath"])
second_command_completed = Path(config["secondCommandCompletedPath"])
second_command_observed = Path(config["secondCommandObservedPath"])
proceed_finish_path = Path(config["proceedFinishPath"])
manual_retakeover_prefix = Path(config["manualRetakeoverObservedPrefix"])
manual_retakeover_continue_prefix = Path(config["manualRetakeoverContinuePrefix"])
final_mac_retakeover_request = Path(config["finalMacRetakeoverRequestPath"])
final_mac_retakeover_observed = Path(config["finalMacRetakeoverObservedPath"])

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}

mac_prepare_commands = [
    "printf '__roundtrip_mac_before_takeover_one__\\n'",
    "printf '__roundtrip_mac_before_takeover_two__\\n'",
]
ios_first_command = config["firstCommandText"]
ios_first_output = f"__roundtrip_{mobile_artifact_name}_one__"
ios_second_command = config["secondCommandText"]
ios_second_output = f"__roundtrip_{mobile_artifact_name}_two__"
bare_command_lines = (
    "s",
    ios_first_command,
    ios_second_command,
)

def check_ui_test_alive(process: subprocess.Popen[str]) -> None:
    return_code = process.poll()
    if return_code is None:
        return
    log_tail = ui_test_log.read_text(errors="replace")[-12000:] if ui_test_log.exists() else "<missing>"
    raise RuntimeError(f"Round-trip UI test exited early with status {return_code}.\n{log_tail}")

def wait_for_file(path: Path, timeout: float, process: subprocess.Popen[str]) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        check_ui_test_alive(process)
        if path.exists():
            return
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for file at {path}")

def write_marker(path: Path, value: str = "done\n") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)

def socket_path(root: Path, session_id: str) -> Path:
    hash_value = 5381
    for byte in f"{root}|{session_id}".encode("utf-8"):
        hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
    return Path("/tmp/spaces-terminal-sockets") / f"{hash_value:016x}.sock"

def current_owner_client_id(excluded_client_ids: set[str] | None = None) -> str:
    excluded_client_ids = excluded_client_ids or set()
    root_directory = os.path.normpath(str(runtime_root / "terminal" / "sessions" / session_id))
    with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
        rows = db.execute(
            """
            SELECT client_id
            FROM terminal_attachments
            WHERE root_directory = ?
              AND mode = 'owner'
              AND detached_at IS NULL
            ORDER BY attached_at DESC
            """,
            (root_directory,),
        ).fetchall()
    for (client_id,) in rows:
        if client_id not in excluded_client_ids:
            return client_id
    raise RuntimeError(f"No active owner attachment was found. rows={rows!r}")

def wait_for_active_owner(excluded_client_ids: set[str] | None = None, timeout: float = 20) -> str:
    deadline = time.time() + timeout
    last_snapshot = ""
    root_directory = os.path.normpath(str(runtime_root / "terminal" / "sessions" / session_id))
    while time.time() < deadline:
        with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
            rows = db.execute(
                """
                SELECT client_id
                FROM terminal_attachments
                WHERE root_directory = ?
                  AND mode = 'owner'
                  AND detached_at IS NULL
                ORDER BY attached_at DESC
                """,
                (root_directory,),
            ).fetchall()
        last_snapshot = repr(rows)
        for (client_id,) in rows:
            if client_id not in (excluded_client_ids or set()):
                return client_id
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for active owner.\n{last_snapshot}")

def send_unix_control_request(request: dict) -> dict:
    path = socket_path(demo_root, session_id)
    deadline = time.time() + 10
    while True:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        try:
            client.connect(str(path))
            client.sendall(json.dumps(request).encode("utf-8"))
            client.shutdown(socket.SHUT_WR)
            response = bytearray()
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                response.extend(chunk)
            return json.loads(response.decode("utf-8"))
        except (ConnectionRefusedError, FileNotFoundError):
            if time.time() >= deadline:
                raise
            time.sleep(0.2)
        finally:
            client.close()

def send_owner_command(command_text: str) -> None:
    owner_client_id = current_owner_client_id()
    response = send_unix_control_request(
        {"command": "send", "text": command_text, "appendNewline": True, "clientID": owner_client_id}
    )
    if not response.get("ok"):
        raise RuntimeError(f"Owner control request failed: {response}")

def wait_for_render_dump(predicate, timeout: float, process: subprocess.Popen[str]) -> dict:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        check_ui_test_alive(process)
        if render_dump_path.exists():
            try:
                payload = json.loads(render_dump_path.read_text())
            except json.JSONDecodeError:
                time.sleep(0.1)
                continue
            last_payload = payload
            if predicate(payload):
                return payload
        time.sleep(0.2)
    if last_payload is not None and predicate(last_payload):
        return last_payload
    raise RuntimeError(
        f"Timed out waiting for render dump at {render_dump_path}.\n"
        f"Last payload: {json.dumps(last_payload or {}, indent=2)}"
    )

def wait_for_terminal_window_dump(output_path: Path, predicate, timeout: float, any_mode: bool) -> dict:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        if output_path.exists():
            output_path.unlink()
        command = [str(spacese2e), "dump-terminal-session-window-state", "--session-id", session_id, "--output-path", str(output_path)]
        if any_mode:
            command.append("--any-mode")
        subprocess.run(command, capture_output=True, text=True, env=env, check=True)
        file_deadline = time.time() + 1.0
        while time.time() < file_deadline:
            if output_path.exists():
                try:
                    payload = json.loads(output_path.read_text())
                except json.JSONDecodeError:
                    time.sleep(0.05)
                    continue
                last_payload = payload
                if predicate(payload):
                    return payload
                break
            time.sleep(0.05)
        time.sleep(0.2)
    raise RuntimeError(
        f"Timed out waiting for terminal window dump at {output_path}.\n"
        f"Last payload: {json.dumps(last_payload or {}, indent=2)}"
    )

def contains_command_output(text: str, command_text: str, output_text: str) -> bool:
    lines = text.splitlines()
    compact_text = re.sub(r"\s+", "", text)
    compact_command = re.sub(r"\s+", "", command_text)
    return (
        f"%{compact_command}" in compact_text
        and any(line.strip() == output_text for line in lines)
    )

def assert_prompt_rendered_after_output(label: str, text: str, output_text: str) -> None:
    lines = [line.rstrip() for line in text.splitlines()]
    for index, line in enumerate(lines):
        if line.strip() != output_text:
            continue
        for next_line in lines[index + 1:]:
            stripped = next_line.strip()
            if not stripped:
                continue
            if output_text in stripped or "printf " in stripped or "echo " in stripped:
                continue
            if re.search(r"%\s*$", next_line):
                return
        raise RuntimeError(f"{label} did not render the next shell prompt after {output_text!r}:\n{text}")
    raise RuntimeError(f"{label} did not render output marker {output_text!r}:\n{text}")

def mobile_rendered_text(payload: dict) -> str:
    return payload.get("renderedText") or ""

def mobile_owner_render_contains(payload: dict, *markers: str) -> bool:
    rendered_text = mobile_rendered_text(payload)
    return (
        payload.get("sessionID") == session_id
        and payload.get("isOwner") is True
        and payload.get("showsTerminalSurface") is True
        and payload.get("isBusy") is False
        and payload.get("isPreparingInput") is False
        and payload.get("isSynchronizingOwnership") is False
        and payload.get("isInputSurfaceReady") is True
        and bool(rendered_text.strip())
        and all(marker in rendered_text for marker in markers)
    )

def wait_for_mobile_owner_render(
    label: str,
    markers: tuple[str, ...],
    timeout: float,
    process: subprocess.Popen[str],
) -> dict:
    payload = wait_for_render_dump(
        lambda candidate: mobile_owner_render_contains(candidate, *markers),
        timeout=timeout,
        process=process,
    )
    if payload.get("errorMessage"):
        raise RuntimeError(f"{label} reported a {mobile_device_label} error:\n{json.dumps(payload, indent=2)}")
    assert_render_output_sane(label, mobile_rendered_text(payload))
    return payload

def assert_render_output_sane(label: str, text: str) -> None:
    if "command not found: s" in text:
        raise RuntimeError(f"{label} render contains split input failure:\n{text}")
    if re.search(r"(?m)^%$", text):
        raise RuntimeError(f"{label} render contains stray percent line:\n{text}")
    for line in text.splitlines():
        if line.count("%") > 1:
            raise RuntimeError(f"{label} render contains duplicated prompt on one line:\n{text}")
        if line.strip() in bare_command_lines:
            raise RuntimeError(f"{label} render contains a bare command line:\n{text}")
    if text.count("Last login:") > 1:
        raise RuntimeError(f"{label} render contains repeated login banner:\n{text}")
    if "\x1b" in text or "^[" in text:
        raise RuntimeError(f"{label} render contains raw escape remnants:\n{text}")

def mac_owner_render_contains(payload: dict, *markers: str) -> bool:
    if payload.get("found") is not True:
        return False
    rendered_text = payload.get("visibleSurfaceOutput") or payload.get("renderedOutput") or payload.get("visibleText") or ""
    if not all(marker in rendered_text for marker in markers):
        return False
    renderer_summary = payload.get("rendererSummary") or ""
    return payload.get("showsTerminalSurface") is True and renderer_summary == "Renderer: ghostty-mirror"

def mac_owner_render_uses_mac_sized_surface(payload: dict) -> bool:
    if payload.get("showsTerminalSurface") is not True:
        return False
    columns = payload.get("surfaceColumns")
    return isinstance(columns, int) and columns > 40

def write_command_request(command_text: str, send_enter: bool = True) -> None:
    payload = {
        "id": f"{int(time.time() * 1000)}-{os.getpid()}",
        "text": command_text,
        "sendEnter": send_enter,
    }
    command_request_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = command_request_path.with_name(f"{command_request_path.name}.{payload['id']}.tmp")
    temp_path.write_text(json.dumps(payload, sort_keys=True))
    temp_path.replace(command_request_path)

def wait_for_output_log_text(text: str, timeout: float, process: subprocess.Popen[str]) -> None:
    deadline = time.time() + timeout
    last_output = ""
    while time.time() < deadline:
        check_ui_test_alive(process)
        if output_log_path.exists():
            last_output = output_log_path.read_text(errors="replace")
            if text in last_output:
                return
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {text!r} in {output_log_path}.\nLast output tail:\n{last_output[-4000:]}")

def assert_status_shell_hides_live_content(label: str, payload: dict) -> None:
    if payload.get("showsTerminalSurface") is not False:
        raise RuntimeError(f"{label} unexpectedly mounted a live terminal surface:\n{json.dumps(payload, indent=2)}")
    visible_text = payload.get("visibleText") or payload.get("renderedOutput") or ""
    if "Current owner:" not in visible_text:
        raise RuntimeError(f"{label} did not show the takeover status shell:\n{json.dumps(payload, indent=2)}")
    if "__roundtrip_" in visible_text:
        raise RuntimeError(f"{label} exposed live terminal content:\n{json.dumps(payload, indent=2)}")

def request_mac_retakeover(expected_previous_owner: str) -> str:
    show_result = subprocess.run(
        [str(spaces_cli), "terminal", "show", session_id],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    if "Requested owner terminal window" not in show_result.stdout:
        raise RuntimeError(f"Mac retakeover did not report success:\n{show_result.stdout}\n{show_result.stderr}")
    reclaimed_owner = wait_for_active_owner(excluded_client_ids={expected_previous_owner}, timeout=20)
    if reclaimed_owner == expected_previous_owner:
        raise RuntimeError(f"Mac retakeover did not transfer ownership away from {mobile_device_label}.")
    return reclaimed_owner

ui_test_command = [
    "xcodebuild",
    "-project",
    "apps/ios/SpacesMobile.xcodeproj",
    "-scheme",
    "SpacesMobile",
    "-destination",
    f"platform=iOS Simulator,id={mobile_udid}",
    "-derivedDataPath",
    str(ios_derived_data),
    "-only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverRoundTripWithCommands",
    "test-without-building",
]

mac_owner_dump_path = scenario_dir / "roundtrip-mac-owner-dump.json"
mac_status_dump_path = scenario_dir / "roundtrip-mac-status-dump.json"

with ui_test_log.open("w") as ui_test_output:
    ui_test_process = subprocess.Popen(
        ui_test_command,
        cwd=repo_root,
        stdout=ui_test_output,
        stderr=subprocess.STDOUT,
        text=True,
        env=os.environ | {"SPACES_MOBILE_UI_TEST_CONFIG_PATH": str(ui_test_config)},
    )

    try:
        for command_text in mac_prepare_commands:
            send_owner_command(command_text)
            time.sleep(0.5)

        mac_owner_payload = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                mac_owner_render_contains(
                    payload, "__roundtrip_mac_before_takeover_one__", "__roundtrip_mac_before_takeover_two__"
                )
            ),
            timeout=45,
            any_mode=False,
        )
        expected_render_text = mac_owner_payload.get("renderedOutput") or ""
        if not expected_render_text:
            raise RuntimeError(f"Unable to derive canonical Mac owner render text:\n{json.dumps(mac_owner_payload, indent=2)}")
        assert_render_output_sane("Mac owner before takeover", expected_render_text)
        mac_visible_text = mac_owner_payload.get("visibleSurfaceOutput") or ""
        if not mac_visible_text:
            raise RuntimeError(f"Mac owner before takeover did not report visible surface text:\n{json.dumps(mac_owner_payload, indent=2)}")
        assert_prompt_rendered_after_output(
            "Mac owner before takeover",
            mac_visible_text,
            "__roundtrip_mac_before_takeover_two__",
        )

        write_marker(proceed_takeover_path, "go\n")

        mobile_owner_payload = wait_for_mobile_owner_render(
            f"{mobile_device_label} after first takeover",
            ("__roundtrip_mac_before_takeover_one__", "__roundtrip_mac_before_takeover_two__"),
            timeout=40,
            process=ui_test_process,
        )
        mobile_owner_text = mobile_rendered_text(mobile_owner_payload)
        if "__roundtrip_mac_before_takeover_one__" not in mobile_owner_text or "__roundtrip_mac_before_takeover_two__" not in mobile_owner_text:
            raise RuntimeError(
                f"{mobile_device_label} owner render did not include the Mac pre-takeover transcript markers:\n"
                f"{json.dumps(mobile_owner_payload, indent=2)}"
            )

        write_marker(first_command_request, "go\n")
        wait_for_file(first_command_focused, timeout=30, process=ui_test_process)
        write_command_request(ios_first_command)
        wait_for_output_log_text(ios_first_output, timeout=20, process=ui_test_process)
        write_marker(first_command_completed)
        wait_for_file(first_command_observed, timeout=20, process=ui_test_process)
        wait_for_mobile_owner_render(
            f"{mobile_device_label} after first command",
            ("__roundtrip_mac_before_takeover_one__", "__roundtrip_mac_before_takeover_two__", ios_first_output),
            timeout=20,
            process=ui_test_process,
        )

        write_marker(second_command_request, "go\n")
        wait_for_file(second_command_focused, timeout=30, process=ui_test_process)
        write_command_request(ios_second_command)
        wait_for_output_log_text(ios_second_output, timeout=20, process=ui_test_process)
        write_marker(second_command_completed)
        wait_for_file(second_command_observed, timeout=20, process=ui_test_process)
        wait_for_mobile_owner_render(
            f"{mobile_device_label} after second command",
            ("__roundtrip_mac_before_takeover_one__", "__roundtrip_mac_before_takeover_two__", ios_first_output, ios_second_output),
            timeout=20,
            process=ui_test_process,
        )

        mobile_owner_client_id = wait_for_active_owner(timeout=10)
        request_mac_retakeover(mobile_owner_client_id)
        mobile_after_mac_retakeover = wait_for_render_dump(
            lambda payload: (
                payload.get("sessionID") == session_id
                and payload.get("isOwner") is False
                and payload.get("showsTerminalSurface") is False
                and (payload.get("renderedText") or "") == ""
                and "Current owner:" in (payload.get("visibleText") or "")
            ),
            timeout=20,
            process=ui_test_process,
        )
        if mobile_after_mac_retakeover.get("errorMessage"):
            raise RuntimeError(
                f"{mobile_device_label} reported an error after Mac retakeover:\n{json.dumps(mobile_after_mac_retakeover, indent=2)}"
            )

        mac_owner_after_retakeover = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                mac_owner_render_contains(payload, ios_first_output, ios_second_output)
                and mac_owner_render_uses_mac_sized_surface(payload)
                and contains_command_output(payload.get("renderedOutput") or "", ios_first_command, ios_first_output)
                and contains_command_output(payload.get("renderedOutput") or "", ios_second_command, ios_second_output)
            ),
            timeout=20,
            any_mode=False,
        )
        assert_render_output_sane("Mac after first retakeover", mac_owner_after_retakeover.get("renderedOutput") or "")
        write_marker(proceed_finish_path)

        for attempt_index in range(2):
            takeover_number = attempt_index + 2
            wait_for_file(Path(f"{manual_retakeover_prefix}-{attempt_index + 1}"), timeout=30, process=ui_test_process)
            wait_for_mobile_owner_render(
                f"{mobile_device_label} after takeover {takeover_number}",
                (ios_first_output, ios_second_output),
                timeout=20,
                process=ui_test_process,
            )
            probe_output = f"__roundtrip_{mobile_artifact_name}_after_takeover_{takeover_number}__"
            probe_command = f"printf '{probe_output}\\n'"
            write_command_request(probe_command)
            wait_for_output_log_text(probe_output, timeout=20, process=ui_test_process)
            wait_for_mobile_owner_render(
                f"{mobile_device_label} after takeover {takeover_number} probe command",
                (ios_first_output, ios_second_output, probe_output),
                timeout=20,
                process=ui_test_process,
            )

            mac_status_payload = wait_for_terminal_window_dump(
                mac_status_dump_path,
                lambda payload: payload.get("found") is True and payload.get("showsTerminalSurface") is False,
                timeout=20,
                any_mode=True,
            )
            assert_status_shell_hides_live_content(f"Mac status after {mobile_device_label} takeover {takeover_number}", mac_status_payload)

            if attempt_index >= 1:
                continue

            current_mobile_owner = wait_for_active_owner(timeout=10)
            request_mac_retakeover(current_mobile_owner)
            mobile_after_mac_retakeover = wait_for_render_dump(
                lambda payload: (
                    payload.get("sessionID") == session_id
                    and payload.get("isOwner") is False
                    and payload.get("showsTerminalSurface") is False
                    and (payload.get("renderedText") or "") == ""
                    and "Current owner:" in (payload.get("visibleText") or "")
                ),
                timeout=20,
                process=ui_test_process,
            )
            if mobile_after_mac_retakeover.get("errorMessage"):
                raise RuntimeError(
                    f"{mobile_device_label} reported an error after Mac retakeover {takeover_number}:\n"
                    f"{json.dumps(mobile_after_mac_retakeover, indent=2)}"
                )
            mac_owner_after_retakeover = wait_for_terminal_window_dump(
                mac_owner_dump_path,
                lambda payload: (
                    mac_owner_render_contains(payload, ios_first_output, ios_second_output)
                    and mac_owner_render_uses_mac_sized_surface(payload)
                    and contains_command_output(payload.get("renderedOutput") or "", ios_first_command, ios_first_output)
                    and contains_command_output(payload.get("renderedOutput") or "", ios_second_command, ios_second_output)
                ),
                timeout=20,
                any_mode=False,
            )
            assert_render_output_sane(
                f"Mac after retakeover {takeover_number}",
                mac_owner_after_retakeover.get("renderedOutput") or "",
            )
            write_marker(Path(f"{manual_retakeover_continue_prefix}-{attempt_index + 1}"))

        final_mobile_owner = wait_for_active_owner(timeout=10)
        request_mac_retakeover(final_mobile_owner)
        mobile_after_final_mac_retakeover = wait_for_render_dump(
            lambda payload: (
                payload.get("sessionID") == session_id
                and payload.get("isOwner") is False
                and payload.get("showsTerminalSurface") is False
                and (payload.get("renderedText") or "") == ""
                and "Current owner:" in (payload.get("visibleText") or "")
            ),
            timeout=20,
            process=ui_test_process,
        )
        if mobile_after_final_mac_retakeover.get("errorMessage"):
            raise RuntimeError(
                f"{mobile_device_label} reported an error after the final Mac retakeover:\n"
                f"{json.dumps(mobile_after_final_mac_retakeover, indent=2)}"
            )
        mac_owner_after_final_retakeover = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                mac_owner_render_contains(payload, ios_first_output, ios_second_output)
                and mac_owner_render_uses_mac_sized_surface(payload)
                and contains_command_output(payload.get("renderedOutput") or "", ios_first_command, ios_first_output)
                and contains_command_output(payload.get("renderedOutput") or "", ios_second_command, ios_second_output)
            ),
            timeout=20,
            any_mode=False,
        )
        assert_render_output_sane("Mac after final retakeover", mac_owner_after_final_retakeover.get("renderedOutput") or "")
        write_marker(final_mac_retakeover_request, "go\n")
        wait_for_file(final_mac_retakeover_observed, timeout=20, process=ui_test_process)

        return_code = ui_test_process.wait(timeout=120)
        if return_code != 0:
            log_tail = ui_test_log.read_text(errors="replace")[-12000:] if ui_test_log.exists() else "<missing>"
            raise RuntimeError(f"Round-trip UI test failed with status {return_code}.\n{log_tail}")

        if not render_dump_path.exists():
            raise RuntimeError(f"Expected final {mobile_device_label} render dump at {render_dump_path}")
        if not event_log_path.exists():
            raise RuntimeError(f"Expected {mobile_device_label} event log at {event_log_path}")
    finally:
        if ui_test_process.poll() is None:
            ui_test_process.terminate()
            try:
                ui_test_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                ui_test_process.kill()
                ui_test_process.wait(timeout=10)
PY
  printf 'Mobile scenario passed: roundtrip\n'
}

launch_scrollback_fixture_on_mac_owner() {
  local session_id="$1"
  python3 - "$ROOT_DIR" "$DEMO_ROOT" "$session_id" "$SPACES_E2E_BIN" "$FIXTURE_LINE_COUNT" "$SCENARIO_DIR" <<'PY'
import json
import os
import shlex
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

repo_root = Path(sys.argv[1])
demo_root = Path(sys.argv[2])
session_id = sys.argv[3]
spacese2e = Path(sys.argv[4])
line_count = int(sys.argv[5])
scenario_dir = Path(sys.argv[6])
runtime_root = demo_root / "runtime"
owner_dump_path = scenario_dir / "scrollback-owner-dump.json"

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
    root_directory = os.path.normpath(str(runtime_root / "terminal" / "sessions" / session_id))
    with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
        row = db.execute(
            """
            SELECT client_id
            FROM terminal_attachments
            WHERE root_directory = ?
              AND mode = 'owner'
              AND detached_at IS NULL
            ORDER BY attached_at DESC
            LIMIT 1
            """,
            (root_directory,),
        ).fetchone()
    if row:
        return row[0]
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
    deadline = time.time() + 15
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

raise RuntimeError("Timed out waiting for the scrollback fixture to complete.")
PY
}

run_scrollback_scenario() {
  begin_scenario "scrollback"
  local session_id
  session_id="$(new_terminal_session)"
  track_current_scenario_session "$session_id"
  launch_scrollback_fixture_on_mac_owner "$session_id" >>"$SCENARIO_LOG" 2>&1 || fail "Failed to launch scrollback fixture."
  write_ui_test_config "scrollback" "$session_id"
  reset_mobile_app
  SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
    xcodebuild \
      -project "$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj" \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$MOBILE_UDID" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      -only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList \
      test-without-building >"$UI_TEST_LOG" 2>&1 &
  local ui_test_pid=$!

  if ! python3 - "$DEMO_ROOT" "$SCENARIO_DIR" "$UI_TEST_CONFIG" "$MOBILE_DEVICE_LABEL" <<'PY'
import json
import sys
import time
from pathlib import Path

demo_root = Path(sys.argv[1])
scenario_dir = Path(sys.argv[2])
ui_test_config = Path(sys.argv[3])
mobile_device_label = sys.argv[4]
config = json.loads(ui_test_config.read_text())
event_log_path = Path(config["eventLogPath"])
performance_log_path = demo_root / "mobile-terminal-performance.jsonl"
command_request_path = Path(f"{event_log_path}.command-request.json")
first_command_request_path = Path(config["firstCommandRequestPath"])
first_command_completed_path = Path(config["firstCommandCompletedPath"])
first_command_observed_path = Path(config["firstCommandObservedPath"])
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

deadline = time.time() + 90
while time.time() < deadline:
    events = read_json_lines(event_log_path)
    kinds = {event.get("kind") for event in events if event.get("kind")}
    performance_events = read_json_lines(performance_log_path)
    if (
        "e2e_scroll_gesture_applied" in kinds
        and any(event.get("name") == "owner_first_input_ready" for event in performance_events)
    ):
        break
    time.sleep(0.2)
else:
    raise SystemExit(f"Timed out waiting for the {mobile_device_label} app to apply the scrollback gesture.")

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
    raise SystemExit(f"Timed out waiting for the {mobile_device_label} app to consume the post-scrollback command request.")

deadline = time.time() + 60
while time.time() < deadline:
    events = read_json_lines(event_log_path)
    send_text_success = any(event.get("kind") == "send_text_success" and command_text in (event.get("detail") or "") for event in events)
    send_key_success = any(event.get("kind") == "send_key_success" and event.get("detail") == "enter" for event in events)
    combined_send_success = any(
        event.get("kind") == "send_text_success"
        and command_text in (event.get("detail") or "")
        and (event.get("detail") or "").endswith("\\n")
        for event in events
    )
    if combined_send_success or (send_text_success and send_key_success):
        break
    time.sleep(0.2)
else:
    raise SystemExit(f"Timed out waiting for the {mobile_device_label} owner command to complete while scrolled up.")

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
    fail "Scrollback command orchestration failed."
  fi

  if ! wait "$ui_test_pid"; then
    fail "Scrollback UI test failed."
  fi

  python3 - "$SCENARIO_DIR" "$DEMO_ROOT" "$FIXTURE_LINE_COUNT" "$UI_TEST_CONFIG" "$MOBILE_DEVICE_LABEL" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

scenario_dir = Path(sys.argv[1])
demo_root = Path(sys.argv[2])
fixture_line_count = int(sys.argv[3])
ui_test_config = Path(sys.argv[4])
mobile_device_label = sys.argv[5]
config = json.loads(ui_test_config.read_text())
owner_dump_path = scenario_dir / "scrollback-owner-dump.json"
mobile_dump_path = Path(config["renderDumpPath"])
event_log_path = Path(config["eventLogPath"])
performance_log_path = demo_root / "mobile-terminal-performance.jsonl"

owner_payload = json.loads(owner_dump_path.read_text())
mobile_payload = json.loads(mobile_dump_path.read_text())
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
mobile_text = mobile_payload.get("renderedText") or mobile_payload.get("snapshotText") or ""
session_id = mobile_payload.get("sessionID")
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
    raise SystemExit(f"The {mobile_device_label} app never applied the scrollback drag gesture.")
if not any(event.get("kind") == "e2e_command_request_consumed" for event in event_payloads):
    raise SystemExit(f"The {mobile_device_label} app never consumed the post-scrollback owner command.")
if f"FIXTURE_DONE mode=lines emitted={fixture_line_count}" not in owner_text:
    raise SystemExit("Owner baseline did not reach the bottom of the long-output fixture.")
if not mobile_text.strip():
    raise SystemExit(f"{mobile_device_label} render dump was blank after scrollback.")
for dump in owner_render_dumps:
    dump_text = dump.get("renderedText") or ""
    if any(line.strip() == "%" for line in dump_text.splitlines()):
        raise SystemExit(
            f"{mobile_device_label} owner render contained a stray percent prompt row during scrollback.\n"
            f"render_state={dump.get('renderStateKey')}\n"
            f"rendered_text={dump_text}"
        )

first_nonblank = [event for event in session_performance_events if event.get("name") == "owner_first_nonblank_render"]
first_input_ready = [event for event in session_performance_events if event.get("name") == "owner_first_input_ready"]
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

if len(first_nonblank) != 1:
    raise SystemExit(f"Expected exactly one first non-blank render during scrollback, found {len(first_nonblank)}")
if len(first_input_ready) != 1:
    raise SystemExit(f"Expected exactly one first input-ready event during scrollback, found {len(first_input_ready)}")
if post_ready_snapshot_exports:
    raise SystemExit(
        "Found unexpected snapshot exports after takeover became interactive during scrollback: "
        + ", ".join(event.get("attributes", {}).get("reason", "?") for event in post_ready_snapshot_exports)
    )
PY

  printf 'Mobile scenario passed: scrollback\n'
}

write_terminal_link_preview_fixture() {
  python3 - "$TERMINAL_LINK_PREVIEW_PATH" <<'PY'
import base64
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_bytes(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
))
PY
}

run_terminal_link_preview_scenario() {
  begin_scenario "terminal-link-preview"
  write_terminal_link_preview_fixture
  local command_text
  local quoted_link_path
  printf -v quoted_link_path '%q' "$TERMINAL_LINK_PREVIEW_PATH"
  command_text="printf '__spaces_mobile_link_preview__\\n%s\\n' $quoted_link_path; exec /bin/zsh -l"
  local session_id
  session_id="$(new_terminal_session "e2e-terminal-link-preview" "$command_text")"
  track_current_scenario_session "$session_id"
  write_ui_test_config "terminal-link-preview" "$session_id"
  run_ui_test "SpacesMobileUITests/SpacesMobileUITests/testTerminalTapLocalImagePathOpensPreview"
  printf 'Mobile scenario passed: terminal-link-preview\n'
}

run_two_session_scenario() {
  begin_scenario "two-session"
  local session_id
  local secondary_session_id
  session_id="$(new_terminal_session)"
  track_current_scenario_session "$session_id"
  secondary_session_id="$(new_terminal_session)"
  track_current_scenario_session "$secondary_session_id"
  write_ui_test_config "two-session" "$session_id" "$secondary_session_id"
  run_ui_test "SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverAcrossTwoSessionsFromList"
  printf 'Mobile scenario passed: two-session\n'
}

assert_ctrl_c_final_frame_scenario() {
  local session_id="$1"
  local secondary_session_id="$2"
  local expected_service_pid="$3"
  python3 - "$DEMO_ROOT" "$SCENARIO_DIR" "$UI_TEST_CONFIG" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$session_id" "$secondary_session_id" "$expected_service_pid" "$BRIDGE_HOST" "$BRIDGE_PORT" "$BUNDLE_ID" "$MOBILE_DEVICE_KEY" "$MOBILE_DEVICE_NAME" "$MOBILE_DEVICE_LABEL" <<'PY'
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

demo_root = Path(sys.argv[1])
scenario_dir = Path(sys.argv[2])
ui_test_config = Path(sys.argv[3])
spaces_cli = Path(sys.argv[4])
spacese2e = Path(sys.argv[5])
session_id = sys.argv[6]
secondary_session_id = sys.argv[7]
expected_service_pid = int(sys.argv[8])
bridge_host = sys.argv[9]
bridge_port = int(sys.argv[10])
bundle_id = sys.argv[11]
mobile_device_key = sys.argv[12]
mobile_device_name = sys.argv[13]
mobile_device_label = sys.argv[14]
runtime_root = demo_root / "runtime"
config = json.loads(ui_test_config.read_text())
expected_interrupted_text = config["expectedInterruptedText"]
expected_secondary_text = config["expectedSecondaryText"]
interrupted_dump_path = Path(config["interruptedRenderDumpPath"])
event_log_path = Path(config["eventLogPath"])
pairing = json.loads((demo_root / "pairing.json").read_text())[mobile_device_key]

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}
client_app = {
    "installationID": pairing["installationID"],
    "bundleID": bundle_id,
    "platform": "ios",
    "deviceName": mobile_device_name,
    "appVersion": "1.0",
}

def combined_terminal_text(payload: dict) -> str:
    return "\n".join(str(payload.get(key) or "") for key in ("renderedText", "snapshotText", "visibleText", "renderedOutput"))

def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)

def process_is_alive(pid: int) -> bool:
    return subprocess.run(["/bin/kill", "-0", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def send_mobile_request(request: dict) -> dict:
    completed = subprocess.run(
        [
            str(spaces_cli),
            "mobile",
            "request",
            "--host",
            bridge_host,
            "--port",
            str(bridge_port),
            "--transport-key",
            pairing["transportKey"],
            "--request-json",
            json.dumps({"authToken": pairing["authToken"], "clientApp": client_app, **request}),
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
        check=True,
    )
    return json.loads(completed.stdout)

require(interrupted_dump_path.exists(), f"Missing interrupted {mobile_device_label} render dump at {interrupted_dump_path}")
interrupted_dump = json.loads(interrupted_dump_path.read_text())
interrupted_text = combined_terminal_text(interrupted_dump)
require(interrupted_dump.get("sessionID") == session_id, f"Interrupted dump used the wrong session:\n{json.dumps(interrupted_dump, indent=2)}")
require(interrupted_dump.get("renderMode") == "ended", f"Interrupted dump did not enter ended mode:\n{json.dumps(interrupted_dump, indent=2)}")
require(interrupted_dump.get("showsTerminalSurface") is True, f"Interrupted dump did not mount the terminal surface:\n{json.dumps(interrupted_dump, indent=2)}")
require(not interrupted_dump.get("isOwner"), f"Interrupted dump still claimed ownership:\n{json.dumps(interrupted_dump, indent=2)}")
require(not interrupted_dump.get("errorMessage"), f"Interrupted dump reported an error:\n{json.dumps(interrupted_dump, indent=2)}")
require(expected_interrupted_text in interrupted_text, f"Interrupted final frame missed {expected_interrupted_text!r}:\n{interrupted_text}")
require("final render was available" not in interrupted_text, f"Interrupted render used the ended fallback message:\n{interrupted_text}")
require("Final terminal render unavailable" not in interrupted_text, f"Interrupted render used the Mac fallback message:\n{interrupted_text}")

event_lines = []
if event_log_path.exists():
    event_lines = [json.loads(line) for line in event_log_path.read_text().splitlines() if line.strip()]
require(
    any(event.get("kind") == "e2e_command_request_consumed" and "key=ctrl+c" in (event.get("detail") or "") for event in event_lines),
    f"The {mobile_device_label} event log did not record the ctrl+c request.",
)
require(
    any(event.get("kind") == "send_key_begin" and event.get("detail") == "ctrl+c" for event in event_lines),
    f"The {mobile_device_label} event log did not begin a ctrl+c key send.",
)

with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
    primary_state = db.execute(
        "SELECT state, service_pid, child_pid FROM terminal_runtime_states WHERE session_id = ?",
        (session_id,),
    ).fetchone()
    secondary_state = db.execute(
        "SELECT state, service_pid, child_pid FROM terminal_runtime_states WHERE session_id = ?",
        (secondary_session_id,),
    ).fetchone()
    persisted_final = db.execute(
        "SELECT reason, payload_json FROM terminal_remote_session_states WHERE session_id = ?",
        (session_id,),
    ).fetchone()
require(process_is_alive(expected_service_pid), f"spacesd pid {expected_service_pid} exited after ctrl+c.")
require(primary_state and primary_state[0] == "exited", f"Primary session did not exit after ctrl+c: {primary_state!r}")
require(
    primary_state[1] == expected_service_pid,
    f"Primary session was closed by a different spacesd pid. expected={expected_service_pid} row={primary_state!r}",
)
require(secondary_state and secondary_state[0] == "running", f"Secondary session did not remain running: {secondary_state!r}")
require(
    secondary_state[1] == expected_service_pid,
    f"Secondary session moved to a different spacesd pid. expected={expected_service_pid} row={secondary_state!r}",
)
require(
    secondary_state[2] and process_is_alive(int(secondary_state[2])),
    f"Secondary child process is not alive after ctrl+c: {secondary_state!r}",
)
require(persisted_final is not None, "Primary session did not persist a final remote state payload.")
require(persisted_final[0] == "terminated", f"Persisted final payload reason was not terminated: {persisted_final[0]!r}")
persisted_final_payload = json.loads(persisted_final[1])
require(bool(persisted_final_payload.get("renderUpdate")), "Persisted final payload did not include an encoded render update.")

overview_response = send_mobile_request({"command": "overview"})
require(overview_response.get("ok"), f"Bridge overview failed after ctrl+c: {overview_response}")
overview_sessions = overview_response.get("overview", {}).get("sessions", [])
require(
    any(session.get("id") == secondary_session_id for session in overview_sessions),
    f"Bridge overview did not include the surviving session after ctrl+c: {json.dumps(overview_response, indent=2)}",
)

def wait_for_terminal_window_dump(session: str, output_path: Path, predicate, timeout: float) -> dict:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        if output_path.exists():
            output_path.unlink()
        subprocess.run(
            [
                str(spacese2e),
                "dump-terminal-session-window-state",
                "--session-id",
                session,
                "--output-path",
                str(output_path),
                "--any-mode",
            ],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )
        file_deadline = time.time() + 1
        while time.time() < file_deadline:
            if output_path.exists():
                try:
                    payload = json.loads(output_path.read_text())
                except json.JSONDecodeError:
                    time.sleep(0.05)
                    continue
                last_payload = payload
                if predicate(payload):
                    return payload
                break
            time.sleep(0.05)
        time.sleep(0.2)
    raise RuntimeError(
        f"Timed out waiting for terminal window dump for {session} at {output_path}.\n"
        f"Last payload: {json.dumps(last_payload or {}, indent=2)}"
    )

primary_window = wait_for_terminal_window_dump(
    session_id,
    scenario_dir / "ctrl-c-primary-window.json",
    lambda payload: (
        payload.get("found") is True
        and payload.get("showsTerminalSurface") is True
        and payload.get("rendererSummary") == "Renderer: final Ghostty render"
        and expected_interrupted_text in combined_terminal_text(payload)
    ),
    timeout=30,
)
primary_window_text = combined_terminal_text(primary_window)
require("final render was available" not in primary_window_text, f"Mac primary window used the ended fallback:\n{primary_window_text}")
require("Final terminal render unavailable" not in primary_window_text, f"Mac primary window used the unavailable fallback:\n{primary_window_text}")

secondary_output_path = runtime_root / "terminal" / "sessions" / secondary_session_id / "output.log"
secondary_output = secondary_output_path.read_text(errors="replace") if secondary_output_path.exists() else ""
if expected_secondary_text:
    require(expected_secondary_text in secondary_output, f"Secondary output log missed {expected_secondary_text!r}:\n{secondary_output[-4000:]}")
wait_for_terminal_window_dump(
    secondary_session_id,
    scenario_dir / "ctrl-c-secondary-window.json",
    lambda payload: (
        payload.get("found") is True
        and payload.get("didCloseWindow") is not True
        and payload.get("rendererSummary") != "Renderer: final Ghostty render"
    ),
    timeout=20,
)

(scenario_dir / "ctrl-c-final-frame-result.json").write_text(json.dumps({
    "sessionID": session_id,
    "secondarySessionID": secondary_session_id,
    "terminalServicePID": expected_service_pid,
    "primaryState": primary_state[0],
    "secondaryState": secondary_state[0],
    "secondaryChildPID": secondary_state[2],
    "primaryRendererSummary": primary_window.get("rendererSummary"),
}, indent=2, sort_keys=True))
PY
}

run_ctrl_c_final_frame_scenario() {
  local scenario="${1:-ctrl-c-final-frame}"
  begin_scenario "$scenario"
  local session_id
  local secondary_session_id
  local interrupt_command="python3 -c 'for i in range(80): print(f\"__spaces_ctrl_c_fill_{i:03d}__\"); print(\"__spaces_ctrl_c_target_ready__\")'; sleep 300"
  session_id="$(new_terminal_session "interrupt-target" "$interrupt_command")"
  track_current_scenario_session "$session_id"
  if [[ "$scenario" == "ctrl-c-final-frame-codex-survivor" ]]; then
    require_codex_auth_for_e2e
    local trusted_project_dir
    trusted_project_dir="$(cd "$PROJECT_DIR" && pwd -P)"
    prepare_codex_home_for_e2e "$trusted_project_dir"
    secondary_session_id="$(new_terminal_session "survivor-codex")"
  else
    local survivor_command="printf '__spaces_survivor_peer_ready__\\n'; sleep 300"
    secondary_session_id="$(new_terminal_session "survivor-peer" "$survivor_command")"
  fi
  track_current_scenario_session "$secondary_session_id"
  if [[ "$scenario" == "ctrl-c-final-frame-codex-survivor" ]]; then
    local codex_command_prefix
    codex_command_prefix="$(codex_demo_command_prefix)"
    launch_codex_on_mac_owner "$secondary_session_id" "${SPACES_MOBILE_CODEX_COMMAND:-$codex_command_prefix}" >>"$SCENARIO_LOG" 2>&1 \
      || fail "Failed to launch Codex survivor in $secondary_session_id."
  fi
  local expected_service_pid
  expected_service_pid="$(
    sqlite3 "$DB_PATH" "SELECT service_pid FROM terminal_runtime_states WHERE session_id = '$secondary_session_id' LIMIT 1;"
  )"
  [[ -n "$expected_service_pid" ]] || fail "Unable to resolve spacesd pid before Ctrl+C scenario."
  write_ui_test_config "$scenario" "$session_id" "$secondary_session_id"
  run_ui_test "SpacesMobileUITests/SpacesMobileUITests/testTerminalInterruptShowsFinalFrameAndKeepsSecondSessionLive"
  assert_ctrl_c_final_frame_scenario "$session_id" "$secondary_session_id" "$expected_service_pid" >>"$SCENARIO_LOG" 2>&1 || fail "Ctrl+C final-frame assertions failed."
  printf 'Mobile scenario passed: %s\n' "$scenario"
}

run_ownership_guard_scenario() {
  begin_scenario "ownership-guard"
  local session_id
  session_id="$(new_terminal_session)"
  track_current_scenario_session "$session_id"
  python3 - "$DEMO_ROOT" "$session_id" "$BRIDGE_HOST" "$BRIDGE_PORT" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$SCENARIO_DIR" "$BUNDLE_ID" "$MOBILE_DEVICE_KEY" "$MOBILE_DEVICE_NAME" "$MOBILE_DEVICE_LABEL" <<'PY'
import json
import os
import socket
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path

demo_root = Path(sys.argv[1])
session_id = sys.argv[2]
bridge_host = sys.argv[3]
bridge_port = int(sys.argv[4])
spaces_cli = Path(sys.argv[5])
spacese2e = Path(sys.argv[6])
scenario_dir = Path(sys.argv[7])
bundle_id = sys.argv[8]
mobile_device_key = sys.argv[9]
mobile_device_name = sys.argv[10]
mobile_device_label = sys.argv[11]
runtime_root = demo_root / "runtime"
output_log_path = runtime_root / "terminal" / "sessions" / session_id / "output.log"
pairing = json.loads((demo_root / "pairing.json").read_text())[mobile_device_key]

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}

client_app = {
    "installationID": pairing["installationID"],
    "bundleID": bundle_id,
    "platform": "ios",
    "deviceName": mobile_device_name,
    "appVersion": "1.0",
}
mobile_client = {
    "id": str(uuid.uuid4()).upper(),
    "kind": "remoteViewer",
    "identity": {"label": f"ownership-guard-{mobile_device_key}", "deviceName": mobile_device_label, "networkAddress": "127.0.0.1"},
    "connectedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "disconnectedAt": None,
}

def send_mobile_request(request: dict) -> dict:
    completed = subprocess.run(
        [
            str(spaces_cli),
            "mobile",
            "request",
            "--host",
            bridge_host,
            "--port",
            str(bridge_port),
            "--transport-key",
            pairing["transportKey"],
            "--request-json",
            json.dumps({"authToken": pairing["authToken"], "clientApp": client_app, **request}),
        ],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    return json.loads(completed.stdout)

def active_owner(excluded: set[str] | None = None, timeout: float = 20) -> str:
    excluded = excluded or set()
    deadline = time.time() + timeout
    last_snapshot = ""
    root_directory = os.path.normpath(str(runtime_root / "terminal" / "sessions" / session_id))
    while time.time() < deadline:
        with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
            rows = db.execute(
                """
                SELECT client_id
                FROM terminal_attachments
                WHERE root_directory = ?
                  AND mode = 'owner'
                  AND detached_at IS NULL
                ORDER BY attached_at DESC
                """,
                (root_directory,),
            ).fetchall()
        last_snapshot = repr(rows)
        for (client_id,) in rows:
            if client_id not in excluded:
                return client_id
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for active owner.\n{last_snapshot}")

def wait_for_output(text: str, timeout: float = 20) -> None:
    deadline = time.time() + timeout
    last_output = ""
    while time.time() < deadline:
        if output_log_path.exists():
            last_output = output_log_path.read_text(errors="replace")
            if text in last_output:
                return
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {text!r} in output log.\n{last_output[-4000:]}")

initial_owner = active_owner(timeout=20)
attach = send_mobile_request({
    "command": "attach",
    "sessionID": session_id,
    "client": mobile_client,
    "attachmentMode": "viewer",
})
if not attach.get("ok"):
    raise RuntimeError(f"Viewer attach failed: {attach}")

blocked = send_mobile_request({
    "command": "send",
    "sessionID": session_id,
    "text": "echo __ownership_viewer_blocked__",
    "appendNewline": True,
    "clientID": mobile_client["id"],
})
if blocked.get("ok"):
    raise RuntimeError(f"Viewer input should have been rejected: {blocked}")

takeover = send_mobile_request({"command": "takeover", "sessionID": session_id, "clientID": mobile_client["id"]})
if not takeover.get("ok"):
    raise RuntimeError(f"Mobile takeover failed: {takeover}")
owner_after_takeover = active_owner(excluded={initial_owner}, timeout=20)
if owner_after_takeover != mobile_client["id"]:
    raise RuntimeError(f"Expected mobile client to own the session, found {owner_after_takeover}")

sent = send_mobile_request({
    "command": "send",
    "sessionID": session_id,
    "text": "echo __ownership_mobile_allowed__",
    "clientID": mobile_client["id"],
})
if not sent.get("ok"):
    raise RuntimeError(f"Mobile owner send failed: {sent}")
key = send_mobile_request({"command": "key", "sessionID": session_id, "key": "enter", "clientID": mobile_client["id"]})
if not key.get("ok"):
    raise RuntimeError(f"Mobile owner enter failed: {key}")
wait_for_output("__ownership_mobile_allowed__", timeout=20)

show_result = subprocess.run(
    [str(spaces_cli), "terminal", "show", session_id],
    capture_output=True,
    text=True,
    env=env,
    check=True,
)
if "Requested owner terminal window" not in show_result.stdout:
    raise RuntimeError(f"Mac retakeover did not report success:\n{show_result.stdout}\n{show_result.stderr}")
mac_owner = active_owner(excluded={mobile_client["id"]}, timeout=20)
if mac_owner == mobile_client["id"]:
    raise RuntimeError("Mac retakeover did not remove mobile ownership.")

blocked_again = send_mobile_request({
    "command": "send",
    "sessionID": session_id,
    "text": "echo __ownership_mobile_blocked_again__",
    "appendNewline": True,
    "clientID": mobile_client["id"],
})
if blocked_again.get("ok"):
    raise RuntimeError(f"Mobile input should have been rejected after Mac retakeover: {blocked_again}")

(scenario_dir / "ownership-guard-result.json").write_text(json.dumps({
    "sessionID": session_id,
    "initialOwner": initial_owner,
    "mobileOwner": owner_after_takeover,
    "macOwnerAfterRetakeover": mac_owner,
}, indent=2, sort_keys=True))
PY
  printf 'Mobile scenario passed: ownership-guard\n'
}

run_app_recovery_scenario() {
  begin_scenario "app-recovery"
  local session_id
  session_id="$(new_terminal_session "app-recovery" "printf '__spaces_app_recovery_live__\\n'; sleep 300")"
  track_current_scenario_session "$session_id"

  local new_app_pid
  if ! new_app_pid="$(python3 - "$DEMO_ROOT" "$DB_PATH" "$RUNTIME_DIR" "$session_id" "$DEMO_TERMINAL_SERVICE_PID" "$SPACES_CLI_BIN" "$BRIDGE_HOST" "$BRIDGE_PORT" "$TERMINAL_SERVICE_BIN" "$BUNDLE_ID" "$MOBILE_DEVICE_KEY" "$MOBILE_DEVICE_NAME" "$SCENARIO_DIR" <<'PY' 2>>"$SCENARIO_LOG"
import json
import os
import shlex
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

demo_root = Path(sys.argv[1])
db_path = Path(sys.argv[2])
runtime_root = Path(sys.argv[3])
session_id = sys.argv[4]
metadata_terminal_service_pid = sys.argv[5]
spaces_cli = Path(sys.argv[6])
bridge_host = sys.argv[7]
bridge_port = int(sys.argv[8])
terminal_service_bin = sys.argv[9]
bundle_id = sys.argv[10]
mobile_device_key = sys.argv[11]
mobile_device_name = sys.argv[12]
scenario_dir = Path(sys.argv[13])
pairing = json.loads((demo_root / "pairing.json").read_text())[mobile_device_key]
app_recovery_state_path = demo_root / "app-recovery-state.json"

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "SPACES_DB_PATH": str(db_path),
    "SPACES_RUNTIME_DIR": str(runtime_root),
    "SPACESD_EXECUTABLE": terminal_service_bin,
}
client_app = {
    "installationID": pairing["installationID"],
    "bundleID": bundle_id,
    "platform": "ios",
    "deviceName": mobile_device_name,
    "appVersion": "1.0",
}

def log(message: str) -> None:
    print(message, file=sys.stderr)

def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)

def write_app_recovery_state(payload: dict) -> None:
    temp_path = app_recovery_state_path.with_suffix(".tmp")
    temp_path.write_text(json.dumps(payload, indent=2, sort_keys=True))
    temp_path.replace(app_recovery_state_path)

def process_is_alive(pid: int) -> bool:
    return subprocess.run(["/bin/kill", "-0", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def process_command(pid: int) -> str:
    completed = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    return completed.stdout.strip() if completed.returncode == 0 else ""

def profile_app_owner() -> dict:
    completed = subprocess.run(
        [str(spaces_cli), "profile", "app-owner", "--json"],
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
        check=True,
    )
    return json.loads(completed.stdout)

def wait_for_app_owner_present(timeout: float = 15) -> dict:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        payload = profile_app_owner()
        last_payload = payload
        owner = payload.get("owner")
        if owner:
            return owner
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for app-owner lease to appear.\nlast={json.dumps(last_payload, indent=2)}")

def wait_for_app_owner_absent(timeout: float = 10) -> None:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        payload = profile_app_owner()
        last_payload = payload
        if payload.get("available") is True and payload.get("owner") is None:
            return
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for app-owner lease to disappear.\nlast={json.dumps(last_payload, indent=2)}")

def send_mobile_request(request: dict) -> dict:
    completed = subprocess.run(
        [
            str(spaces_cli),
            "mobile",
            "request",
            "--host",
            bridge_host,
            "--port",
            str(bridge_port),
            "--transport-key",
            pairing["transportKey"],
            "--request-json",
            json.dumps({"authToken": pairing["authToken"], "clientApp": client_app, **request}),
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
        check=True,
    )
    return json.loads(completed.stdout)

def session_runtime_state() -> tuple[str, int, int | None]:
    with sqlite3.connect(db_path) as db:
        row = db.execute(
            "SELECT state, service_pid, child_pid FROM terminal_runtime_states WHERE session_id = ?",
            (session_id,),
        ).fetchone()
    require(row is not None, f"Missing runtime state for session {session_id}.")
    return row[0], int(row[1]), int(row[2]) if row[2] is not None else None

def assert_session_live(expected_service_pid: int, label: str) -> None:
    state, service_pid, child_pid = session_runtime_state()
    require(state == "running", f"{label}: session state is not running: {state!r}")
    require(service_pid == expected_service_pid, f"{label}: service pid changed from {expected_service_pid} to {service_pid}.")
    require(process_is_alive(service_pid), f"{label}: spacesd pid {service_pid} is not alive.")
    require(child_pid is not None and process_is_alive(child_pid), f"{label}: session child pid is not alive: {child_pid!r}")

def terminate_app_owner(owner: dict) -> None:
    pid = int(owner["pid"])
    executable = owner.get("executablePath") or ""
    command = process_command(pid)
    require(Path(executable).name == "SpacesApp", f"Refusing to kill app owner with unexpected executable: {executable!r}")
    require("SpacesApp" in command, f"Refusing to kill pid {pid}; command does not look like SpacesApp: {command!r}")
    log(f"Terminating current-profile SpacesApp owner pid={pid} command={command!r}")
    subprocess.run(["/bin/kill", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 5
    while time.time() < deadline:
        if not process_is_alive(pid):
            return
        time.sleep(0.2)
    subprocess.run(["/bin/kill", "-9", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 3
    while time.time() < deadline:
        if not process_is_alive(pid):
            return
        time.sleep(0.1)
    log(f"SpacesApp owner pid {pid} still appears in the process table after SIGKILL; waiting on lease removal.")

expected_service_pid = int(metadata_terminal_service_pid) if metadata_terminal_service_pid else session_runtime_state()[1]
assert_session_live(expected_service_pid, "before app recovery")

old_owner = wait_for_app_owner_present(timeout=15)
old_pid = int(old_owner["pid"])
write_app_recovery_state({
    "status": "recovering",
    "sessionID": session_id,
    "oldAppPID": old_pid,
    "terminalServicePID": expected_service_pid,
})
terminate_app_owner(old_owner)
wait_for_app_owner_absent(timeout=10)
assert_session_live(expected_service_pid, "after app owner termination")

overview_before = send_mobile_request({"command": "overview"})
require(overview_before.get("ok"), f"Overview failed after app owner termination: {overview_before}")
require(
    any(session.get("id") == session_id and int(session.get("servicePID", -1)) == expected_service_pid for session in overview_before.get("overview", {}).get("sessions", [])),
    f"Overview after app owner termination did not include the live session: {json.dumps(overview_before, indent=2)}",
)

launch_response = send_mobile_request({"command": "launchSpacesApp"})
require(launch_response.get("ok"), f"launchSpacesApp failed: {launch_response}")
require(launch_response.get("message") == "Launched Spaces on Mac.", f"Unexpected launch response: {launch_response}")

new_owner = wait_for_app_owner_present(timeout=20)
new_pid = int(new_owner["pid"])
require(new_pid != old_pid, f"launchSpacesApp reused the old app pid {old_pid}.")
new_command = process_command(new_pid)
require("SpacesApp" in new_command, f"Relaunched owner pid {new_pid} is not SpacesApp: {new_command!r}")
write_app_recovery_state({
    "status": "recovered",
    "sessionID": session_id,
    "oldAppPID": old_pid,
    "newAppPID": new_pid,
    "terminalServicePID": expected_service_pid,
})
assert_session_live(expected_service_pid, "after app recovery")

overview_after = send_mobile_request({"command": "overview"})
require(overview_after.get("ok"), f"Overview failed after app recovery: {overview_after}")
require(
    any(session.get("id") == session_id and int(session.get("servicePID", -1)) == expected_service_pid for session in overview_after.get("overview", {}).get("sessions", [])),
    f"Overview after app recovery did not include the live session: {json.dumps(overview_after, indent=2)}",
)

(scenario_dir / "app-recovery-result.json").write_text(json.dumps({
    "sessionID": session_id,
    "oldAppPID": old_pid,
    "newAppPID": new_pid,
    "terminalServicePID": expected_service_pid,
    "launchResponse": launch_response,
}, indent=2, sort_keys=True))
log(
    "App recovery result: "
    + " ".join(
        [
            f"session={shlex.quote(session_id)}",
            f"old_app_pid={old_pid}",
            f"new_app_pid={new_pid}",
            f"terminal_service_pid={expected_service_pid}",
        ]
    )
)
print(new_pid)
PY
  )"; then
    fail "App recovery assertions failed."
  fi
  [[ "$new_app_pid" =~ ^[0-9]+$ ]] || fail "App recovery did not return a numeric app pid: $new_app_pid"
  DEMO_APP_PID="$new_app_pid"
  printf 'Mobile scenario passed: app-recovery\n'
}

run_selected_scenarios() {
  local scenario
  for scenario in "${SELECTED_SCENARIOS[@]}"; do
    case "$scenario" in
      codex|codex-resume-reopen)
        run_codex_scenario "$scenario"
        ;;
      roundtrip)
        run_roundtrip_scenario
        ;;
      scrollback)
        run_scrollback_scenario
        ;;
      terminal-link-preview)
        run_terminal_link_preview_scenario
        ;;
      two-session)
        run_two_session_scenario
        ;;
      ctrl-c-final-frame)
        run_ctrl_c_final_frame_scenario
        ;;
      ctrl-c-final-frame-codex-survivor)
        run_ctrl_c_final_frame_scenario "$scenario"
        ;;
      ownership-guard)
        run_ownership_guard_scenario
        ;;
      app-recovery)
        run_app_recovery_scenario
        ;;
      *)
        fail "unknown scenario: $scenario"
        ;;
    esac
    cleanup_current_scenario_sessions
  done
}

parse_args "$@"
case "$MOBILE_DEVICE_KEY" in
  iphone|ipad)
    ;;
  *)
    fail "SPACES_MOBILE_E2E_DEVICE_KEY must be iphone or ipad, got: $MOBILE_DEVICE_KEY"
    ;;
esac
SUITE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-mobile-e2e.XXXXXX")"
MOBILE_UDID="$(resolve_simulator_udid "$MOBILE_DEVICE_NAME")"
build_macos_debug_products
build_ios_for_testing "$MOBILE_UDID"
start_demo
case "$MOBILE_DEVICE_KEY" in
  iphone) MOBILE_UDID="$IPHONE_UDID" ;;
  ipad) MOBILE_UDID="$IPAD_UDID" ;;
esac
run_selected_scenarios

printf '\nMobile E2E passed: %s\n' "${SELECTED_SCENARIOS[*]}"
