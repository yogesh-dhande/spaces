#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/spaces-e2e-env.sh"
spaces_e2e_load_env "$ROOT_DIR"

DEMO_SCRIPT="$ROOT_DIR/apps/macos/Tests/run_mobile_terminal_demo.sh"
REMOTE_DEVICE_E2E_SCRIPT="$ROOT_DIR/apps/macos/Tests/e2e_remote_device_api.sh"
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
# Where the demo puts its ephemeral profile roots; mirrors run_mobile_terminal_demo.sh's own default so
# cleanup can recognize a demo profile without the demo having reported which root it used.
DEMO_ROOT_PARENT="${SPACES_MOBILE_DEMO_ROOT_PARENT:-$USER_HOME/.spaces-dev/mobile-demo}"
SOURCE_CODEX_HOME="${SPACES_MOBILE_CODEX_HOME:-${CODEX_HOME:-$USER_HOME/.codex}}"
E2E_CODEX_HOME="$SOURCE_CODEX_HOME"
USER_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$USER_HOME/.config}"
E2E_GHOSTTY_XDG_CONFIG_HOME="${SPACES_MOBILE_GHOSTTY_XDG_CONFIG_HOME:-$USER_XDG_CONFIG_HOME}"
FIXTURE_LINE_COUNT=520
SCROLLBACK_SWIPE_COUNT=2
TERMINAL_LINK_PREVIEW_IMAGE_NAME="${SPACES_MOBILE_E2E_LINK_PREVIEW_IMAGE_NAME:-spaces-link-preview.png}"
TERMINAL_LINK_PREVIEW_PATH="${SPACES_MOBILE_E2E_LINK_PREVIEW_PATH:-/tmp/$TERMINAL_LINK_PREVIEW_IMAGE_NAME}"

SCENARIOS=(takeover codex codex-resume-reopen roundtrip scrollback mouse-reporting-scroll terminal-link-preview two-session ctrl-c-final-frame ctrl-c-final-frame-codex-survivor ownership-guard workspace-delete-scroll workspace-hide-scroll session-end-scroll)
REMOTE_UI_SCENARIOS=(takeover two-session)
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
DEMO_DEVICE_API_PID=""
DEMO_TERMINAL_SERVICE_PID=""
DEMO_ROOT=""
PROJECT_DIR=""
DEMO_PROJECT_DIR=""
LOCAL_PROJECT_DIR=""
LOCAL_SESSION_ID=""
DB_PATH=""
RUNTIME_DIR=""
DEVICE_API_HOST=""
DEVICE_API_PORT=""
DEMO_REMOTE_HOST=""
DEMO_REMOTE_PORT=""
DEMO_REMOTE_CERTIFICATE_FINGERPRINT=""
DEMO_REMOTE_PROJECT_DIR=""
DEMO_REMOTE_WORKSPACE_ID=""
DEMO_REMOTE_AUTH_TOKEN=""
DEMO_REMOTE_INSTALLATION_ID=""
TARGET_DEVICE_ID=""
TARGET_DEVICE_NAME=""
TARGET_DEVICE_API_HOST=""
TARGET_DEVICE_API_PORT=""
TARGET_DEVICE_AUTH_TOKEN=""
TARGET_DEVICE_CERTIFICATE_FINGERPRINT=""
TARGET_DEVICE_INSTALLATION_ID=""
TARGET_WORKSPACE_ID=""
IPAD_UDID=""
IPHONE_UDID=""
MOBILE_UDID=""
PERFORMANCE_LOG_PATH=""
CURRENT_SCENARIO=""
CURRENT_TARGET="local"
SCENARIO_DIR=""
SCENARIO_LOG=""
SCENARIO_RESULTS_LOG=""
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
  --port PORT            Use a specific daemon device API port.
  --help                 Show this help text.

Scenarios:
  takeover
  codex
  codex-resume-reopen
  roundtrip
  scrollback
  mouse-reporting-scroll
  terminal-link-preview
  two-session
  ctrl-c-final-frame
  ctrl-c-final-frame-codex-survivor
  ownership-guard
  workspace-delete-scroll
  workspace-hide-scroll
  session-end-scroll
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
  local -a env_args=(
    HOME="$DEMO_ROOT/home"
    CODEX_HOME="$E2E_CODEX_HOME"
    XDG_CONFIG_HOME="$E2E_GHOSTTY_XDG_CONFIG_HOME"
    SPACES_DB_PATH="$DB_PATH"
    SPACES_RUNTIME_DIR="$RUNTIME_DIR"
    SPACESD_EXECUTABLE="$TERMINAL_SERVICE_BIN"
    SPACESD_CREATE_TIMEOUT="$TERMINAL_CREATE_TIMEOUT"
    SPACES_DEVICE_API_HOST="${SPACES_MOBILE_DEMO_BIND_HOST:-0.0.0.0}"
    SPACES_DEVICE_API_PORT="$DEVICE_API_PORT"
  )
  run_demo_env "${env_args[@]}" "$@"
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

timestamp_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

record_scenario_result() {
  local status="$1"
  local target="$2"
  local scenario="$3"
  local duration_ms="$4"
  local detail="${5:-}"
  [[ -n "$SCENARIO_RESULTS_LOG" ]] || return 0
  mkdir -p "$(dirname "$SCENARIO_RESULTS_LOG")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$target" "$scenario" "$duration_ms" "${detail:-"-"}" >>"$SCENARIO_RESULTS_LOG"
}

capture_desktop_screenshot() {
  local path="$1"
  command -v screencapture >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$path")"
  screencapture -x "$path" >/dev/null 2>&1 || true
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  PRESERVE_ROOT=1
  if [[ -n "$DEMO_ROOT" && -d "$DEMO_ROOT" ]]; then
    local failure_screenshot="$DEMO_ROOT/failure-desktop.png"
    capture_desktop_screenshot "$failure_screenshot"
    [[ -f "$failure_screenshot" ]] && printf 'Failure desktop screenshot: %s\n' "$failure_screenshot" >&2
  fi
  tail_if_present "Scenario log tail" "$SCENARIO_LOG" 160
  tail_if_present "UI test output tail" "$UI_TEST_LOG" 160
  tail_if_present "Demo output tail" "$DEMO_STDOUT_LOG" 120
  tail_if_present "iOS build-for-testing output tail" "$IOS_BUILD_LOG" 120
  if [[ -n "$DEMO_ROOT" ]]; then
    tail_if_present "Mac app log tail" "$DEMO_ROOT/app.log" 160
    tail_if_present "Device API log tail" "$DEMO_ROOT/device-api.log" 160
    tail_if_present "$MOBILE_DEVICE_LABEL app stderr tail" "$DEMO_ROOT/$MOBILE_ARTIFACT_NAME-app.stderr.log" 160
  fi
  exit 1
}

device_api_connect_host() {
  case "$1" in
    "" | "0.0.0.0" | "::")
      printf '127.0.0.1'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
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

# Stops a demo SpacesApp that outlived its run while holding the desktop-global control lease.
#
# `DEMO_APP_PID` is parsed from the demo's metadata block, so a demo that dies before printing it — a
# failed bring-up — leaves cleanup with no pid to reap at all. An orphaned demo app keeps desktop-global
# control, and every later desktop-driving lane then fails out its full frontmost/window wait instead of
# naming the lease. The lease records its own holder, so read it and stop that process when it is a
# SpacesApp running on a demo profile root. Scoped to `DEMO_ROOT_PARENT` so a real profile's app — the
# installed one, or another worktree's — is never touched.
#
# The candidate must also be orphaned (reparented to launchd), which is what tells a leak apart from a
# live run: the demo launches SpacesApp as its own child, so an app whose demo shell is still alive
# belongs to a mobile lane that is still using it. Another worktree's mobile lane can be mid-run while
# this one fails waiting for the shared harness lock, and killing its app would break a passing run.
stop_leaked_demo_desktop_control_owner() {
  local owner_json leaked_pid parent_pid
  owner_json="$("$SPACES_E2E_BIN" profile-desktop-control-owner --json 2>/dev/null || true)"
  [[ -n "$owner_json" ]] || return 0
  leaked_pid="$(
    python3 - "$DEMO_ROOT_PARENT" "$owner_json" <<'PY' || true
import json
import sys

root_parent = sys.argv[1].rstrip("/") + "/"
try:
    payload = json.loads(sys.argv[2])
except ValueError:
    raise SystemExit(0)
owner = payload.get("owner") or {}
pid = owner.get("pid")
profile_root = owner.get("profileRoot") or ""
if isinstance(pid, int) and pid > 0 and profile_root.startswith(root_parent):
    print(pid)
PY
  )"
  [[ -n "$leaked_pid" ]] || return 0
  parent_pid="$(ps -o ppid= -p "$leaked_pid" 2>/dev/null | tr -d ' ')"
  if [[ "$parent_pid" != "1" ]]; then
    printf 'Leaving demo SpacesApp pid %s alone: its demo (ppid %s) is still running.\n' "$leaked_pid" "$parent_pid" >&2
    return 0
  fi
  printf 'Stopping demo SpacesApp still holding desktop control: pid %s\n' "$leaked_pid" >&2
  terminate_pid_if_command_matches "$leaked_pid" "leaked demo app" "SpacesApp"
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
  stop_leaked_demo_desktop_control_owner
  if [[ "$DEMO_DEVICE_API_PID" != "$DEMO_TERMINAL_SERVICE_PID" ]]; then
    terminate_pid_if_command_matches "$DEMO_DEVICE_API_PID" "demo Device API" "spacesd"
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
    if [[ "$REQUESTED_KEEP_ROOT" == "1" || "$PRESERVE_ROOT" == "1" || $exit_code -ne 0 ]]; then
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
  if [[ "${SPACES_E2E_SKIP_MACOS_BUILD:-0}" == "1" ]]; then
    return 0
  fi
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
        required_keys = ["localProjectDir", "localSessionID"]
        missing = [key for key in required_keys if not payload.get(key)]
        if missing:
            print(f"DEMO_METADATA_ERROR={shlex.quote('Mobile demo metadata is missing: ' + ', '.join(missing))}")
            raise SystemExit(0)
        fields = {
            "DEMO_ROOT": payload["root"],
            "PROJECT_DIR": payload["projectDir"],
            "LOCAL_PROJECT_DIR": payload["localProjectDir"],
            "LOCAL_SESSION_ID": payload["localSessionID"],
            "DB_PATH": payload["dbPath"],
            "RUNTIME_DIR": payload.get("runtimeDir") or str(pathlib.Path(payload["root"]) / "runtime"),
            "DEVICE_API_HOST": payload["deviceAPIHost"],
            "DEVICE_API_PORT": str(payload["deviceAPIPort"]),
            "IPAD_UDID": payload["ipadSimulatorUDID"],
            "IPHONE_UDID": payload["iphoneSimulatorUDID"],
            "DEMO_APP_PID": str(payload.get("appPID") or ""),
            "DEMO_DEVICE_API_PID": str(payload.get("deviceAPIPID") or ""),
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
  if [[ -n "${DEMO_METADATA_ERROR:-}" ]]; then
    fail "$DEMO_METADATA_ERROR"
  fi
  DEVICE_API_HOST="$(device_api_connect_host "$DEVICE_API_HOST")"
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
  DEMO_PROJECT_DIR="$LOCAL_PROJECT_DIR"
  PROJECT_DIR="$LOCAL_PROJECT_DIR"
  printf 'Shared demo root: %s\n' "$DEMO_ROOT"
}

run_remote_device_e2e() {
  local remote_result="$SUITE_ROOT/remote-device-e2e.json"
  local remote_stdout="$SUITE_ROOT/remote-device-e2e.stdout"
  local remote_log="$SUITE_ROOT/remote-device-e2e.log"
  printf 'Running remote paired-device Device API parity flow...\n'
  SPACES_E2E="$SPACES_E2E_BIN" \
    SPACES_E2E_REMOTE_DEVICE_RESULT_JSON="$remote_result" \
    "$REMOTE_DEVICE_E2E_SCRIPT" >"$remote_stdout" 2>"$remote_log" \
    || fail "Remote paired-device E2E failed. See $remote_log"
  # Validate the parity flow produced a complete result. The remote mobile-UI scenarios run against
  # the demo's own remote daemon (see load_demo_remote_target), so this flow is independent remote
  # Device API parity coverage rather than the source of the UI target.
  python3 - "$remote_result" <<'PY' || fail "Remote paired-device E2E produced an incomplete result. See $remote_log"
import json
import sys
payload = json.load(open(sys.argv[1]))
required = [
    "deviceID", "name", "remoteDaemonHost", "remoteDaemonPort", "authToken", "certificateFingerprint", "projectDir",
    "workspaceID",
]
missing = [name for name in required if not str(payload.get(name, "")).strip()]
if missing:
    raise SystemExit("remote device result missing: " + ", ".join(missing))
PY
}

create_device_api_parity_fixture() {
  local project_dir="$1"
  rm -rf "$project_dir"
  mkdir -p "$project_dir"
  printf 'local device api sentinel\n' >"$project_dir/README.txt"
  cat >"$project_dir/spaces.yaml" <<'YAML'
version: 1
processes:
  - name: parity-process
    command: >-
      python3 -c "import time; print('device-api-process-ready', flush=True); time.sleep(120)"
    on_exit: none
agent_launchers:
  - name: parity-agent
    command: >-
      python3 -c "import time; print('device-api-agent-ready', flush=True); time.sleep(120)"
YAML
  git -C "$project_dir" init >/dev/null
  git -C "$project_dir" config user.email "spaces-e2e@example.invalid"
  git -C "$project_dir" config user.name "Spaces E2E"
  git -C "$project_dir" add README.txt spaces.yaml
  git -C "$project_dir" commit -m "Initial device API parity fixture" >/dev/null
}

run_local_device_api_parity() {
  local parity_project_dir="$DEMO_ROOT/device-api-parity/local"
  local parity_result="$SUITE_ROOT/local-device-api-parity.json"
  local parity_stdout="$SUITE_ROOT/local-device-api-parity.stdout"
  local parity_log="$SUITE_ROOT/local-device-api-parity.log"
  local parsed auth_token certificate_fingerprint installation_id
  create_device_api_parity_fixture "$parity_project_dir"
  parsed="$(
    python3 - "$DEMO_ROOT/pairing.json" "$MOBILE_DEVICE_KEY" <<'PY'
import json
import shlex
import sys
payload = json.load(open(sys.argv[1]))[sys.argv[2]]
for key, name in (("authToken", "auth_token"), ("certificateFingerprint", "certificate_fingerprint"), ("installationID", "installation_id")):
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"pairing payload missing {key}")
    print(f"{name}={shlex.quote(value)}")
PY
  )"
  eval "$parsed"
  printf 'Running local paired-device Device API parity flow...\n'
  "$ROOT_DIR/apps/macos/Tests/device_api_parity.py" \
    --spacese2e "$SPACES_E2E_BIN" \
    --host "$DEVICE_API_HOST" \
    --port "$DEVICE_API_PORT" \
    --certificate-fingerprint="$certificate_fingerprint" \
    --auth-token "$auth_token" \
    --project-dir "$parity_project_dir" \
    --label "local-device" \
    --client-installation-id "$installation_id" \
    --client-device-name "$MOBILE_DEVICE_LABEL Device API E2E" \
    --result-json "$parity_result" >"$parity_stdout" 2>"$parity_log" \
    || fail "Local Device API parity flow failed. See $parity_log"
}

# Loads the remote UI target from the demo's pairing.json. This is the daemon the mobile apps and
# harness are actually paired with (the demo's remote daemon reached over the SSH forward), together
# with the remote project/workspace the demo created on it. The per-device auth token/installation ID
# match the simulator that drives this run's UI test. Populates the DEMO_REMOTE_* vars.
load_demo_remote_target() {
  local parsed
  parsed="$(
    python3 - "$DEMO_ROOT/pairing.json" "$MOBILE_DEVICE_KEY" <<'PY'
import json
import shlex
import sys

payload = json.load(open(sys.argv[1]))
device_key = sys.argv[2]
remote = payload.get("remote")
if not isinstance(remote, dict) or not remote:
    raise SystemExit("mobile demo pairing.json is missing the remote target section")
device = remote.get(device_key) or {}
fields = {
    "DEMO_REMOTE_HOST": remote.get("host"),
    "DEMO_REMOTE_PORT": remote.get("port"),
    "DEMO_REMOTE_CERTIFICATE_FINGERPRINT": remote.get("certificateFingerprint"),
    "DEMO_REMOTE_PROJECT_DIR": remote.get("projectDir"),
    "DEMO_REMOTE_WORKSPACE_ID": remote.get("workspaceID"),
    "DEMO_REMOTE_AUTH_TOKEN": device.get("authToken"),
    "DEMO_REMOTE_INSTALLATION_ID": device.get("installationID"),
}
for name, value in fields.items():
    if value is None or str(value).strip() == "":
        raise SystemExit(f"mobile demo remote target is missing {name}")
    print(f"{name}={shlex.quote(str(value))}")
PY
  )" || fail "Failed to load the remote mobile demo target from $DEMO_ROOT/pairing.json"
  eval "$parsed"
}

configure_target() {
  CURRENT_TARGET="$1"
  case "$CURRENT_TARGET" in
    local)
      PROJECT_DIR="$LOCAL_PROJECT_DIR"
      TARGET_DEVICE_ID="local"
      TARGET_DEVICE_NAME="This Mac"
      TARGET_DEVICE_API_HOST="$DEVICE_API_HOST"
      TARGET_DEVICE_API_PORT="$DEVICE_API_PORT"
      TARGET_WORKSPACE_ID=""
      ;;
    remote)
      load_demo_remote_target
      PROJECT_DIR="$DEMO_REMOTE_PROJECT_DIR"
      TARGET_DEVICE_ID="remote"
      TARGET_DEVICE_NAME="Remote Device"
      TARGET_DEVICE_API_HOST="$DEMO_REMOTE_HOST"
      TARGET_DEVICE_API_PORT="$DEMO_REMOTE_PORT"
      TARGET_DEVICE_AUTH_TOKEN="$DEMO_REMOTE_AUTH_TOKEN"
      TARGET_DEVICE_CERTIFICATE_FINGERPRINT="$DEMO_REMOTE_CERTIFICATE_FINGERPRINT"
      TARGET_DEVICE_INSTALLATION_ID="$DEMO_REMOTE_INSTALLATION_ID"
      TARGET_WORKSPACE_ID="$DEMO_REMOTE_WORKSPACE_ID"
      ;;
    *)
      fail "unsupported mobile E2E target without a paired remote-daemon harness: $CURRENT_TARGET"
      ;;
  esac
  printf '\n[%s] Using mobile E2E target: %s project=%s\n' "$(date +%H:%M:%S)" "$CURRENT_TARGET" "$PROJECT_DIR"
}

begin_scenario() {
  CURRENT_SCENARIO="$1"
  SCENARIO_CREATED_SESSIONS=()
  SCENARIO_DIR="$DEMO_ROOT/mobile-e2e/$CURRENT_TARGET/$CURRENT_SCENARIO"
  SCENARIO_LOG="$SCENARIO_DIR/scenario.log"
  UI_TEST_CONFIG="$SCENARIO_DIR/ui-test-config.json"
  UI_TEST_LOG="$SCENARIO_DIR/ui-test.log"
  mkdir -p "$SCENARIO_DIR"
  : >"$SCENARIO_LOG"
  printf '\n[%s] Running mobile scenario: %s target=%s\n' "$(date +%H:%M:%S)" "$CURRENT_SCENARIO" "$CURRENT_TARGET"
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

profile_app_owner_json() {
  demo_env "$SPACES_E2E_BIN" profile-app-owner --json
}

profile_app_owner_pid() {
  python3 -c '
import json
import os
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

owner = payload.get("owner")
if not owner:
    raise SystemExit(1)
pid = owner.get("pid")
if not isinstance(pid, int) or pid <= 0:
    raise SystemExit(1)
try:
    os.kill(pid, 0)
except OSError:
    raise SystemExit(1)
print(pid)
'
}

record_profile_app_owner_pid() {
  local owner_pid="$1"
  [[ -n "$owner_pid" && "$owner_pid" =~ ^[0-9]+$ ]] || return 0
  DEMO_APP_PID="$owner_pid"
}

remote_device_api_request() {
  local request_json="$1"
  [[ -n "$DEMO_REMOTE_HOST" && -n "$DEMO_REMOTE_PORT" && -n "$DEMO_REMOTE_CERTIFICATE_FINGERPRINT" && -n "$DEMO_REMOTE_AUTH_TOKEN" ]] \
    || fail "remote Device API request attempted before the remote mobile demo target was loaded"
  python3 - "$SPACES_E2E_BIN" "$BUNDLE_ID" "$DEMO_REMOTE_HOST" "$DEMO_REMOTE_PORT" "$DEMO_REMOTE_CERTIFICATE_FINGERPRINT" "$DEMO_REMOTE_AUTH_TOKEN" "$DEMO_REMOTE_INSTALLATION_ID" "$request_json" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

spacese2e = Path(sys.argv[1])
bundle_id = sys.argv[2]
host = sys.argv[3]
port = sys.argv[4]
certificate_fingerprint = sys.argv[5]
auth_token = sys.argv[6]
installation_id = sys.argv[7]
request = json.loads(sys.argv[8])
client_app = {
    "installationID": installation_id,
    "bundleID": bundle_id,
    "platform": "ios",
    "deviceName": "Remote Device E2E",
    "appVersion": "1.0",
}

def typed_device_request(request):
    command = request.get("command")
    if isinstance(command, dict):
        return request
    payload = {key: value for key, value in request.items() if key != "command"}
    if command in {"attach", "detach", "heartbeat", "takeover", "send", "key", "clear", "clearScreen", "resize", "scroll"}:
        payload["action"] = "clearScreen" if command == "clear" else command
        payload.setdefault("appendNewline", False)
        payload.setdefault("asPaste", False)
        return {"command": {"terminalControl": payload}}
    return {"command": {command: payload}}

request = typed_device_request(request)
try:
    completed = subprocess.run(
        [
            str(spacese2e),
            "mobile-request",
            "--host",
            host,
            "--port",
            str(port),
            "--certificate-fingerprint=" + certificate_fingerprint,
            "--request-json",
            json.dumps({"authToken": auth_token, "clientApp": client_app, **request}),
        ],
        capture_output=True,
        text=True,
        env=os.environ,
        timeout=20,
        check=True,
    )
except subprocess.CalledProcessError as error:
    sys.stderr.write(f"mobile-request failed (exit {error.returncode}): {(error.stderr or error.stdout or '').strip()}\n")
    raise SystemExit(1)
print(completed.stdout, end="")
PY
}

device_api_response_ok() {
  local response_json="$1"
  python3 - "$response_json" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if payload.get("ok") else 1)
PY
}

wait_for_mobile_overview_sessions() {
  local overview_log="$SCENARIO_DIR/mobile-overview-wait.log"
  demo_env python3 - "$SPACES_E2E_BIN" "$BUNDLE_ID" "$MOBILE_DEVICE_NAME" "$UI_TEST_CONFIG" "$overview_log" <<'PY'
import json
import os
import subprocess
import sys
import time
from pathlib import Path

spacese2e = Path(sys.argv[1])
bundle_id = sys.argv[2]
fallback_device_name = sys.argv[3]
config_path = Path(sys.argv[4])
log_path = Path(sys.argv[5])

config = json.loads(config_path.read_text())
required_session_ids = [
    value for value in (config.get("sessionID"), config.get("secondarySessionID"))
    if isinstance(value, str) and value
]
if not required_session_ids:
    raise SystemExit(0)

client_app = {
    "installationID": config["installationID"],
    "bundleID": bundle_id,
    "platform": "ios",
    "deviceName": config.get("deviceName") or fallback_device_name,
    "appVersion": "1.0",
}
command = [
    str(spacese2e),
    "mobile-request",
    "--host",
    config["host"],
    "--port",
    str(config["port"]),
    "--certificate-fingerprint=" + config["certificateFingerprint"],
    "--request-json",
    json.dumps({"authToken": config["authToken"], "clientApp": client_app, "command": {"overview": {}}}),
]

def session_id_for_row(row):
    if not isinstance(row, dict):
        return None
    for key in ("sessionID", "id"):
        value = row.get(key)
        if isinstance(value, str) and value:
            return value
    return None

def collect_terminal_rows(value, rows):
    if isinstance(value, dict):
        row_session_id = session_id_for_row(value)
        if row_session_id in required_session_ids:
            rows.append(value)
        for child in value.values():
            collect_terminal_rows(child, rows)
    elif isinstance(value, list):
        for child in value:
            collect_terminal_rows(child, rows)

deadline = time.time() + 30
last_detail = ""
attempt = 0
while time.time() < deadline:
    attempt += 1
    completed = subprocess.run(command, capture_output=True, text=True, env=os.environ, timeout=20)
    if completed.returncode == 0:
        try:
            payload = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            last_detail = f"attempt {attempt}: invalid JSON: {error}\nstdout={completed.stdout}\nstderr={completed.stderr}"
        else:
            terminal_rows = []
            collect_terminal_rows(((payload.get("result") or {}).get("overview") or {}), terminal_rows)
            visible_ids = {session_id_for_row(row) for row in terminal_rows}
            missing = [session_id for session_id in required_session_ids if session_id not in visible_ids]
            last_detail = json.dumps(
                {
                    "attempt": attempt,
                    "requiredSessionIDs": required_session_ids,
                    "visibleSessionIDs": sorted(session_id for session_id in visible_ids if session_id),
                    "missingSessionIDs": missing,
                    "ok": payload.get("ok"),
                },
                indent=2,
                sort_keys=True,
            )
            if payload.get("ok") and not missing:
                log_path.write_text(last_detail + "\n")
                raise SystemExit(0)
    else:
        last_detail = f"attempt {attempt}: exit={completed.returncode}\nstdout={completed.stdout}\nstderr={completed.stderr}"
    time.sleep(1)

log_path.write_text(last_detail + "\n")
raise SystemExit(f"Device API overview did not include required sessions before UI test.\n{last_detail}")
PY
}

ensure_profile_app_owner() {
  local log_path="$1"
  local owner_json=""
  local owner_pid=""
  if owner_json="$(profile_app_owner_json 2>&1)"; then
    {
      printf 'profile-app-owner before terminal show:\n'
      printf '%s\n' "$owner_json"
    } >>"$log_path" || true
    if owner_pid="$(printf '%s' "$owner_json" | profile_app_owner_pid 2>/dev/null)"; then
      record_profile_app_owner_pid "$owner_pid"
      return 0
    fi
  else
    {
      printf 'profile-app-owner failed before terminal show:\n'
      printf '%s\n' "$owner_json"
    } >>"$log_path" || true
  fi

  {
    printf 'No live profile app owner.\n'
  } >>"$log_path" || true
  return 1
}

new_remote_workspace_terminal_session() {
  local title="${1:-e2e-$CURRENT_SCENARIO}"
  local command_text="${2:-}"
  [[ -z "$command_text" ]] || fail "remote mobile E2E terminal creation does not support scenario-specific launch commands: $CURRENT_SCENARIO"
  [[ -n "$TARGET_WORKSPACE_ID" ]] || fail "remote mobile E2E target is missing a workspace ID"
  local create_request create_response session_id primer_request primer_response seed_request seed_response
  create_request="$(
    python3 - "$TARGET_WORKSPACE_ID" <<'PY'
import json
import sys
print(json.dumps({"command": "openWorkspaceTerminal", "workspaceID": sys.argv[1]}, separators=(",", ":")))
PY
  )"
  create_response="$(remote_device_api_request "$create_request")" || fail "Failed to create remote workspace terminal for $CURRENT_SCENARIO."
  session_id="$(
    python3 - "$create_response" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
mutation = ((payload.get("result") or {}).get("mutation") or {})
session_id = mutation.get("sessionID")
if not payload.get("ok") or not session_id:
    raise SystemExit(f"openWorkspaceTerminal did not return a session ID: {payload}")
print(session_id)
PY
  )" || fail "Unable to parse remote workspace terminal session ID for $CURRENT_SCENARIO."
  primer_request="$(
    python3 - "$session_id" "$title" <<'PY'
import json
import sys
from datetime import datetime, timezone
session_id, title = sys.argv[1:3]
client_id = f"mobile-e2e-primer-{session_id}"
payload = {
    "command": "attach",
    "sessionID": session_id,
    "client": {
        "id": client_id,
        "kind": "remoteViewer",
        "identity": {
            "label": "Remote E2E Primer",
            "deviceName": "Remote E2E Primer",
            "networkAddress": "127.0.0.1",
        },
        "connectedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    },
    "attachmentMode": "owner",
}
print(json.dumps(payload, separators=(",", ":")))
PY
  )"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    primer_response="$(remote_device_api_request "$primer_request" 2>&1 || true)"
    if device_api_response_ok "$primer_response"; then
      break
    fi
    if [[ "$attempt" == "10" ]]; then
      printf '%s\n' "$primer_response" >>"$SCENARIO_LOG" || true
      fail "Remote primer owner attach failed for mobile E2E."
    fi
    sleep 0.5
  done
  seed_request="$(
    python3 - "$session_id" "$title" <<'PY'
import json
import sys
session_id, title = sys.argv[1:3]
client_id = f"mobile-e2e-primer-{session_id}"
command = f"printf '__spaces_remote_mobile_ready__ {title}\\n'; pwd"
print(json.dumps({
    "command": "send",
    "sessionID": session_id,
    "clientID": client_id,
    "text": command,
    "appendNewline": True,
}, separators=(",", ":")))
PY
  )"
  for attempt in 1 2 3 4 5; do
    seed_response="$(remote_device_api_request "$seed_request" 2>&1 || true)"
    if device_api_response_ok "$seed_response"; then
      break
    fi
    if [[ "$attempt" == "5" ]]; then
      printf '%s\n' "$seed_response" >>"$SCENARIO_LOG" || true
      fail "Remote terminal output seed failed for mobile E2E."
    fi
    sleep 0.5
  done
  printf '%s\n' "$session_id"
}

new_terminal_session() {
  if [[ "$CURRENT_TARGET" == "remote" ]]; then
    new_remote_workspace_terminal_session "$@"
    return
  fi
  local title="${1:-e2e-$CURRENT_SCENARIO}"
  local command_text="${2:-}"
  local create_log="$SCENARIO_DIR/start-workspace-terminal-session.log"
  local show_log="$SCENARIO_DIR/show-terminal.log"
  local session_id
  : >"$create_log"
  for attempt in 1 2 3 4 5; do
    local attempt_log="$SCENARIO_DIR/start-workspace-terminal-session-attempt-$attempt.log"
    local -a create_args
    create_args=(start-workspace-terminal-session --workspace-dir "$PROJECT_DIR" --title "$title")
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
  python3 - "$create_log" "$SCENARIO_DIR/session-$session_id.output-path" "$RUNTIME_DIR" "$session_id" <<'PY'
import json
import pathlib
import sys

create_log = pathlib.Path(sys.argv[1])
output_path_file = pathlib.Path(sys.argv[2])
runtime_dir = pathlib.Path(sys.argv[3])
session_id = sys.argv[4]
decoder = json.JSONDecoder()
text = create_log.read_text()
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
output_path = (payload or {}).get("outputPath") or str(runtime_dir / "terminal" / "sessions" / session_id / "output.log")
output_path_file.write_text(output_path)
PY
  : >"$show_log"
  for attempt in 1 2 3; do
    local show_attempt_log="$SCENARIO_DIR/show-terminal-attempt-$attempt.log"
    if ! ensure_profile_app_owner "$show_log"; then
      fail "No current-profile SpacesApp owner was available for fresh terminal session $session_id."
    fi
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
    local screenshot_path="$SCENARIO_DIR/show-terminal-attempt-$attempt-desktop.png"
    capture_desktop_screenshot "$screenshot_path"
    [[ -f "$screenshot_path" ]] && printf 'Desktop screenshot: %s\n' "$screenshot_path" >>"$show_log"
    sleep 1
  done
  fail "Fresh terminal session did not become owner-ready: $session_id"
}

session_output_path() {
  local session_id="$1"
  local path_file="$SCENARIO_DIR/session-$session_id.output-path"
  if [[ -f "$path_file" ]]; then
    cat "$path_file"
  else
    printf '%s/terminal/sessions/%s/output.log\n' "$RUNTIME_DIR" "$session_id"
  fi
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
    if [[ "$CURRENT_TARGET" == "remote" ]]; then
      local stop_request
      stop_request="$(
        python3 - "$TARGET_WORKSPACE_ID" "$session_id" <<'PY'
import json
import sys
workspace_id, session_id = sys.argv[1:3]
print(json.dumps({
    "command": "stopWorkspaceTerminal",
    "workspaceID": workspace_id,
    "sessionID": session_id,
}, separators=(",", ":")))
PY
      )"
      if [[ -n "$SCENARIO_LOG" ]]; then
        {
          printf -- '--- stop remote workspace terminal %s ---\n' "$session_id"
          remote_device_api_request "$stop_request"
        } >>"$SCENARIO_LOG" 2>&1 || true
      else
        remote_device_api_request "$stop_request" >/dev/null 2>&1 || true
      fi
      continue
    fi
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

mobile_launch_environment_assignments() {
  python3 - "$UI_TEST_CONFIG" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
payload = json.loads(config_path.read_text())
mapping = {
    "host": "SPACES_MOBILE_TEST_HOST",
    "port": "SPACES_MOBILE_TEST_PORT",
    "authToken": "SPACES_MOBILE_TEST_AUTH_TOKEN",
    "certificateFingerprint": "SPACES_MOBILE_TEST_CERTIFICATE_FINGERPRINT",
    "installationID": "SPACES_MOBILE_TEST_INSTALLATION_ID",
    "sessionID": "SPACES_MOBILE_E2E_TARGET_SESSION_ID",
    "secondarySessionID": "SPACES_MOBILE_E2E_SECONDARY_SESSION_ID",
    "renderDumpPath": "SPACES_MOBILE_E2E_RENDER_DUMP_PATH",
    "eventLogPath": "SPACES_MOBILE_E2E_EVENT_LOG_PATH",
}
for json_key, environment_key in mapping.items():
    value = payload.get(json_key)
    if value is not None and str(value).strip():
        print(f"SIMCTL_CHILD_{environment_key}={value}")
required_seed_keys = [
    "host",
    "port",
    "authToken",
    "certificateFingerprint",
]
if all(str(payload.get(key, "")).strip() for key in required_seed_keys):
    device_id = str(payload.get("deviceID") or "").strip()
    device_name = str(payload.get("deviceName") or "This Mac").strip() or "This Mac"
    device = {
        "name": device_name,
        "host": payload["host"],
        "port": int(payload["port"]),
        "authToken": payload["authToken"],
        "certificateFingerprint": payload["certificateFingerprint"],
    }
    if device_id:
        device["id"] = device_id
    seed = {
        "devices": [device]
    }
    if device_id:
        seed["activeDeviceID"] = device_id
    print(f"SIMCTL_CHILD_SPACES_MOBILE_TEST_DEVICE_SEED_JSON={json.dumps(seed, separators=(',', ':'))}")
print(f"SIMCTL_CHILD_SPACES_MOBILE_UI_TEST_CONFIG_PATH={config_path}")
PY
}

reset_mobile_app() {
  local launch_env=()
  local assignment
  while IFS= read -r assignment; do
    [[ -n "$assignment" ]] && launch_env+=("$assignment")
  done < <(mobile_launch_environment_assignments)
  xcrun simctl terminate "$MOBILE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "${MOBILE_APP_LAUNCH_MODE:-default}" == "console-capture" ]]; then
    # Attached to a pty so the app's stdout/stderr land in the scenario directory. An uncaught
    # NSException prints its reason there and nowhere else — the .ips crash report carries the
    # backtrace but not the assertion text.
    env \
      "${launch_env[@]}" \
      SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_TRACE=1 \
      SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$PERFORMANCE_LOG_PATH" \
      SIMCTL_CHILD_SPACES_MOBILE_PAYWALL_BYPASS=1 \
      SIMCTL_CHILD_SPACES_MOBILE_LIST_IDENTITY_DUMP="${SPACES_MOBILE_LIST_IDENTITY_DUMP:-0}" \
      xcrun simctl launch --console-pty "$MOBILE_UDID" "$BUNDLE_ID" \
      >"$SCENARIO_DIR/app-stdout.log" 2>"$SCENARIO_DIR/app-stderr.log" </dev/null &
    sleep 4
  else
    env \
      "${launch_env[@]}" \
      SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_TRACE=1 \
      SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$PERFORMANCE_LOG_PATH" \
      SIMCTL_CHILD_SPACES_MOBILE_PAYWALL_BYPASS=1 \
      xcrun simctl launch "$MOBILE_UDID" "$BUNDLE_ID" >>"$SCENARIO_LOG" 2>&1 || fail "Failed to launch SpacesMobile on the $MOBILE_DEVICE_LABEL simulator."
    sleep 2
  fi
}

write_ui_test_config() {
  local scenario="$1"
  local session_id="$2"
  local secondary_session_id="${3:-}"
  python3 - "$DEMO_ROOT" "$scenario" "$session_id" "$secondary_session_id" "$DEVICE_API_HOST" "$DEVICE_API_PORT" "$MOBILE_UDID" "$MOBILE_DEVICE_KEY" "$MOBILE_ARTIFACT_NAME" "$UI_TEST_CONFIG" "$DEFAULT_UI_TEST_CONFIG" "$BUNDLE_ID" "$SCROLLBACK_SWIPE_COUNT" "$TERMINAL_LINK_PREVIEW_IMAGE_NAME" "$TERMINAL_LINK_PREVIEW_PATH" "$CURRENT_TARGET" "$TARGET_DEVICE_ID" "$TARGET_DEVICE_NAME" "$TARGET_DEVICE_API_HOST" "$TARGET_DEVICE_API_PORT" "$TARGET_DEVICE_AUTH_TOKEN" "$TARGET_DEVICE_CERTIFICATE_FINGERPRINT" "$TARGET_DEVICE_INSTALLATION_ID" <<'PY'
import json
import os
import sys
from pathlib import Path

(
    demo_root_raw,
    scenario,
    session_id,
    secondary_session_id,
    device_api_host,
    device_api_port_raw,
    mobile_udid,
    mobile_device_key,
    mobile_artifact_name,
    scenario_config_raw,
    default_config_raw,
    bundle_id,
    scrollback_swipe_count_raw,
    terminal_link_preview_image_name,
    terminal_link_preview_path,
    current_target,
    target_device_id,
    target_device_name,
    target_device_api_host,
    target_device_api_port_raw,
    target_device_auth_token,
    target_device_certificate_fingerprint,
    target_device_installation_id,
) = sys.argv[1:]

demo_root = Path(demo_root_raw)
artifacts_dir = Path(scenario_config_raw).parent
device_api_port = int(device_api_port_raw)
scrollback_swipe_count = int(scrollback_swipe_count_raw)
config_paths = [Path(scenario_config_raw), Path(default_config_raw)]
pairing = json.loads((demo_root / "pairing.json").read_text())
mobile_pairing = pairing[mobile_device_key]
if current_target == "remote":
    device_api_host = target_device_api_host
    device_api_port = int(target_device_api_port_raw)
    mobile_pairing = {
        "authToken": target_device_auth_token,
        "certificateFingerprint": target_device_certificate_fingerprint,
        "installationID": target_device_installation_id,
    }
    if not all(str(mobile_pairing.get(key, "")).strip() for key in ("authToken", "certificateFingerprint", "installationID")):
        raise SystemExit("remote UI test target credentials are incomplete")
prefix = scenario
artifact_prefix = f"{prefix}-{mobile_artifact_name}"

payload = {
    "sessionID": session_id,
    "secondarySessionID": None,
    "deviceID": target_device_id or None,
    "deviceName": target_device_name or ("This Mac" if current_target == "local" else "Remote Device"),
    "host": device_api_host,
    "port": device_api_port,
    "authToken": mobile_pairing["authToken"],
    "certificateFingerprint": mobile_pairing["certificateFingerprint"],
    "installationID": mobile_pairing["installationID"],
    "renderDumpPath": str(artifacts_dir / f"{artifact_prefix}-render.json"),
    "eventLogPath": str(artifacts_dir / f"{artifact_prefix}-events.jsonl"),
    "immediateScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-takeover-immediate.png"),
    "shortDelayScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-takeover-plus-2s.png"),
    "longDelayScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-takeover-plus-6s.png"),
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
    "firstCommandOutputText": None,
    "secondCommandOutputText": None,
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
    "finalScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-final.png"),
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
        "proceedTakeOverPath": str(artifacts_dir / f"{artifact_prefix}-proceed-takeover"),
        "firstCommandRequestPath": str(artifacts_dir / f"{artifact_prefix}-first-command-request"),
        "firstCommandFocusedPath": str(artifacts_dir / f"{artifact_prefix}-first-command-focused"),
        "firstCommandCompletedPath": str(artifacts_dir / f"{artifact_prefix}-first-command-completed"),
        "firstCommandObservedPath": str(artifacts_dir / f"{artifact_prefix}-first-command-observed"),
        "secondCommandRequestPath": str(artifacts_dir / f"{artifact_prefix}-second-command-request"),
        "secondCommandFocusedPath": str(artifacts_dir / f"{artifact_prefix}-second-command-focused"),
        "secondCommandCompletedPath": str(artifacts_dir / f"{artifact_prefix}-second-command-completed"),
        "secondCommandObservedPath": str(artifacts_dir / f"{artifact_prefix}-second-command-observed"),
        "proceedFinishPath": str(artifacts_dir / f"{artifact_prefix}-proceed-finish"),
        "firstCommandText": "printf '__rt_i1__\\n\\n\\n'",
        "secondCommandText": "printf '__rt_i2__\\n\\n\\n'",
        "firstCommandOutputText": "__rt_i1__",
        "secondCommandOutputText": "__rt_i2__",
        "manualRetakeoverAttempts": 2,
        "manualRetakeoverObservedPrefix": str(artifacts_dir / f"{artifact_prefix}-manual-retakeover-observed"),
        "manualRetakeoverContinuePrefix": str(artifacts_dir / f"{artifact_prefix}-manual-retakeover-continue"),
        "postFirstCommandScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-first-command.png"),
        "postSecondCommandScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-second-command.png"),
        "finalMacRetakeoverRequestPath": str(artifacts_dir / f"{artifact_prefix}-final-mac-retakeover-request"),
        "finalMacRetakeoverObservedPath": str(artifacts_dir / f"{artifact_prefix}-final-mac-retakeover-observed"),
        "postFinalMacRetakeoverScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-final-mac-retakeover.png"),
        "minimumVisibleTerminalInkBands": 3,
        "maximumTerminalTopBlankRatio": 0.20,
    })
elif scenario == "scrollback":
    payload.update({
        "firstCommandRequestPath": str(artifacts_dir / f"{artifact_prefix}-first-command-request"),
        "firstCommandFocusedPath": str(artifacts_dir / f"{artifact_prefix}-first-command-focused"),
        "firstCommandCompletedPath": str(artifacts_dir / f"{artifact_prefix}-first-command-completed"),
        "firstCommandObservedPath": str(artifacts_dir / f"{artifact_prefix}-first-command-observed"),
        "postFirstCommandScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-command-while-scrolled.png"),
        "scrollbackSwipeCount": scrollback_swipe_count,
        "minimumVisibleTerminalInkBands": 3,
        "maximumTerminalTopBlankRatio": 0.20,
    })
elif scenario == "mouse-reporting-scroll":
    payload.update({
        "scrollbackSwipeCount": 1,
        "minimumVisibleTerminalInkBands": 1,
        "maximumTerminalTopBlankRatio": 0.40,
    })
elif scenario == "terminal-link-preview":
    payload.update({
        "terminalLinkText": terminal_link_preview_path,
        "expectedLinkPreviewTitle": terminal_link_preview_image_name,
        "linkPreviewScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-preview.png"),
        "minimumVisibleTerminalInkBands": 2,
        "maximumTerminalTopBlankRatio": 0.30,
    })
elif scenario == "two-session":
    payload.update({
        "secondarySessionID": secondary_session_id,
        "immediateScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-first-takeover.png"),
        "shortDelayScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-first-takeover-plus-2s.png"),
        "longDelayScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-first-takeover-plus-6s.png"),
        "finalScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-post-second-takeover.png"),
        "firstCommandText": "pwd",
    })
elif scenario == "session-end-scroll":
    payload.update({
        "targetWorkspaceID": os.environ.get("SPACES_MOBILE_E2E_TARGET_WORKSPACE_ID", ""),
        "terminalRowRemovalTimeoutSeconds": 55.0,
        "immediateScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-failure.png"),
        "finalScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-after-scroll.png"),
    })
elif scenario in ("workspace-delete-scroll", "workspace-hide-scroll"):
    payload.update({
        "targetWorkspaceID": os.environ.get("SPACES_MOBILE_E2E_TARGET_WORKSPACE_ID", ""),
        "removalScrollSeconds": 12.0,
        "immediateScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-failure.png"),
        "finalScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-after-scroll.png"),
    })
elif scenario in ("ctrl-c-final-frame", "ctrl-c-final-frame-codex-survivor"):
    expected_secondary_text = "" if scenario == "ctrl-c-final-frame-codex-survivor" else "__spaces_survivor_peer_ready__"
    payload.update({
        "secondarySessionID": secondary_session_id,
        "interruptedRenderDumpPath": str(artifacts_dir / f"{artifact_prefix}-interrupted-render.json"),
        "postInterruptScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-interrupted-final-frame.png"),
        "finalScreenshotPath": str(artifacts_dir / f"{artifact_prefix}-secondary-live-after-interrupt.png"),
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
  wait_for_mobile_overview_sessions
  reset_mobile_app
  if ! SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
    xcodebuild \
      -project "$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj" \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$MOBILE_UDID" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      -only-testing:"$test_name" \
      test-without-building >"$UI_TEST_LOG" 2>&1; then
    tail -40 "$UI_TEST_LOG" 2>/dev/null | grep -E "error:|failed" || true
    # An uncaught NSException's reason text appears only in the app's captured stderr — the .ips crash
    # report carries the backtrace but not the assertion text — so print it before failing.
    if [[ -s "$SCENARIO_DIR/app-stderr.log" ]]; then
      printf '\n--- SpacesMobile app stderr ---\n'
      cat "$SCENARIO_DIR/app-stderr.log"
      printf -- '--- end SpacesMobile app stderr ---\n\n'
    fi
    fail "UI test failed: $test_name"
  fi
}

launch_codex_on_mac_owner() {
  local session_id="$1"
  local command_text="$2"
  local output_path
  output_path="$(session_output_path "$session_id")"
  python3 - "$DEMO_ROOT" "$session_id" "$SPACES_E2E_BIN" "$command_text" "$SCENARIO_DIR" "$output_path" <<'PY'
import json
import os
import shlex
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
output_log_path = Path(sys.argv[6])
runtime_root = demo_root / "runtime"
owner_dump_path = scenario_dir / "codex-mac-owner-dump.json"

env = os.environ | {
    "HOME": str(demo_root / "home"),
    "CODEX_HOME": os.environ.get("CODEX_HOME", str(Path.home() / ".codex")),
    "XDG_CONFIG_HOME": os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")),
    "SPACES_DB_PATH": str(demo_root / "spaces.db"),
    "SPACES_RUNTIME_DIR": str(runtime_root),
}

def current_owner_client_id() -> str:
    root_directory = os.path.normpath(str(runtime_root / "terminal" / "sessions" / session_id))
    deadline = time.time() + 30
    rows = []
    while time.time() < deadline:
        with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
            rows = db.execute(
                """
                SELECT client_id, mode, detached_at
                FROM terminal_attachments
                WHERE root_directory = ?
                ORDER BY attached_at DESC
                """,
                (root_directory,),
            ).fetchall()
        for client_id, mode, detached_at in rows:
            if client_id and mode == "owner" and detached_at is None:
                return client_id
        time.sleep(0.1)
    raise RuntimeError(f"No active owner attachment was found for the demo session. rows={rows!r}")

def send_request(request: dict) -> dict:
    command = [
        str(spacese2e),
        "terminal-service-control",
        "--session-id",
        session_id,
        "--command",
        request["command"],
        "--client-id",
        request["clientID"],
    ]
    if request.get("text") is not None:
        command.extend(["--text", request["text"]])
    if request.get("key") is not None:
        command.extend(["--key", request["key"]])
    if request.get("appendNewline"):
        command.append("--append-newline")
    completed = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
    return json.loads(completed.stdout)

def wait_for_owner_control_ready(owner_client_id: str) -> None:
    deadline = time.time() + 15
    last_response = None
    while time.time() < deadline:
        response = send_request(
            {"command": "send", "text": "", "clientID": owner_client_id}
        )
        last_response = response
        message = response.get("message", "")
        if response.get("ok"):
            return
        if "Only the active owner" in message:
            time.sleep(0.1)
            continue
        raise RuntimeError(f"Owner control readiness probe failed: {response}")
    raise RuntimeError(f"Timed out waiting for owner control readiness. last_response={last_response!r}")

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
wait_for_owner_control_ready(owner_client_id)
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

run_takeover_scenario() {
  begin_scenario "takeover"
  local session_id
  session_id="$(new_terminal_session)"
  track_current_scenario_session "$session_id"
  write_ui_test_config "takeover" "$session_id"
  run_ui_test "SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList"
  printf 'Mobile scenario passed: takeover\n'
}

run_roundtrip_scenario() {
  begin_scenario "roundtrip"
  local session_id
  session_id="$(new_terminal_session)"
  track_current_scenario_session "$session_id"
  write_ui_test_config "roundtrip" "$session_id"
  wait_for_mobile_overview_sessions
  reset_mobile_app
  python3 - "$ROOT_DIR" "$DEMO_ROOT" "$session_id" "$DEVICE_API_HOST" "$DEVICE_API_PORT" "$MOBILE_UDID" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$UI_TEST_CONFIG" "$UI_TEST_LOG" "$IOS_DERIVED_DATA" "$SCENARIO_DIR" "$MOBILE_DEVICE_LABEL" "$MOBILE_ARTIFACT_NAME" <<'PY'
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

repo_root = Path(sys.argv[1])
demo_root = Path(sys.argv[2])
session_id = sys.argv[3]
device_api_host = sys.argv[4]
device_api_port = int(sys.argv[5])
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
    "export PS1='READY PROMPT > '",
    "printf '__roundtrip_mac_before_takeover_one__\\n'",
    "printf '__roundtrip_mac_before_takeover_two__\\nMAC BEFORE TAKEOVER TWO\\n'",
]
mac_ready_prompt_text = "READY PROMPT"
ios_first_command = config["firstCommandText"]
ios_first_output = config.get("firstCommandOutputText") or f"__roundtrip_{mobile_artifact_name}_one__"
ios_second_command = config["secondCommandText"]
ios_second_output = config.get("secondCommandOutputText") or f"__roundtrip_{mobile_artifact_name}_two__"
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

def send_terminal_control_request(request: dict) -> dict:
    command = [
        str(spacese2e),
        "terminal-service-control",
        "--session-id",
        session_id,
        "--command",
        request["command"],
    ]
    if request.get("clientID") is not None:
        command.extend(["--client-id", request["clientID"]])
    if request.get("text") is not None:
        command.extend(["--text", request["text"]])
    if request.get("key") is not None:
        command.extend(["--key", request["key"]])
    if request.get("appendNewline"):
        command.append("--append-newline")
    completed = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
    return json.loads(completed.stdout)

def send_owner_command(command_text: str) -> None:
    owner_client_id = current_owner_client_id()
    response = send_terminal_control_request(
        {"command": "send", "text": command_text, "appendNewline": True, "clientID": owner_client_id}
    )
    if not response.get("ok"):
        raise RuntimeError(f"Owner control request failed: {response}")

def focus_mac_terminal_window() -> None:
    show_result = subprocess.run(
        [str(spaces_cli), "terminal", "show", session_id],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    if "Requested owner terminal window" not in show_result.stdout:
        raise RuntimeError(f"Mac terminal focus request did not report success:\n{show_result.stdout}\n{show_result.stderr}")

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
    compact_prompts = tuple(re.sub(r"\s+", "", prompt) for prompt in ("%", "$", "#", mac_ready_prompt_text, f"{mac_ready_prompt_text} >"))
    return (
        any(f"{prompt}{compact_command}" in compact_text for prompt in compact_prompts)
        and any(line.strip() == output_text for line in lines)
    )

def assert_prompt_rendered_after_output(label: str, text: str, output_text: str) -> None:
    if prompt_rendered_after_output(text, output_text):
        return
    if output_text in text:
        raise RuntimeError(f"{label} did not render the next shell prompt after {output_text!r}:\n{text}")
    raise RuntimeError(f"{label} did not render output marker {output_text!r}:\n{text}")

def prompt_rendered_after_output(text: str, output_text: str) -> bool:
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
            if mac_ready_prompt_text in stripped:
                return True
            if re.search(r"[%#$]\s*$", next_line):
                return True
        return False
    return False

def normalized_ocr_text(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()

def assert_mac_screen_prompt_rendered_after_output(label: str, payload: dict, output_text: str, prompt_text: str) -> None:
    screenshot_path = scenario_dir / "roundtrip-mac-before-takeover-screen.png"
    ocr_path = scenario_dir / "roundtrip-mac-before-takeover-screen-ocr.txt"
    window_number = payload.get("windowNumber")
    if not isinstance(window_number, int) or window_number <= 0:
        raise RuntimeError(f"{label} did not report a captureable terminal window number:\n{json.dumps(payload, indent=2)}")

    swift_script = r'''
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
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])
let recognizedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
print(recognizedText)
'''
    output_needle = normalized_ocr_text(output_text)
    prompt_needle = normalized_ocr_text(prompt_text)
    deadline = time.time() + 2.0
    recognized_text = ""
    last_error = ""
    while time.time() < deadline:
        try:
            subprocess.run(
                ["screencapture", "-x", "-l", str(window_number), str(screenshot_path)],
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            )
        except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            raise RuntimeError(f"{label} could not capture a desktop screenshot for UI assertion: {error}") from error

        result = subprocess.run(
            ["swift", "-", str(screenshot_path)],
            input=swift_script,
            capture_output=True,
            text=True,
            timeout=30,
        )
        recognized_text = result.stdout
        ocr_path.write_text(recognized_text)
        if result.returncode != 0:
            last_error = f"OCR failed for {screenshot_path}:\n{result.stderr}\nOCR output:\n{recognized_text}"
            time.sleep(0.2)
            continue

        normalized = normalized_ocr_text(recognized_text)
        output_index = normalized.find(output_needle)
        prompt_index = normalized.find(prompt_needle, output_index + len(output_needle)) if output_index >= 0 else -1
        if output_index >= 0 and prompt_index >= 0:
            return
        time.sleep(0.2)

    raise RuntimeError(
        f"{label} did not visibly render command output followed by the next prompt.\n"
        f"Screenshot: {screenshot_path}\nOCR: {ocr_path}\n"
        f"Expected output {output_text!r} before prompt {prompt_text!r}.\n"
        f"{last_error}\n"
        f"OCR output:\n{recognized_text}"
    )

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
    last_render_payload = None
    while time.time() < deadline:
        check_ui_test_alive(process)
        if output_log_path.exists():
            last_output = output_log_path.read_text(errors="replace")
            if text in last_output:
                return
        if render_dump_path.exists():
            try:
                last_render_payload = json.loads(render_dump_path.read_text())
            except json.JSONDecodeError:
                last_render_payload = None
            if last_render_payload is not None:
                rendered_text = last_render_payload.get("renderedText") or ""
                snapshot_text = last_render_payload.get("snapshotText") or ""
                if text in rendered_text or text in snapshot_text:
                    return
        time.sleep(0.2)
    raise RuntimeError(
        f"Timed out waiting for {text!r} in {output_log_path} or the {mobile_device_label} render dump.\n"
        f"Last output tail:\n{last_output[-4000:]}\n"
        f"Last render payload:\n{json.dumps(last_render_payload or {}, indent=2)}"
    )

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
mac_before_takeover_dump_path = scenario_dir / "roundtrip-mac-before-takeover-dump.json"
mac_status_dump_path = scenario_dir / "roundtrip-mac-status-dump.json"

with ui_test_log.open("w") as ui_test_output:
    ui_test_process = None

    try:
        focus_mac_terminal_window()
        for command_text in mac_prepare_commands:
            send_owner_command(command_text)
            time.sleep(0.5)

        focus_mac_terminal_window()
        mac_owner_payload = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                payload.get("found") is True
                and payload.get("showsTerminalSurface") is True
                and isinstance(payload.get("windowNumber"), int)
            ),
            timeout=45,
            any_mode=False,
        )
        mac_before_takeover_dump_path.write_text(json.dumps(mac_owner_payload, indent=2, sort_keys=True))
        assert_mac_screen_prompt_rendered_after_output(
            "Mac owner before takeover",
            mac_owner_payload,
            "MAC BEFORE TAKEOVER TWO",
            mac_ready_prompt_text,
        )
        refreshed_mac_owner_payload = wait_for_terminal_window_dump(
            mac_owner_dump_path,
            lambda payload: (
                mac_owner_render_contains(
                    payload, "__roundtrip_mac_before_takeover_one__", "__roundtrip_mac_before_takeover_two__"
                )
                and prompt_rendered_after_output(
                    payload.get("visibleSurfaceOutput") or "",
                    "__roundtrip_mac_before_takeover_two__",
                )
            ),
            timeout=5,
            any_mode=False,
        )
        expected_render_text = refreshed_mac_owner_payload.get("renderedOutput") or ""
        if not expected_render_text:
            raise RuntimeError(f"Unable to derive canonical Mac owner render text:\n{json.dumps(refreshed_mac_owner_payload, indent=2)}")
        assert_render_output_sane("Mac owner before takeover", expected_render_text)

        ui_test_process = subprocess.Popen(
            ui_test_command,
            cwd=repo_root,
            stdout=ui_test_output,
            stderr=subprocess.STDOUT,
            text=True,
            env=os.environ | {"SPACES_MOBILE_UI_TEST_CONFIG_PATH": str(ui_test_config)},
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
        if ui_test_process is not None and ui_test_process.poll() is None:
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

fixture_command = "\n".join(
    [
        "python3 - <<'PY'",
        "import random",
        "import string",
        "import sys",
        f"line_count = {line_count}",
        "width = 32",
        "rng = random.Random(7)",
        "alphabet = string.ascii_letters + string.digits",
        (
            "print("
            "f'FIXTURE_START mode=lines lines={line_count} frames=300 rows=24 width={width} seed=7', "
            "flush=True)"
        ),
        "for seq in range(1, line_count + 1):",
        "    payload = ''.join(rng.choice(alphabet) for _ in range(max(width, 1)))",
        "    print(f'SEQ {seq:08d} {payload}')",
        "    if seq % 100 == 0:",
        "        sys.stdout.flush()",
        "sys.stdout.flush()",
        "print(f'FIXTURE_DONE mode=lines emitted={line_count}', flush=True)",
        "PY",
    ]
)

def current_owner_client_id() -> str:
    root_directory = os.path.normpath(str(runtime_root / "terminal" / "sessions" / session_id))
    deadline = time.time() + 30
    rows = []
    while time.time() < deadline:
        with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
            rows = db.execute(
                """
                SELECT client_id, mode, detached_at
                FROM terminal_attachments
                WHERE root_directory = ?
                ORDER BY attached_at DESC
                """,
                (root_directory,),
            ).fetchall()
        for client_id, mode, detached_at in rows:
            if client_id and mode == "owner" and detached_at is None:
                return client_id
        time.sleep(0.1)
    raise RuntimeError(f"No active owner attachment was found for the demo session. rows={rows!r}")

def send_request(request: dict) -> dict:
    command = [
        str(spacese2e),
        "terminal-service-control",
        "--session-id",
        session_id,
        "--command",
        request["command"],
    ]
    if request.get("clientID") is not None:
        command.extend(["--client-id", request["clientID"]])
    if request.get("text") is not None:
        command.extend(["--text", request["text"]])
    if request.get("key") is not None:
        command.extend(["--key", request["key"]])
    completed = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
    return json.loads(completed.stdout)

def wait_for_owner_control_ready(owner_client_id: str) -> None:
    deadline = time.time() + 15
    last_response = None
    while time.time() < deadline:
        response = send_request(
            {"command": "send", "text": "", "clientID": owner_client_id}
        )
        last_response = response
        message = response.get("message", "")
        if response.get("ok"):
            return
        if "Only the active owner" in message:
            time.sleep(0.1)
            continue
        raise RuntimeError(f"Owner control readiness probe failed: {response}")
    raise RuntimeError(f"Timed out waiting for owner control readiness. last_response={last_response!r}")

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
wait_for_owner_control_ready(owner_client_id)
for request in (
    {"command": "send", "text": fixture_command, "clientID": owner_client_id},
    {"command": "key", "key": "enter", "clientID": owner_client_id},
):
    response = send_request(request)
    if not response.get("ok"):
        raise RuntimeError(f"Fixture launch request failed: {response}")

final_sequence = f"SEQ {line_count:08d}"
done_marker = f"FIXTURE_DONE mode=lines emitted={line_count}"

def rendered_fixture_complete(rendered_output: str) -> bool:
    if final_sequence not in rendered_output:
        return False
    if done_marker in rendered_output:
        return True
    saw_final_sequence = False
    for line in rendered_output.splitlines():
        if final_sequence in line:
            saw_final_sequence = True
            continue
        if saw_final_sequence and line.strip().endswith(("%", "$", "#")):
            return True
    return False

deadline = time.time() + 60
while time.time() < deadline:
    rendered_output = dump_owner_window().get("renderedOutput") or ""
    if rendered_fixture_complete(rendered_output):
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
final_sequence = f"SEQ {fixture_line_count:08d}"
done_marker = f"FIXTURE_DONE mode=lines emitted={fixture_line_count}"

def rendered_fixture_complete(rendered_output: str) -> bool:
    if final_sequence not in rendered_output:
        return False
    if done_marker in rendered_output:
        return True
    saw_final_sequence = False
    for line in rendered_output.splitlines():
        if final_sequence in line:
            saw_final_sequence = True
            continue
        if saw_final_sequence and line.strip().endswith(("%", "$", "#")):
            return True
    return False

if not rendered_fixture_complete(owner_text):
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

run_mouse_reporting_scroll_scenario() {
  begin_scenario "mouse-reporting-scroll"
  [[ "$CURRENT_TARGET" == "local" ]] || fail "Mouse-reporting mobile scroll E2E currently requires the local macOS Ghostty daemon."

  local probe_script="$SCENARIO_DIR/mouse-reporting-scroll.py"
  local probe_output="$SCENARIO_DIR/mouse-reporting-input.bin"
  python3 - "$probe_script" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
    """
import os
import re
import select
import sys
import termios
import time
import tty

fd = sys.stdin.fileno()
previous = termios.tcgetattr(fd)
captured = bytearray()
deadline = time.time() + 45
try:
    tty.setraw(fd)
    os.write(sys.stdout.fileno(), b"\\x1b[?1000h\\x1b[?1006hMOUSE_SCROLL_READY\\r\\n")
    while time.time() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.25)
        if not readable:
            continue
        captured.extend(os.read(fd, 128))
        if re.search(rb"\\x1b\\[<(64|65);[0-9]+;[0-9]+M", captured):
            break
finally:
    with open(sys.argv[1], "wb") as output:
        output.write(captured)
    termios.tcsetattr(fd, termios.TCSADRAIN, previous)
""".lstrip()
)
PY

  local command_text session_id output_log
  command_text="$(
    python3 - "$probe_script" "$probe_output" <<'PY'
import shlex
import sys
print(f"/usr/bin/python3 {shlex.quote(sys.argv[1])} {shlex.quote(sys.argv[2])}")
PY
  )"
  session_id="$(new_terminal_session "e2e-mouse-reporting-scroll" "$command_text")"
  track_current_scenario_session "$session_id"
  output_log="$(session_output_path "$session_id")"

  if ! python3 - "$output_log" <<'PY'
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
deadline = time.time() + 30
while time.time() < deadline:
    if path.exists() and b"MOUSE_SCROLL_READY" in path.read_bytes():
        raise SystemExit(0)
    time.sleep(0.1)
raise SystemExit("Timed out waiting for the mouse-reporting fixture to become ready.")
PY
  then
    fail "Mouse-reporting fixture did not become ready."
  fi

  write_ui_test_config "mouse-reporting-scroll" "$session_id"
  reset_mobile_app
  if ! SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
    xcodebuild \
      -project "$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj" \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$MOBILE_UDID" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      -only-testing:SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverFromList \
      test-without-building >"$UI_TEST_LOG" 2>&1
  then
    fail "Mouse-reporting scroll UI test failed."
  fi

  if ! python3 - "$probe_output" "$UI_TEST_CONFIG" "$MOBILE_DEVICE_LABEL" <<'PY'
import json
import re
import sys
import time
from pathlib import Path

probe_output = Path(sys.argv[1])
config = json.loads(Path(sys.argv[2]).read_text())
mobile_device_label = sys.argv[3]
event_log = Path(config["eventLogPath"])
deadline = time.time() + 10
while time.time() < deadline:
    if probe_output.exists():
        captured = probe_output.read_bytes()
        match = re.search(rb"\x1b\[<(64|65);([0-9]+);([0-9]+)M", captured)
        if match:
            column = int(match.group(2))
            row = int(match.group(3))
            if column < 1 or row < 1:
                raise SystemExit(f"Invalid application mouse coordinates: column={column} row={row}")
            break
    time.sleep(0.1)
else:
    captured = probe_output.read_bytes() if probe_output.exists() else b""
    raise SystemExit(f"{mobile_device_label} swipe did not reach the mouse-reporting terminal application: {captured!r}")

events = []
if event_log.exists():
    events = [json.loads(line) for line in event_log.read_text().splitlines() if line.strip()]
if not any(event.get("kind") == "e2e_scroll_gesture_applied" for event in events):
    raise SystemExit(f"{mobile_device_label} UI test did not record an applied terminal scroll gesture.")
PY
  then
    fail "Mouse-reporting scroll event validation failed."
  fi

  printf 'Mobile scenario passed: mouse-reporting-scroll\n'
}

write_terminal_link_preview_fixture() {
  local image_base64="iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAMElEQVR42mP4T2PAQCcLGKqoj0YtGLVg1IJRC0YtGLVg1IJRC0YtGLWAHAuGcOsaABQNUCo17017AAAAAElFTkSuQmCC"
  python3 - "$TERMINAL_LINK_PREVIEW_PATH" "$image_base64" <<'PY'
import base64
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_bytes(base64.b64decode(sys.argv[2]))
PY

}

run_terminal_link_preview_scenario() {
  begin_scenario "terminal-link-preview"
  write_terminal_link_preview_fixture
  local command_text
  local quoted_link_path
  printf -v quoted_link_path '%q' "$TERMINAL_LINK_PREVIEW_PATH"
  command_text="printf '__spaces_mobile_link_preview__\\n%s\\n' $quoted_link_path; exec /bin/bash -l"
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
  session_id="$(new_terminal_session "e2e-two-session-primary")"
  track_current_scenario_session "$session_id"
  secondary_session_id="$(new_terminal_session "e2e-two-session-secondary")"
  track_current_scenario_session "$secondary_session_id"
  write_ui_test_config "two-session" "$session_id" "$secondary_session_id"
  run_ui_test "SpacesMobileUITests/SpacesMobileUITests/testTerminalTakeOverAcrossTwoSessionsFromList"
  printf 'Mobile scenario passed: two-session\n'
}

assert_ctrl_c_final_frame_scenario() {
  local session_id="$1"
  local secondary_session_id="$2"
  local expected_service_pid="$3"
  python3 - "$DEMO_ROOT" "$SCENARIO_DIR" "$UI_TEST_CONFIG" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$session_id" "$secondary_session_id" "$expected_service_pid" "$DEVICE_API_HOST" "$DEVICE_API_PORT" "$BUNDLE_ID" "$MOBILE_DEVICE_KEY" "$MOBILE_DEVICE_NAME" "$MOBILE_DEVICE_LABEL" "$CURRENT_TARGET" <<'PY'
import json
import os
import shlex
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
device_api_host = sys.argv[9]
device_api_port = int(sys.argv[10])
bundle_id = sys.argv[11]
mobile_device_key = sys.argv[12]
mobile_device_name = sys.argv[13]
mobile_device_label = sys.argv[14]
current_target = sys.argv[15]
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

def typed_device_request(request: dict) -> dict:
    command = request.get("command")
    if isinstance(command, dict):
        return request
    payload = {key: value for key, value in request.items() if key != "command"}
    if command in {"attach", "detach", "heartbeat", "takeover", "send", "key", "clear", "clearScreen", "resize", "scroll"}:
        payload["action"] = "clearScreen" if command == "clear" else command
        payload.setdefault("appendNewline", False)
        payload.setdefault("asPaste", False)
        return {"command": {"terminalControl": payload}}
    return {"command": {command: payload}}

def send_mobile_request(request: dict, attempts: int = 3) -> dict:
    request = typed_device_request(request)
    command = [
        str(spacese2e),
        "mobile-request",
        "--host",
        device_api_host,
        "--port",
        str(device_api_port),
        "--certificate-fingerprint=" + pairing["certificateFingerprint"],
        "--request-json",
        json.dumps({"authToken": pairing["authToken"], "clientApp": client_app, **request}),
    ]
    last_detail = ""
    for attempt in range(1, attempts + 1):
        completed = subprocess.run(command, capture_output=True, text=True, env=env, timeout=20)
        if completed.returncode == 0:
            try:
                return json.loads(completed.stdout)
            except json.JSONDecodeError as error:
                last_detail = f"attempt {attempt}: invalid JSON: {error}\nstdout={completed.stdout}\nstderr={completed.stderr}"
        else:
            last_detail = (
                f"attempt {attempt}: exit={completed.returncode}\nstdout={completed.stdout}\nstderr={completed.stderr}"
            )
        time.sleep(1)
    raise RuntimeError(f"Device API request failed after {attempts} attempts: {request}\n{last_detail}")

def terminal_tail(session: str) -> str:
    output_path = runtime_root / "terminal" / "sessions" / session / "output.log"
    if output_path.exists():
        return output_path.read_text(errors="replace")
    completed = subprocess.run(
        [str(spaces_cli), "terminal", "tail", session],
        capture_output=True,
        text=True,
        env=env,
        timeout=20,
    )
    require(
        completed.returncode == 0,
        f"Failed to read terminal output for {session}: stdout={completed.stdout}\nstderr={completed.stderr}",
    )
    return completed.stdout

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
    # The row stores the payload plus `has_final_render`, the flag every device-overview build reads
    # to answer "can this ended pane replay?" without decoding the payload. The emitting reason lives
    # inside the payload itself.
    persisted_final = db.execute(
        "SELECT payload_json, has_final_render FROM terminal_remote_session_states WHERE session_id = ?",
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
persisted_final_payload = json.loads(persisted_final[0])
require(
    persisted_final_payload.get("reason") == "terminated",
    f"Persisted final payload reason was not terminated: {persisted_final_payload.get('reason')!r}",
)
require(bool(persisted_final_payload.get("renderUpdate")), "Persisted final payload did not include an encoded render update.")
require(
    persisted_final[1] == 1,
    f"Persisted final payload was not flagged as carrying a replayable frame: has_final_render={persisted_final[1]!r}",
)

overview_response = send_mobile_request({"command": "overview"})
require(overview_response.get("ok"), f"Device API overview failed after ctrl+c: {overview_response}")
overview_sessions = ((overview_response.get("result") or {}).get("overview") or {}).get("sessions", [])
require(
    any(session.get("id") == secondary_session_id for session in overview_sessions),
    f"Device API overview did not include the surviving session after ctrl+c: {json.dumps(overview_response, indent=2)}",
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

if expected_secondary_text:
    secondary_output = terminal_tail(secondary_session_id)
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
  python3 - "$DEMO_ROOT" "$session_id" "$DEVICE_API_HOST" "$DEVICE_API_PORT" "$SPACES_CLI_BIN" "$SPACES_E2E_BIN" "$SCENARIO_DIR" "$BUNDLE_ID" "$MOBILE_DEVICE_KEY" "$MOBILE_DEVICE_NAME" "$MOBILE_DEVICE_LABEL" <<'PY'
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
device_api_host = sys.argv[3]
device_api_port = int(sys.argv[4])
spaces_cli = Path(sys.argv[5])
spacese2e = Path(sys.argv[6])
scenario_dir = Path(sys.argv[7])
bundle_id = sys.argv[8]
mobile_device_key = sys.argv[9]
mobile_device_name = sys.argv[10]
mobile_device_label = sys.argv[11]
runtime_root = demo_root / "runtime"
output_log_path = runtime_root / "terminal" / "sessions" / session_id / "output.log"
performance_log_path = demo_root / "mobile-terminal-performance.jsonl"
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

def typed_device_request(request: dict) -> dict:
    command = request.get("command")
    if isinstance(command, dict):
        return request
    payload = {key: value for key, value in request.items() if key != "command"}
    if command in {"attach", "detach", "heartbeat", "takeover", "send", "key", "clear", "clearScreen", "resize", "scroll"}:
        payload["action"] = "clearScreen" if command == "clear" else command
        payload.setdefault("appendNewline", False)
        payload.setdefault("asPaste", False)
        return {"command": {"terminalControl": payload}}
    return {"command": {command: payload}}

def send_mobile_request(request: dict) -> dict:
    request = typed_device_request(request)
    completed = subprocess.run(
        [
            str(spacese2e),
            "mobile-request",
            "--host",
            device_api_host,
            "--port",
            str(device_api_port),
            "--certificate-fingerprint=" + pairing["certificateFingerprint"],
            "--request-json",
            json.dumps({"authToken": pairing["authToken"], "clientApp": client_app, **request}),
        ],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    return json.loads(completed.stdout)

def send_terminal_control(command: list[str]) -> dict:
    completed = subprocess.run(command, capture_output=True, text=True, env=env, check=True)
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

def wait_for_registered_client(client_id: str, timeout: float = 10) -> None:
    deadline = time.time() + timeout
    last_snapshot = ""
    root_directory = os.path.normpath(str(runtime_root / "terminal" / "sessions" / session_id))
    while time.time() < deadline:
        with sqlite3.connect(env["SPACES_DB_PATH"]) as db:
            rows = db.execute(
                """
                SELECT client_id, kind, disconnected_at
                FROM terminal_clients
                WHERE root_directory = ?
                  AND client_id = ?
                """,
                (root_directory, client_id),
            ).fetchall()
        last_snapshot = repr(rows)
        if any(row[0] == client_id and row[2] is None for row in rows):
            return
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for registered client {client_id}.\n{last_snapshot}")

def wait_for_attachment_activity_quiet(timeout: float = 8, quiet_for: float = 1) -> None:
    deadline = time.time() + timeout
    last_count = -1
    quiet_since = time.time()
    seen = False
    while time.time() < deadline:
        count = 0
        if performance_log_path.exists():
            for line in performance_log_path.read_text(errors="replace").splitlines():
                if session_id in line and '"reason":"attachment_state"' in line:
                    count += 1
                    seen = True
        now = time.time()
        if count != last_count:
            last_count = count
            quiet_since = now
        elif seen and now - quiet_since >= quiet_for:
            return
        time.sleep(0.1)

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
wait_for_attachment_activity_quiet(timeout=8, quiet_for=1)
attach = send_terminal_control([
    str(spacese2e),
    "terminal-service-control",
    "--session-id",
    session_id,
    "--command",
    "attach",
    "--direct-control",
    "--client-id",
    mobile_client["id"],
    "--client-kind",
    mobile_client["kind"],
    "--client-label",
    mobile_client["identity"]["label"],
    "--client-device-name",
    mobile_client["identity"]["deviceName"],
    "--client-network-address",
    mobile_client["identity"]["networkAddress"],
    "--attachment-mode",
    "viewer",
])
if not attach.get("ok"):
    raise RuntimeError(f"Viewer attach failed: {attach}")
wait_for_registered_client(mobile_client["id"], timeout=10)

blocked = send_mobile_request({
    "command": "send",
    "sessionID": session_id,
    "text": "echo __ownership_viewer_blocked__",
    "appendNewline": True,
    "clientID": mobile_client["id"],
})
if blocked.get("ok"):
    raise RuntimeError(f"Viewer input should have been rejected: {blocked}")
if "Only the active owner" not in blocked.get("message", ""):
    raise RuntimeError(f"Viewer input was not rejected by ownership guard: {blocked}")

takeover = send_mobile_request({"command": "takeover", "sessionID": session_id, "clientID": mobile_client["id"]})
if not takeover.get("ok"):
    raise RuntimeError(f"Mobile takeover failed: {takeover}")
owner_after_takeover = active_owner(excluded={initial_owner}, timeout=20)
if owner_after_takeover != mobile_client["id"]:
    raise RuntimeError(f"Expected device client to own the session, found {owner_after_takeover}")

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

demo_project_id() {
  local project_dir="$1"
  local listing="$SCENARIO_DIR/project-list.txt"
  demo_env "$SPACES_CLI_BIN" project list >"$listing" 2>>"$SCENARIO_LOG" || return 1
  python3 - "$listing" "$project_dir" <<'PY'
import os
import sys

listing = open(sys.argv[1], encoding="utf-8").read().splitlines()
wanted = os.path.realpath(sys.argv[2])
for line in listing:
    fields = line.split("\t")
    if not fields or not fields[0]:
        continue
    directory = ""
    for field in fields[1:]:
        if field.startswith("dir="):
            directory = field[4:]
    if directory and os.path.realpath(directory) == wanted:
        print(fields[0])
        break
else:
    raise SystemExit(f"No Spaces project registered for {wanted}. Listing:\n" + "\n".join(listing))
PY
}

# Prints "<id>\t<branch>" for every workspace of the project whose branch carries the given prefix.
demo_workspaces_with_branch_prefix() {
  local project_id="$1"
  local prefix="$2"
  local listing="$SCENARIO_DIR/workspace-list.txt"
  demo_env "$SPACES_CLI_BIN" workspace list --project "$project_id" >"$listing" 2>>"$SCENARIO_LOG" || return 1
  python3 - "$listing" "$prefix" "$DB_PATH" <<'PY'
import sqlite3
import sys

listing = open(sys.argv[1], encoding="utf-8").read().splitlines()
prefix = sys.argv[2]
# `workspace list` does not report hidden state, and a hidden workspace has no band in the Spaces
# list, so it cannot be the target of a swipe.
with sqlite3.connect(sys.argv[3]) as db:
    hidden = {row[0] for row in db.execute("SELECT id FROM workspaces WHERE is_hidden = 1")}
for line in listing:
    fields = line.split("\t")
    if not fields or not fields[0] or fields[0] in hidden:
        continue
    branch = ""
    for field in fields[1:]:
        if field.startswith("branch="):
            branch = field[7:]
    if branch.startswith(prefix):
        print(f"{fields[0]}\t{branch}")
PY
}

# Regression lane for removing a workspace while the Spaces list is being scrolled: its rows are diffed
# out from under a moving collection view, which must stay a consistent batch update. Populates the
# project with extra workspaces so the list is long enough to scroll, starts the target so the daemon's
# stop-then-remove takes real time, then drives the swipe -> Delete/Hide -> confirm -> keep scrolling
# flow from the simulator and verifies the workspace really was removed or hidden.
run_workspace_removal_scroll_scenario() {
  local scenario="$1"
  local action="delete"
  local ui_test_name="SpacesMobileUITests/SpacesMobileUITests/testWorkspaceDeleteWhileScrollingList"
  if [[ "$scenario" == "workspace-hide-scroll" ]]; then
    action="hide"
    ui_test_name="SpacesMobileUITests/SpacesMobileUITests/testWorkspaceHideWhileScrollingList"
  fi
  begin_scenario "$scenario"

  local project_id
  project_id="$(demo_project_id "$PROJECT_DIR")" || fail "Unable to resolve the demo project for $PROJECT_DIR."
  printf 'Removal-scroll project: %s (%s)\n' "$project_id" "$PROJECT_DIR" >>"$SCENARIO_LOG"

  local branch_prefix="e2e-removal-scroll-"
  local existing_count
  existing_count="$(demo_workspaces_with_branch_prefix "$project_id" "$branch_prefix" | wc -l | tr -d ' ')"
  local wanted=4
  local stamp
  stamp="$(date +%s)"
  local index=0
  while (( existing_count + index < wanted )); do
    index=$((index + 1))
    demo_env "$SPACES_CLI_BIN" workspace create --project "$project_id" --branch "${branch_prefix}${stamp}-${index}" >>"$SCENARIO_LOG" 2>&1 \
      || fail "Failed to create removal-scroll workspace ${branch_prefix}${stamp}-${index}."
  done

  local target_workspace_id
  target_workspace_id="$(demo_workspaces_with_branch_prefix "$project_id" "$branch_prefix" | head -1 | cut -f1)"
  [[ -n "$target_workspace_id" ]] || fail "No removal-scroll workspace was available to remove."
  printf 'Removal target workspace: %s\n' "$target_workspace_id" >>"$SCENARIO_LOG"

  # A running workspace makes the daemon's stop-then-remove path take seconds, so the removal lands
  # well inside the scroll window rather than before the list has started moving.
  demo_env "$SPACES_CLI_BIN" workspace start --workspace "$target_workspace_id" >>"$SCENARIO_LOG" 2>&1 \
    || fail "Failed to start removal-scroll workspace $target_workspace_id."

  local session_id
  session_id="$(new_terminal_session "e2e-$scenario")"
  track_current_scenario_session "$session_id"
  export SPACES_MOBILE_E2E_TARGET_WORKSPACE_ID="$target_workspace_id"
  write_ui_test_config "$scenario" "$session_id"
  MOBILE_APP_LAUNCH_MODE="console-capture"
  run_ui_test "$ui_test_name"
  MOBILE_APP_LAUNCH_MODE="default"

  if [[ "$action" == "delete" ]]; then
    local post_listing="$SCENARIO_DIR/workspace-list-after-delete.txt"
    demo_env "$SPACES_CLI_BIN" workspace list --project "$project_id" >"$post_listing" 2>>"$SCENARIO_LOG" \
      || fail "Unable to list workspaces after the delete."
    python3 - "$post_listing" "$target_workspace_id" <<'PY' || fail "Workspace $target_workspace_id still exists after the delete."
import sys

workspace_id = sys.argv[2]
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if line.split("\t")[0] == workspace_id:
        raise SystemExit(f"Workspace {workspace_id} still exists after the delete.")
PY
  else
    python3 - "$DB_PATH" "$target_workspace_id" <<'PY' || fail "Workspace $target_workspace_id is not hidden after the hide."
import sqlite3
import sys

db_path, workspace_id = sys.argv[1:3]
with sqlite3.connect(db_path) as db:
    row = db.execute("SELECT is_hidden FROM workspaces WHERE id = ?", (workspace_id,)).fetchone()
if row is None:
    raise SystemExit(f"Workspace {workspace_id} not found after the hide.")
if row[0] != 1:
    raise SystemExit(f"Workspace {workspace_id} is not hidden after the hide (is_hidden={row[0]}).")
PY
  fi
  printf 'Mobile scenario passed: %s\n' "$scenario"
}

# Prints the workspace id whose directory is `$1`.
demo_workspace_id_for_dir() {
  python3 - "$DB_PATH" "$1" <<'PY'
import os
import sqlite3
import sys

db_path, wanted = sys.argv[1], os.path.realpath(sys.argv[2])
with sqlite3.connect(db_path) as db:
    for workspace_id, directory in db.execute("SELECT id, dir FROM workspaces"):
        if directory and os.path.realpath(directory) == wanted:
            print(workspace_id)
            break
    else:
        raise SystemExit(f"No workspace registered for {wanted}.")
PY
}

# Regression lane for the other way the Spaces list loses a row: a terminal session ends and its runtime
# row drops out from under a workspace band that stays listed. The session is ended from the daemon side
# on a delay so the removal lands while the simulator is mid-scroll, which is when the list's batch update
# has to stay consistent.
run_session_end_scroll_scenario() {
  begin_scenario "session-end-scroll"

  local project_id
  project_id="$(demo_project_id "$PROJECT_DIR")" || fail "Unable to resolve the demo project for $PROJECT_DIR."
  local branch_prefix="e2e-removal-scroll-"
  local existing_count
  existing_count="$(demo_workspaces_with_branch_prefix "$project_id" "$branch_prefix" | wc -l | tr -d ' ')"
  local stamp
  stamp="$(date +%s)"
  local index=0
  # The list has to be long enough that scrolling it means something.
  while (( existing_count + index < 4 )); do
    index=$((index + 1))
    demo_env "$SPACES_CLI_BIN" workspace create --project "$project_id" --branch "${branch_prefix}${stamp}-${index}" >>"$SCENARIO_LOG" 2>&1       || fail "Failed to create session-end workspace ${branch_prefix}${stamp}-${index}."
  done

  local target_workspace_id
  target_workspace_id="$(demo_workspace_id_for_dir "$PROJECT_DIR")" || fail "Unable to resolve the workspace owning $PROJECT_DIR."
  printf 'Session-end target workspace: %s
' "$target_workspace_id" >>"$SCENARIO_LOG"

  local session_id
  session_id="$(new_terminal_session "e2e-session-end-scroll")"
  printf 'Session-end target session: %s
' "$session_id" >>"$SCENARIO_LOG"
  export SPACES_MOBILE_E2E_TARGET_WORKSPACE_ID="$target_workspace_id"
  write_ui_test_config "session-end-scroll" "$session_id"

  # Ends the session while the UI test is already scrolling: the app needs time to launch, pair and
  # render the list first, and the test scrolls until the row goes or its own timeout expires.
  (
    sleep 30
    demo_env "$SPACES_E2E_BIN" terminate-terminal-session "$session_id" >>"$SCENARIO_LOG" 2>&1 || true
  ) &
  local terminator_pid=$!

  MOBILE_APP_LAUNCH_MODE="console-capture"
  run_ui_test "SpacesMobileUITests/SpacesMobileUITests/testTerminalRowRemovedWhileScrollingList"
  MOBILE_APP_LAUNCH_MODE="default"
  wait "$terminator_pid" 2>/dev/null || true

  # No database assertion here: ending a session stops it but leaves its record until the daemon
  # collects it, so the record says nothing about what the list did. What matters is what the UI test
  # already asserted — the row left the list while its workspace band stayed, and the app survived
  # the scroll.
  printf 'Mobile scenario passed: session-end-scroll\n'
}

run_selected_scenarios() {
  local scenario
  for scenario in "${SELECTED_SCENARIOS[@]}"; do
    local started_ms duration_ms
    started_ms="$(timestamp_ms)"
    case "$scenario" in
      takeover)
        run_takeover_scenario
        ;;
      codex|codex-resume-reopen)
        run_codex_scenario "$scenario"
        ;;
      roundtrip)
        run_roundtrip_scenario
        ;;
      scrollback)
        run_scrollback_scenario
        ;;
      mouse-reporting-scroll)
        run_mouse_reporting_scroll_scenario
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
      workspace-delete-scroll|workspace-hide-scroll)
        run_workspace_removal_scroll_scenario "$scenario"
        ;;
      session-end-scroll)
        run_session_end_scroll_scenario
        ;;
      *)
        fail "unknown scenario: $scenario"
        ;;
    esac
    duration_ms="$(( $(timestamp_ms) - started_ms ))"
    record_scenario_result "PASS" "$CURRENT_TARGET" "$scenario" "$duration_ms"
    cleanup_current_scenario_sessions
  done
}

run_remote_ui_scenarios() {
  local scenario
  local ran=0
  for scenario in "${REMOTE_UI_SCENARIOS[@]}"; do
    if [[ " ${SELECTED_SCENARIOS[*]} " != *" $scenario "* ]]; then
      continue
    fi
    local started_ms duration_ms
    started_ms="$(timestamp_ms)"
    case "$scenario" in
      takeover)
        run_takeover_scenario
        ;;
      two-session)
        run_two_session_scenario
        ;;
      *)
        fail "unknown remote UI scenario: $scenario"
        ;;
    esac
    duration_ms="$(( $(timestamp_ms) - started_ms ))"
    record_scenario_result "PASS" "$CURRENT_TARGET" "$scenario" "$duration_ms"
    cleanup_current_scenario_sessions
    ran=1
  done
  if (( ran == 0 )); then
    printf 'No selected mobile scenarios have a remote UI parity path.\n'
  fi
}

parse_args "$@"
case "$MOBILE_DEVICE_KEY" in
  iphone|ipad)
    ;;
  *)
    fail "SPACES_MOBILE_E2E_DEVICE_KEY must be iphone or ipad, got: $MOBILE_DEVICE_KEY"
    ;;
esac
if [[ "${SPACES_E2E_RUN_REMOTE:-0}" == "1" ]]; then
  spaces_e2e_require_remote_host_env "$ROOT_DIR"
fi
SUITE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-mobile-e2e.XXXXXX")"
SCENARIO_RESULTS_LOG="$SUITE_ROOT/scenario-results.tsv"
MOBILE_UDID="$(resolve_simulator_udid "$MOBILE_DEVICE_NAME")"
build_macos_debug_products
if [[ "${SPACES_E2E_RUN_REMOTE:-0}" == "1" ]]; then
  run_remote_device_e2e
fi
build_ios_for_testing "$MOBILE_UDID"
start_demo
run_local_device_api_parity
case "$MOBILE_DEVICE_KEY" in
  iphone) MOBILE_UDID="$IPHONE_UDID" ;;
  ipad) MOBILE_UDID="$IPAD_UDID" ;;
esac
configure_target "local"
run_selected_scenarios
if [[ "${SPACES_E2E_RUN_REMOTE:-0}" == "1" ]]; then
  configure_target "remote"
  run_remote_ui_scenarios
fi

if [[ "${SPACES_E2E_RUN_REMOTE:-0}" == "1" ]]; then
  printf '\nMobile E2E passed: scenarios=%s targets=local,remote-device-api,remote-ui\n' "${SELECTED_SCENARIOS[*]}"
else
  printf '\nMobile E2E passed: scenarios=%s targets=local\n' "${SELECTED_SCENARIOS[*]}"
fi
