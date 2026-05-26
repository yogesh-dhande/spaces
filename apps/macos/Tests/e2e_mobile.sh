#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

DEMO_SCRIPT="$ROOT_DIR/apps/macos/Tests/run_mobile_terminal_demo.sh"
SPACES_CLI_BIN="${SPACES_CLI:-$ROOT_DIR/apps/macos/.build/debug/spaces}"
SPACES_E2E_BIN="${SPACES_E2E:-$ROOT_DIR/apps/macos/.build/debug/spacese2e}"
TERMINAL_SERVICE_BIN="${SPACES_TERMINAL_SERVICE_EXECUTABLE:-$ROOT_DIR/apps/macos/.build/debug/SpacesTerminalService}"
DEFAULT_UI_TEST_CONFIG="/tmp/spaces-mobile-ui-test-config.json"
BUNDLE_ID="com.yogeshdhande.spacesmobile"
IPAD_NAME="${SPACES_MOBILE_DEMO_IPAD_NAME:-iPad Pro 13-inch (M5)}"
CODEX_RESUME_THREAD_ID="${SPACES_MOBILE_CODEX_RESUME_THREAD_ID:-019e380a-9def-7852-9834-74c67b2da894}"
FIXTURE_LINE_COUNT=520
SCROLLBACK_SWIPE_COUNT=2

SCENARIOS=(codex codex-resume-reopen roundtrip scrollback two-session ownership-guard)
SELECTED_SCENARIOS=()
REQUESTED_KEEP_ROOT="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
DEMO_PORT="${SPACES_MOBILE_DEMO_PORT:-}"

SUITE_ROOT=""
IOS_DERIVED_DATA=""
IOS_APP_PATH=""
IOS_BUILD_LOG=""
DEMO_STDOUT_LOG=""
DEMO_PID=""
DEMO_ROOT=""
PROJECT_DIR=""
DB_PATH=""
RUNTIME_DIR=""
BRIDGE_HOST=""
BRIDGE_PORT=""
IPAD_UDID=""
PERFORMANCE_LOG_PATH=""
CURRENT_SCENARIO=""
SCENARIO_DIR=""
SCENARIO_LOG=""
UI_TEST_CONFIG=""
UI_TEST_LOG=""
PRESERVE_ROOT=0

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
  two-session
  ownership-guard
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
    SPACES_DB_PATH="$DB_PATH" \
    SPACES_RUNTIME_DIR="$RUNTIME_DIR" \
    SPACES_TERMINAL_SERVICE_EXECUTABLE="$TERMINAL_SERVICE_BIN" \
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
    tail_if_present "iPad app stderr tail" "$DEMO_ROOT/ipad-app.stderr.log" 160
  fi
  exit 1
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
            "RUNTIME_DIR": str(pathlib.Path(payload["root"]) / "runtime"),
            "BRIDGE_HOST": payload["bridgeHost"],
            "BRIDGE_PORT": str(payload["bridgePort"]),
            "IPAD_UDID": payload["ipadSimulatorUDID"],
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
  printf 'Launching shared mobile demo on port %s...\n' "$DEMO_PORT"
  SPACES_MOBILE_DEMO_KEEP_ROOT=1 \
    SPACES_MOBILE_DEMO_BUILD_MACOS=0 \
    SPACES_MOBILE_DEMO_APP_PATH="$IOS_APP_PATH" \
    SPACES_MOBILE_DEMO_PORT="$DEMO_PORT" \
    "$DEMO_SCRIPT" >"$DEMO_STDOUT_LOG" 2>&1 &
  DEMO_PID=$!
  wait_for_demo_metadata
  printf 'Shared demo root: %s\n' "$DEMO_ROOT"
}

begin_scenario() {
  CURRENT_SCENARIO="$1"
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
  python3 - "$RUNTIME_DIR" "$session_id" <<'PY'
import json
import pathlib
import sys
import time

runtime_dir = pathlib.Path(sys.argv[1])
session_id = sys.argv[2]
attachments_path = runtime_dir / "terminal" / "sessions" / session_id / "attachments.json"
deadline = time.time() + 30
last_snapshot = ""
while time.time() < deadline:
    if attachments_path.exists():
        try:
            payload = json.loads(attachments_path.read_text())
        except json.JSONDecodeError:
            time.sleep(0.1)
            continue
        last_snapshot = json.dumps(payload, indent=2, sort_keys=True)
        for attachment in payload:
            if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None and attachment.get("clientID"):
                raise SystemExit(0)
    time.sleep(0.1)
raise SystemExit(f"Timed out waiting for active owner attachment for {session_id}.\n{last_snapshot}")
PY
}

new_terminal_session() {
  local before_file="$SCENARIO_DIR/session-ids-before-$(date +%s%N).txt"
  local open_log="$SCENARIO_DIR/open-terminal.log"
  local session_id
  discover_session_ids >"$before_file"
  if ! demo_env "$SPACES_E2E_BIN" open-workspace-terminal --workspace-dir "$PROJECT_DIR" >"$open_log" 2>&1; then
    cat "$open_log" >>"$SCENARIO_LOG" || true
    fail "Failed to open a fresh workspace terminal for $CURRENT_SCENARIO."
  fi
  cat "$open_log" >>"$SCENARIO_LOG" || true
  session_id="$(python3 - "$RUNTIME_DIR" "$before_file" <<'PY'
import pathlib
import sys
import time

runtime_dir = pathlib.Path(sys.argv[1])
before_path = pathlib.Path(sys.argv[2])
before = {line.strip() for line in before_path.read_text().splitlines() if line.strip()}
sessions_root = runtime_dir / "terminal" / "sessions"
deadline = time.time() + 30
last_ids = []
while time.time() < deadline:
    if sessions_root.exists():
        ids = sorted(path.name for path in sessions_root.iterdir() if path.is_dir())
        last_ids = ids
        created = [session_id for session_id in ids if session_id not in before]
        if created:
            print(created[-1])
            raise SystemExit(0)
    time.sleep(0.25)
raise SystemExit(f"Timed out waiting for a new terminal session. Existing={sorted(before)} current={last_ids}")
PY
  )"
  wait_for_session_owner "$session_id" || fail "Fresh terminal session did not become owner-ready: $session_id"
  printf '%s\n' "$session_id"
}

reset_ipad_app() {
  xcrun simctl terminate "$IPAD_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  env \
    SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_TRACE=1 \
    SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$PERFORMANCE_LOG_PATH" \
    xcrun simctl launch "$IPAD_UDID" "$BUNDLE_ID" >>"$SCENARIO_LOG" 2>&1 || fail "Failed to launch SpacesMobile on the iPad simulator."
  sleep 2
}

write_ui_test_config() {
  local scenario="$1"
  local session_id="$2"
  local secondary_session_id="${3:-}"
  python3 - "$DEMO_ROOT" "$scenario" "$session_id" "$secondary_session_id" "$BRIDGE_HOST" "$BRIDGE_PORT" "$IPAD_UDID" "$UI_TEST_CONFIG" "$DEFAULT_UI_TEST_CONFIG" "$BUNDLE_ID" "$SCROLLBACK_SWIPE_COUNT" <<'PY'
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
    ipad_udid,
    scenario_config_raw,
    default_config_raw,
    bundle_id,
    scrollback_swipe_count_raw,
) = sys.argv[1:]

demo_root = Path(demo_root_raw)
bridge_port = int(bridge_port_raw)
scrollback_swipe_count = int(scrollback_swipe_count_raw)
config_paths = [Path(scenario_config_raw), Path(default_config_raw)]
pairing = json.loads((demo_root / "pairing.json").read_text())
ipad_pairing = pairing["ipad"]
prefix = scenario

payload = {
    "sessionID": session_id,
    "secondarySessionID": None,
    "host": bridge_host,
    "port": bridge_port,
    "authToken": ipad_pairing["authToken"],
    "transportKey": ipad_pairing["transportKey"],
    "installationID": ipad_pairing["installationID"],
    "renderDumpPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-render.json"),
    "eventLogPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-events.jsonl"),
    "immediateScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-takeover-immediate.png"),
    "shortDelayScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-takeover-plus-2s.png"),
    "longDelayScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-takeover-plus-6s.png"),
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
    "postFirstCommandScreenshotPath": None,
    "postSecondCommandScreenshotPath": None,
    "finalMacRetakeoverRequestPath": None,
    "finalMacRetakeoverObservedPath": None,
    "postFinalMacRetakeoverScreenshotPath": None,
    "finalScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-final.png"),
    "scrollbackSwipeCount": 0,
    "attachToExistingApp": True,
    "bundleID": bundle_id,
    "ipadUDID": ipad_udid,
}

if scenario == "codex-resume-reopen":
    payload["secondarySessionID"] = session_id
elif scenario == "roundtrip":
    payload.update({
        "proceedTakeOverPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-proceed-takeover"),
        "firstCommandRequestPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-first-command-request"),
        "firstCommandFocusedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-first-command-focused"),
        "firstCommandCompletedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-first-command-completed"),
        "firstCommandObservedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-first-command-observed"),
        "secondCommandRequestPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-second-command-request"),
        "secondCommandFocusedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-second-command-focused"),
        "secondCommandCompletedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-second-command-completed"),
        "secondCommandObservedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-second-command-observed"),
        "proceedFinishPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-proceed-finish"),
        "firstCommandText": "echo __roundtrip_ipad_one__",
        "secondCommandText": "echo __roundtrip_ipad_two__",
        "manualRetakeoverAttempts": 2,
        "manualRetakeoverObservedPrefix": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-manual-retakeover-observed"),
        "postFirstCommandScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-first-command.png"),
        "postSecondCommandScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-second-command.png"),
        "finalMacRetakeoverRequestPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-final-mac-retakeover-request"),
        "finalMacRetakeoverObservedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-final-mac-retakeover-observed"),
        "postFinalMacRetakeoverScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-final-mac-retakeover.png"),
    })
elif scenario == "scrollback":
    payload.update({
        "firstCommandRequestPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-first-command-request"),
        "firstCommandFocusedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-first-command-focused"),
        "firstCommandCompletedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-first-command-completed"),
        "firstCommandObservedPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-first-command-observed"),
        "postFirstCommandScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-command-while-scrolled.png"),
        "scrollbackSwipeCount": scrollback_swipe_count,
    })
elif scenario == "two-session":
    payload.update({
        "secondarySessionID": secondary_session_id,
        "immediateScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-first-takeover.png"),
        "shortDelayScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-first-takeover-plus-2s.png"),
        "longDelayScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-first-takeover-plus-6s.png"),
        "finalScreenshotPath": str(demo_root / "mobile-e2e" / scenario / f"{prefix}-ipad-post-second-takeover.png"),
        "firstCommandText": "pwd",
    })

encoded = json.dumps(payload, indent=2, sort_keys=True)
for config_path in config_paths:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(encoded)
PY
}

run_ui_test() {
  local test_name="$1"
  printf 'Running iPad UI test: %s\n' "$test_name"
  reset_ipad_app
  if ! SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
    xcodebuild \
      -project "$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj" \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$IPAD_UDID" \
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
attachments_path = runtime_root / "terminal" / "sessions" / session_id / "attachments.json"
owner_dump_path = scenario_dir / "codex-mac-owner-dump.json"

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
    {"command": "send", "text": command_text, "clientID": owner_client_id},
    {"command": "key", "key": "enter", "clientID": owner_client_id},
):
    response = send_request(request)
    if not response.get("ok"):
        raise RuntimeError(f"Codex launch request failed: {response}")

trust_prompt_confirmed = False
resume_directory_prompt_confirmed = False
deadline = time.time() + 30
while time.time() < deadline:
    rendered_output = (dump_owner_window().get("renderedOutput") or "")
    if "Choose working directory to resume this session" in rendered_output:
        if resume_directory_prompt_confirmed:
            time.sleep(0.2)
            continue
        response = send_request({"command": "key", "key": "enter", "clientID": owner_client_id})
        if not response.get("ok"):
            raise RuntimeError(f"Failed to confirm the Codex resume directory prompt: {response}")
        resume_directory_prompt_confirmed = True
        time.sleep(0.2)
        continue
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
    normalized_output = rendered_output.lower()
    if (
        "openai codex" in normalized_output
        or "gpt-" in normalized_output
        or "/review on my current changes" in normalized_output
        or "/model to change" in normalized_output
        or "/mcp to list configured mcp tools" in normalized_output
    ):
        raise SystemExit(0)
    time.sleep(0.2)

raise RuntimeError(f"Timed out waiting for Codex startup output in the demo session for {command_text!r}.")
PY
}

assert_ipad_terminal_text_rendered() {
  local screenshot_path="$SCENARIO_DIR/$CURRENT_SCENARIO-ipad-post-takeover-plus-2s.png"
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
    fail "Codex takeover rendered a blank or unreadable iPad terminal surface."
  fi
}

assert_codex_takeover_metrics() {
  local session_id="$1"
  local takeover_started_at="$2"
  local reopen_same_session="$3"
  python3 - "$SCENARIO_DIR" "$CURRENT_SCENARIO" "$DEMO_ROOT" "$session_id" "$takeover_started_at" "$reopen_same_session" <<'PY'
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
render_dump_path = scenario_dir / f"{scenario}-ipad-render.json"
event_log_path = scenario_dir / f"{scenario}-ipad-events.jsonl"
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
if render_dump.get("errorMessage"):
    raise SystemExit(f"Unexpected iPad error after takeover: {render_dump.get('errorMessage')!r}")
if not render_dump.get("isInputSurfaceReady"):
    raise SystemExit("The iPad owner path never reached input-ready state.")
if not any(event.get("kind") == "input_readiness" and event.get("detail") == "ready" for event in event_payloads):
    raise SystemExit("The iPad event log never recorded input readiness.")
rendered_terminal_text = "\n".join(
    str(render_dump.get(key) or "")
    for key in ("renderedText", "snapshotText", "visibleText")
).lower()
if "codex resume" in rendered_terminal_text and not any(
    marker in rendered_terminal_text
    for marker in ("openai codex", "gpt-", "/model to change", "/mcp to list configured mcp tools", "conversation interrupted", "›")
):
    raise SystemExit("The iPad owner bootstrap appears to be the stale pre-takeover shell prompt.")

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

if reopen_same_session:
    expected_local_bootstraps = 4
    if len(local_bootstraps) != expected_local_bootstraps:
        raise SystemExit(
            f"Expected {expected_local_bootstraps} local owner bootstraps across reopen cycles, "
            f"found {len(local_bootstraps)}"
        )
    if len(first_nonblank) != expected_local_bootstraps:
        raise SystemExit(
            f"Expected {expected_local_bootstraps} first non-blank render events across reopen cycles, "
            f"found {len(first_nonblank)}"
        )
    if len(first_input_ready) != expected_local_bootstraps:
        raise SystemExit(
            f"Expected {expected_local_bootstraps} first input-ready events across reopen cycles, "
            f"found {len(first_input_ready)}"
        )
    if len(bootstrap_receipts) < expected_local_bootstraps:
        raise SystemExit(
            f"Expected at least {expected_local_bootstraps} owner bootstrap receipts across reopen cycles, "
            f"found {len(bootstrap_receipts)}"
        )
    if not initial_snapshot_exports:
        raise SystemExit("Expected at least one initial snapshot export across reopen cycles.")
else:
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

run_codex_scenario() {
  local scenario="$1"
  begin_scenario "$scenario"
  local session_id
  session_id="$(new_terminal_session)"
  local command_text
  local reopen_same_session=0
  local ui_test_name="SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList"
  if [[ "$scenario" == "codex-resume-reopen" ]]; then
    command_text="codex resume $CODEX_RESUME_THREAD_ID"
    reopen_same_session=1
    ui_test_name="SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverReopenSameSessionFromList"
  else
    command_text="${SPACES_MOBILE_CODEX_COMMAND:-codex}"
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
  assert_ipad_terminal_text_rendered
  assert_codex_takeover_metrics "$session_id" "$takeover_started_at" "$reopen_same_session"
  printf 'Mobile scenario passed: %s\n' "$scenario"
}

run_roundtrip_scenario() {
  begin_scenario "roundtrip"
  local session_id
  session_id="$(new_terminal_session)"
  write_ui_test_config "roundtrip" "$session_id"
  reset_ipad_app
  python3 - "$ROOT_DIR" "$DEMO_ROOT" "$session_id" "$BRIDGE_HOST" "$BRIDGE_PORT" "$IPAD_UDID" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$UI_TEST_CONFIG" "$UI_TEST_LOG" "$IOS_DERIVED_DATA" "$SCENARIO_DIR" <<'PY'
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

repo_root = Path(sys.argv[1])
demo_root = Path(sys.argv[2])
session_id = sys.argv[3]
bridge_host = sys.argv[4]
bridge_port = int(sys.argv[5])
ipad_udid = sys.argv[6]
spaces_cli = Path(sys.argv[7])
spacese2e = Path(sys.argv[8])
ui_test_config = Path(sys.argv[9])
ui_test_log = Path(sys.argv[10])
ios_derived_data = Path(sys.argv[11])
scenario_dir = Path(sys.argv[12])
runtime_root = demo_root / "runtime"
attachments_path = runtime_root / "terminal" / "sessions" / session_id / "attachments.json"
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
ios_first_output = "__roundtrip_ipad_one__"
ios_second_command = config["secondCommandText"]
ios_second_output = "__roundtrip_ipad_two__"
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
    payload = json.loads(attachments_path.read_text())
    for attachment in payload:
        if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None:
            client_id = attachment.get("clientID")
            if client_id and client_id not in excluded_client_ids:
                return client_id
    raise RuntimeError(f"No active owner attachment was found.\n{json.dumps(payload, indent=2)}")

def wait_for_active_owner(excluded_client_ids: set[str] | None = None, timeout: float = 20) -> str:
    deadline = time.time() + timeout
    last_snapshot = ""
    while time.time() < deadline:
        if attachments_path.exists():
            payload = json.loads(attachments_path.read_text())
            last_snapshot = json.dumps(payload, indent=2, sort_keys=True)
            for attachment in payload:
                if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None:
                    client_id = attachment.get("clientID")
                    if client_id and client_id not in (excluded_client_ids or set()):
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
    for request in (
        {"command": "send", "text": command_text, "clientID": owner_client_id},
        {"command": "key", "key": "enter", "clientID": owner_client_id},
    ):
        response = send_unix_control_request(request)
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
    return f"% {command_text}" in text and f"\n{output_text}\n" in text

def assert_render_output_sane(label: str, text: str) -> None:
    if "command not found: s" in text:
        raise RuntimeError(f"{label} render contains split input failure:\n{text}")
    if re.search(r"(?m)^%$", text):
        raise RuntimeError(f"{label} render contains stray percent line:\n{text}")
    for line in text.splitlines():
        if line.count("%") > 1:
            raise RuntimeError(f"{label} render contains duplicated prompt on one line:\n{text}")
        if line.strip() in bare_command_lines:
            raise RuntimeError(f"{label} render contains a bare replay command line:\n{text}")
    if text.count("Last login:") > 1:
        raise RuntimeError(f"{label} render contains repeated login banner:\n{text}")
    if "\x1b" in text or "^[" in text:
        raise RuntimeError(f"{label} render contains raw escape remnants:\n{text}")

def write_command_request(command_text: str, send_enter: bool = True) -> None:
    payload = {
        "id": f"{int(time.time() * 1000)}-{os.getpid()}",
        "text": command_text,
        "sendEnter": send_enter,
    }
    command_request_path.parent.mkdir(parents=True, exist_ok=True)
    command_request_path.write_text(json.dumps(payload, sort_keys=True))

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
        raise RuntimeError("Mac retakeover did not transfer ownership away from iPad.")
    return reclaimed_owner

ui_test_command = [
    "xcodebuild",
    "-project",
    "apps/ios/SpacesMobile.xcodeproj",
    "-scheme",
    "SpacesMobile",
    "-destination",
    f"platform=iOS Simulator,id={ipad_udid}",
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
                payload.get("found") is True
                and payload.get("showsTerminalSurface") is True
                and "__roundtrip_mac_before_takeover_one__" in (payload.get("renderedOutput") or "")
                and "__roundtrip_mac_before_takeover_two__" in (payload.get("renderedOutput") or "")
            ),
            timeout=45,
            any_mode=False,
        )
        expected_render_text = mac_owner_payload.get("renderedOutput") or ""
        if not expected_render_text:
            raise RuntimeError(f"Unable to derive canonical Mac owner render text:\n{json.dumps(mac_owner_payload, indent=2)}")
        assert_render_output_sane("Mac owner before takeover", expected_render_text)

        write_marker(proceed_takeover_path, "go\n")

        ipad_owner_payload = wait_for_render_dump(
            lambda payload: (
                payload.get("sessionID") == session_id
                and payload.get("isOwner") is True
                and payload.get("isBusy") is False
                and payload.get("isPreparingInput") is False
                and payload.get("isSynchronizingOwnership") is False
                and payload.get("isInputSurfaceReady") is True
                and "__roundtrip_mac_before_takeover_one__" in (payload.get("snapshotText") or payload.get("renderedText") or "")
                and "__roundtrip_mac_before_takeover_two__" in (payload.get("snapshotText") or payload.get("renderedText") or "")
            ),
            timeout=40,
            process=ui_test_process,
        )
        if ipad_owner_payload.get("errorMessage"):
            raise RuntimeError(f"iPad reported an error after first takeover:\n{json.dumps(ipad_owner_payload, indent=2)}")
        ipad_owner_text = ipad_owner_payload.get("snapshotText") or ipad_owner_payload.get("renderedText") or ""
        if "__roundtrip_mac_before_takeover_one__" not in ipad_owner_text or "__roundtrip_mac_before_takeover_two__" not in ipad_owner_text:
            raise RuntimeError(
                "iPad owner render did not include the Mac pre-takeover transcript markers:\n"
                f"{json.dumps(ipad_owner_payload, indent=2)}"
            )

        write_marker(first_command_request, "go\n")
        wait_for_file(first_command_focused, timeout=30, process=ui_test_process)
        write_command_request(ios_first_command)
        wait_for_output_log_text(ios_first_output, timeout=20, process=ui_test_process)
        write_marker(first_command_completed)
        wait_for_file(first_command_observed, timeout=20, process=ui_test_process)

        write_marker(second_command_request, "go\n")
        wait_for_file(second_command_focused, timeout=30, process=ui_test_process)
        write_command_request(ios_second_command)
        wait_for_output_log_text(ios_second_output, timeout=20, process=ui_test_process)
        write_marker(second_command_completed)
        wait_for_file(second_command_observed, timeout=20, process=ui_test_process)

        ipad_owner_client_id = wait_for_active_owner(timeout=10)
        request_mac_retakeover(ipad_owner_client_id)
        ipad_after_mac_retakeover = wait_for_render_dump(
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
        if ipad_after_mac_retakeover.get("errorMessage"):
            raise RuntimeError(f"iPad reported an error after Mac retakeover:\n{json.dumps(ipad_after_mac_retakeover, indent=2)}")

        mac_owner_after_retakeover = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                payload.get("found") is True
                and payload.get("showsTerminalSurface") is True
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
            ipad_after_manual_takeover = wait_for_render_dump(
                lambda payload: (
                    payload.get("sessionID") == session_id
                    and payload.get("isOwner") is True
                    and payload.get("isBusy") is False
                    and payload.get("isSynchronizingOwnership") is False
                    and payload.get("isInputSurfaceReady") is True
                    and (payload.get("renderedText") or payload.get("snapshotText") or "").strip()
                ),
                timeout=20,
                process=ui_test_process,
            )
            if ipad_after_manual_takeover.get("errorMessage"):
                raise RuntimeError(
                    f"iPad reported an error after takeover {takeover_number}:\n{json.dumps(ipad_after_manual_takeover, indent=2)}"
                )

            mac_status_payload = wait_for_terminal_window_dump(
                mac_status_dump_path,
                lambda payload: payload.get("found") is True and payload.get("showsTerminalSurface") is False,
                timeout=20,
                any_mode=True,
            )
            assert_status_shell_hides_live_content(f"Mac status after iPad takeover {takeover_number}", mac_status_payload)

            if attempt_index >= 1:
                continue

            current_ipad_owner = wait_for_active_owner(timeout=10)
            request_mac_retakeover(current_ipad_owner)
            ipad_after_mac_retakeover = wait_for_render_dump(
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
            if ipad_after_mac_retakeover.get("errorMessage"):
                raise RuntimeError(
                    f"iPad reported an error after Mac retakeover {takeover_number}:\n{json.dumps(ipad_after_mac_retakeover, indent=2)}"
                )
            mac_owner_after_retakeover = wait_for_terminal_window_dump(
                mac_owner_dump_path,
                lambda payload: (
                    payload.get("found") is True
                    and payload.get("showsTerminalSurface") is True
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

        final_ipad_owner = wait_for_active_owner(timeout=10)
        request_mac_retakeover(final_ipad_owner)
        ipad_after_final_mac_retakeover = wait_for_render_dump(
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
        if ipad_after_final_mac_retakeover.get("errorMessage"):
            raise RuntimeError(
                f"iPad reported an error after the final Mac retakeover:\n{json.dumps(ipad_after_final_mac_retakeover, indent=2)}"
            )
        mac_owner_after_final_retakeover = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                payload.get("found") is True
                and payload.get("showsTerminalSurface") is True
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
            raise RuntimeError(f"Expected final iPad render dump at {render_dump_path}")
        if not event_log_path.exists():
            raise RuntimeError(f"Expected iPad event log at {event_log_path}")
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
attachments_path = runtime_root / "terminal" / "sessions" / session_id / "attachments.json"
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

raise RuntimeError("Timed out waiting for the scrollback fixture to complete.")
PY
}

run_scrollback_scenario() {
  begin_scenario "scrollback"
  local session_id
  session_id="$(new_terminal_session)"
  launch_scrollback_fixture_on_mac_owner "$session_id" >>"$SCENARIO_LOG" 2>&1 || fail "Failed to launch scrollback fixture."
  write_ui_test_config "scrollback" "$session_id"
  reset_ipad_app
  SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
    xcodebuild \
      -project "$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj" \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$IPAD_UDID" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      -only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList \
      test-without-building >"$UI_TEST_LOG" 2>&1 &
  local ui_test_pid=$!

  if ! python3 - "$DEMO_ROOT" "$SCENARIO_DIR" <<'PY'
import json
import sys
import time
from pathlib import Path

demo_root = Path(sys.argv[1])
scenario_dir = Path(sys.argv[2])
event_log_path = scenario_dir / "scrollback-ipad-events.jsonl"
performance_log_path = demo_root / "mobile-terminal-performance.jsonl"
command_request_path = Path(f"{event_log_path}.command-request.json")
first_command_request_path = scenario_dir / "scrollback-ipad-first-command-request"
first_command_completed_path = scenario_dir / "scrollback-ipad-first-command-completed"
first_command_observed_path = scenario_dir / "scrollback-ipad-first-command-observed"
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
    fail "Scrollback command orchestration failed."
  fi

  if ! wait "$ui_test_pid"; then
    fail "Scrollback UI test failed."
  fi

  python3 - "$SCENARIO_DIR" "$DEMO_ROOT" "$FIXTURE_LINE_COUNT" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

scenario_dir = Path(sys.argv[1])
demo_root = Path(sys.argv[2])
fixture_line_count = int(sys.argv[3])
owner_dump_path = scenario_dir / "scrollback-owner-dump.json"
ipad_dump_path = scenario_dir / "scrollback-ipad-render.json"
event_log_path = scenario_dir / "scrollback-ipad-events.jsonl"
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
    raise SystemExit("The iPad app never applied the scrollback drag gesture.")
if not any(event.get("kind") == "e2e_command_request_consumed" for event in event_payloads):
    raise SystemExit("The iPad app never consumed the post-scrollback owner command.")
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

  printf 'Mobile scenario passed: scrollback\n'
}

run_two_session_scenario() {
  begin_scenario "two-session"
  local session_id
  local secondary_session_id
  session_id="$(new_terminal_session)"
  secondary_session_id="$(new_terminal_session)"
  write_ui_test_config "two-session" "$session_id" "$secondary_session_id"
  run_ui_test "SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverAcrossTwoSessionsFromList"
  printf 'Mobile scenario passed: two-session\n'
}

run_ownership_guard_scenario() {
  begin_scenario "ownership-guard"
  local session_id
  session_id="$(new_terminal_session)"
  python3 - "$DEMO_ROOT" "$session_id" "$BRIDGE_HOST" "$BRIDGE_PORT" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$SCENARIO_DIR" "$BUNDLE_ID" <<'PY'
import json
import os
import socket
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
runtime_root = demo_root / "runtime"
attachments_path = runtime_root / "terminal" / "sessions" / session_id / "attachments.json"
output_log_path = runtime_root / "terminal" / "sessions" / session_id / "output.log"
pairing = json.loads((demo_root / "pairing.json").read_text())["ipad"]

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}

client_app = {
    "installationID": pairing["installationID"],
    "bundleID": bundle_id,
    "platform": "ios",
    "deviceName": "iPad Pro 13-inch (M5)",
    "appVersion": "1.0",
}
mobile_client = {
    "id": str(uuid.uuid4()).upper(),
    "kind": "remoteViewer",
    "identity": {"label": "ownership-guard-ipad", "deviceName": "iPad", "networkAddress": "127.0.0.1"},
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
    while time.time() < deadline:
        if attachments_path.exists():
            payload = json.loads(attachments_path.read_text())
            last_snapshot = json.dumps(payload, indent=2, sort_keys=True)
            for attachment in payload:
                if attachment.get("mode") == "owner" and attachment.get("detachedAt") is None:
                    client_id = attachment.get("clientID")
                    if client_id and client_id not in excluded:
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
      two-session)
        run_two_session_scenario
        ;;
      ownership-guard)
        run_ownership_guard_scenario
        ;;
      *)
        fail "unknown scenario: $scenario"
        ;;
    esac
  done
}

parse_args "$@"
SUITE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-mobile-e2e.XXXXXX")"
IPAD_UDID="$(resolve_simulator_udid "$IPAD_NAME")"
build_macos_debug_products
build_ios_for_testing "$IPAD_UDID"
start_demo
run_selected_scenarios

printf '\nMobile E2E passed: %s\n' "${SELECTED_SCENARIOS[*]}"
