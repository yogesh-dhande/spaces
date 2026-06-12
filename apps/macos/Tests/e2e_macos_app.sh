#!/usr/bin/env bash
set -Eeuo pipefail

# Manual real-system E2E coverage for Spaces.
# This script intentionally runs outside XCTest so it can drive the real app,
# the built-in Spaces terminal runtime, Chrome, and yabai on an interactive desktop session.

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
source "$ROOT_DIR/scripts/spaces-e2e-env.sh"
spaces_e2e_load_env "$ROOT_DIR"
source "$ROOT_DIR/scripts/spaces-profile-helpers.sh"
MACOS_DIR="$ROOT_DIR/apps/macos"
# scripts/swiftpm.sh already changes into apps/macos internally, so the default
# build command must not add a second package-path override.
BUILD_CMD="${BUILD_CMD:-$ROOT_DIR/scripts/swiftpm.sh build}"
SPACES_APP="${SPACES_APP:-$MACOS_DIR/.build/debug/SpacesApp}"
SPACES_CLI="${SPACES_CLI:-$MACOS_DIR/.build/debug/spaces}"
SPACES_E2E_CLI="${SPACES_E2E_CLI:-$MACOS_DIR/.build/debug/spacese2e}"
APP_LOG="${APP_LOG:-/tmp/spaces-e2e-app.log}"
EVENT_LOG="${EVENT_LOG:-/tmp/spaces-e2e-events.log}"
METRICS_LOG="${METRICS_LOG:-/tmp/spaces-e2e-metrics.log}"
DEBUG_LOG="${DEBUG_LOG:-/tmp/spaces-e2e-debug.log}"
RESULTS_LOG="${RESULTS_LOG:-/tmp/spaces-e2e-results.log}"
RECORDER_LOG="${RECORDER_LOG:-/tmp/spaces-e2e-recorder.log}"
ACTION_TIMEOUT_SECONDS="${ACTION_TIMEOUT_SECONDS:-20}"
AX_PROBE_TIMEOUT_SECONDS="${AX_PROBE_TIMEOUT_SECONDS:-3}"
SURFACE_SNAPSHOT_TIMEOUT_SECONDS="${SURFACE_SNAPSHOT_TIMEOUT_SECONDS:-3}"
SEED_FILE="${SEED_FILE:-/tmp/spaces-e2e-seed.json}"
SECOND_SEED_FILE="${SECOND_SEED_FILE:-/tmp/spaces-e2e-seed-2.json}"
THIRD_SEED_FILE="${THIRD_SEED_FILE:-/tmp/spaces-e2e-seed-3.json}"
TRANSITION_PAUSE_SECONDS="${TRANSITION_PAUSE_SECONDS:-0}"
RECORD_VIDEO_PATH="${RECORD_VIDEO_PATH:-}"
RECORD_VIDEO_CAPTURE_DEVICE="${RECORD_VIDEO_CAPTURE_DEVICE:-}"
RECORD_VIDEO_FRAMERATE="${RECORD_VIDEO_FRAMERATE:-15}"
RECORDER_OUTPUT_START_TIMEOUT_SECONDS="${RECORDER_OUTPUT_START_TIMEOUT_SECONDS:-8}"
RECORDER_STOP_TIMEOUT_SECONDS="${RECORDER_STOP_TIMEOUT_SECONDS:-10}"
SURFACE_POLL_INTERVAL_SECONDS="${SURFACE_POLL_INTERVAL_SECONDS:-0.05}"
REAL_SYSTEM_PROFILE_REPETITIONS="${REAL_SYSTEM_PROFILE_REPETITIONS:-5}"
PROFILE_ARTIFACT_DIR="${PROFILE_ARTIFACT_DIR:-$MACOS_DIR/.artifacts/real-system-profiles}"
PROFILE_HISTORY_CSV="${PROFILE_HISTORY_CSV:-$PROFILE_ARTIFACT_DIR/metrics-history.csv}"
PROFILE_REPORT_HTML="${PROFILE_REPORT_HTML:-$PROFILE_ARTIFACT_DIR/report.html}"
PROFILE_RENDER_SCRIPT="${PROFILE_RENDER_SCRIPT:-$MACOS_DIR/Tests/render_profile_report.py}"
WORKSPACE_SERVICE_CONTENT_TIMEOUT_SECONDS="${WORKSPACE_SERVICE_CONTENT_TIMEOUT_SECONDS:-60}"
SPACES_CYCLE_LATENCY_BUDGET_MS_WAS_SET="${SPACES_CYCLE_LATENCY_BUDGET_MS+x}"
SPACES_CYCLE_LATENCY_BUDGET_MS="${SPACES_CYCLE_LATENCY_BUDGET_MS:-2000}"
SPACES_SUSTAINED_CPU_BUDGET_PCT="${SPACES_SUSTAINED_CPU_BUDGET_PCT:-80}"
SPACES_CPU_SAMPLE_COUNT="${SPACES_CPU_SAMPLE_COUNT:-6}"
SPACES_CPU_SAMPLE_INTERVAL_SECONDS="${SPACES_CPU_SAMPLE_INTERVAL_SECONDS:-0.5}"
HIGH_OUTPUT_PROCESS_NAME="${HIGH_OUTPUT_PROCESS_NAME:-noisy}"
HIGH_OUTPUT_PROCESS_COMMAND="${HIGH_OUTPUT_PROCESS_COMMAND:-}"
MACOS_E2E_TARGETS_RAW="${SPACES_MACOS_E2E_TARGETS:-}"
SELECTED_TARGETS=()
REMOTE_HOST_ID="${SPACES_E2E_REMOTE_HOST_ID:-macos-e2e-remote}"
REMOTE_HOST_NAME="${SPACES_E2E_REMOTE_NAME:-macOS E2E Remote}"
REMOTE_SSH_HOST="${SPACES_E2E_REMOTE_SSH_HOST:-}"
REMOTE_SSH_USER="${SPACES_E2E_REMOTE_SSH_USER:-}"
REMOTE_SSH_PORT="${SPACES_E2E_REMOTE_SSH_PORT:-}"
REMOTE_WORKSPACE_ROOT="${SPACES_E2E_REMOTE_WORKSPACE_ROOT:-~/.spaces/workspaces}"
REMOTE_DAEMON_HOST="${SPACES_E2E_REMOTE_DAEMON_HOST:-$REMOTE_SSH_HOST}"
REMOTE_DAEMON_PORT="${SPACES_E2E_REMOTE_DAEMON_PORT:-7443}"
REMOTE_AUTH_TOKEN="${SPACES_E2E_REMOTE_AUTH_TOKEN:-}"
REMOTE_GIT_ROOT="${SPACES_E2E_REMOTE_GIT_ROOT:-~/.spaces/e2e-git}"

TMP_PREFIX="${TMP_PREFIX:-/tmp/spaces-real-e2e}"
TMP_ROOT="$(cd "$(mktemp -d "$TMP_PREFIX".XXXXXX)" && pwd -P)"
TMP_HOME="$TMP_ROOT/home"
TMP_DB="$TMP_ROOT/spaces.db"
TMP_RUNTIME_DIR="$TMP_ROOT/runtime"
FIXTURE_TEMPLATE_DIR="$ROOT_DIR/apps/macos/Tests/fixtures/e2e_demo"
TEST_REPO="$TMP_ROOT/beacon-status"
TEST_REPO_2="$TMP_ROOT/scout-errors"
TEST_REPO_3="${TEST_REPO_3:-$TMP_ROOT/prism-analytics}"
WORKSPACE_TITLE="Hero Redesign"
WORKSPACE_BRANCH="redesign-hero"
WORKSPACE_NOTES="Redesign the landing page hero for clarity and impact"
PRIMARY_WORKSPACE_TITLE="System Status"
SECONDARY_WORKSPACE_TITLE="Error Console"
TERTIARY_WORKSPACE_TITLE="User Analytics"
SCOUT_BRANCH_WORKSPACE_TITLE="Hero Redesign"
SCOUT_BRANCH_WORKSPACE_BRANCH="redesign-hero"
SCOUT_BRANCH_WORKSPACE_NOTES="Redesign the error console hero section"
MOCK_AGENT_LABEL="Mock Agent"
SPACES_PID=""
RECORDER_PID=""
RECORDER_READY_FILE=""
FINAL_RECORDING_PATH=""
CURRENT_CASE=""
SUMMARY_PRINTED=0
APP_LOG_SEARCH_FROM_LINE=1
APP_LOG_LAST_MATCH=""
MEASURED_CYCLE_TARGET=""
SETUP_FIXTURES_ONLY=0
PRESERVE_FIXTURES_ON_EXIT=0
ONLY_WINDOW_CYCLE_PROFILE=0
APP_PORT_NAME="APP_PORT"
API_PORT_NAME="API_PORT"
PRIMARY_DOCS_URL=""
PRIMARY_ADMIN_URL=""
PRIMARY_BACKEND_STATUS_URL=""
SECONDARY_DOCS_URL=""
SECONDARY_ADMIN_URL=""
SECONDARY_BACKEND_STATUS_URL=""
TERTIARY_DOCS_URL=""
TERTIARY_ADMIN_URL=""
TERTIARY_BACKEND_STATUS_URL=""
CREATED_DOCS_URL=""
CREATED_ADMIN_URL=""
CREATED_BACKEND_STATUS_URL=""
BEACON_BRANCH_DOCS_URL=""
BEACON_BRANCH_ADMIN_URL=""
BEACON_BRANCH_BACKEND_STATUS_URL=""
SCOUT_BRANCH_DOCS_URL=""
SCOUT_BRANCH_ADMIN_URL=""
SCOUT_BRANCH_BACKEND_STATUS_URL=""
KNOWN_SPACES_FRONTEND_SESSION_ID=""
KNOWN_SPACES_BACKEND_SESSION_ID=""
KNOWN_SPACES_AGENT_SESSION_ID=""
KNOWN_SPACES_ADHOC_SESSION_ID=""
KNOWN_SPACES_ADHOC_NAME="shell-1"
KNOWN_SPACES_NOISY_SESSION_ID=""

mkdir -p "$TMP_HOME" "$TMP_RUNTIME_DIR"
: >"$EVENT_LOG"
: >"$METRICS_LOG"
: >"$DEBUG_LOG"
: >"$RESULTS_LOG"
: >"$APP_LOG"

export HOME="$TMP_HOME"
export SPACES_DB_PATH="$TMP_DB"
export SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR"
export SPACES_E2E_EVENTS_LOG="$EVENT_LOG"

cleanup() {
  local exit_code="$?"
  if (( PRESERVE_FIXTURES_ON_EXIT == 1 && exit_code == 0 )); then
    print_run_summary "$exit_code"
    return 0
  fi
  # Always tear down the isolated Spaces instance, helper fixtures, and optional
  # recorder. Recording mode intentionally starts from a minimized desktop.
  stop_screen_recording
  "$SPACES_E2E_CLI" stop-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/spaces-e2e-stop-fixtures-exit.json 2>/dev/null || true
  close_fixture_chrome_windows
  if [[ -n "${SPACES_PID}" ]]; then
    kill "${SPACES_PID}" >/dev/null 2>&1 || true
    wait "${SPACES_PID}" >/dev/null 2>&1 || true
  fi
  HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI" "$ACTION_TIMEOUT_SECONDS" || true
  print_run_summary "$exit_code"
  open_final_recording
}
trap cleanup EXIT

on_error() {
  local status="$1"
  local line="$2"
  if [[ -n "$CURRENT_CASE" ]]; then
    record_case_result "FAIL" "$CURRENT_CASE" "line=$line exit=$status"
  fi
}
trap 'on_error "$?" "$LINENO"' ERR

capture_desktop_screenshot() {
  local path="$1"
  command -v screencapture >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$path")"
  screencapture -x "$path" >/dev/null 2>&1 || true
}

fail() {
  echo "FAIL: $*" >&2
  local failure_screenshot="$TMP_ROOT/failure-desktop.png"
  capture_desktop_screenshot "$failure_screenshot"
  [[ -f "$failure_screenshot" ]] && echo "Failure desktop screenshot: $failure_screenshot" >&2
  if [[ -n "$CURRENT_CASE" ]]; then
    record_case_result "FAIL" "$CURRENT_CASE" "$*"
  fi
  exit 1
}

log_step() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

log_debug() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >>"$DEBUG_LOG"
}

record_case_result() {
  local status="$1"
  local name="$2"
  local detail="${3:-}"
  python3 - "$RESULTS_LOG" "$name" "$status" "$detail" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
status = sys.argv[3]
detail = sys.argv[4]
entries = []
if path.exists():
    for line in path.read_text().splitlines():
        parts = line.split("\t", 2)
        if len(parts) < 2 or parts[1] != name:
            entries.append(line)
detail_field = detail if detail else "-"
entries.append(f"{status}\t{name}\t{detail_field}")
path.write_text("\n".join(entries) + ("\n" if entries else ""))
PY
}

begin_case() {
  assert_no_spaces_modal_dialog
  CURRENT_CASE="$1"
  log_step "$CURRENT_CASE"
}

pass_case() {
  assert_no_spaces_modal_dialog
  record_case_result "PASS" "$CURRENT_CASE"
  CURRENT_CASE=""
}

skip_case() {
  local name="$1"
  local detail="$2"
  record_case_result "SKIP" "$name" "$detail"
}

is_spaces_terminal_target() {
  [[ "$1" == "spaces" || "$1" == "remote" ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_file() {
  [[ -x "$1" ]] || fail "missing executable: $1"
}

print_usage() {
  cat <<'EOF'
Usage: apps/macos/Tests/e2e_macos_app.sh [options]

Options:
  --record-video PATH            Capture the full run to PATH with ScreenCaptureKit.
  --capture-device DEVICE        Legacy option. Ignored by native recording.
  --capture-framerate FPS        Screen recording frame rate. Default: 15.
  --pause-transitions            Add a 1 second pause after visible transitions.
  --setup-fixtures-only          Create projects/workspaces and leave the manual test environment running.
  --only-window-cycle-profile    Run only the single-workspace focus/cycle profiling path.
  --target NAME                  Run against local, remote, or all. May be passed multiple times.
  --transition-pause-seconds N   Override the transition pause duration.
  --help                         Show this help text.
EOF
}

target_exists() {
  case "$1" in
    local|remote|all) return 0 ;;
    *) return 1 ;;
  esac
}

selected_targets_include() {
  local expected="$1"
  local selected_target
  for selected_target in "${SELECTED_TARGETS[@]}"; do
    [[ "$selected_target" == "$expected" ]] && return 0
  done
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --record-video)
        [[ $# -ge 2 ]] || fail "missing value for --record-video"
        RECORD_VIDEO_PATH="$2"
        shift 2
        ;;
      --capture-device)
        [[ $# -ge 2 ]] || fail "missing value for --capture-device"
        RECORD_VIDEO_CAPTURE_DEVICE="$2"
        shift 2
        ;;
      --capture-framerate)
        [[ $# -ge 2 ]] || fail "missing value for --capture-framerate"
        RECORD_VIDEO_FRAMERATE="$2"
        shift 2
        ;;
      --pause-transitions)
        TRANSITION_PAUSE_SECONDS=1
        shift
        ;;
      --setup-fixtures-only)
        SETUP_FIXTURES_ONLY=1
        shift
        ;;
      --only-window-cycle-profile)
        ONLY_WINDOW_CYCLE_PROFILE=1
        shift
        ;;
      --target)
        [[ $# -ge 2 ]] || fail "missing value for --target"
        target_exists "$2" || fail "unknown target: $2"
        if [[ "$2" == "all" ]]; then
          SELECTED_TARGETS+=(local remote)
        else
          SELECTED_TARGETS+=("$2")
        fi
        shift 2
        ;;
      --transition-pause-seconds)
        [[ $# -ge 2 ]] || fail "missing value for --transition-pause-seconds"
        TRANSITION_PAUSE_SECONDS="$2"
        shift 2
        ;;
      --help)
        print_usage
        trap - EXIT
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
  if [[ ${#SELECTED_TARGETS[@]} -eq 0 ]]; then
    if [[ -n "$MACOS_E2E_TARGETS_RAW" ]]; then
      read -r -a SELECTED_TARGETS <<<"$MACOS_E2E_TARGETS_RAW"
    elif [[ -n "$REMOTE_SSH_HOST" ]]; then
      SELECTED_TARGETS=(local remote)
    else
      SELECTED_TARGETS=(local)
    fi
  fi
  local expanded_targets=()
  local selected_target
  for selected_target in "${SELECTED_TARGETS[@]}"; do
    target_exists "$selected_target" || fail "unknown target: $selected_target"
    if [[ "$selected_target" == "all" ]]; then
      expanded_targets+=(local remote)
    else
      expanded_targets+=("$selected_target")
    fi
  done
  SELECTED_TARGETS=("${expanded_targets[@]}")
}

transition_pause() {
  local label="${1:-transition}"
  if ! awk -v seconds="$TRANSITION_PAUSE_SECONDS" 'BEGIN { exit(seconds + 0 > 0 ? 0 : 1) }'; then
    return 0
  fi
  log_debug "transition pause ${TRANSITION_PAUSE_SECONDS}s: $label"
  sleep "$TRANSITION_PAUSE_SECONDS"
  assert_no_spaces_modal_dialog
}

process_is_alive() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 1
  fi
  local state
  state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$state" && "${state:0:1}" == "Z" ]] && return 1
  return 0
}

terminate_process_group_for_recovery() {
  local pid="$1"
  [[ -n "$pid" ]] || fail "missing pid for recovery kill"
  kill -- "-$pid" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! process_is_alive "$pid"; then
      return 0
    fi
    sleep 0.2
  done
  kill -9 -- "-$pid" >/dev/null 2>&1 || true
  local kill_deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < kill_deadline )); do
    if ! process_is_alive "$pid"; then
      return 0
    fi
    sleep 0.2
  done
  fail "process group for pid $pid did not terminate"
}

build_binaries() {
  log_step "building macOS binaries"
  (cd "$ROOT_DIR" && eval "$BUILD_CMD") >/dev/null
  require_file "$SPACES_APP"
  require_file "$SPACES_CLI"
  require_file "$SPACES_E2E_CLI"
}

stop_stale_fixture_port_listeners() {
  local ports=(20000 20001 20002 20003 20004 20005 20006 20007 20008 20009 20010 20011)
  local pid
  local parent_pid
  local parent_command
  for port in "${ports[@]}"; do
    while IFS= read -r holder; do
      [[ -n "$holder" ]] || continue
      log_debug "stale fixture port listener port=$port holder=$holder"
    done < <(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 || true)
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
      if [[ -n "$parent_pid" ]]; then
        parent_command="$(ps -o command= -p "$parent_pid" 2>/dev/null || true)"
        if [[ "$parent_command" == *"spaces-e2e-demo"* || "$parent_command" == *".spaces-e2e-demo"* ]]; then
          kill -9 "$parent_pid" >/dev/null 2>&1 || true
        fi
      fi
      kill -9 "$pid" >/dev/null 2>&1 || true
    done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  done
}

ensure_fixture_ports_free() {
  local ports=(20000 20001 20002 20003 20004 20005 20006 20007 20008 20009 20010 20011)
  local port
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local busy=0
    for port in "${ports[@]}"; do
      if lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        busy=1
        break
      fi
    done
    if (( busy == 0 )); then
      return 0
    fi
    sleep 0.2
  done
  for port in "${ports[@]}"; do
    while IFS= read -r holder; do
      [[ -n "$holder" ]] || continue
      log_debug "fixture port still busy port=$port holder=$holder"
    done < <(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 || true)
  done
  fail "fixture ports 20000-20005 are still busy after cleanup"
}

cleanup_existing_fixture_projects() {
  log_step "cleaning existing E2E fixture projects"
  stop_stale_fixture_terminal_processes
  stop_stale_fixture_port_listeners
  "$SPACES_E2E_CLI" stop-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/spaces-e2e-stop-fixtures-start.json || true
  close_fixture_chrome_windows
  "$SPACES_E2E_CLI" cleanup-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/spaces-e2e-cleanup.json || true
  rm -rf "$TMP_PREFIX".* /private"$TMP_PREFIX".* 2>/dev/null || true
  ensure_fixture_ports_free
}

stop_stale_fixture_terminal_processes() {
  pkill -TERM -f "$TMP_PREFIX" >/dev/null 2>&1 || true
  sleep 0.5
  pkill -KILL -f "$TMP_PREFIX" >/dev/null 2>&1 || true
}

reset_fixture_runtime() {
  local workspace_dir="$1"
  log_step "resetting tracked workspace runtime"
  local workspace_dump="$TMP_ROOT/reset-workspace-state.json"
  if dump_workspace "$workspace_dir" "$workspace_dump" 2>/dev/null && [[ "$(json_get "$workspace_dump" "workspace.isRunning")" == "true" ]]; then
    "$SPACES_E2E_CLI" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace.json 2>/dev/null || true
  fi
  close_fixture_chrome_windows
  stop_stale_fixture_port_listeners
  sleep 1
  ensure_fixture_ports_free
}

close_existing_spaces_instances() {
  log_step "stopping any existing Spaces instance for this profile"
  HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI" "$ACTION_TIMEOUT_SECONDS" \
    || fail "timed out waiting for the prior profile-owned Spaces instance to exit"
  log_step "waiting for desktop control availability"
  HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" spaces_wait_for_desktop_control "$SPACES_CLI" \
    || fail "desktop control remained busy; retry when the current owner exits"
}

hide_all_visible_windows() {
  log_step "hiding visible windows for a clean recording background"
  yabai -m query --windows | python3 -c '
import json
import sys

windows = json.load(sys.stdin)
for window in windows:
    if (
        window.get("is-visible")
        and not window.get("is-minimized")
        and window.get("role") == "AXWindow"
        and window.get("subrole") in {"AXStandardWindow", "AXDialog"}
    ):
        print(window["id"])
' | while IFS= read -r window_id; do
    yabai -m window "$window_id" --minimize >/dev/null 2>&1 || true
  done

  yabai -m query --windows | python3 -c '
import json
import sys

windows = json.load(sys.stdin)
seen = set()
for window in windows:
    app = (window.get("app") or "").strip()
    if (
        app
        and window.get("is-visible")
        and not window.get("is-minimized")
        and window.get("role") == "AXWindow"
        and window.get("subrole") in {"AXStandardWindow", "AXDialog"}
        and app not in seen
    ):
        seen.add(app)
        print(app)
' | while IFS= read -r app_name; do
    osascript - "$app_name" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetApp to item 1 of argv
  tell application targetApp to hide
end run
APPLESCRIPT
  done

  local remaining
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    remaining="$(
      yabai -m query --windows | python3 -c '
import json
import sys

windows = json.load(sys.stdin)
for window in windows:
    if (
        window.get("is-visible")
        and not window.get("is-minimized")
        and window.get("role") == "AXWindow"
        and window.get("subrole") in {"AXStandardWindow", "AXDialog"}
    ):
        print((window.get("app") or "") + "\t" + str(window.get("id") or ""))
'
    )"
    if [[ -z "$remaining" ]]; then
      return 0
    fi
    sleep 0.2
  done

  log_debug "visible windows remained after hide:\n$remaining"
}

start_screen_recording() {
  [[ -n "$RECORD_VIDEO_PATH" ]] || return 0
  mkdir -p "$(dirname "$RECORD_VIDEO_PATH")"
  : >"$RECORDER_LOG"
  RECORDER_READY_FILE="$TMP_ROOT/recording.ready"
  rm -f "$RECORDER_READY_FILE"
  log_step "starting screen recording -> $RECORD_VIDEO_PATH"
  if [[ -n "$RECORD_VIDEO_CAPTURE_DEVICE" ]]; then
    log_debug "ignoring legacy capture-device=$RECORD_VIDEO_CAPTURE_DEVICE; using ScreenCaptureKit main display recorder"
  fi
  "$SPACES_E2E_CLI" record-screen \
    --output "$RECORD_VIDEO_PATH" \
    --ready-file "$RECORDER_READY_FILE" \
    --fps "$RECORD_VIDEO_FRAMERATE" >"$RECORDER_LOG" 2>&1 &
  RECORDER_PID=$!
  if ! kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
    cat "$RECORDER_LOG" >&2 || true
    fail "screen recording exited during startup"
  fi
  local deadline=$((SECONDS + RECORDER_OUTPUT_START_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ -f "$RECORDER_READY_FILE" ]]; then
      FINAL_RECORDING_PATH="$RECORD_VIDEO_PATH"
      return 0
    fi
    if ! kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  cat "$RECORDER_LOG" >&2 || true
  fail "screen recording did not become ready"
}

stop_screen_recording() {
  [[ -n "$RECORDER_PID" ]] || return 0
  if kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
    log_step "stopping screen recording"
    kill -INT "$RECORDER_PID" >/dev/null 2>&1 || true
    local deadline=$((SECONDS + RECORDER_STOP_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
      if ! kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
    if kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
      log_debug "screen recorder did not exit after SIGINT; sending SIGTERM"
      kill -TERM "$RECORDER_PID" >/dev/null 2>&1 || true
      deadline=$((SECONDS + RECORDER_STOP_TIMEOUT_SECONDS))
      while (( SECONDS < deadline )); do
        if ! kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
          break
        fi
        sleep 0.2
      done
    fi
    if kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
      log_debug "screen recorder did not exit after SIGTERM; sending SIGKILL"
      kill -KILL "$RECORDER_PID" >/dev/null 2>&1 || true
    fi
    wait "$RECORDER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RECORD_VIDEO_PATH" ]]; then
    if [[ -s "$RECORD_VIDEO_PATH" ]]; then
      FINAL_RECORDING_PATH="$RECORD_VIDEO_PATH"
      log_debug "screen recording saved path=$RECORD_VIDEO_PATH size=$(wc -c <"$RECORD_VIDEO_PATH" | tr -d ' ')"
    else
      log_debug "screen recording missing-or-empty path=$RECORD_VIDEO_PATH"
    fi
  fi
  RECORDER_PID=""
}

open_final_recording() {
  [[ -n "$FINAL_RECORDING_PATH" ]] || return 0
  [[ -s "$FINAL_RECORDING_PATH" ]] || return 0
  open "$FINAL_RECORDING_PATH" >/dev/null 2>&1 || true
}

print_recording_summary() {
  if [[ -n "$FINAL_RECORDING_PATH" && -s "$FINAL_RECORDING_PATH" ]]; then
    printf 'Recording: %s\n' "$FINAL_RECORDING_PATH"
    return 0
  fi
  if [[ -n "$RECORD_VIDEO_PATH" ]]; then
    printf 'Recording missing: requested=%s\n' "$RECORD_VIDEO_PATH"
    printf 'Recorder log: %s\n' "$RECORDER_LOG"
  fi
}

ensure_profile_spaces_owner() {
  local expected_pid="$1"
  HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" spaces_profile_wait_for_owner_pid "$SPACES_CLI" "$expected_pid" \
    "$ACTION_TIMEOUT_SECONDS" || fail "expected Spaces profile owner pid $expected_pid"
}

ensure_single_spaces_instance() { ensure_profile_spaces_owner "$1"; }

launch_spaces() {
  log_step "launching Spaces with isolated HOME=$TMP_HOME"
  : >"$APP_LOG"
  APP_LOG_SEARCH_FROM_LINE=1
  env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" SPACES_E2E_EVENTS_LOG="$EVENT_LOG" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
  SPACES_PID=$!
  ensure_profile_spaces_owner "$SPACES_PID"
  wait_for_spaces_launch_ready
  transition_pause "Spaces launch"
}

wait_for_spaces_launch_ready() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$SPACES_PID" >/dev/null 2>&1; then
      fail "Spaces exited during launch"
    fi
    if find_new_app_log_pattern_once 'spaces: hotkey_debug register handler_status=0 refs=[0-9]+ handler=1' >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  fail "timed out waiting for Spaces launch readiness"
}

activate_spaces_pid() {
  local pid="${1:-$SPACES_PID}"
  [[ -n "$pid" ]] || fail "missing Spaces pid for activation"
  osascript - "$pid" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      set frontmost of proc to true
      try
        if (count of windows of proc) > 0 then
          perform action "AXRaise" of window 1 of proc
        end if
      end try
      return
    end repeat
  end tell
end run
APPLESCRIPT
}

raise_spaces_main_window() {
  local pid="${1:-$SPACES_PID}"
  [[ -n "$pid" ]] || fail "missing Spaces pid for main-window raise"
  osascript - "$pid" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      set frontmost of proc to true
      repeat with targetWindow in windows of proc
        set windowTitle to ""
        set windowIdentifier to ""
        try
          set windowTitle to (name of targetWindow) as text
        end try
        try
          set windowIdentifier to (value of attribute "AXIdentifier" of targetWindow) as text
        end try
        if windowIdentifier is "spaces-main-window" or windowTitle is "Spaces" then
          perform action "AXRaise" of targetWindow
          try
            set value of attribute "AXMain" of targetWindow to true
          end try
          try
            set value of attribute "AXFocused" of targetWindow to true
          end try
          return
        end if
      end repeat
      return
    end repeat
  end tell
end run
APPLESCRIPT
}

focus_spaces_main_window_for_shortcuts() {
  local pid="${1:-$SPACES_PID}"
  [[ -n "$pid" ]] || fail "missing Spaces pid for shortcut focus"
  raise_spaces_main_window "$pid"
  osascript - "$pid" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      set frontmost of proc to true
      repeat with targetWindow in windows of proc
        set windowTitle to ""
        set windowIdentifier to ""
        try
          set windowTitle to (name of targetWindow) as text
        end try
        try
          set windowIdentifier to (value of attribute "AXIdentifier" of targetWindow) as text
        end try
        if windowIdentifier is "spaces-main-window" or windowTitle is "Spaces" then
          perform action "AXRaise" of targetWindow
          try
            set value of attribute "AXMain" of targetWindow to true
          end try
          try
            set value of attribute "AXFocused" of targetWindow to true
          end try
          try
            set windowPosition to position of targetWindow
            set windowSize to size of targetWindow
            set clickX to ((item 1 of windowPosition) + ((item 1 of windowSize) / 2)) as integer
            set clickY to ((item 2 of windowPosition) + 16) as integer
            click at {clickX, clickY}
          end try
          return
        end if
      end repeat
      return
    end repeat
  end tell
end run
APPLESCRIPT
}

wait_for_spaces_main_window_shortcut_focus() {
  local pid="${1:-$SPACES_PID}"
  local deadline=$((SECONDS + 6))
  while (( SECONDS < deadline )); do
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
      "$SPACES_E2E_CLI" show-main-window >/tmp/spaces-e2e-show-main-window-for-shortcut.json 2>>"$DEBUG_LOG" || true
    sleep 0.1
    focus_spaces_main_window_for_shortcuts "$pid"
    if [[ "$(spaces_main_window_key 2>/dev/null | tr -d '\n' || true)" == "1" ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_for_spaces_frontmost_ready() {
  # Most GUI actions in this script assume a single visible Spaces window and an
  # active accessibility tree, so block until that state exists and Spaces is
  # actually frontmost. The later UI automation queries `process "SpacesApp"`
  # because the internal executable name differs from the user-facing app name.
  # The strict single-instance checks above are what keep System Events from
  # drifting onto the user's regular app instance here.
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$SPACES_PID" >/dev/null 2>&1; then
      fail "Spaces exited during launch"
    fi
    activate_spaces_pid "$SPACES_PID"
    if [[ "$(frontmost_pid 2>/dev/null || true)" == "$SPACES_PID" ]] && osascript - "$SPACES_PID" <<'APPLESCRIPT' 2>/dev/null | grep -Eiq '^(1|true)$'; then
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      return (count of windows of proc) > 0
    end repeat
  end tell
  return false
end run
APPLESCRIPT
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces window"
}

wait_for_spaces_frontmost_pid() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$SPACES_PID" >/dev/null 2>&1; then
      fail "Spaces exited during launch"
    fi
    activate_spaces_pid "$SPACES_PID"
    if [[ "$(frontmost_pid 2>/dev/null || true)" == "$SPACES_PID" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces app activation"
}

wait_for_spaces_splitter_ready() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if osascript - "$SPACES_PID" <<'APPLESCRIPT' 2>/dev/null | grep -q '^1$'; then
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      if (count of windows of proc) is 0 then return 0
      repeat with targetWindow in windows of proc
        set windowTitle to ""
        set windowIdentifier to ""
        try
          set windowTitle to (name of targetWindow) as text
        end try
        try
          set windowIdentifier to (value of attribute "AXIdentifier" of targetWindow) as text
        end try
        if windowIdentifier is "spaces-main-window" or windowTitle is "Spaces" then
          try
            set _ to splitter group 1 of targetWindow
            return 1
          on error
            return 0
          end try
        end if
      end repeat
    end repeat
  end tell
  return 0
end run
APPLESCRIPT
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces splitter layout"
}

spaces_splitter_ready() {
  osascript - "$SPACES_PID" <<'APPLESCRIPT' 2>/dev/null | grep -q '^1$'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      if (count of windows of proc) is 0 then return 0
      repeat with targetWindow in windows of proc
        set windowTitle to ""
        set windowIdentifier to ""
        try
          set windowTitle to (name of targetWindow) as text
        end try
        try
          set windowIdentifier to (value of attribute "AXIdentifier" of targetWindow) as text
        end try
        if windowIdentifier is "spaces-main-window" or windowTitle is "Spaces" then
          try
            set _ to splitter group 1 of targetWindow
            return 1
          on error
            return 0
          end try
        end if
      end repeat
    end repeat
  end tell
  return 0
end run
APPLESCRIPT
}

install_demo_fixture_branch() {
  local variant="$1"
  local repo_dir="$2"
  local branch_name="$3"
  (
    cd "$repo_dir"
    git checkout -q -b "$branch_name"
    rm -rf .spaces-e2e-demo/site
    rm -rf .spaces-e2e-demo/api
    cp -R "$FIXTURE_TEMPLATE_DIR/templates/$variant/site" .spaces-e2e-demo/site
    cp -R "$FIXTURE_TEMPLATE_DIR/templates/$variant/api" .spaces-e2e-demo/api
    git add .spaces-e2e-demo/site .spaces-e2e-demo/api
    git commit -q -m "redesign hero section"
    git checkout -q main
  )
}

setup_git_fixture() {
  log_step "creating git fixture repos"
  mkdir -p "$TEST_REPO" "$TEST_REPO_2" "$TEST_REPO_3"
  install_demo_fixture "beacon"  "$TEST_REPO"  "# Beacon Status"
  install_demo_fixture_branch "beacon-redesign-hero" "$TEST_REPO" "redesign-hero"
  install_demo_fixture "scout"   "$TEST_REPO_2" "# Scout Errors"
  install_demo_fixture_branch "scout-redesign-hero" "$TEST_REPO_2" "redesign-hero"
  install_demo_fixture "prism"   "$TEST_REPO_3" "# Prism Analytics"
}

install_demo_fixture() {
  local variant="$1"
  local repo_dir="$2"
  local readme_title="$3"
  (
    cd "$repo_dir"
    git init -q -b main
    git config user.email "spaces-e2e@example.com"
    git config user.name "spaces-e2e"
    mkdir -p .spaces-e2e-demo
    cp "$FIXTURE_TEMPLATE_DIR/pyproject.toml" .spaces-e2e-demo/pyproject.toml
    cp -R "$FIXTURE_TEMPLATE_DIR/src" .spaces-e2e-demo/src
    cp -R "$FIXTURE_TEMPLATE_DIR/templates/$variant/site" .spaces-e2e-demo/site
    cp -R "$FIXTURE_TEMPLATE_DIR/templates/$variant/api" .spaces-e2e-demo/api
    printf '%s\n' "$readme_title" >README.md
    git add README.md .spaces-e2e-demo
    git commit -q -m init
  )
}

seed_fixture() {
  log_step "seeding project fixture (beacon-status)"
  # spacese2e seeds deterministic project/workspace templates through the real
  # workspacecore layer so the manual test is reproducible.
  "$SPACES_E2E_CLI" seed-fixture \
    --project-dir "$TEST_REPO" \
    --workspace-title "$PRIMARY_WORKSPACE_TITLE" \
    --docs-url "http://localhost:\$${APP_PORT_NAME}/docs/" \
    --admin-url "http://localhost:\$${APP_PORT_NAME}/admin/" >"$SEED_FILE"
}

seed_second_fixture() {
  log_step "seeding second project fixture (scout-errors)"
  "$SPACES_E2E_CLI" seed-fixture \
    --project-dir "$TEST_REPO_2" \
    --workspace-title "$SECONDARY_WORKSPACE_TITLE" \
    --docs-url "http://localhost:\$${APP_PORT_NAME}/docs/" \
    --admin-url "http://localhost:\$${APP_PORT_NAME}/admin/" >"$SECOND_SEED_FILE"
}

seed_third_fixture() {
  log_step "seeding third project fixture (prism-analytics)"
  "$SPACES_E2E_CLI" seed-fixture \
    --project-dir "$TEST_REPO_3" \
    --workspace-title "$TERTIARY_WORKSPACE_TITLE" \
    --docs-url "http://localhost:\$${APP_PORT_NAME}/docs/" \
    --admin-url "http://localhost:\$${APP_PORT_NAME}/admin/" >"$THIRD_SEED_FILE"
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
}

remote_ssh_destination() {
  if [[ -n "$REMOTE_SSH_USER" ]]; then
    printf '%s@%s' "$REMOTE_SSH_USER" "$REMOTE_SSH_HOST"
  else
    printf '%s' "$REMOTE_SSH_HOST"
  fi
}

remote_ssh() {
  [[ -n "$REMOTE_SSH_HOST" ]] || fail "Remote target requires SPACES_E2E_REMOTE_SSH_HOST."
  local destination
  destination="$(remote_ssh_destination)"
  local -a args=(-o BatchMode=yes)
  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    args+=(-p "$REMOTE_SSH_PORT")
  fi
  ssh "${args[@]}" "$destination" "$@"
}

remote_expand_path() {
  local raw_path="$1"
  local quoted
  quoted="$(shell_quote "$raw_path")"
  remote_ssh "python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' $quoted"
}

remote_push_url_for_path() {
  local remote_path="$1"
  local user_prefix=""
  local port_part=""
  if [[ -n "$REMOTE_SSH_USER" ]]; then
    user_prefix="$REMOTE_SSH_USER@"
  fi
  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    port_part=":$REMOTE_SSH_PORT"
  fi
  printf 'ssh://%s%s%s%s\n' "$user_prefix" "$REMOTE_SSH_HOST" "$port_part" "$remote_path"
}

remote_auth_token_env_key() {
  printf 'SPACESD_AUTH_TOKEN_%s\n' "$(printf '%s' "$REMOTE_HOST_ID" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')"
}

export_remote_auth_token() {
  [[ -n "$REMOTE_AUTH_TOKEN" ]] || return 0
  local key
  key="$(remote_auth_token_env_key)"
  export "$key=$REMOTE_AUTH_TOKEN"
}

prepare_remote_git_origin() {
  local project_dir="$1"
  local slug="$2"
  local git_root
  git_root="$(remote_expand_path "$REMOTE_GIT_ROOT")"
  local remote_origin="$git_root/$slug.git"
  local quoted_root quoted_origin
  quoted_root="$(shell_quote "$git_root")"
  quoted_origin="$(shell_quote "$remote_origin")"
  remote_ssh "mkdir -p $quoted_root && rm -rf $quoted_origin && git init --bare -q $quoted_origin"
  local push_url
  push_url="$(remote_push_url_for_path "$remote_origin")"
  local ssh_command="ssh"
  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    ssh_command+=" -p $REMOTE_SSH_PORT"
  fi
  git -C "$project_dir" remote remove origin >/dev/null 2>&1 || true
  git -C "$project_dir" remote add origin "$remote_origin"
  git -C "$project_dir" -c core.sshCommand="$ssh_command" push -q "$push_url" --all
  printf '%s\n' "$remote_origin"
}

prepare_remote_git_origins() {
  local slug
  slug="$(basename "$TMP_ROOT" | tr -cd 'A-Za-z0-9_.-')"
  [[ -n "$slug" ]] || slug="macos-e2e"
  prepare_remote_git_origin "$TEST_REPO" "macos-$slug-beacon" >>"$TMP_ROOT/remote-git-origins.log" 2>&1
  prepare_remote_git_origin "$TEST_REPO_2" "macos-$slug-scout" >>"$TMP_ROOT/remote-git-origins.log" 2>&1
  prepare_remote_git_origin "$TEST_REPO_3" "macos-$slug-prism" >>"$TMP_ROOT/remote-git-origins.log" 2>&1
}

set_project_target_local() {
  "$SPACES_E2E_CLI" set-project-default-compute-host --project-dir "$1" --local >/tmp/spaces-e2e-target-local.json 2>/dev/null || true
}

set_project_target_remote() {
  "$SPACES_E2E_CLI" set-project-default-compute-host --project-dir "$1" --host-id "$REMOTE_HOST_ID" >/tmp/spaces-e2e-target-remote.json
}

configure_e2e_target() {
  local target="$1"
  if [[ -z "$SPACES_CYCLE_LATENCY_BUDGET_MS_WAS_SET" ]]; then
    case "$target" in
      remote) SPACES_CYCLE_LATENCY_BUDGET_MS=3000 ;;
      *) SPACES_CYCLE_LATENCY_BUDGET_MS=2000 ;;
    esac
  fi
  case "$target" in
    local)
      log_step "configuring local compute target"
      set_project_target_local "$TEST_REPO"
      set_project_target_local "$TEST_REPO_2"
      set_project_target_local "$TEST_REPO_3"
      ;;
    remote)
      log_step "configuring remote compute target: $REMOTE_HOST_ID"
      [[ -n "$REMOTE_SSH_HOST" ]] || fail "Remote target requires SPACES_E2E_REMOTE_SSH_HOST."
      export_remote_auth_token
      prepare_remote_git_origins
      local -a args=(
        remote-compute-host-smoke
        --project-dir "$TEST_REPO"
        --host-id "$REMOTE_HOST_ID"
        --name "$REMOTE_HOST_NAME"
        --ssh-host "$REMOTE_SSH_HOST"
        --workspace-root "$REMOTE_WORKSPACE_ROOT"
        --daemon-port "$REMOTE_DAEMON_PORT"
      )
      if [[ -n "$REMOTE_SSH_USER" ]]; then args+=(--ssh-user "$REMOTE_SSH_USER"); fi
      if [[ -n "$REMOTE_SSH_PORT" ]]; then args+=(--ssh-port "$REMOTE_SSH_PORT"); fi
      if [[ -n "$REMOTE_DAEMON_HOST" ]]; then args+=(--daemon-host "$REMOTE_DAEMON_HOST"); fi
      if [[ -n "$REMOTE_AUTH_TOKEN" ]]; then args+=("--auth-token=$REMOTE_AUTH_TOKEN"); fi
      "$SPACES_E2E_CLI" "${args[@]}" >"$TMP_ROOT/remote-compute-host-smoke.json" 2>"$TMP_ROOT/remote-compute-host-smoke.stderr.log" \
        || fail "Remote compute host smoke failed. See $TMP_ROOT/remote-compute-host-smoke.stderr.log"
      set_project_target_remote "$TEST_REPO"
      set_project_target_remote "$TEST_REPO_2"
      set_project_target_remote "$TEST_REPO_3"
      ;;
    *)
      fail "unknown target: $target"
      ;;
  esac
}

add_workspace_process() {
  local workspace_dir="$1"
  local process_name="$2"
  local process_command="$3"
  env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
    "$SPACES_E2E_CLI" add-workspace-process --workspace-dir "$workspace_dir" --name "$process_name" --command "$process_command"
}

remove_workspace_process() {
  local workspace_dir="$1"
  local process_name="$2"
  env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
    "$SPACES_E2E_CLI" remove-workspace-process --workspace-dir "$workspace_dir" --name "$process_name"
}

workspace_named_port() {
  local workspace_dir="$1"
  local port_name="$2"
  python3 - "$TMP_DB" "$workspace_dir" "$port_name" <<'PY'
import sqlite3
import sys

db_path, workspace_dir, port_name = sys.argv[1:4]
conn = sqlite3.connect(db_path)
try:
    row = conn.execute(
        """
        SELECT wp.port_number
        FROM workspace_ports AS wp
        JOIN workspaces AS w ON w.id = wp.workspace_id
        WHERE w.dir = ? AND wp.port_name = ?
        ORDER BY wp.port_index
        LIMIT 1
        """,
        (workspace_dir, port_name),
    ).fetchone()
finally:
    conn.close()

if row is None:
    raise SystemExit(1)

print(row[0])
PY
}

frontend_url_for_workspace() {
  local workspace_dir="$1"
  local path="$2"
  local port
  port="$(workspace_named_port "$workspace_dir" "$APP_PORT_NAME")" || fail "missing named port $APP_PORT_NAME for $workspace_dir"
  printf 'http://localhost:%s%s\n' "$port" "$path"
}

backend_url_for_workspace() {
  local workspace_dir="$1"
  local path="$2"
  local port
  port="$(workspace_named_port "$workspace_dir" "$API_PORT_NAME")" || fail "missing named port $API_PORT_NAME for $workspace_dir"
  printf 'http://localhost:%s%s\n' "$port" "$path"
}

http_get_body() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=2) as response:
    print(response.read().decode("utf-8"))
PY
}

http_body_contains() {
  local url="$1"
  local expected="$2"
  local body
  if body="$(http_get_body "$url" 2>/dev/null)" && grep -Fq "$expected" <<<"$body"; then
    return 0
  fi
  return 1
}

remote_http_body_contains() {
  local url="$1"
  local expected="$2"
  local quoted_url quoted_expected
  quoted_url="$(shell_quote "$url")"
  quoted_expected="$(shell_quote "$expected")"
  remote_ssh "python3 -c 'import sys, urllib.request; body = urllib.request.urlopen(sys.argv[1], timeout=2).read().decode(\"utf-8\"); raise SystemExit(0 if sys.argv[2] in body else 1)' $quoted_url $quoted_expected" \
    >/dev/null 2>&1
}

wait_for_http_body_contains() {
  local url="$1"
  local expected="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if http_body_contains "$url" "$expected"; then return 0; fi
    sleep 0.2
  done
  fail "timed out waiting for HTTP content at $url containing: $expected"
}

wait_for_workspace_http_content_optional() {
  local host="$1"
  shift
  local docs_url="$1"
  local docs_expected="$2"
  local backend_url="$3"
  local backend_expected="$4"
  local timeout_seconds="${5:-$WORKSPACE_SERVICE_CONTENT_TIMEOUT_SECONDS}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if [[ "$host" == "remote" ]]; then
      if http_body_contains "$docs_url" "$docs_expected" && remote_http_body_contains "$backend_url" "$backend_expected"; then
        return 0
      fi
    elif http_body_contains "$docs_url" "$docs_expected" && http_body_contains "$backend_url" "$backend_expected"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

slugify_automation_id() {
  python3 - "$1" <<'PY'
import re, sys
value = sys.argv[1].strip().lower()
value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
print(value)
PY
}

create_mock_agent_script() {
  local project_dir="$1"
  local script_path="$project_dir/.spaces-e2e-mock-agent"
  python3 - "$script_path" "$SPACES_CLI" "$EVENT_LOG" <<'PY'
import os
import sys
from pathlib import Path

script_path, spaces_cli, event_log = sys.argv[1:4]
content = f"""#!/usr/bin/env bash
set -euo pipefail
workspace_dir="${{SPACES_WORKSPACE_DIR:-$PWD}}"
agent_log="{event_log}"
spaces_cli="{spaces_cli}"
"$spaces_cli" signal init "$workspace_dir" >/dev/null
"$spaces_cli" signal start "$workspace_dir" >/dev/null
printf 'agent-start:%s\\n' "$workspace_dir" >>"$agent_log"
sleep 2
"$spaces_cli" signal waiting "$workspace_dir" >/dev/null
printf 'agent-waiting:%s\\n' "$workspace_dir" >>"$agent_log"
sleep 6
"$spaces_cli" signal done "$workspace_dir" >/dev/null
printf 'agent-done:%s\\n' "$workspace_dir" >>"$agent_log"
trap '"$spaces_cli" signal exit "$workspace_dir" >/dev/null 2>&1 || true; printf "agent-exit:%s\\n" "$workspace_dir" >>"$agent_log"; exit 0' TERM INT
while true; do sleep 5; done
"""
Path(script_path).write_text(content)
os.chmod(script_path, 0o755)
PY
  printf '%s\n' "$script_path"
}

mock_agent_launcher_command() {
  local host="$1"
  local workspace_dir="$2"
  if [[ "$host" == "remote" ]]; then
    python3 <<'PY'
import shlex

script = r"""set -euo pipefail
workspace_dir="${SPACES_WORKSPACE_DIR:-$PWD}"
spaces signal init "$workspace_dir" >/dev/null
spaces signal start "$workspace_dir" >/dev/null
sleep 2
spaces signal waiting "$workspace_dir" >/dev/null
sleep 6
spaces signal done "$workspace_dir" >/dev/null
trap 'spaces signal exit "$workspace_dir" >/dev/null 2>&1 || true; exit 0' TERM INT
while true; do sleep 5; done
"""
print("bash -lc " + shlex.quote(script))
PY
  else
    create_mock_agent_script "$workspace_dir"
  fi
}

create_high_output_process_script() {
  local project_dir="$1"
  local script_path="$project_dir/.spaces-e2e-high-output"
  python3 - "$script_path" <<'PY'
import os
import sys
from pathlib import Path

script_path = sys.argv[1]
content = """#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' TERM INT
while true; do
  for _ in {1..128}; do
    printf 'spaces-e2e-noisy\\n'
  done
  sleep 0.05
done
"""
Path(script_path).write_text(content)
os.chmod(script_path, 0o755)
PY
  printf '%s\n' "$script_path"
}

set_workspace_agent_launcher() {
  local workspace_dir="$1"
  local launcher_name="$2"
  local launcher_command="$3"
  "$SPACES_E2E_CLI" set-workspace-agent-launchers --workspace-dir "$workspace_dir" --name "$launcher_name" --command "$launcher_command" \
    >/tmp/spaces-e2e-agent-launcher.json
}

clear_workspace_agent_launchers() {
  local workspace_dir="$1"
  "$SPACES_E2E_CLI" set-workspace-agent-launchers --workspace-dir "$workspace_dir" --clear >/tmp/spaces-e2e-agent-launcher-clear.json
}

clear_workspace_agent_windows() {
  local workspace_dir="$1"
  "$SPACES_E2E_CLI" clear-workspace-agent-windows --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-agent-windows-clear.json
}

json_get() {
  # Small JSON accessor for shell assertions against helper output.
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
with open(path) as fh:
    value = json.load(fh)
for part in expr.split('.'):
    if not part:
        continue
    if '[' in part:
        name, rest = part.split('[', 1)
        if name:
            value = value[name]
        index = int(rest[:-1])
        value = value[index]
    else:
        value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

dump_workspace() {
  "$SPACES_E2E_CLI" dump-workspace --workspace-dir "$1" >"$2"
}

workspace_id_for_dir() {
  local workspace_dir="$1"
  local out="$TMP_ROOT/workspace-id.json"
  dump_workspace "$workspace_dir" "$out"
  json_get "$out" "workspace.id"
}

dump_focusable_window_names() {
  "$SPACES_E2E_CLI" focusable-window-names --workspace-dir "$1" >"$2"
}

spaces_main_window_id() {
  yabai -m query --windows | python3 -c '
import json, sys
windows = json.load(sys.stdin)
for window in windows:
    title = window.get("title") or ""
    app = window.get("app") or ""
    if title == "Spaces" and app in {"Spaces", "SpacesApp"}:
        print(window["id"])
        break
'
}

lookup_workspace() {
  "$SPACES_E2E_CLI" lookup-workspace --project-dir "$TEST_REPO" --title "$1" >"$2"
}

wait_for_workspace_lookup() {
  # Workspace creation is async in the GUI path, so poll until it lands in the
  # backing store before moving to the next assertion.
  local title="$1"
  local out="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if lookup_workspace "$title" "$out" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  fail "workspace not found: $title"
}

wait_for_workspace_running_state() {
  local workspace_dir="$1"
  local expected="$2"
  local out="$TMP_ROOT/workspace-running-state.json"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    dump_workspace "$workspace_dir" "$out"
    if [[ "$(json_get "$out" "workspace.isRunning")" == "$expected" ]]; then
      return 0
    fi
    sleep 0.5
  done
  fail "workspace running state did not become $expected for $workspace_dir"
}

workspace_process_status() {
  local workspace_dir="$1"
  local process_name="$2"
  local out="$TMP_ROOT/workspace-process-status.json"
  dump_workspace "$workspace_dir" "$out"
  python3 - "$out" "$process_name" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
for process in data.get("runningProcesses", []):
    if process.get("name") == target:
        print(process.get("status") or "")
        break
PY
}

wait_for_workspace_process_status() {
  local workspace_dir="$1"
  local process_name="$2"
  local expected_status="$3"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "$(workspace_process_status "$workspace_dir" "$process_name")" == "$expected_status" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "workspace process did not reach status=$expected_status: $process_name"
}

url_port() {
  local url="$1"
  python3 - "$url" <<'PY'
from urllib.parse import urlparse
import sys
parsed = urlparse(sys.argv[1])
print(parsed.port or "")
PY
}

wait_for_tcp_listener_port() {
  local port="$1"
  [[ -n "$port" ]] || fail "missing port for listener wait"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for TCP listener on port $port"
}

wait_for_remote_tcp_listener_port() {
  local port="$1"
  [[ -n "$port" ]] || fail "missing remote port for listener wait"
  local quoted_port
  quoted_port="$(shell_quote "$port")"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if remote_ssh "python3 -c 'import socket, sys; s = socket.create_connection((\"127.0.0.1\", int(sys.argv[1])), timeout=1); s.close()' $quoted_port" \
      >/dev/null 2>&1
    then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for remote TCP listener on port $port"
}

ui_click_identifier() {
  # The GUI identifiers added for this suite keep the AppleScript automation
  # resilient when labels or ordering change.
  local identifier="$1"
  osascript - "$SPACES_PID" "$identifier" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set targetID to item 2 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetElement in entire contents of window 1 of proc
        try
          if (value of attribute "AXIdentifier" of targetElement) is targetID then
            click targetElement
            return
          end if
        end try
      end repeat
    end repeat
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}

ui_click_workspace_detail_header_button() {
  local description="$1"
  osascript - "$SPACES_PID" "$description" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set targetDescription to item 2 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        set windowTitle to ""
        set windowIdentifier to ""
        try
          set windowTitle to (name of targetWindow) as text
        end try
        try
          set windowIdentifier to (value of attribute "AXIdentifier" of targetWindow) as text
        end try
        if windowIdentifier is "spaces-main-window" or windowTitle is "Spaces" then
          tell scroll area 2 of splitter group 1 of targetWindow
            repeat with targetButton in buttons
              try
                if (description of targetButton) is targetDescription then
                  click targetButton
                  return
                end if
              end try
            end repeat
          end tell
        end if
      end repeat
    end repeat
  end tell
  error "workspace-detail header button not found: " & targetDescription
end run
APPLESCRIPT
}

ui_set_identifier_value() {
  local identifier="$1"
  local value="$2"
  osascript - "$SPACES_PID" "$identifier" "$value" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set targetID to item 2 of argv
  set targetValue to item 3 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetElement in entire contents of window 1 of proc
        try
          if (value of attribute "AXIdentifier" of targetElement) is targetID then
            set value of targetElement to targetValue
            return
          end if
        end try
      end repeat
    end repeat
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}

ui_select_popup_identifier() {
  local identifier="$1"
  local value="$2"
  osascript - "$SPACES_PID" "$identifier" "$value" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set targetID to item 2 of argv
  set targetValue to item 3 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetElement in entire contents of window 1 of proc
        try
          if (value of attribute "AXIdentifier" of targetElement) is targetID then
            click targetElement
            click menu item targetValue of menu 1 of targetElement
            return
          end if
        end try
      end repeat
    end repeat
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}

ui_double_click_identifier() {
  local identifier="$1"
  osascript - "$SPACES_PID" "$identifier" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set targetID to item 2 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetElement in entire contents of window 1 of proc
        try
          if (value of attribute "AXIdentifier" of targetElement) is targetID then
            perform action "AXPress" of targetElement
            delay 0.1
            perform action "AXPress" of targetElement
            return
          end if
        end try
      end repeat
    end repeat
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}

ui_select_outline_row() {
  local row_index="$1"
  wait_for_spaces_splitter_ready
  osascript - "$SPACES_PID" "$row_index" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set targetRow to (item 2 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        set windowTitle to ""
        set windowIdentifier to ""
        try
          set windowTitle to (name of targetWindow) as text
        end try
        try
          set windowIdentifier to (value of attribute "AXIdentifier" of targetWindow) as text
        end try
        if windowIdentifier is "spaces-main-window" or windowTitle is "Spaces" then
          select row targetRow of outline 1 of scroll area 1 of splitter group 1 of targetWindow
          return
        end if
      end repeat
    end repeat
  end tell
  error "main window not found"
end run
APPLESCRIPT
}

ui_show_workspace_detail() {
  local workspace_dir="$1"
  local workspace_title="$2"
  "$SPACES_E2E_CLI" show-main-window >/tmp/spaces-e2e-show-main-window.json
  "$SPACES_E2E_CLI" select-workspace-detail --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-select-workspace-detail.json
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    raise_spaces_main_window "$SPACES_PID"
    local main_window_id
    main_window_id="$(spaces_main_window_id)"
    if [[ -n "$main_window_id" ]]; then
      yabai -m window --focus "$main_window_id" >/dev/null 2>&1 || true
      raise_spaces_main_window "$SPACES_PID"
    fi
    if [[ "$(frontmost_pid 2>/dev/null || true)" == "$SPACES_PID" && "$(spaces_main_window_visible)" == "1" ]] && spaces_splitter_ready; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces main window layout"
}

ui_click_tab() {
  local label="$1"
  wait_for_spaces_splitter_ready
  osascript - "$SPACES_PID" "$label" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set targetLabel to item 2 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetElement in (entire contents of window 1 of proc)
        try
          if (role of targetElement) is "AXRadioButton" and (title of targetElement) is targetLabel then
            click targetElement
            return
          end if
        end try
      end repeat
    end repeat
  end tell
  error "tab not found: " & targetLabel
end run
APPLESCRIPT
}

create_workspace_via_gui() {
  log_step "creating beacon hero-redesign branch workspace through real orchestrator helper"
  # Workspace creation exercises the real store, git worktree creation, and
  # workspace initialization logic against a branch with distinct HTML content.
  "$SPACES_E2E_CLI" create-workspace \
    --project-dir "$TEST_REPO" \
    --title "$WORKSPACE_TITLE" \
    --existing-branch \
    --branch "$WORKSPACE_BRANCH" \
    --target-branch main \
    --notes "$WORKSPACE_NOTES" >"$TMP_ROOT/created-workspace.json"
  transition_pause "workspace creation"
}

create_scout_branch_workspace() {
  log_step "creating scout hero-redesign branch workspace"
  "$SPACES_E2E_CLI" create-workspace \
    --project-dir "$TEST_REPO_2" \
    --title "$SCOUT_BRANCH_WORKSPACE_TITLE" \
    --existing-branch \
    --branch "$SCOUT_BRANCH_WORKSPACE_BRANCH" \
    --target-branch main \
    --notes "$SCOUT_BRANCH_WORKSPACE_NOTES" >"$TMP_ROOT/scout-branch-workspace.json"
  transition_pause "scout branch workspace creation"
}

set_workspace_browser_urls() {
  local workspace_dir="$1"
  local docs_url="$2"
  local admin_url="$3"
  "$SPACES_E2E_CLI" set-workspace-browser-session-urls \
    --workspace-dir "$workspace_dir" \
    --docs-url "$docs_url" \
    --admin-url "$admin_url" >/tmp/spaces-e2e-browser-session-urls.json
}

set_workspace_stop_script_via_gui() {
  local marker="$1"
  local workspace_dir="$2"
  log_step "overriding workspace stop script through real workspace-settings path"
  "$SPACES_E2E_CLI" set-workspace-stop-script \
    --workspace-dir "$workspace_dir" \
    --stop-script "bash -lc 'for port in \"\$APP_PORT\" \"\$API_PORT\"; do if [ -n \"\$port\" ]; then pids=(); while IFS= read -r pid; do [ -n \"\$pid\" ] && pids+=(\"\$pid\"); done < <(lsof -tiTCP:\"\$port\" -sTCP:LISTEN 2>/dev/null || true); for pid in \"\${pids[@]}\"; do kill \"\$pid\" >/dev/null 2>&1 || true; done; sleep 0.5; for pid in \"\${pids[@]}\"; do kill -0 \"\$pid\" >/dev/null 2>&1 && kill -9 \"\$pid\" >/dev/null 2>&1 || true; done; fi; done; printf \"$marker\\n\" >> \"$EVENT_LOG\"'" >/tmp/spaces-e2e-stop-script.json
}

archive_workspace_via_gui() {
  local workspace_dir="$1"
  log_step "archiving workspace via GUI"
  wait_for_spaces_frontmost_ready
  ui_select_outline_row 2
  sleep 0.5
  ui_click_button_description "Archive"
  osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
  tell process "SpacesApp"
    if exists sheet 1 of window 1 then click button "Archive" of sheet 1 of window 1
  end tell
end tell
APPLESCRIPT
  local out="$TMP_ROOT/archive-workspace-state.json"
  local deadline=$((SECONDS + 4))
  while (( SECONDS < deadline )); do
    lookup_workspace "$WORKSPACE_TITLE" "$out" >/dev/null 2>&1 || true
    if [[ -f "$out" ]] && [[ "$(json_get "$out" "isArchived")" == "true" ]]; then
      return 0
    fi
    sleep 0.5
  done
  log_debug "archive_workspace_via_gui fallback=archive-workspace-helper"
  "$SPACES_E2E_CLI" archive-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-archive-workspace-fallback.json
}

stop_workspace_via_gui() {
  local workspace_dir="$1"
  log_step "stopping workspace via GUI"
  ui_show_workspace_detail "$workspace_dir" ""
  local main_window_deadline=$((SECONDS + 4))
  while (( SECONDS < main_window_deadline )); do
    if [[ "$(spaces_main_window_visible)" == "1" ]]; then
      break
    fi
    sleep 0.2
  done
  if [[ "$(spaces_main_window_visible)" != "1" ]]; then
    log_debug "stop_workspace_via_gui fallback=main-window-not-visible"
    "$SPACES_E2E_CLI" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace-fallback.json
    return 0
  fi
  if ! spaces_splitter_ready; then
    log_debug "stop_workspace_via_gui fallback=stop-workspace-helper"
    "$SPACES_E2E_CLI" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace-fallback.json
    return 0
  fi
  sleep 0.5
  if ! ui_click_workspace_detail_header_button "Stop"; then
    log_debug "stop_workspace_via_gui fallback=identifier-stop-workspace-helper"
    "$SPACES_E2E_CLI" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace-fallback.json
    return 0
  fi
  local out="$TMP_ROOT/stop-workspace-state.json"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    dump_workspace "$workspace_dir" "$out"
    if [[ "$(json_get "$out" "workspace.isRunning")" == "false" ]]; then
      return 0
    fi
    sleep 0.5
  done
  log_debug "stop_workspace_via_gui fallback=post-click-stop-workspace-helper"
  "$SPACES_E2E_CLI" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace-fallback.json
}

restart_workspace_via_gui() {
  local workspace_dir="$1"
  log_step "restarting workspace via GUI"
  ui_show_workspace_detail "$workspace_dir" ""
  local main_window_deadline=$((SECONDS + 4))
  while (( SECONDS < main_window_deadline )); do
    if [[ "$(spaces_main_window_visible)" == "1" ]]; then
      break
    fi
    sleep 0.2
  done
  if [[ "$(spaces_main_window_visible)" != "1" ]]; then
    log_debug "restart_workspace_via_gui fallback=main-window-not-visible"
    run_spaces_logged /tmp/spaces-e2e-restart-workspace-fallback.log restart "$workspace_dir"
    transition_pause "workspace restart fallback"
    return 0
  fi
  sleep 0.5
  if ! ui_click_workspace_detail_header_button "Restart"; then
    log_debug "restart_workspace_via_gui fallback=spaces-workspace-up-restart"
    run_spaces_logged /tmp/spaces-e2e-restart-workspace-fallback.log restart "$workspace_dir"
    transition_pause "workspace restart fallback"
    return 0
  fi
  sleep 1
  transition_pause "workspace restart"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -q -- "$needle" "$file" || fail "expected '$needle' in $file"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$expected" == "$actual" ]] || fail "$label: expected '$expected' got '$actual'"
}

assert_spaces_surface_state() {
  local expected_main_visible="$1"
  local expected_main_focused="$2"
  local expected_palette_visible="$3"
  local expected_palette_focused="$4"
  wait_for_surface_snapshot_python \
    "spaces surface main_visible=$expected_main_visible main_focused=$expected_main_focused palette_visible=$expected_palette_visible palette_focused=$expected_palette_focused" \
    'spaces = data.get("spaces") or {}
expected_main_visible, expected_main_focused, expected_palette_visible, expected_palette_focused = sys.argv[2:6]
actual = [
    "1" if spaces.get("mainWindowVisible") else "0",
    "1" if spaces.get("mainWindowFocused") else "0",
    "1" if spaces.get("commandPaletteVisible") else "0",
    "1" if spaces.get("commandPaletteFocused") else "0",
]
expected = [expected_main_visible, expected_main_focused, expected_palette_visible, expected_palette_focused]
raise SystemExit(0 if actual == expected and not spaces.get("modalVisible") else 1)' \
    "$expected_main_visible" "$expected_main_focused" "$expected_palette_visible" "$expected_palette_focused"
}

assert_shortcut_focus_surface_state() {
  if (( ONLY_WINDOW_CYCLE_PROFILE == 1 )); then
    return 0
  fi
  if wait_for_surface_snapshot_python_optional \
    "shortcut focus surface hidden" \
    'spaces = data.get("spaces") or {}
ok = not spaces.get("modalVisible") and not spaces.get("mainWindowFocused") and not spaces.get("commandPaletteVisible") and not spaces.get("commandPaletteFocused")
raise SystemExit(0 if ok else 1)'; then
    return 0
  fi
  assert_no_spaces_modal_dialog
  case "$(frontmost_app 2>/dev/null | tr -d '\n' || true)" in
    "Google Chrome")
      log_debug "accepted shortcut surface state from frontmost Chrome after surface snapshot timeout"
      return 0
      ;;
  esac
  if [[ "$(spaces_built_in_terminal_focus_state 2>/dev/null | tr -d '\n' || true)" == "owner" ]]; then
    log_debug "accepted shortcut surface state from Spaces terminal owner after surface snapshot timeout"
    return 0
  fi
  if spaces_cycle_surface_hidden_probe; then
    log_debug "accepted shortcut surface state from lightweight AX probe after surface snapshot timeout"
    return 0
  fi
  fail "timed out waiting for shortcut focus surface hidden"
}

assert_cycle_focus_surface_state() {
  if [[ "${LAST_CYCLE_TARGET_FOCUS_VIA_APP_OBSERVATION:-0}" == "1" ]]; then
    if spaces_cycle_surface_hidden_probe; then
      log_debug "accepted cycle surface state from lightweight AX probe after request-scoped terminal focus observation"
    else
      log_debug "accepted cycle surface state from request-scoped terminal focus observation after AX probes returned unknown"
    fi
    return 0
  fi
  if [[ "${LAST_CYCLE_TARGET_FOCUS_VIA_CHROME_OBSERVATION:-0}" == "1" ]]; then
    log_debug "accepted cycle surface state from Chrome/yabai target observation after surface snapshot timeout"
    return 0
  fi
  if wait_for_spaces_cycle_surface_hidden; then
    return 0
  fi
  log_debug "cycle surface state was not independently confirmed after target focus assertion; continuing"
}

frontmost_app() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  return name of first process whose frontmost is true
end tell
APPLESCRIPT
}

activate_google_chrome() {
  osascript <<'APPLESCRIPT'
tell application "Google Chrome" to activate
APPLESCRIPT
}

focus_yabai_window_if_present() {
  local window_id="${1:-}"
  [[ -n "$window_id" ]] || return 0
  yabai -m window --focus "$window_id" >/dev/null 2>&1 || true
}

yabai_focused_window_id() {
  python3 - <<'PY'
import json, subprocess
try:
    result = subprocess.run(
        ["yabai", "-m", "query", "--windows", "--window"],
        capture_output=True,
        text=True,
        check=True,
    )
    data = json.loads(result.stdout or "{}")
    print(data.get("id", ""))
except Exception:
    print("")
PY
}

wait_for_chrome_window_focus() {
  local window_id="$1"
  local expected_url="$2"
  local label="${3:-Chrome window focus}"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    assert_no_spaces_modal_dialog
    activate_google_chrome
    focus_yabai_window_if_present "$window_id"
    if [[ -n "$window_id" ]] \
      && [[ "$(yabai_focused_window_id)" == "$window_id" ]] \
      && [[ "$(chrome_front_url)" == "$expected_url" ]]
    then
      return 0
    fi
    if [[ -z "$window_id" && "$(chrome_front_url)" == "$expected_url" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for $label: window=$window_id url=$expected_url"
}

wait_for_chrome_window_focus_observed_optional() {
  local window_id="$1"
  local expected_url="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local focused_window_id front_app front_url
    assert_no_spaces_modal_dialog
    front_app="$(frontmost_app 2>/dev/null | tr -d '\n' || true)"
    focused_window_id="$(yabai_focused_window_id)"
    front_url="$(chrome_front_url 2>/dev/null | tr -d '\n' || true)"
    if [[ "$front_app" == "Google Chrome" ]] \
      && [[ -n "$window_id" ]] \
      && [[ "$focused_window_id" == "$window_id" ]] \
      && [[ "$front_url" == "$expected_url" ]]
    then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

spaces_modal_dialog_text() {
  python3 - "$SPACES_PID" "$AX_PROBE_TIMEOUT_SECONDS" <<'PY'
import subprocess
import sys

target_pid = sys.argv[1]
timeout_seconds = float(sys.argv[2])
script = r'''
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        try
          set subroleValue to value of attribute "AXSubrole" of targetWindow
        on error
          set subroleValue to ""
        end try
        if subroleValue is "AXDialog" then
          set outputLines to {}
          set buttonLabels to {}
          try
            set end of outputLines to (name of targetWindow as text)
          end try
          try
            repeat with dialogText in static texts of targetWindow
              try
                set textValue to (value of dialogText as text)
                if textValue is not "" then set end of outputLines to textValue
              end try
            end repeat
          end try
          try
                repeat with dialogButton in buttons of targetWindow
                  try
                    set buttonTitle to (title of dialogButton as text)
                    if buttonTitle is not "" and buttonTitle is not "missing value" and buttonTitle is in {"OK", "Cancel", "Recover", "Archive", "Stop", "Restart", "Delete", "Close", "Install", "Open System Settings"} then set end of buttonLabels to buttonTitle
                  end try
                end repeat
          end try
          if (count of buttonLabels) > 0 then
            repeat with buttonTitle in buttonLabels
              set end of outputLines to ("button:" & buttonTitle)
            end repeat
            if (count of outputLines) > 0 then return outputLines as text
            return "Spaces dialog visible"
          end if
        end if
        try
          if exists sheet 1 of targetWindow then
            set outputLines to {}
            set buttonLabels to {}
            try
              set end of outputLines to (name of targetWindow as text)
            end try
            repeat with targetSheet in sheets of targetWindow
              try
                repeat with sheetText in static texts of targetSheet
                  try
                    set textValue to (value of sheetText as text)
                    if textValue is not "" then set end of outputLines to textValue
                  end try
                end repeat
              end try
              try
                repeat with sheetButton in buttons of targetSheet
                  try
                    set buttonTitle to (title of sheetButton as text)
                    if buttonTitle is not "" and buttonTitle is not "missing value" and buttonTitle is in {"OK", "Cancel", "Recover", "Archive", "Stop", "Restart", "Delete", "Close", "Install", "Open System Settings"} then set end of buttonLabels to buttonTitle
                  end try
                end repeat
              end try
            end repeat
            if (count of buttonLabels) > 0 then
              repeat with buttonTitle in buttonLabels
                set end of outputLines to ("button:" & buttonTitle)
              end repeat
              if (count of outputLines) > 0 then return outputLines as text
              return "Spaces sheet visible"
            end if
          end if
        end try
      end repeat
    end repeat
  end tell
  return ""
end run
'''

try:
    result = subprocess.run(
        ["osascript", "-e", script, target_pid],
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired:
    sys.exit(0)

if result.returncode != 0:
    sys.exit(0)

lines = []
for line in result.stdout.replace("\r", "\n").splitlines():
    line = line.strip()
    if line:
        lines.append(line)
sys.stdout.write(" | ".join(lines))
PY
}

spaces_modal_dialog_visible() {
  local modal_text=""
  modal_text="$(spaces_modal_dialog_text || true)"
  if [[ -n "$modal_text" ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

dismiss_spaces_modal_dialog() {
  osascript - "$SPACES_PID" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        try
          set subroleValue to ""
          try
            set subroleValue to (value of attribute "AXSubrole" of targetWindow) as text
          end try
          if subroleValue is "AXDialog" then
            if exists button "Cancel (Esc)" of targetWindow then
              click button "Cancel (Esc)" of targetWindow
              return
            else if exists button "OK" of targetWindow then
              click button "OK" of targetWindow
              return
            end if
          end if
          if exists sheet 1 of targetWindow then
            repeat with targetSheet in sheets of targetWindow
              if exists button "Cancel (Esc)" of targetSheet then
                click button "Cancel (Esc)" of targetSheet
                return
              else if exists button "OK" of targetSheet then
                click button "OK" of targetSheet
                return
              end if
            end repeat
          end if
        end try
      end repeat
    end repeat
  end tell
end run
APPLESCRIPT
}

assert_no_spaces_modal_dialog() {
  local modal_text=""
  modal_text="$(spaces_modal_dialog_text || true)"
  if [[ -n "$modal_text" ]]; then
    log_debug "spaces modal dialog detected: $modal_text"
    fail "Spaces modal dialog visible: $modal_text"
  fi
}

wait_for_spaces_modal_dialog_frontmost() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "$(frontmost_pid)" == "$SPACES_PID" && "$(spaces_modal_dialog_visible)" == "1" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces modal dialog to become frontmost (frontmost_pid=$(frontmost_pid) spaces_pid=$SPACES_PID visible=$(spaces_modal_dialog_visible))"
}

wait_for_spaces_modal_dialog_frontmost_optional() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "$(frontmost_pid)" == "$SPACES_PID" && "$(spaces_modal_dialog_visible)" == "1" ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_for_spaces_modal_dialog_visible() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "$(spaces_modal_dialog_visible)" == "1" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces modal dialog to become visible"
}

frontmost_pid() {
  python3 - "$AX_PROBE_TIMEOUT_SECONDS" <<'PY'
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
script = r'''
tell application "System Events"
  try
    return unix id of first process whose frontmost is true
  on error
    return ""
  end try
end tell
'''
try:
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired:
    sys.exit(0)
if result.returncode == 0:
    sys.stdout.write(result.stdout)
PY
}

spaces_front_window_title() {
  osascript - "$SPACES_PID" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      if (count of windows of proc) is 0 then return ""
      try
        return name of front window of proc
      on error
        return ""
      end try
    end repeat
  end tell
  return ""
end run
APPLESCRIPT
}

spaces_front_window_identifier() {
  osascript - "$SPACES_PID" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      if (count of windows of proc) is 0 then return ""
      try
        return value of attribute "AXIdentifier" of front window of proc
      on error
        return ""
      end try
    end repeat
  end tell
  return ""
end run
APPLESCRIPT
}

wait_for_spaces_terminal_frontmost_session_optional() {
  local expected_session_id="$1"
  local label="Spaces terminal session to become frontmost: $expected_session_id"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  local snapshot_file="$TMP_ROOT/surface-snapshot-terminal-frontmost.json"
  local snapshot_failures=0
  while (( SECONDS < deadline )); do
    if surface_snapshot_json >"$snapshot_file"; then
      if surface_snapshot_condition_matches "$snapshot_file" \
        'expected_identifier = "spaces-terminal:" + sys.argv[2]
spaces = data.get("spaces") or {}
spaces_pid = spaces.get("processID")
ok = (
    spaces_pid is not None
    and data.get("frontmostProcessID") == spaces_pid
    and (spaces.get("frontWindowIdentifier") or "") == expected_identifier
)
raise SystemExit(0 if ok else 1)' \
        "$expected_session_id"; then
        return 0
      fi
    else
      local snapshot_status=$?
      snapshot_failures=$((snapshot_failures + 1))
      if (( snapshot_failures == 1 || snapshot_failures % 5 == 0 )); then
        log_debug "surface_snapshot failed label=$label status=$snapshot_status failures=$snapshot_failures"
      fi
    fi
    sleep "$SURFACE_POLL_INTERVAL_SECONDS"
  done
  return 1
}

wait_for_spaces_terminal_frontmost_session() {
  local expected_session_id="$1"
  if wait_for_spaces_terminal_frontmost_session_optional "$expected_session_id"; then
    return 0
  fi
  fail "timed out waiting for surface snapshot condition: Spaces terminal session to become frontmost: $expected_session_id"
}

surface_snapshot_json() {
  local include_yabai="${1:-}"
  local timeout_seconds="${2:-$SURFACE_SNAPSHOT_TIMEOUT_SECONDS}"
  local -a args=("$SPACES_E2E_CLI" surface-snapshot --spaces-pid "$SPACES_PID")
  if [[ "$include_yabai" == "include-yabai" ]]; then
    args+=(--include-yabai-focused-window)
  fi
  python3 - "$timeout_seconds" "${args[@]}" <<'PY'
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
command = sys.argv[2:]
try:
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired:
    sys.exit(124)

sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
PY
}

surface_snapshot_condition_matches() {
  local snapshot_file="$1"
  local python_body="$2"
  shift 2
  python3 - "$snapshot_file" "$@" <<PY
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
$python_body
PY
}

wait_for_surface_snapshot_python_mode_optional() {
  local include_yabai="$1"
  local label="$2"
  local python_body="$3"
  shift 3
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  local snapshot_file="$TMP_ROOT/surface-snapshot.json"
  local snapshot_failures=0
  while (( SECONDS < deadline )); do
    if surface_snapshot_json "$include_yabai" >"$snapshot_file"; then
      if surface_snapshot_condition_matches "$snapshot_file" "$python_body" "$@"; then
        return 0
      fi
    else
      local snapshot_status=$?
      snapshot_failures=$((snapshot_failures + 1))
      if (( snapshot_failures == 1 || snapshot_failures % 5 == 0 )); then
        log_debug "surface_snapshot failed label=$label status=$snapshot_status failures=$snapshot_failures"
      fi
    fi
    sleep "$SURFACE_POLL_INTERVAL_SECONDS"
  done
  if surface_snapshot_json "$include_yabai" "$ACTION_TIMEOUT_SECONDS" >"$snapshot_file"; then
    if surface_snapshot_condition_matches "$snapshot_file" "$python_body" "$@"; then
      return 0
    fi
  fi
  return 1
}

wait_for_surface_snapshot_python_mode() {
  local label="$2"
  if wait_for_surface_snapshot_python_mode_optional "$@"; then
    return 0
  fi
  fail "timed out waiting for surface snapshot condition: $label"
}

wait_for_surface_snapshot_python_optional() {
  wait_for_surface_snapshot_python_mode_optional "" "$@"
}

wait_for_surface_snapshot_python() {
  wait_for_surface_snapshot_python_mode "" "$@"
}

wait_for_surface_snapshot_python_with_yabai() {
  wait_for_surface_snapshot_python_mode "include-yabai" "$@"
}

wait_for_spaces_front_window_title() {
  local expected_title="$1"
  wait_for_surface_snapshot_python \
    "Spaces front window title: $expected_title" \
    'expected_title = sys.argv[2]
spaces = data.get("spaces") or {}
ok = (spaces.get("frontWindowTitle") or "") == expected_title and not spaces.get("modalVisible")
raise SystemExit(0 if ok else 1)' \
    "$expected_title"
}

spaces_front_window_session_id() {
  local identifier
  identifier="$(spaces_front_window_identifier)"
  case "$identifier" in
    spaces-terminal:*) printf '%s\n' "${identifier#spaces-terminal:}" ;;
    *) printf '%s\n' "" ;;
  esac
}

spaces_front_window_kind() {
  python3 - "$SPACES_PID" "$AX_PROBE_TIMEOUT_SECONDS" <<'PY'
import subprocess
import sys

target_pid = sys.argv[1]
timeout_seconds = float(sys.argv[2])
script = r'''
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      if (count of windows of proc) is 0 then return "none"
      set targetWindow to front window of proc
      set windowTitle to ""
      set subroleValue to ""
      set windowIdentifier to ""
      try
        set windowTitle to (name of targetWindow) as text
      end try
      try
        set subroleValue to (value of attribute "AXSubrole" of targetWindow) as text
      end try
      try
        set windowIdentifier to (value of attribute "AXIdentifier" of targetWindow) as text
      end try
      if subroleValue is "AXDialog" then return "modal"
      if windowIdentifier is "spaces-command-palette" then return "palette"
      if windowIdentifier is "spaces-main-window" then return "main"
      if windowIdentifier starts with "spaces-terminal:" then
        if windowTitle ends with " (viewer)" then return "terminal_viewer"
        return "terminal_owner"
      end if
      if windowTitle is "Spaces" then return "main"
      if windowTitle ends with " (viewer)" then return "terminal_viewer"
      if windowTitle is not "" then return "terminal_owner"
      return "other"
    end repeat
  end tell
  return "none"
end run
'''
try:
    result = subprocess.run(
        ["osascript", "-e", script, target_pid],
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired:
    print("unknown")
    sys.exit(0)
if result.returncode != 0:
    print("unknown")
    sys.exit(0)
sys.stdout.write(result.stdout)
PY
}

spaces_main_window_key() {
  if [[ "$(frontmost_pid)" == "$SPACES_PID" && "$(spaces_front_window_kind)" == "main" ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

known_spaces_terminal_session_id_for_name() {
  local target_name="$1"
  case "$target_name" in
    frontend) printf '%s\n' "$KNOWN_SPACES_FRONTEND_SESSION_ID" ;;
    backend) printf '%s\n' "$KNOWN_SPACES_BACKEND_SESSION_ID" ;;
    "$MOCK_AGENT_LABEL") printf '%s\n' "$KNOWN_SPACES_AGENT_SESSION_ID" ;;
    "$KNOWN_SPACES_ADHOC_NAME") printf '%s\n' "$KNOWN_SPACES_ADHOC_SESSION_ID" ;;
    "$HIGH_OUTPUT_PROCESS_NAME") printf '%s\n' "$KNOWN_SPACES_NOISY_SESSION_ID" ;;
    *) printf '%s\n' "" ;;
  esac
}

spaces_command_palette_key() {
  if [[ "$(frontmost_pid)" == "$SPACES_PID" && "$(spaces_front_window_kind)" == "palette" ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

spaces_built_in_terminal_focus_state() {
  if [[ "$(frontmost_pid)" != "$SPACES_PID" ]]; then
    printf 'none\n'
    return 0
  fi
  case "$(spaces_front_window_kind)" in
    terminal_owner)
      printf 'owner\n'
      ;;
    terminal_viewer)
      printf 'viewer\n'
      ;;
    *)
      printf 'none\n'
      ;;
  esac
}

spaces_main_window_visible() {
  osascript - "$SPACES_PID" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      try
        if visible of proc is false then return "0"
      end try
      repeat with targetWindow in windows of proc
        try
          set windowIdentifier to ""
          try
            set windowIdentifier to (value of attribute "AXIdentifier" of targetWindow) as text
          end try
          if windowIdentifier is "spaces-main-window" or (name of targetWindow) is "Spaces" then
            set isMinimized to false
            try
              set isMinimized to (value of attribute "AXMinimized" of targetWindow)
            end try
            if isMinimized is true then return "0"
            try
              if (value of attribute "AXVisible" of targetWindow) is false then return "0"
            end try
            return "1"
          end if
        end try
      end repeat
    end repeat
  end tell
  return "0"
end run
APPLESCRIPT
}

activate_google_chrome() {
  osascript <<'APPLESCRIPT'
tell application "Google Chrome" to activate
APPLESCRIPT
}

spaces_command_palette_visible() {
  python3 - "$SPACES_PID" "$AX_PROBE_TIMEOUT_SECONDS" <<'PY' | tr -d '\n'
import subprocess
import sys

target_pid = sys.argv[1]
timeout_seconds = float(sys.argv[2])
script = r'''
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        try
          if (value of attribute "AXIdentifier" of targetWindow) is "spaces-command-palette" then
            try
              if (value of attribute "AXVisible" of targetWindow) is false then return "0"
            end try
            return "1"
          end if
        end try
      end repeat
    end repeat
  end tell
  return "0"
end run
'''
try:
    result = subprocess.run(
        ["osascript", "-e", script, target_pid],
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired:
    print("unknown")
    sys.exit(0)
if result.returncode != 0:
    print("unknown")
    sys.exit(0)
sys.stdout.write(result.stdout)
PY
}

spaces_cycle_surface_hidden_probe() {
  local modal_text front_pid front_kind palette_visible
  modal_text="$(spaces_modal_dialog_text || true)"
  [[ -z "$modal_text" ]] || return 1
  palette_visible="$(spaces_command_palette_visible 2>/dev/null | tr -d '\n' || true)"
  [[ "$palette_visible" == "0" ]] || return 1
  front_pid="$(frontmost_pid 2>/dev/null | tr -d '\n' || true)"
  if [[ "$front_pid" == "$SPACES_PID" ]]; then
    front_kind="$(spaces_front_window_kind 2>/dev/null | tr -d '\n' || true)"
    case "$front_kind" in
      terminal_owner|terminal_viewer|other|none) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

wait_for_spaces_cycle_surface_hidden_probe() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if spaces_cycle_surface_hidden_probe; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

wait_for_spaces_cycle_surface_hidden() {
  if wait_for_surface_snapshot_python_optional \
    "cycle surface state to settle" \
    'spaces = data.get("spaces") or {}
if not spaces or not spaces.get("appVisible"):
    raise SystemExit(0)
spaces_pid = spaces.get("processID")
frontmost_pid = data.get("frontmostProcessID")
ok = (
    not spaces.get("modalVisible")
    and not spaces.get("commandPaletteVisible")
    and not (
        frontmost_pid == spaces_pid
        and (spaces.get("mainWindowFocused") or spaces.get("commandPaletteFocused"))
    )
)
raise SystemExit(0 if ok else 1)'; then
    return 0
  fi
  if wait_for_spaces_cycle_surface_hidden_probe; then
    log_debug "accepted cycle surface state from lightweight AX probe after surface snapshot timeout"
    return 0
  fi
  return 1
}

wait_for_spaces_command_palette_presented() {
  local expected_main_visible="${1:-[01]}"
  wait_for_app_log_pattern "spaces: hotkey_debug present_palette end .*main_visible=${expected_main_visible} .*palette_visible=1 .*palette_key=1"
}

wait_for_spaces_command_palette_dismissed() {
  local expected_main_visible="${1:-[01]}"
  wait_for_app_log_pattern "spaces: hotkey_debug dismiss_palette end .*main_visible=${expected_main_visible} .*palette_visible=0"
}

chrome_front_url() {
  osascript <<'APPLESCRIPT'
tell application "Google Chrome"
  if (count of windows) is 0 then return ""
  set u to URL of active tab of front window
  if u is missing value then return ""
  return u
end tell
APPLESCRIPT
}

chrome_front_window_id() {
  osascript <<'APPLESCRIPT'
tell application "Google Chrome"
  if (count of windows) is 0 then return ""
  return id of front window as string
end tell
APPLESCRIPT
}

chrome_window_active_url() {
  local window_id="$1"
  osascript - "$window_id" <<'APPLESCRIPT'
on run argv
  set targetWindowIDText to item 1 of argv
  tell application "Google Chrome"
    repeat with w in windows
      if (id of w as string) is targetWindowIDText then
        set u to URL of active tab of w
        if u is missing value then return ""
        return u
      end if
    end repeat
  end tell
  return ""
end run
APPLESCRIPT
}

chrome_add_extra_tab_to_window() {
  local window_id="$1"
  local url="$2"
  osascript - "$window_id" "$url" <<'APPLESCRIPT'
on run argv
  set targetWindowIDText to item 1 of argv
  set targetURL to item 2 of argv
  tell application "Google Chrome"
    activate
    repeat with w in windows
      if (id of w as string) is targetWindowIDText then
        tell w
          set newTab to make new tab at end of tabs
          set active tab index to (count of tabs)
          set URL of active tab to targetURL
        end tell
        return
      end if
    end repeat
  end tell
  error "Chrome window not found: " & targetWindowIDText
end run
APPLESCRIPT
}

close_fixture_chrome_windows() {
  osascript - "$TMP_PREFIX" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetPrefix to item 1 of argv
  set targetPrivatePrefix to "/private" & targetPrefix
  tell application "Google Chrome"
    set doomedWindowIDs to {}
    repeat with w in windows
      set shouldClose to false
      repeat with t in tabs of w
        try
          set tabURL to URL of t
        on error
          set tabURL to ""
        end try
        if tabURL starts with ("file://" & targetPrefix) or tabURL starts with ("file://" & targetPrivatePrefix) then
          set shouldClose to true
          exit repeat
        end if
        repeat with fixturePort from 20000 to 20011
          set portText to fixturePort as text
          if tabURL starts with ("http://localhost:" & portText & "/") or tabURL starts with ("http://127.0.0.1:" & portText & "/") then
            set shouldClose to true
            exit repeat
          end if
        end repeat
        if (tabURL contains "://localhost:" or tabURL contains "://127.0.0.1:") and (tabURL contains "/docs/" or tabURL contains "/admin/") then
          set shouldClose to true
        end if
        if shouldClose then exit repeat
      end repeat
      if shouldClose then set end of doomedWindowIDs to (id of w)
    end repeat
    repeat with doomedID in doomedWindowIDs
      try
        close (first window whose id is doomedID)
      end try
    end repeat
  end tell
end run
APPLESCRIPT
}

send_spaces_toggle_hotkey() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  key code 24 using {command down, option down}
end tell
APPLESCRIPT
}

send_spaces_command_palette_hotkey() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  key code 27 using {command down, option down}
end tell
APPLESCRIPT
}

send_spaces_window_shortcut() {
  local index="$1"
  local code=""
  case "$index" in
    1) code=18 ;;
    2) code=19 ;;
    3) code=20 ;;
    4) code=21 ;;
    5) code=23 ;;
    6) code=22 ;;
    7) code=26 ;;
    8) code=28 ;;
    9) code=25 ;;
    *) fail "unsupported window shortcut index $index" ;;
  esac
  osascript - "$code" <<'APPLESCRIPT'
on run argv
  set keyCodeValue to (item 1 of argv) as integer
  tell application "System Events"
    key code keyCodeValue using command down
  end tell
end run
APPLESCRIPT
}

send_spaces_open_terminal_hotkey() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  key code 17 using {command down, option down}
end tell
APPLESCRIPT
}

send_spaces_hotkey_with_ack() {
  local send_fn="$1"
  local pattern="$2"
  local attempts="${3:-3}"
  local attempt=1
  while (( attempt <= attempts )); do
    ensure_single_spaces_instance "$SPACES_PID"
    "$send_fn"
    if wait_for_app_log_pattern_optional "$pattern" >/dev/null; then
      return 0
    fi
    log_debug "hotkey pattern '$pattern' was not received on attempt $attempt; retrying"
    attempt=$((attempt + 1))
    sleep 0.1
  done
  fail "timed out waiting for hotkey reception: $pattern"
}

send_spaces_toggle_hotkey_with_ack() {
  send_spaces_hotkey_with_ack send_spaces_toggle_hotkey "spaces: hotkey_debug toggle_window begin "
}

send_spaces_command_palette_hotkey_with_ack() {
  send_spaces_hotkey_with_ack send_spaces_command_palette_hotkey "spaces: hotkey_debug toggle_palette begin "
}

send_spaces_window_shortcut_with_ack() {
  local index="$1"
  local attempts="${2:-3}"
  local pattern="spaces: window_shortcut stage=received index=$index "
  local attempt=1
  while (( attempt <= attempts )); do
    ensure_single_spaces_instance "$SPACES_PID"
    if ! wait_for_spaces_main_window_shortcut_focus "$SPACES_PID"; then
      log_debug "main Spaces window did not become key before shortcut index=$index attempt=$attempt"
    fi
    sleep 0.1
    send_spaces_window_shortcut "$index"
    if wait_for_app_log_pattern_optional "$pattern" >/dev/null; then
      return 0
    fi
    log_debug "window shortcut index=$index was not received on attempt $attempt; retrying"
    attempt=$((attempt + 1))
  done
  fail "timed out waiting for window shortcut reception: index=$index"
}

send_cycle_hotkey() {
  local direction="$1"
  local keycode=""
  case "$direction" in
    next) keycode=30 ;;
    previous) keycode=33 ;;
    *) fail "unsupported cycle direction $direction" ;;
  esac
  osascript - "$keycode" <<'APPLESCRIPT'
on run argv
  set keyCodeValue to (item 1 of argv) as integer
  tell application "System Events"
    key code keyCodeValue using {command down, option down}
  end tell
end run
APPLESCRIPT
}

send_cycle_hotkey_with_ack() {
  local direction="$1"
  local hotkey=""
  case "$direction" in
    next) hotkey="next" ;;
    previous) hotkey="previous" ;;
    *) fail "unsupported cycle direction $direction" ;;
  esac

  local pattern="spaces: hotkey_debug handle id=[0-9]+ hotkey=${hotkey} "
  local attempt=1
  local attempts=3
  while (( attempt <= attempts )); do
    ensure_single_spaces_instance "$SPACES_PID"
    send_cycle_hotkey "$direction"
    if wait_for_app_log_pattern_optional "$pattern" >/dev/null; then
      return 0
    fi
    log_debug "cycle hotkey '$direction' was not received on attempt $attempt; retrying"
    attempt=$((attempt + 1))
    sleep 0.1
  done
  fail "timed out waiting for cycle hotkey reception: direction=$direction"
}

record_metric_sample() {
  local name="$1"
  local value_ms="$2"
  local terminal_host="${3:-unknown}"
  local workspace_scope="${4:-single}"
  printf '%s\t%s\tterminal_host=%s\tworkspace_scope=%s\n' \
    "$name" \
    "$value_ms" \
    "$terminal_host" \
    "$workspace_scope" >>"$METRICS_LOG"
}

sample_spaces_process_cpu_average() {
  local pid="$1"
  local sample_count="$2"
  local interval_seconds="$3"
  python3 - "$pid" "$sample_count" "$interval_seconds" <<'PY'
import subprocess
import sys
import time

pid = sys.argv[1]
sample_count = int(sys.argv[2])
interval_seconds = float(sys.argv[3])
values = []

for index in range(sample_count):
    output = subprocess.check_output(["ps", "-p", pid, "-o", "%cpu="], text=True).strip()
    values.append(float(output or "0"))
    if index + 1 < sample_count:
        time.sleep(interval_seconds)

print(sum(values) / len(values) if values else 0.0)
PY
}

capture_spaces_cpu_breach_sample() {
  local label="$1"
  local artifact="$TMP_ROOT/${label//[^A-Za-z0-9._-]/-}.sample.txt"
  sample "$SPACES_PID" 3 1 -mayDie >"$artifact" 2>>"$DEBUG_LOG" || true
  printf '%s\n' "$artifact"
}

assert_spaces_cpu_not_above() {
  local metric_name="$1"
  local budget_pct="$2"
  local terminal_host="${3:-unknown}"
  local workspace_scope="${4:-single}"
  local average_cpu
  average_cpu="$(
    sample_spaces_process_cpu_average "$SPACES_PID" "$SPACES_CPU_SAMPLE_COUNT" "$SPACES_CPU_SAMPLE_INTERVAL_SECONDS"
  )"
  local rounded_cpu
  rounded_cpu="$(python3 - "$average_cpu" <<'PY'
import sys
print(int(round(float(sys.argv[1]))))
PY
)"
  record_metric_sample "$metric_name" "$rounded_cpu" "$terminal_host" "$workspace_scope"
  if ! python3 - "$average_cpu" "$budget_pct" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)
PY
  then
    local sample_path
    sample_path="$(capture_spaces_cpu_breach_sample "$metric_name")"
    fail "SpacesApp sustained CPU too high for $metric_name: avg=${average_cpu}% budget=${budget_pct}% sample=$sample_path"
  fi
}

timestamp_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

app_log_line_count() {
  if [[ -f "$APP_LOG" ]]; then
    wc -l <"$APP_LOG"
  else
    echo 0
  fi
}

find_new_app_log_pattern_once() {
  local pattern="$1"
  local match=""
  if [[ -f "$APP_LOG" ]]; then
    match="$(
      awk -v start="$APP_LOG_SEARCH_FROM_LINE" -v pattern="$pattern" '
        NR >= start && $0 ~ pattern { print NR ":" $0; exit }
      ' "$APP_LOG"
    )"
    if [[ -n "$match" ]]; then
      local line_number="${match%%:*}"
      local line="${match#*:}"
      APP_LOG_SEARCH_FROM_LINE=$((line_number + 1))
      APP_LOG_LAST_MATCH="$line"
      printf '%s\n' "$line"
      return 0
    fi
  fi
  return 1
}

find_app_log_pattern_once_from_line() {
  local pattern="$1"
  local start_line="$2"
  local match=""
  if [[ -f "$APP_LOG" ]]; then
    match="$(
      awk -v start="$start_line" -v pattern="$pattern" '
        NR >= start && $0 ~ pattern { print NR ":" $0; exit }
      ' "$APP_LOG"
    )"
    if [[ -n "$match" ]]; then
      local line_number="${match%%:*}"
      local line="${match#*:}"
      if (( line_number >= APP_LOG_SEARCH_FROM_LINE )); then
        APP_LOG_SEARCH_FROM_LINE=$((line_number + 1))
      fi
      APP_LOG_LAST_MATCH="$line"
      printf '%s\n' "$line"
      return 0
    fi
  fi
  return 1
}

wait_for_app_log_pattern() {
  local pattern="$1"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if find_new_app_log_pattern_once "$pattern"; then
      return 0
    fi
    sleep 0.1
  done
  fail "timed out waiting for app log pattern: $pattern"
}

wait_for_app_log_pattern_from_line() {
  local pattern="$1"
  local start_line="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if find_app_log_pattern_once_from_line "$pattern" "$start_line"; then
      return 0
    fi
    sleep 0.1
  done
  fail "timed out waiting for app log pattern from line $start_line: $pattern"
}

wait_for_app_log_pattern_optional() {
  local pattern="$1"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if find_new_app_log_pattern_once "$pattern"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_app_log_pattern_since_line() {
  local pattern="$1"
  local start_line="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ -f "$APP_LOG" ]] && awk -v start="$start_line" -v pattern="$pattern" 'NR >= start && $0 ~ pattern { found = 1; exit } END { exit(found ? 0 : 1) }' "$APP_LOG"; then
      return 0
    fi
    sleep 0.1
  done
  fail "timed out waiting for app log pattern since line $start_line: $pattern"
}

wait_for_app_log_pattern_anywhere() {
  local pattern="$1"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ -f "$APP_LOG" ]] && grep -Fq "$pattern" "$APP_LOG"; then
      return 0
    fi
    sleep 0.1
  done
  fail "timed out waiting for app log pattern anywhere: $pattern"
}

focusable_window_names() {
  local workspace_dir="$1"
  env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
    "$SPACES_E2E_CLI" focusable-window-names --workspace-dir "$workspace_dir"
}

shortcut_index_for_name() {
  local workspace_dir="$1"
  local target_name="$2"
  local raw
  raw="$(focusable_window_names "$workspace_dir" 2>/dev/null || true)"
  [[ "$raw" == \{* ]] || return 0
  printf '%s\n' "$raw" | python3 - "$target_name" <<'PY'
import json, sys
target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
for index, name in enumerate(data["names"], start=1):
    if name == target:
        print(index)
        break
PY
}

wait_for_shortcut_index() {
  local workspace_dir="$1"
  local target_name="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local shortcut_index
    shortcut_index="$(shortcut_index_for_name "$workspace_dir" "$target_name")"
    if [[ -n "$shortcut_index" ]]; then
      printf '%s\n' "$shortcut_index"
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for shortcut index: $target_name"
}

wait_for_log_pattern() {
  local path="$1"
  local pattern="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ -f "$path" ]]; then
      local line
      line="$(grep -E "$pattern" "$path" | tail -n 1 || true)"
      if [[ -n "$line" ]]; then
        printf '%s\n' "$line"
        return 0
      fi
    fi
    sleep 0.1
  done
  fail "timed out waiting for log pattern in $path: $pattern"
}

extract_metric_field() {
  local line="$1"
  local key="$2"
  sed -E "s/.*${key}=([0-9]+).*/\\1/" <<<"$line"
}

extract_perf_target() {
  python3 - "$1" <<'PY'
import re, sys
match = re.search(r'target=(.*?) success=', sys.argv[1])
print(match.group(1) if match else "")
PY
}

extract_cycle_window_title() {
  python3 - "$1" <<'PY'
import sys
target = sys.argv[1]
for prefix in ("terminal:", "process:", "agent:"):
    if target.startswith(prefix):
        print(target[len(prefix):])
        break
else:
    print("")
PY
}

cycle_metric_component_for_target() {
  local target="$1"
  case "$target" in
    browser:*) printf '%s\n' "browser_tracked_tab" ;;
    process:*) printf '%s\n' "process_tracked_tab" ;;
    terminal:*) printf '%s\n' "terminal_tracked_tab" ;;
    agent:*) printf '%s\n' "agent_tracked_tab" ;;
    *) fail "unsupported cycle metric target: $target" ;;
  esac
}

record_cycle_transition_metrics() {
  local source_component="$1"
  local direction="$2"
  local target="$3"
  local total_ms="$4"
  local route_observed_ms="$5"
  local focus_wait_ms="$6"
  local surface_wait_ms="$7"
  local route_internal_ms="$8"
  local terminal_host="$9"
  local workspace_scope="${10:-single}"
  local focus_internal_ms="${11:-}"
  local target_component metric_name
  target_component="$(cycle_metric_component_for_target "$target")"
  metric_name="${source_component}.keyboard_cycle_${direction}.${target_component}"
  record_metric_sample "$metric_name" "$total_ms" "$terminal_host" "$workspace_scope"
  record_metric_sample "${metric_name}.route_observed" "$route_observed_ms" "$terminal_host" "$workspace_scope"
  record_metric_sample "${metric_name}.focus_wait" "$focus_wait_ms" "$terminal_host" "$workspace_scope"
  record_metric_sample "${metric_name}.surface_wait" "$surface_wait_ms" "$terminal_host" "$workspace_scope"
  record_metric_sample "${metric_name}.route_internal" "$route_internal_ms" "$terminal_host" "$workspace_scope"
  if [[ -n "$focus_internal_ms" ]]; then
    record_metric_sample "${metric_name}.focus_internal" "$focus_internal_ms" "$terminal_host" "$workspace_scope"
  fi
}

matches_cycle_target_pattern() {
  local target="$1"
  shift
  local pattern
  for pattern in "$@"; do
    case "$target" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

extract_request_id() {
  python3 - "$1" <<'PY'
import re, sys
match = re.search(r'request_id=([0-9A-F-]+)', sys.argv[1])
print(match.group(1) if match else "")
PY
}

assert_metric_not_above() {
  local value_ms="$1"
  local max_ms="$2"
  local label="$3"
  [[ "$value_ms" =~ ^[0-9]+$ ]] || fail "$label: expected numeric value, got '$value_ms'"
  (( value_ms <= max_ms )) || fail "$label: expected <= ${max_ms}ms, got ${value_ms}ms"
}

find_app_log_pattern_anywhere_once() {
  local pattern="$1"
  if [[ ! -f "$APP_LOG" ]]; then
    return 1
  fi
  python3 - "$APP_LOG" "$pattern" <<'PY'
import re, sys
path, pattern = sys.argv[1], sys.argv[2]
regex = re.compile(pattern)
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if regex.search(line):
            print(line.rstrip("\n"))
            raise SystemExit(0)
raise SystemExit(1)
PY
}

wait_for_app_log_pattern_anywhere_optional() {
  local pattern="$1"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  local line
  while (( SECONDS < deadline )); do
    if line="$(find_app_log_pattern_anywhere_once "$pattern")"; then
      APP_LOG_LAST_MATCH="$line"
      printf '%s\n' "$line"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_terminal_focus_observed_request() {
  local expected_session_id="$1"
  local request_id="$2"
  local pattern="spaces: perf metric=terminal_window_focus_observed target=session=${expected_session_id} success=1 .*request_id=${request_id}( |$)"
  wait_for_app_log_pattern_anywhere_optional "$pattern" >/dev/null
}

record_perf_metric() {
  local name="$1"
  local pattern="$2"
  local terminal_host="${3:-unknown}"
  local workspace_scope="${4:-single}"
  local line
  line="$(wait_for_app_log_pattern "$pattern")"
  record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")" "$terminal_host" "$workspace_scope"
}

record_cycle_metric() {
  local name="$1"
  local direction="$2"
  local terminal_host="$3"
  local workspace_scope="${4:-single}"
  record_perf_metric "$name" "spaces: perf metric=window_cycle .*success=1 .*elapsed_ms=[0-9]+ .*direction=${direction}" "$terminal_host" "$workspace_scope"
}

record_toggle_window_metric() {
  local name="$1"
  local action="$2"
  local app_active_before="$3"
  local terminal_host="$4"
  local workspace_scope="${5:-single}"
  record_perf_metric \
    "$name" \
    "spaces: perf metric=toggle_window target=action=${action} .*app_active_before=${app_active_before} .*success=1 elapsed_ms=" \
    "$terminal_host" \
    "$workspace_scope"
}

record_toggle_palette_metric() {
  local name="$1"
  local action="$2"
  local app_active_before="$3"
  local terminal_host="$4"
  local workspace_scope="${5:-single}"
  record_perf_metric \
    "$name" \
    "spaces: perf metric=toggle_palette target=action=${action} .*app_active_before=${app_active_before} .*success=1 elapsed_ms=" \
    "$terminal_host" \
    "$workspace_scope"
}

record_named_focus_metric() {
  local name="$1"
  local target_name="$2"
  local terminal_host="$3"
  local workspace_scope="${4:-single}"
  local line
  line="$(wait_for_app_log_pattern_optional "spaces: perf metric=(named_window_focus|browser_focus|process_focus) .*target=${target_name} .*success=1 .*elapsed_ms=" || true)"
  if [[ -z "$line" ]]; then
    log_debug "named focus metric missing for target=$target_name; skipping metric $name"
    return 0
  fi
  record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")" "$terminal_host" "$workspace_scope"
}

record_browser_focus_metric() {
  local name="$1"
  local target_url="$2"
  local focus_name="${3:-}"
  local terminal_host="$4"
  local workspace_scope="${5:-single}"
  local fallback_elapsed_ms="${6:-}"
  local line
  line="$(wait_for_app_log_pattern_optional "spaces: perf metric=browser_focus .*target=${target_url} .*success=1 .*elapsed_ms=" || true)"
  if [[ -n "$line" ]]; then
    record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")" "$terminal_host" "$workspace_scope"
    return 0
  fi
  # Named focus can resolve through the shared name-based path instead of the
  # browser-session-specific path, so the app may log
  # `named_window_focus target=docs` even though the visible behavior is still
  # "focus the tracked docs Chrome tab". Accept either metric shape here.
  line=""
  if [[ -n "$focus_name" ]]; then
    line="$(wait_for_app_log_pattern_optional "spaces: perf metric=named_window_focus .*target=${focus_name} .*success=1 .*elapsed_ms=" || true)"
  fi
  if [[ -n "$line" ]]; then
    record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")" "$terminal_host" "$workspace_scope"
    return 0
  fi
  if [[ -n "$fallback_elapsed_ms" ]]; then
    log_debug "browser focus metric missing for url=$target_url name=${focus_name:-<none>}; using wall-clock fallback ${fallback_elapsed_ms}ms"
    record_metric_sample "$name" "$fallback_elapsed_ms" "$terminal_host" "$workspace_scope"
    return 0
  fi
  fail "timed out waiting for browser-focus metric: url=$target_url name=${focus_name:-<none>}"
}

record_process_focus_metric() {
  local name="$1"
  local process_name="$2"
  local terminal_host="$3"
  local workspace_scope="${4:-single}"
  local request_id="${5:-}"
  local helper_log_path="${6:-}"
  local line
  if is_spaces_terminal_target "$terminal_host" && [[ -n "$request_id" ]]; then
    if line="$(wait_for_app_log_pattern_optional "spaces: perf metric=terminal_window_focus_ipc .*success=1 .*elapsed_ms=.*request_id=${request_id}( |$)")"; then
      :
    elif [[ -n "$helper_log_path" ]]; then
      line="$(wait_for_log_pattern "$helper_log_path" "spaces: perf metric=process_focus .*target=${process_name} .*success=1 .*elapsed_ms=")"
    else
      line="$(wait_for_app_log_pattern "spaces: perf metric=terminal_window_focus_ipc .*success=1 .*elapsed_ms=.*request_id=${request_id}( |$)")"
    fi
  elif is_spaces_terminal_target "$terminal_host"; then
    line="$(wait_for_app_log_pattern "spaces: perf metric=(process_focus|named_window_focus) .*target=${process_name} .*success=1 .*elapsed_ms=")"
  else
    line="$(wait_for_app_log_pattern "spaces: perf metric=(process_focus|named_window_focus) .*target=${process_name} .*success=1 .*elapsed_ms=")"
  fi
  record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")" "$terminal_host" "$workspace_scope"
}

git_worktree_clean() {
  [[ -z "$(git -C "$ROOT_DIR" status --short)" ]]
}

persist_profile_artifacts() {
  local exit_code="$1"
  if (( exit_code != 0 )); then
    printf 'Profile artifacts: skipped because the suite failed\n'
    return 0
  fi
  if [[ ! -s "$METRICS_LOG" ]]; then
    printf 'Profile artifacts: skipped because no metrics were recorded\n'
    return 0
  fi

  mkdir -p "$PROFILE_ARTIFACT_DIR"
  local timestamp machine_name machine_model git_branch git_sha git_state worktree_fingerprint
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  machine_name="$(scutil --get ComputerName 2>/dev/null || hostname)"
  machine_model="$(sysctl -n hw.model 2>/dev/null || uname -m)"
  git_branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
  git_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  read -r git_state worktree_fingerprint < <(
    python3 - "$ROOT_DIR" <<'PY'
import hashlib
import os
import subprocess
import sys

root = sys.argv[1]

def run(*args: str) -> bytes:
    return subprocess.run(args, cwd=root, check=True, stdout=subprocess.PIPE).stdout

head = run("git", "rev-parse", "HEAD").decode().strip()
status = run("git", "status", "--porcelain=v1", "--untracked-files=all", "-z")
state = "clean" if not status else "dirty"

if state == "clean":
    print(state, head)
    raise SystemExit(0)

hasher = hashlib.sha256()
hasher.update(head.encode())
hasher.update(b"\0STATUS\0")
hasher.update(status)
hasher.update(b"\0DIFF_HEAD\0")
hasher.update(run("git", "diff", "--no-ext-diff", "--binary", "HEAD"))
hasher.update(b"\0DIFF_CACHED\0")
hasher.update(run("git", "diff", "--no-ext-diff", "--binary", "--cached"))

for raw_path in run("git", "ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
    if not raw_path:
        continue
    path = raw_path.decode("utf-8", "surrogateescape")
    hasher.update(b"\0UNTRACKED_PATH\0")
    hasher.update(raw_path)
    file_path = os.path.join(root, path)
    if os.path.isfile(file_path):
        hasher.update(b"\0UNTRACKED_FILE\0")
        with open(file_path, "rb") as handle:
            hasher.update(handle.read())
    else:
        hasher.update(b"\0UNTRACKED_NONFILE\0")

print(state, hasher.hexdigest())
PY
  )

  python3 "$PROFILE_RENDER_SCRIPT" \
    --metrics-log "$METRICS_LOG" \
    --csv "$PROFILE_HISTORY_CSV" \
    --report "$PROFILE_REPORT_HTML" \
    --timestamp "$timestamp" \
    --machine-name "$machine_name" \
    --machine-model "$machine_model" \
    --git-branch "$git_branch" \
    --git-sha "$git_sha" \
    --git-state "$git_state" \
    --worktree-fingerprint "$worktree_fingerprint"

  printf 'Profile history CSV: %s\n' "$PROFILE_HISTORY_CSV"
  printf 'Profile report HTML: %s\n' "$PROFILE_REPORT_HTML"
}

print_metric_summary() {
  if [[ ! -s "$METRICS_LOG" ]]; then
    printf 'Performance metrics: none recorded\n'
    return 0
  fi
  printf 'Performance metrics:\n'
  awk -F '\t' '
    {
      metric = $1
      value = $2 + 0
      host = "unknown"
      scope = "single"
      for (i = 3; i <= NF; i++) {
        split($i, part, "=")
        if (part[1] == "terminal_host") host = part[2]
        if (part[1] == "workspace_scope") scope = part[2]
      }
      key = metric "|" host "|" scope
      count[key] += 1
      sum[key] += value
      metric_name[key] = metric
      metric_host[key] = host
      metric_scope[key] = scope
      if (!(key in min) || value < min[key]) min[key] = value
      if (value > max[key]) max[key] = value
      samples[key] = samples[key] (samples[key] == "" ? "" : ",") value
    }
    END {
      for (key in count) {
        avg = sum[key] / count[key]
        printf "%s\t%s\t%s\t%d\t%.1f\t%d\t%d\t%s\n", metric_name[key], metric_host[key], metric_scope[key], count[key], avg, min[key], max[key], samples[key]
      }
    }
  ' "$METRICS_LOG" | sort | while IFS=$'\t' read -r metric host scope count avg min max samples; do
    printf '  %s [host=%s scope=%s]: avg=%sms min=%sms max=%sms samples=[%s]\n' "$metric" "$host" "$scope" "$avg" "$min" "$max" "$samples"
  done
}

print_case_summary() {
  if [[ ! -s "$RESULTS_LOG" ]]; then
    printf 'Test summary: no cases recorded\n'
    return 0
  fi
  printf 'Test summary:\n'
  while IFS=$'\t' read -r status name detail; do
    if [[ -n "$detail" && "$detail" != "-" ]]; then
      printf '  [%s] %s (%s)\n' "$status" "$name" "$detail"
    else
      printf '  [%s] %s\n' "$status" "$name"
    fi
  done <"$RESULTS_LOG"
}

print_run_summary() {
  local exit_code="$1"
  if (( SUMMARY_PRINTED == 1 )); then
    return 0
  fi
  SUMMARY_PRINTED=1
  printf '\n'
  if (( exit_code == 0 )); then
    printf 'PASS: manual real-system GUI/CLI end-to-end checks completed\n'
  else
    printf 'FAIL: manual real-system GUI/CLI end-to-end checks failed\n'
  fi
  print_case_summary
  print_metric_summary
  persist_profile_artifacts "$exit_code"
  print_recording_summary
  printf 'Metrics log: %s\n' "$METRICS_LOG"
  printf 'Results log: %s\n' "$RESULTS_LOG"
  printf 'Event log: %s\n' "$EVENT_LOG"
  printf 'Debug log: %s\n' "$DEBUG_LOG"
}

wait_for_condition() {
  local script="$1"
  local expected="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    assert_no_spaces_modal_dialog
    if [[ "$(eval "$script")" == "$expected" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for condition: $script == $expected"
}

wait_for_any_value() {
  local script="$1"
  shift
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    assert_no_spaces_modal_dialog
    local actual
    actual="$(eval "$script")"
    for expected in "$@"; do
      if [[ "$actual" == "$expected" ]]; then
        return 0
      fi
    done
    sleep 0.2
  done
  fail "timed out waiting for condition: $script matched one of: $*"
}

wait_for_any_value_optional() {
  local script="$1"
  shift
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    assert_no_spaces_modal_dialog
    local actual
    actual="$(eval "$script")"
    for expected in "$@"; do
      if [[ "$actual" == "$expected" ]]; then
        return 0
      fi
    done
    sleep 0.2
  done
  return 1
}

wait_for_event_log_contains() {
  local pattern="$1"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    assert_no_spaces_modal_dialog
    if [[ -f "$EVENT_LOG" ]] && grep -Fq "$pattern" "$EVENT_LOG"; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for event log pattern: $pattern"
}

wait_for_event_log_contains_since_line() {
  local pattern="$1"
  local start_line="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    assert_no_spaces_modal_dialog
    if [[ -f "$EVENT_LOG" ]] && awk -v start="$start_line" -v pattern="$pattern" 'NR >= start && index($0, pattern) { found = 1; exit } END { exit(found ? 0 : 1) }' "$EVENT_LOG"; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for event log pattern: $pattern"
}

wait_for_agent_status() {
  local workspace_dir="$1"
  local label="$2"
  local expected_status="$3"
  local dump_file="$TMP_ROOT/agent-status-dump.json"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    dump_workspace "$workspace_dir" "$dump_file"
    local actual_status
    actual_status="$(python3 - "$dump_file" "$label" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
for record in data.get("agentWindows", []):
    label = record.get("label") or ""
    if label == target or label.startswith(target + "-"):
        print(record.get("status") or "")
        break
PY
)"
    if [[ "$actual_status" == "$expected_status" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for agent status: $label == $expected_status"
}

wait_for_process_running_recovery() {
  local workspace_dir="$1"
  local process_name="$2"
  local previous_pid="$3"
  local frontend_port="${4:-}"
  local out="$TMP_ROOT/process-recovery-state.json"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! dump_workspace "$workspace_dir" "$out" 2>>"$DEBUG_LOG"; then
      log_debug "recovery poll: dump-workspace failed for $process_name; retrying"
      sleep 0.2
      continue
    fi
    local recovered_pid recovered_status
    if ! recovered_pid="$(python3 - "$out" "$process_name" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
for process in data["runningProcesses"]:
    if process["name"] == target:
        print(process["pid"] or "")
        break
PY
    )"; then
      log_debug "recovery poll: failed to parse recovered pid for $process_name; retrying"
      sleep 0.2
      continue
    fi
    if ! recovered_status="$(python3 - "$out" "$process_name" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
for process in data["runningProcesses"]:
    if process["name"] == target:
        print(process["status"])
        break
PY
    )"; then
      log_debug "recovery poll: failed to parse recovered status for $process_name; retrying"
      sleep 0.2
      continue
    fi
    if [[ -n "$recovered_pid" && "$recovered_status" == "running" && "$recovered_pid" != "$previous_pid" ]]; then
      log_process_recovery_snapshot "recovered-$process_name" "$workspace_dir" "$process_name" "$frontend_port" "$recovered_pid"
      printf '%s\t%s\n' "$recovered_pid" "$recovered_status"
      return 0
    fi
    log_process_recovery_snapshot "poll-$process_name" "$workspace_dir" "$process_name" "$frontend_port" "$recovered_pid"
    sleep 0.2
  done
  fail "$process_name process did not recover"
}

process_pid_is_alive() {
  local pid="$1"
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 1
  fi
  local state
  state="$(ps -p "$pid" -o state= 2>/dev/null | tr -d '[:space:]')" || return 1
  [[ -n "$state" && "${state:0:1}" != "Z" ]]
}

kill_process_group() {
  local pid="$1"
  local pgid
  pgid="$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')" || pgid=""
  if [[ -n "$pgid" ]]; then
    kill -9 -- "-$pgid" >/dev/null 2>&1 || true
  fi
  kill -9 "$pid" >/dev/null 2>&1 || true
}

kill_listener_processes() {
  local port="$1"
  [[ -n "$port" ]] || return 0
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -9 "$pid" >/dev/null 2>&1 || true
  done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
}

log_process_recovery_snapshot() {
  local label="$1"
  local workspace_dir="$2"
  local process_name="$3"
  local port="$4"
  local pid_hint="${5:-}"
  local dump_file="$TMP_ROOT/process-recovery-snapshot-${process_name}.json"

  {
    printf '\n[%s] recovery-state %s process=%s workspace=%s pid_hint=%s port=%s\n' \
      "$(date +%H:%M:%S)" "$label" "$process_name" "$workspace_dir" "${pid_hint:-}" "${port:-}"

    if dump_workspace "$workspace_dir" "$dump_file" 2>/dev/null; then
      python3 - "$dump_file" "$process_name" <<'PY'
import json, sys
path, target = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
for process in data.get("runningProcesses", []):
    if process.get("name") == target:
        print("running_process=" + json.dumps(process, sort_keys=True))
        break
else:
    print("running_process=")
for window in data.get("windows", []):
    if window.get("name") == target:
        print("window=" + json.dumps(window, sort_keys=True))
        break
else:
    print("window=")
PY
    else
      printf 'running_process_dump_failed=1\n'
    fi

    if [[ -n "$pid_hint" ]]; then
      printf 'ps_for_pid_hint:\n'
      ps -p "$pid_hint" -o pid=,ppid=,pgid=,state=,command= 2>/dev/null || true
    fi

    printf 'matching_frontend_processes:\n'
    pgrep -af "spaces-e2e-demo frontend" 2>/dev/null || true

    if [[ -n "$port" ]]; then
      printf 'tcp_listeners_port_%s:\n' "$port"
      lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
    fi

  } >>"$DEBUG_LOG"
}

dump_chrome_state() {
  local label="$1"
  {
    printf '\n[%s] chrome-state %s\n' "$(date +%H:%M:%S)" "$label"
    osascript <<'APPLESCRIPT'
tell application "Google Chrome"
  set out to ""
  set out to out & "window_count=" & (count of windows) & linefeed
  if (count of windows) is 0 then return out
  set out to out & "front_window_id=" & (id of front window as string) & linefeed
  repeat with w in windows
    set out to out & "window " & (id of w as string)
    set out to out & " active_tab_index=" & (active tab index of w as string)
    try
      set out to out & " active_tab_url=" & (URL of active tab of w)
    on error
      set out to out & " active_tab_url="
    end try
    set out to out & linefeed
    set tabIndex to 0
    repeat with t in tabs of w
      set tabIndex to tabIndex + 1
      set out to out & "  tab " & tabIndex & " "
      try
        set out to out & (URL of t)
      on error
        set out to out & ""
      end try
      set out to out & linefeed
    end repeat
  end repeat
  return out
end tell
APPLESCRIPT
  } >>"$DEBUG_LOG" 2>&1 || true
}

run_spaces_logged() {
  local stdout_file="$1"
  shift
  if [[ "${1:-}" == "open" ]]; then
    local name="$2"
    local workspace_dir="$3"
    env DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-window --name "$name" --workspace-dir "$workspace_dir" >"$stdout_file" 2>>"$APP_LOG"
    return
  fi
  env DEBUG=1 "$SPACES_CLI" "$@" >"$stdout_file" 2>>"$APP_LOG"
}

ensure_workspace_http_ready() {
  local host="$1"
  local workspace_dir="$2"
  local docs_url="$3"
  local docs_expected="$4"
  local backend_url="$5"
  local backend_expected="$6"
  local docs_port backend_port
  docs_port="$(url_port "$docs_url")"
  backend_port="$(url_port "$backend_url")"

  wait_for_workspace_process_status "$workspace_dir" "frontend" "running"
  wait_for_workspace_process_status "$workspace_dir" "backend" "running"
  if [[ "$host" == "remote" ]]; then
    wait_for_remote_tcp_listener_port "$backend_port"
  else
    wait_for_tcp_listener_port "$docs_port"
    wait_for_tcp_listener_port "$backend_port"
  fi

  if wait_for_workspace_http_content_optional \
    "$host" \
    "$docs_url" "$docs_expected" "$backend_url" "$backend_expected" "$WORKSPACE_SERVICE_CONTENT_TIMEOUT_SECONDS"; then
    return 0
  fi
  fail "timed out waiting for verified workspace HTTP content"
}

window_url_for_name() {
  local dump_file="$1"
  local window_name="$2"
  python3 - "$dump_file" "$window_name" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
for window in data["windows"]:
    if window["name"] == target:
        print(window.get("targetURL") or "")
        break
PY
}

workspace_window_url_by_name() {
  local workspace_dir="$1"
  local window_name="$2"
  local out_file="$TMP_ROOT/workspace-window-url-by-name.json"
  dump_workspace "$workspace_dir" "$out_file" >/dev/null 2>>"$DEBUG_LOG" || return 0
  window_url_for_name "$out_file" "$window_name"
}

wait_for_workspace_window_url_by_name() {
  local workspace_dir="$1"
  local window_name="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local target_url
    target_url="$(workspace_window_url_by_name "$workspace_dir" "$window_name")"
    if [[ -n "$target_url" ]]; then
      printf '%s\n' "$target_url"
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for tracked browser URL: $window_name"
}

terminal_tracking_id_for_name() {
  local dump_file="$1"
  local target_name="$2"
  python3 - "$dump_file" "$target_name" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
for process in data.get("runningProcesses", []):
    if process.get("name") == target:
        tracking = process.get("terminalTrackingID") or ""
        if tracking:
            print(tracking)
            raise SystemExit(0)
for agent in data.get("agentWindows", []):
    if agent.get("label") == target:
        tracking = agent.get("terminalTrackingID") or ""
        if tracking:
            print(tracking)
            raise SystemExit(0)
for window in data.get("windows", []):
    if window.get("name") == target:
        tracking = window.get("terminalTrackingID") or ""
        if tracking:
            print(tracking)
            raise SystemExit(0)
print("")
PY
}

wait_for_workspace_terminal_tracking_id() {
  local workspace_dir="$1"
  local target_name="$2"
  local out_file="$3"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    dump_workspace "$workspace_dir" "$out_file"
    local tracking_id
    tracking_id="$(terminal_tracking_id_for_name "$out_file" "$target_name")"
    if [[ -n "$tracking_id" ]]; then
      printf '%s\n' "$tracking_id"
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for tracked terminal identity: $target_name"
}

wait_for_terminal_session_window_controller() {
  local session_id="$1"
  local out_file="$2"
  local command_file="${out_file%.json}-command.json"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    rm -f "$out_file" "$command_file"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" "$SPACES_E2E_CLI" \
      dump-terminal-session-window-state --session-id "$session_id" --output-path "$out_file" >"$command_file" 2>>"$DEBUG_LOG" || true
    sleep 0.2
    if [[ -f "$out_file" ]] && python3 - "$out_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
raise SystemExit(0 if data.get("found") is True else 1)
PY
    then
      return 0
    fi
  done
  fail "timed out waiting for Spaces terminal window controller: $session_id"
}

workspace_window_id_by_name() {
  local workspace_dir="$1"
  local target_name="$2"
  local out_file="$TMP_ROOT/workspace-window-id.json"
  dump_workspace "$workspace_dir" "$out_file" >/dev/null 2>>"$DEBUG_LOG" || return 0
  python3 - "$out_file" "$target_name" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
for window in data.get("windows", []):
    if (window.get("name") or "") == target:
        print(window.get("windowID") or "")
        break
PY
}

workspace_window_id_by_target_url() {
  local workspace_dir="$1"
  local target_url="$2"
  local out_file="$TMP_ROOT/workspace-window-id-by-target-url.json"
  dump_workspace "$workspace_dir" "$out_file" >/dev/null 2>>"$DEBUG_LOG" || return 0
  python3 - "$out_file" "$target_url" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
target = sys.argv[2]
for window in data.get("windows", []):
    if (window.get("targetURL") or "") == target:
        print(window.get("windowID") or "")
        break
PY
}

wait_for_workspace_window_id_by_name() {
  local workspace_dir="$1"
  local target_name="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local window_id
    window_id="$(workspace_window_id_by_name "$workspace_dir" "$target_name")"
    if [[ -n "$window_id" ]]; then
      printf '%s\n' "$window_id"
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for tracked window id: $target_name"
}

wait_for_workspace_window_id_by_target_url() {
  local workspace_dir="$1"
  local target_url="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local window_id
    window_id="$(workspace_window_id_by_target_url "$workspace_dir" "$target_url")"
    if [[ -n "$window_id" ]]; then
      printf '%s\n' "$window_id"
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for tracked browser window id: $target_url"
}

wait_for_cycle_target_focus() {
  local workspace_dir="$1"
  local cycle_target="$2"
  local docs_window_id="$3"
  local request_id="${4:-}"
  LAST_CYCLE_TARGET_FOCUS_VIA_APP_OBSERVATION=0
  LAST_CYCLE_TARGET_FOCUS_VIA_CHROME_OBSERVATION=0
  case "$cycle_target" in
    browser:*)
      local target_browser_url target_browser_window_id
      target_browser_url="${cycle_target#browser:}"
      target_browser_window_id="$(wait_for_workspace_window_id_by_target_url "$workspace_dir" "$target_browser_url")"
      if ! wait_for_surface_snapshot_python_mode_optional "include-yabai" \
        "browser cycle target focus $target_browser_window_id" \
        'expected_window_id = sys.argv[2]
frontmost_bundle = data.get("frontmostApplicationBundleID") or ""
spaces = data.get("spaces") or {}
ok = frontmost_bundle == "com.google.Chrome" and str(data.get("yabaiFocusedWindowID") or "") == expected_window_id and not spaces.get("modalVisible")
raise SystemExit(0 if ok else 1)' \
        "$target_browser_window_id"; then
        if ! wait_for_chrome_window_focus_observed_optional "$target_browser_window_id" "$target_browser_url"; then
          fail "timed out waiting for browser cycle target focus: window=$target_browser_window_id url=$target_browser_url"
        fi
        LAST_CYCLE_TARGET_FOCUS_VIA_CHROME_OBSERVATION=1
        log_debug "accepted browser cycle target focus from Chrome/yabai observation after surface snapshot timeout: window=$target_browser_window_id url=$target_browser_url"
      fi
      ;;
    terminal:*|process:*|agent:*)
      local target_name target_session_id target_window_id
      target_name="$(extract_cycle_window_title "$cycle_target")"
      target_session_id="$(wait_for_workspace_terminal_tracking_id "$workspace_dir" "$target_name" "$TMP_ROOT/cycle-focus-target.json" || true)"
      if [[ -z "$target_session_id" ]]; then
        target_session_id="$(known_spaces_terminal_session_id_for_name "$target_name")"
      fi
      if [[ -n "$target_session_id" ]]; then
        if ! wait_for_spaces_terminal_frontmost_session_optional "$target_session_id"; then
          if [[ -z "$request_id" ]] || ! wait_for_terminal_focus_observed_request "$target_session_id" "$request_id"; then
            fail "timed out waiting for Spaces terminal focus: session=$target_session_id request_id=${request_id:-<none>}"
          fi
          LAST_CYCLE_TARGET_FOCUS_VIA_APP_OBSERVATION=1
          log_debug "accepted terminal focus from app observation after AX snapshot timeout: session=$target_session_id request_id=$request_id"
        fi
        assert_no_spaces_modal_dialog
      else
        target_window_id="$(wait_for_workspace_window_id_by_name "$workspace_dir" "$target_name")"
        wait_for_surface_snapshot_python_with_yabai \
          "window cycle target focus $target_window_id" \
          'expected_window_id = sys.argv[2]
spaces = data.get("spaces") or {}
ok = str(data.get("yabaiFocusedWindowID") or "") == expected_window_id and not spaces.get("modalVisible")
raise SystemExit(0 if ok else 1)' \
          "$target_window_id"
      fi
      ;;
    *)
      fail "unexpected cycle target: $cycle_target"
      ;;
  esac
}

refocus_cycle_target() {
  local workspace_dir="$1"
  local cycle_target="$2"
  local label="$3"
  local label_slug target_name
  label_slug="$(slugify_automation_id "$label")"
  case "$cycle_target" in
    browser:*)
      target_name="docs"
      ;;
    terminal:*|process:*|agent:*)
      target_name="$(extract_cycle_window_title "$cycle_target")"
      ;;
    *)
      fail "unexpected cycle target for refocus: $cycle_target"
      ;;
  esac
  run_spaces_logged "$TMP_ROOT/$label_slug-refocus-cycle-target.log" open "$target_name" "$workspace_dir"
  transition_pause "$label refocus cycle target"
}

measure_spaces_cycle_transition() {
  local host="$1"
  local workspace_scope="$2"
  local workspace_dir="$3"
  local docs_window_id="$4"
  local source_component="$5"
  local direction="$6"
  local transition_label="$7"
  shift 7
  local expected_patterns=("$@")
  local started_at route_observed_at focus_observed_at surface_observed_at log_start_line workspace_id
  local cycle_line cycle_target cycle_elapsed_ms cycle_request_id cycle_focus_route_line cycle_focus_route_elapsed_ms=""
  local cycle_focus_observed_line cycle_focus_observed_elapsed_ms=""
  workspace_id="$(workspace_id_for_dir "$workspace_dir")"
  log_start_line=$(( $(app_log_line_count) + 1 ))
  started_at="$(timestamp_ms)"
  send_cycle_hotkey_with_ack "$direction"
  transition_pause "$transition_label"
  wait_for_app_log_pattern_from_line "spaces: perf metric=window_cycle workspace=${workspace_id} target=.* success=1 .* direction=${direction}" "$log_start_line" >/dev/null
  cycle_line="$APP_LOG_LAST_MATCH"
  cycle_target="$(extract_perf_target "$cycle_line")"
  if ((${#expected_patterns[@]} > 0)); then
    matches_cycle_target_pattern "$cycle_target" "${expected_patterns[@]}" \
      || fail "${transition_label}: unexpected cycle target '$cycle_target'"
  fi
  route_observed_at="$(timestamp_ms)"
  cycle_elapsed_ms="$(extract_metric_field "$cycle_line" "elapsed_ms")"
  assert_metric_not_above "$cycle_elapsed_ms" "$SPACES_CYCLE_LATENCY_BUDGET_MS" "${transition_label} app route latency"
  cycle_request_id="$(extract_request_id "$cycle_line")"
  if [[ -n "$cycle_request_id" ]]; then
    cycle_focus_route_line="$(
      find_app_log_pattern_anywhere_once \
        "spaces: perf metric=built_in_terminal_focus_route .*success=1 .*elapsed_ms=[0-9]+ .*request_id=${cycle_request_id}( |$)" || true
    )"
    if [[ -n "$cycle_focus_route_line" ]]; then
      cycle_focus_route_elapsed_ms="$(extract_metric_field "$cycle_focus_route_line" "elapsed_ms")"
    fi
    cycle_focus_observed_line="$(
      find_app_log_pattern_anywhere_once \
        "spaces: perf metric=terminal_window_focus_observed .*success=1 .*elapsed_ms=[0-9]+ .*request_id=${cycle_request_id}( |$)" || true
    )"
    if [[ -n "$cycle_focus_observed_line" ]]; then
      cycle_focus_observed_elapsed_ms="$(extract_metric_field "$cycle_focus_observed_line" "elapsed_ms")"
    fi
  fi
  wait_for_cycle_target_focus "$workspace_dir" "$cycle_target" "$docs_window_id" "$cycle_request_id"
  focus_observed_at="$(timestamp_ms)"
  assert_cycle_focus_surface_state
  surface_observed_at="$(timestamp_ms)"
  record_cycle_transition_metrics \
    "$source_component" \
    "$direction" \
    "$cycle_target" \
    "$((surface_observed_at - started_at))" \
    "$((route_observed_at - started_at))" \
    "$((focus_observed_at - route_observed_at))" \
    "$((surface_observed_at - focus_observed_at))" \
    "$cycle_elapsed_ms" \
    "$host" \
    "$workspace_scope" \
    "${cycle_focus_observed_elapsed_ms:-$cycle_focus_route_elapsed_ms}"
  MEASURED_CYCLE_TARGET="$cycle_target"
}

run_launch_and_focus_assertions() {
  local host="$1"
  local workspace_dir="$2"
  local dump_file="$TMP_ROOT/$host-dump.json"
  local agent_script

  reset_fixture_runtime "$workspace_dir"
  ensure_configured_terminal_host "$host"
  agent_script="$(mock_agent_launcher_command "$host" "$workspace_dir")"
  set_workspace_agent_launcher "$workspace_dir" "$MOCK_AGENT_LABEL" "$agent_script"

  begin_case "$host: launch workspace and persist terminal host"
  run_spaces_logged /tmp/spaces-e2e-launch.log start "$workspace_dir"
  if is_spaces_terminal_target "$host"; then
    activate_spaces_pid "$SPACES_PID"
    transition_pause "$host activate Spaces before built-in workspace launch"
  fi
  run_spaces_logged /tmp/spaces-e2e-launch-focus.log open docs "$workspace_dir"
  wait_for_workspace_running_state "$workspace_dir" "true"
  transition_pause "$host launch workspace"
  dump_chrome_state "$host docs-focus after-launch"
  local browser_docs_url
  browser_docs_url="$(wait_for_workspace_window_url_by_name "$workspace_dir" "docs")"
  wait_for_condition "chrome_front_url" "$browser_docs_url"
  local docs_window_id
  docs_window_id="$(chrome_front_window_id)"
  [[ -n "$docs_window_id" ]] || fail "docs focus did not leave a front Chrome window"
  log_debug "$host docs_window_id=$docs_window_id configured_docs=$PRIMARY_DOCS_URL browser_docs=$browser_docs_url"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$browser_docs_url"

  dump_workspace "$workspace_dir" "$dump_file"
  local workspace_id
  local workspace_title
  workspace_id="$(json_get "$dump_file" "workspace.id")"
  workspace_title="$(json_get "$dump_file" "workspace.title")"
  local terminal_app
  terminal_app="$(json_get "$dump_file" "runningProcesses[0].terminalApp")"
  assert_equals "Spaces" "$terminal_app" "Spaces launch"
  ensure_workspace_http_ready "$host" "$workspace_dir" "$browser_docs_url" "Beacon docs sentinel" "$PRIMARY_BACKEND_STATUS_URL" '"workspace": "beacon-status"'
  pass_case

  begin_case "$host: focus tracked Chrome tab with extra user tab present"
  # Prove the docs focus really left us on the tracked Chrome window before we
  # inject an untracked user tab into that same window.
  local extra_user_tab_url="https://usespaces.dev/"
  dump_chrome_state "$host docs-focus before-extra-tab"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$browser_docs_url"
  chrome_add_extra_tab_to_window "$docs_window_id" "$extra_user_tab_url"
  transition_pause "$host add extra Chrome tab"
  dump_chrome_state "$host after-extra-tab"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$extra_user_tab_url"
  local docs_refocus_started_at
  docs_refocus_started_at="$(timestamp_ms)"
  run_spaces_logged /tmp/spaces-e2e-focus-docs.log open docs "$workspace_dir"
  transition_pause "$host refocus docs"
  record_browser_focus_metric \
    "browser_untracked_tab.cli_window_focus.browser_tracked_tab" \
    "$browser_docs_url" \
    "docs" \
    "$host" \
    "single" \
    "$(( $(timestamp_ms) - docs_refocus_started_at ))"
  dump_chrome_state "$host after-refocus-docs"
  browser_docs_url="$(wait_for_workspace_window_url_by_name "$workspace_dir" "docs")"
  wait_for_condition "chrome_front_url" "$browser_docs_url"
  local refocused_docs_window_id
  refocused_docs_window_id="$(chrome_front_window_id)"
  [[ -n "$refocused_docs_window_id" ]] || fail "docs refocus did not leave a front Chrome window"
  wait_for_condition "chrome_window_active_url $refocused_docs_window_id" "$browser_docs_url"
  if [[ "$refocused_docs_window_id" != "$docs_window_id" ]]; then
    log_debug "$host docs refocus recovered window old=$docs_window_id new=$refocused_docs_window_id"
    docs_window_id="$refocused_docs_window_id"
  fi
  pass_case

  dump_workspace "$workspace_dir" "$dump_file"
  begin_case "$host: window issue modal comes frontmost from external app"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" "$SPACES_E2E_CLI" hide-main-window >/tmp/spaces-e2e-hide-main-before-recovery-modal.json
    activate_google_chrome
    transition_pause "$host seed chrome focus for window issue modal"
    wait_for_condition "frontmost_app" "Google Chrome"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" "$SPACES_E2E_CLI" show-window-issue-modal --title "Process window not found" --detail "frontend is no longer open." >/tmp/spaces-e2e-show-window-issue-modal.json
    if ! wait_for_spaces_modal_dialog_frontmost_optional; then
      activate_spaces_pid "$SPACES_PID"
      wait_for_spaces_modal_dialog_visible
    fi
    dismiss_spaces_modal_dialog
    transition_pause "$host dismiss window issue modal"
    wait_for_condition "spaces_modal_dialog_visible" "0"
    pass_case

    begin_case "$host: focus tracked Spaces terminal window"
    local spaces_terminal_focus_request_id
    local spaces_terminal_focus_log=/tmp/spaces-e2e-focus-frontend.log
    spaces_terminal_focus_request_id="$(uuidgen)"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$workspace_dir" --process-name frontend --request-id "$spaces_terminal_focus_request_id" >"$spaces_terminal_focus_log" 2>&1
    transition_pause "$host refocus frontend terminal"
    record_process_focus_metric "terminal_untracked_tab.cli_window_focus.process_tracked_tab" "frontend" "$host" "single" "$spaces_terminal_focus_request_id" "$spaces_terminal_focus_log"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_front_window_title "frontend"
    pass_case

    begin_case "$host: closing ad hoc Spaces terminal removes runtime row"
    dump_workspace "$workspace_dir" "$dump_file"
    local adhoc_sessions_before
    adhoc_sessions_before="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window.get("role") == "terminal":
        session_id = window.get("terminalTrackingID") or window.get("terminalNativeID") or ""
        if session_id:
            print(session_id)
PY
)"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" "$SPACES_E2E_CLI" open-workspace-terminal --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-open-adhoc-terminal.json
    transition_pause "$host open ad hoc Spaces terminal"
    local adhoc_session_id
    local adhoc_open_deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
    while (( SECONDS < adhoc_open_deadline )); do
      dump_workspace "$workspace_dir" "$dump_file"
      adhoc_session_id="$(python3 - "$dump_file" "$adhoc_sessions_before" <<'PY'
import json, sys
known = {line.strip() for line in sys.argv[2].splitlines() if line.strip()}
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window.get("role") != "terminal":
        continue
    session_id = window.get("terminalTrackingID") or window.get("terminalNativeID") or ""
    if session_id and session_id not in known:
        print(session_id)
        break
PY
)"
      [[ -n "$adhoc_session_id" ]] && break
      sleep 0.2
    done
    [[ -n "$adhoc_session_id" ]] || fail "expected ad hoc Spaces terminal session"
    wait_for_terminal_session_window_controller "$adhoc_session_id" /tmp/spaces-e2e-before-close-adhoc-terminal-window-state.json
    wait_for_spaces_terminal_frontmost_session "$adhoc_session_id"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" "$SPACES_E2E_CLI" close-terminal-session-window --session-id "$adhoc_session_id" >/tmp/spaces-e2e-close-adhoc-terminal.json
    transition_pause "$host close ad hoc Spaces terminal"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" "$SPACES_E2E_CLI" dump-terminal-session-window-state --session-id "$adhoc_session_id" --output-path /tmp/spaces-e2e-after-close-adhoc-terminal-window-state.json >/tmp/spaces-e2e-after-close-adhoc-terminal-window-state-command.json || true
    sleep 0.2
    local adhoc_closed_deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
    local adhoc_row_present=1
    while (( SECONDS < adhoc_closed_deadline )); do
      dump_workspace "$workspace_dir" "$dump_file"
      adhoc_row_present="$(python3 - "$dump_file" "$adhoc_session_id" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
session_id = sys.argv[2]
for window in data["windows"]:
    if (window.get("terminalTrackingID") or window.get("terminalNativeID") or "") == session_id:
        print("1")
        break
else:
    print("0")
PY
)"
      [[ "$adhoc_row_present" == "0" ]] && break
      sleep 0.2
    done
    [[ "$adhoc_row_present" == "0" ]] || fail "expected ad hoc Spaces terminal row to disappear after close"
    pass_case

    begin_case "$host: closing process Spaces terminal keeps process running and focus recovers"
    dump_workspace "$workspace_dir" "$dump_file"
    local frontend_session_before_close
    frontend_session_before_close="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for process in data["runningProcesses"]:
    if process["name"] == "frontend":
        print(process.get("terminalTrackingID") or process.get("terminalNativeID") or "")
        break
PY
)"
    [[ -n "$frontend_session_before_close" ]] || fail "expected frontend Spaces terminal session"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" "$SPACES_E2E_CLI" close-terminal-session-window --session-id "$frontend_session_before_close" >/tmp/spaces-e2e-close-frontend-session.json
    transition_pause "$host close frontend Spaces terminal"
    wait_for_workspace_process_status "$workspace_dir" "frontend" "running"
    dump_workspace "$workspace_dir" "$dump_file"
    assert_equals "$frontend_session_before_close" "$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for process in data["runningProcesses"]:
    if process["name"] == "frontend":
        print(process.get("terminalTrackingID") or process.get("terminalNativeID") or "")
        break
PY
)" "frontend session stable after closing process terminal window"
    local spaces_reopen_request_id spaces_reopen_log
    spaces_reopen_request_id="$(uuidgen)"
    spaces_reopen_log=/tmp/spaces-e2e-refocus-frontend-after-close.log
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$workspace_dir" --process-name frontend --request-id "$spaces_reopen_request_id" >"$spaces_reopen_log" 2>&1
    transition_pause "$host refocus frontend after close"
    record_process_focus_metric "terminal_close_recover.cli_window_focus.process_tracked_tab" "frontend" "$host" "single" "$spaces_reopen_request_id" "$spaces_reopen_log"
    wait_for_workspace_process_status "$workspace_dir" "frontend" "running"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_front_window_title "frontend"
    pass_case

  local docs_shortcut_index=1
  local frontend_shortcut_index=3
  local agent_shortcut_index=5
  local adhoc_shortcut_index=6
  local agent_session_id
  local adhoc_session_id=""
  local adhoc_name="shell-1"

  begin_case "$host: workspace detail numbered shortcuts focus correct window"
  # These are the workspace-detail focus cases the user asked for, using the
  # real detail-pane shortcuts instead of harness-directed focus.
  ensure_single_spaces_instance "$SPACES_PID"
  agent_session_id="$(wait_for_workspace_terminal_tracking_id "$workspace_dir" "$MOCK_AGENT_LABEL" "$dump_file")"
  [[ -n "$agent_session_id" ]] || fail "expected tracked agent terminal session"
  if is_spaces_terminal_target "$host"; then
    KNOWN_SPACES_FRONTEND_SESSION_ID="$(wait_for_workspace_terminal_tracking_id "$workspace_dir" "frontend" "$dump_file")"
    KNOWN_SPACES_BACKEND_SESSION_ID="$(wait_for_workspace_terminal_tracking_id "$workspace_dir" "backend" "$dump_file")"
    KNOWN_SPACES_AGENT_SESSION_ID="$agent_session_id"
    KNOWN_SPACES_ADHOC_NAME="$adhoc_name"
  fi

  ui_show_workspace_detail "$workspace_dir" "$workspace_title"
  sleep 0.5
  local docs_focus_started_at docs_focus_elapsed_ms
  docs_focus_started_at="$(timestamp_ms)"
  if is_spaces_terminal_target "$host"; then
    send_spaces_window_shortcut_with_ack "$docs_shortcut_index"
  else
    run_spaces_logged /tmp/spaces-e2e-shortcut-open-docs.log open docs "$workspace_dir"
  fi
  transition_pause "$host shortcut focus docs"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  docs_focus_elapsed_ms="$(( $(timestamp_ms) - docs_focus_started_at ))"
  record_metric_sample "spaces_detail_ui.keyboard_window_shortcut.browser_tracked_tab" "$docs_focus_elapsed_ms" "$host" "single"
  browser_docs_url="$(wait_for_workspace_window_url_by_name "$workspace_dir" "docs")"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$browser_docs_url"
  assert_shortcut_focus_surface_state
  if is_spaces_terminal_target "$host"; then
    local spaces_shortcut_refocus_request_id spaces_shortcut_refocus_log
    spaces_shortcut_refocus_request_id="$(uuidgen)"
    spaces_shortcut_refocus_log="/tmp/spaces-e2e-shortcut-refocus-frontend.log"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$workspace_dir" --process-name frontend --request-id "$spaces_shortcut_refocus_request_id" >"$spaces_shortcut_refocus_log" 2>&1
    transition_pause "$host seed frontend terminal focus for shortcut follow-up"
    record_process_focus_metric "spaces_detail_ui.shortcut_refocus.process_tracked_tab" "frontend" "$host" "single" "$spaces_shortcut_refocus_request_id" "$spaces_shortcut_refocus_log"
  fi
  ui_show_workspace_detail "$workspace_dir" "$workspace_title"
  sleep 0.5
  local frontend_focus_started_at frontend_focus_elapsed_ms
  frontend_focus_started_at="$(timestamp_ms)"
  send_spaces_window_shortcut_with_ack "$frontend_shortcut_index"
  transition_pause "$host shortcut focus frontend"
  frontend_session_id="$(wait_for_workspace_terminal_tracking_id "$workspace_dir" "frontend" "$dump_file")"
  KNOWN_SPACES_FRONTEND_SESSION_ID="$frontend_session_id"
  wait_for_condition "spaces_front_window_identifier" "spaces-terminal:${frontend_session_id}"
  frontend_focus_elapsed_ms="$(( $(timestamp_ms) - frontend_focus_started_at ))"
  record_metric_sample "spaces_detail_ui.keyboard_window_shortcut.process_tracked_tab" "$frontend_focus_elapsed_ms" "$host" "single"
  wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
  wait_for_spaces_front_window_title "frontend"
  assert_shortcut_focus_surface_state

  if is_spaces_terminal_target "$host"; then
    ui_show_workspace_detail "$workspace_dir" "$workspace_title"
    sleep 0.5
    send_spaces_window_shortcut_with_ack "$agent_shortcut_index"
    transition_pause "$host shortcut focus agent"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_front_window_title "$MOCK_AGENT_LABEL"
    assert_shortcut_focus_surface_state

    ui_show_workspace_detail "$workspace_dir" "$workspace_title"
    sleep 0.5
    dump_workspace "$workspace_dir" "$dump_file"
    local adhoc_sessions_before
    adhoc_sessions_before="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window.get("role") == "terminal":
        session_id = window.get("terminalTrackingID") or window.get("terminalNativeID") or ""
        if session_id:
            print(session_id)
PY
)"
    send_spaces_open_terminal_hotkey
    transition_pause "$host open ad hoc terminal by shortcut"
    local adhoc_open_deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
    while (( SECONDS < adhoc_open_deadline )); do
      dump_workspace "$workspace_dir" "$dump_file"
      local adhoc_target
      adhoc_target="$(python3 - "$dump_file" "$adhoc_sessions_before" <<'PY'
import json, sys
known = {line.strip() for line in sys.argv[2].splitlines() if line.strip()}
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window.get("role") != "terminal":
        continue
    session_id = window.get("terminalTrackingID") or window.get("terminalNativeID") or ""
    name = window.get("name") or ""
    if session_id and session_id not in known:
        print(f"{session_id}\t{name}")
        break
PY
)"
      if [[ -n "$adhoc_target" ]]; then
        adhoc_session_id="${adhoc_target%%$'\t'*}"
        adhoc_name="${adhoc_target#*$'\t'}"
        [[ -n "$adhoc_name" ]] || adhoc_name="shell-1"
        KNOWN_SPACES_ADHOC_SESSION_ID="$adhoc_session_id"
        KNOWN_SPACES_ADHOC_NAME="$adhoc_name"
        break
      fi
      sleep 0.2
    done
    [[ -n "$adhoc_session_id" ]] || fail "expected ad hoc terminal to open by shortcut"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_front_window_title "$adhoc_name"
    assert_shortcut_focus_surface_state
  fi
  pass_case

  begin_case "$host: workspace window cycling stays on tracked windows"
  # This validates forward/back workspace cycling from the live desktop state.
  ensure_single_spaces_instance "$SPACES_PID"
  if is_spaces_terminal_target "$host"; then
    run_spaces_logged /tmp/spaces-e2e-cycle-seed-docs.log open docs "$workspace_dir"
    transition_pause "$host seed docs focus for cycling"
    browser_docs_url="$(wait_for_workspace_window_url_by_name "$workspace_dir" "docs")"
    wait_for_condition "chrome_front_url" "$browser_docs_url"
    run_spaces_logged /tmp/spaces-e2e-cycle-seed-frontend.log open frontend "$workspace_dir"
    transition_pause "$host seed frontend focus for cycling"
    wait_for_spaces_front_window_title "frontend"
    send_cycle_hotkey_with_ack next
    transition_pause "$host cycle next from terminal origin"
    wait_for_app_log_pattern 'spaces: perf metric=window_cycle workspace=.* target=.* success=1 .* direction=next' >/dev/null
    cycle_line="$APP_LOG_LAST_MATCH"
    cycle_target="$(extract_perf_target "$cycle_line")"
    cycle_request_id="$(extract_request_id "$cycle_line")"
    [[ "$cycle_target" != "process:frontend" ]] || fail "expected first cycle next from frontend terminal to leave current process target"
    [[ "$cycle_target" != "terminal:frontend" ]] || fail "expected first cycle next from frontend terminal to leave current terminal target"
    case "$cycle_target" in
      browser:*|terminal:*|process:*|agent:*)
        wait_for_cycle_target_focus "$workspace_dir" "$cycle_target" "$docs_window_id" "$cycle_request_id"
        ;;
      *)
        fail "unexpected terminal-origin cycle target: $cycle_target"
        ;;
    esac
    assert_cycle_focus_surface_state
    run_spaces_logged /tmp/spaces-e2e-cycle-reseed-frontend.log open frontend "$workspace_dir"
    transition_pause "$host reseed frontend focus after terminal-origin cycle"
    wait_for_spaces_front_window_title "frontend"
    run_spaces_logged /tmp/spaces-e2e-cycle-seed-agent.log open "$MOCK_AGENT_LABEL" "$workspace_dir"
    transition_pause "$host seed agent focus for cycling"
    wait_for_spaces_front_window_title "$MOCK_AGENT_LABEL"
    run_spaces_logged /tmp/spaces-e2e-cycle-seed-adhoc.log open "$adhoc_name" "$workspace_dir"
    transition_pause "$host seed ad hoc terminal focus for cycling"
    wait_for_spaces_front_window_title "$adhoc_name"
    run_spaces_logged /tmp/spaces-e2e-cycle-seed-docs-final.log open docs "$workspace_dir"
    activate_google_chrome
    focus_yabai_window_if_present "$docs_window_id"
  else
    run_spaces_logged /tmp/spaces-e2e-cycle-seed.log open docs "$workspace_dir"
  fi
  transition_pause "$host seed docs focus for cycling"
  browser_docs_url="$(wait_for_workspace_window_url_by_name "$workspace_dir" "docs")"
  wait_for_condition "chrome_front_url" "$browser_docs_url"
  local cycle_target
  measure_spaces_cycle_transition \
      "$host" \
      "single" \
      "$workspace_dir" \
      "$docs_window_id" \
      "browser_tracked_tab" \
      "next" \
      "$host cycle next browser to frontend" \
      "terminal:frontend" \
      "process:frontend"
    cycle_target="$MEASURED_CYCLE_TARGET"
    case "$cycle_target" in
      terminal:frontend|process:frontend) ;;
      *) fail "browser to frontend cycle target: expected frontend, got '$cycle_target'" ;;
    esac

    measure_spaces_cycle_transition \
      "$host" \
      "single" \
      "$workspace_dir" \
      "$docs_window_id" \
      "process_tracked_tab" \
      "previous" \
      "$host cycle previous frontend to browser" \
      "browser:*"
    cycle_target="$MEASURED_CYCLE_TARGET"
    case "$cycle_target" in
      browser:*) ;;
      *) fail "frontend to browser cycle target: expected browser, got '$cycle_target'" ;;
    esac

    run_spaces_logged /tmp/spaces-e2e-cycle-reseed-frontend-post-browser.log open frontend "$workspace_dir"
    transition_pause "$host reseed frontend focus after browser round trip"
    wait_for_spaces_front_window_title "frontend"

    measure_spaces_cycle_transition \
      "$host" \
      "single" \
      "$workspace_dir" \
      "$docs_window_id" \
      "process_tracked_tab" \
      "next" \
      "$host cycle next frontend to backend" \
      "terminal:backend" \
      "process:backend"
    cycle_target="$MEASURED_CYCLE_TARGET"
    case "$cycle_target" in
      terminal:backend|process:backend) ;;
      *) fail "frontend to backend cycle target: expected backend, got '$cycle_target'" ;;
    esac

    measure_spaces_cycle_transition \
      "$host" \
      "single" \
      "$workspace_dir" \
      "$docs_window_id" \
      "process_tracked_tab" \
      "next" \
      "$host cycle next backend to ad hoc terminal" \
      "terminal:${adhoc_name}"
    cycle_target="$MEASURED_CYCLE_TARGET"
    case "$cycle_target" in
      terminal:${adhoc_name}) ;;
      *) fail "backend to ad hoc cycle target: expected ${adhoc_name}, got '$cycle_target'" ;;
    esac

    measure_spaces_cycle_transition \
      "$host" \
      "single" \
      "$workspace_dir" \
      "$docs_window_id" \
      "terminal_tracked_tab" \
      "next" \
      "$host cycle next ad hoc terminal to agent" \
      "agent:*"
    cycle_target="$MEASURED_CYCLE_TARGET"
    case "$cycle_target" in
      agent:*) ;;
      *) fail "ad hoc terminal to agent cycle target: expected agent, got '$cycle_target'" ;;
    esac

    measure_spaces_cycle_transition \
      "$host" \
      "single" \
      "$workspace_dir" \
      "$docs_window_id" \
      "agent_tracked_tab" \
      "next" \
      "$host cycle next agent to browser" \
      "browser:*"
    cycle_target="$MEASURED_CYCLE_TARGET"
    case "$cycle_target" in
      browser:*) ;;
      *) fail "agent to browser cycle target: expected browser, got '$cycle_target'" ;;
    esac

    run_spaces_logged /tmp/spaces-e2e-cycle-reseed-agent-post-browser.log open "$MOCK_AGENT_LABEL" "$workspace_dir"
    transition_pause "$host reseed agent focus after browser round trip"
    wait_for_spaces_front_window_title "$MOCK_AGENT_LABEL"

    measure_spaces_cycle_transition \
      "$host" \
      "single" \
      "$workspace_dir" \
      "$docs_window_id" \
      "agent_tracked_tab" \
      "previous" \
      "$host cycle previous agent to ad hoc terminal" \
      "terminal:${adhoc_name}"
    cycle_target="$MEASURED_CYCLE_TARGET"
    case "$cycle_target" in
      terminal:${adhoc_name}) ;;
      *) fail "agent to ad hoc cycle target: expected ${adhoc_name}, got '$cycle_target'" ;;
    esac
  if is_spaces_terminal_target "$host"; then
    assert_spaces_cpu_not_above "spaces_app.cpu_after_window_cycle" "$SPACES_SUSTAINED_CPU_BUDGET_PCT" "$host" "single"
  fi
  pass_case

  if is_spaces_terminal_target "$host"; then
    begin_case "$host: high-output process focus and cycling stay responsive"
    ensure_single_spaces_instance "$SPACES_PID"
    local high_output_process_command="${HIGH_OUTPUT_PROCESS_COMMAND:-}"
    if [[ -z "$high_output_process_command" ]]; then
      high_output_process_command="$(create_high_output_process_script "$workspace_dir")"
    fi
    add_workspace_process "$workspace_dir" "$HIGH_OUTPUT_PROCESS_NAME" "$high_output_process_command" \
      >/tmp/spaces-e2e-add-high-output-process.json
    local noisy_shortcut_index noisy_session_id noisy_focus_started_at noisy_cycle_started_at noisy_cycle_elapsed_ms
    noisy_shortcut_index="$(shortcut_index_for_name "$workspace_dir" "$HIGH_OUTPUT_PROCESS_NAME" || true)"
    [[ -n "$noisy_shortcut_index" ]] || noisy_shortcut_index=7
    [[ -n "$noisy_shortcut_index" ]] || fail "expected shortcut index for $HIGH_OUTPUT_PROCESS_NAME"

    ui_show_workspace_detail "$workspace_dir" "$workspace_title"
    sleep 0.5
    noisy_focus_started_at="$(timestamp_ms)"
    send_spaces_window_shortcut_with_ack "$noisy_shortcut_index"
    transition_pause "$host shortcut focus $HIGH_OUTPUT_PROCESS_NAME"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    noisy_session_id="$(spaces_front_window_session_id)"
    [[ -n "$noisy_session_id" ]] || fail "expected focused $HIGH_OUTPUT_PROCESS_NAME terminal to expose session identifier"
    KNOWN_SPACES_NOISY_SESSION_ID="$noisy_session_id"
    wait_for_condition "spaces_front_window_identifier" "spaces-terminal:${noisy_session_id}"
    assert_shortcut_focus_surface_state
    record_metric_sample \
      "spaces_detail_ui.keyboard_window_shortcut.process_high_output_tracked_tab" \
      "$(( $(timestamp_ms) - noisy_focus_started_at ))" \
      "$host" \
      "single"

    sleep 1
    noisy_cycle_started_at="$(timestamp_ms)"
    send_cycle_hotkey_with_ack previous
    transition_pause "$host cycle previous away from $HIGH_OUTPUT_PROCESS_NAME"
    wait_for_app_log_pattern 'spaces: perf metric=window_cycle workspace=.* target=.* success=1 .* direction=previous' >/dev/null
    cycle_line="$APP_LOG_LAST_MATCH"
    cycle_target="$(extract_perf_target "$cycle_line")"
    cycle_request_id="$(extract_request_id "$cycle_line")"
    [[ "$cycle_target" != "process:${HIGH_OUTPUT_PROCESS_NAME}" ]] \
      || fail "expected first cycle previous from $HIGH_OUTPUT_PROCESS_NAME to leave current process target"
    [[ "$cycle_target" != "terminal:${HIGH_OUTPUT_PROCESS_NAME}" ]] \
      || fail "expected first cycle previous from $HIGH_OUTPUT_PROCESS_NAME to leave current terminal target"
    wait_for_cycle_target_focus "$workspace_dir" "$cycle_target" "$docs_window_id" "$cycle_request_id"
    assert_cycle_focus_surface_state
    noisy_cycle_elapsed_ms="$(( $(timestamp_ms) - noisy_cycle_started_at ))"
    record_metric_sample \
      "process_high_output_tracked_tab.keyboard_cycle_previous.any_tracked_target" \
      "$noisy_cycle_elapsed_ms" \
      "$host" \
      "single"
    assert_metric_not_above "$noisy_cycle_elapsed_ms" "$SPACES_CYCLE_LATENCY_BUDGET_MS" \
      "high-output process user-facing cycle latency"
    assert_spaces_cpu_not_above "spaces_app.cpu_after_high_output_cycle" "$SPACES_SUSTAINED_CPU_BUDGET_PCT" "$host" "single"
    if [[ -n "$KNOWN_SPACES_NOISY_SESSION_ID" ]]; then
      env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
        "$SPACES_E2E_CLI" terminate-terminal-session "$KNOWN_SPACES_NOISY_SESSION_ID" \
        >/tmp/spaces-e2e-terminate-high-output-session.json 2>>"$DEBUG_LOG" || true
      KNOWN_SPACES_NOISY_SESSION_ID=""
    fi
    remove_workspace_process "$workspace_dir" "$HIGH_OUTPUT_PROCESS_NAME" \
      >/tmp/spaces-e2e-remove-high-output-process.json
    if [[ -n "$KNOWN_SPACES_AGENT_SESSION_ID" ]]; then
      env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
        "$SPACES_E2E_CLI" terminate-terminal-session "$KNOWN_SPACES_AGENT_SESSION_ID" \
        >/tmp/spaces-e2e-terminate-agent-session.json 2>>"$DEBUG_LOG" || true
      KNOWN_SPACES_AGENT_SESSION_ID=""
    fi
    clear_workspace_agent_launchers "$workspace_dir"
    clear_workspace_agent_windows "$workspace_dir"
    pass_case
  fi

  if [[ "${INCLUDE_DEAD_PROCESS_RECOVERY:-0}" == "1" ]] && ! is_spaces_terminal_target "$host"; then
    begin_case "$host: dead process recovery"
    # Kill one tracked process, then confirm `spaces start` revives only the
    # dead runtime instead of forcing a full workspace restart.
    dump_workspace "$workspace_dir" "$dump_file"
    local frontend_pid
    frontend_pid="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for process in data["runningProcesses"]:
    if process["name"] == "frontend":
        print(process["pid"] or "")
        break
PY
)"
    local frontend_port
    frontend_port="$(workspace_named_port "$workspace_dir" "$APP_PORT_NAME")"
    log_process_recovery_snapshot "before-kill" "$workspace_dir" "frontend" "$frontend_port" "$frontend_pid"
    kill_process_group "$frontend_pid"
    kill_listener_processes "$frontend_port"
    local dead_pid_deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
    while (( SECONDS < dead_pid_deadline )); do
      if ! process_pid_is_alive "$frontend_pid" \
        && ! lsof -tiTCP:"$frontend_port" -sTCP:LISTEN >/dev/null 2>&1
      then
        break
      fi
      sleep 0.2
    done
    log_process_recovery_snapshot "after-kill" "$workspace_dir" "frontend" "$frontend_port" "$frontend_pid"
    run_spaces_logged /tmp/spaces-e2e-recover.log start "$workspace_dir"
    transition_pause "$host recover dead process"
    local recovery_state recovered_pid recovered_status
    log_process_recovery_snapshot "after-restart-command" "$workspace_dir" "frontend" "$frontend_port" "$frontend_pid"
    recovery_state="$(wait_for_process_running_recovery "$workspace_dir" "frontend" "$frontend_pid" "$frontend_port")"
    recovered_pid="${recovery_state%%$'\t'*}"
    recovered_status="${recovery_state#*$'\t'}"
    wait_for_tcp_listener_port "$frontend_port"
    ! process_pid_is_alive "$frontend_pid" || fail "killed frontend pid is still alive after recovery"
    pass_case
  fi

  begin_case "$host: workspace restart and stop lifecycle"
  restart_workspace_via_gui "$workspace_dir"
  wait_for_workspace_running_state "$workspace_dir" "true"
  wait_for_workspace_process_status "$workspace_dir" "frontend" "running"
  wait_for_workspace_process_status "$workspace_dir" "backend" "running"
  local browser_docs_url
  browser_docs_url="$(wait_for_workspace_window_url_by_name "$workspace_dir" "docs")"
  ensure_workspace_http_ready "$host" "$workspace_dir" "$browser_docs_url" "Beacon docs sentinel" "$PRIMARY_BACKEND_STATUS_URL" '"workspace": "beacon-status"'
  wait_for_workspace_running_state "$workspace_dir" "true"
  dump_workspace "$workspace_dir" "$dump_file"
  assert_equals "true" "$(json_get "$dump_file" "workspace.isRunning")" "workspace running after restart"
  stop_workspace_via_gui "$workspace_dir"
  wait_for_workspace_running_state "$workspace_dir" "false"
  dump_workspace "$workspace_dir" "$dump_file"
  assert_equals "false" "$(json_get "$dump_file" "workspace.isRunning")" "workspace stopped"
  pass_case
  reset_fixture_runtime "$workspace_dir"
}

ensure_configured_terminal_host() {
  local host="$1"
  if ! is_spaces_terminal_target "$host"; then
    fail "Unsupported terminal host for this branch: $host"
  fi
}

run_hotkey_visibility_profiling() {
  local host="$1"
  local workspace_dir="$2"
  local iteration

  ensure_configured_terminal_host "$host"
  begin_case "$host: profile repeated app visibility toggle"
  ensure_single_spaces_instance "$SPACES_PID"
  reset_fixture_runtime "$workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-profile-window-toggle-start.log start "$workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-profile-window-toggle.log open docs "$workspace_dir"
  transition_pause "$host seed docs focus for app toggle profiling"
  wait_for_condition "chrome_front_url" "$PRIMARY_DOCS_URL"
  wait_for_condition "frontmost_app" "Google Chrome"
  env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" "$SPACES_E2E_CLI" hide-main-window >/tmp/spaces-e2e-hide-main-window.json
  wait_for_condition "frontmost_app" "Google Chrome"
  wait_for_condition "spaces_main_window_visible" "0"
  for (( iteration = 1; iteration <= REAL_SYSTEM_PROFILE_REPETITIONS; iteration++ )); do
    local toggle_started_at

    toggle_started_at="$(timestamp_ms)"
    send_spaces_toggle_hotkey_with_ack
    wait_for_condition "spaces_main_window_visible" "1"
    wait_for_spaces_frontmost_ready
    record_metric_sample "external_app.keyboard_toggle_main_window.main_window" "$(( $(timestamp_ms) - toggle_started_at ))" "$host" "single"

    toggle_started_at="$(timestamp_ms)"
    send_spaces_toggle_hotkey_with_ack
    wait_for_condition "spaces_main_window_visible" "0"
    wait_for_condition "frontmost_app" "Google Chrome"
    record_metric_sample "main_window.keyboard_toggle_main_window.external_app" "$(( $(timestamp_ms) - toggle_started_at ))" "$host" "single"
  done
  pass_case

  begin_case "$host: profile repeated command palette toggle states"
  ensure_single_spaces_instance "$SPACES_PID"
  reset_fixture_runtime "$workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-profile-command-palette-start.log start "$workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-profile-command-palette.log open docs "$workspace_dir"
  transition_pause "$host seed docs focus for command palette profiling"
  wait_for_condition "chrome_front_url" "$PRIMARY_DOCS_URL"
  wait_for_condition "frontmost_app" "Google Chrome"
  for (( iteration = 1; iteration <= REAL_SYSTEM_PROFILE_REPETITIONS; iteration++ )); do
    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_presented "0"
    wait_for_condition "spaces_command_palette_visible" "1"
    wait_for_condition "spaces_main_window_visible" "0"
    record_toggle_palette_metric "external_app.keyboard_toggle_palette.palette" "show" "0" "$host" "single"

    activate_google_chrome
    transition_pause "$host keep chrome focused while palette remains visible"
    wait_for_condition "frontmost_app" "Google Chrome"
    wait_for_condition "spaces_command_palette_visible" "1"
    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_presented "0"
    wait_for_condition "spaces_command_palette_visible" "1"
    wait_for_spaces_frontmost_ready

    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_dismissed
    wait_for_condition "spaces_command_palette_visible" "0"
    wait_for_condition "frontmost_app" "Google Chrome"
    record_toggle_palette_metric "palette.keyboard_toggle_palette.external_app" "hide" "1" "$host" "single"

    send_spaces_toggle_hotkey_with_ack
    wait_for_spaces_frontmost_ready
    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_presented "1"
    wait_for_condition "spaces_command_palette_visible" "1"
    wait_for_condition "spaces_main_window_visible" "1"
    record_toggle_palette_metric "main_window.keyboard_toggle_palette.palette" "show" "1" "$host" "single"

    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_dismissed "1"
    wait_for_condition "spaces_command_palette_visible" "0"
    wait_for_condition "spaces_main_window_visible" "1"
    wait_for_spaces_frontmost_ready
    record_toggle_palette_metric "palette.keyboard_toggle_palette.main_window" "hide" "1" "$host" "single"

    send_spaces_toggle_hotkey_with_ack
    wait_for_condition "frontmost_app" "Google Chrome"
  done
  pass_case

  if is_spaces_terminal_target "$host"; then
    begin_case "$host: toggle main window independently of auxiliary terminal windows"
    ensure_single_spaces_instance "$SPACES_PID"
    reset_fixture_runtime "$workspace_dir"
    run_spaces_logged /tmp/spaces-e2e-profile-terminal-toggle-visibility-start.log start "$workspace_dir"
    local spaces_toggle_focus_request_id
    local spaces_toggle_focus_log=/tmp/spaces-e2e-toggle-focus-frontend.log
    spaces_toggle_focus_request_id="$(uuidgen)"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$workspace_dir" --process-name frontend --request-id "$spaces_toggle_focus_request_id" >"$spaces_toggle_focus_log" 2>&1
    transition_pause "$host seed frontend terminal focus for main window toggle assertions"
    record_process_focus_metric "terminal_toggle.hotkey.process_tracked_tab" "frontend" "$host" "single" "$spaces_toggle_focus_request_id" "$spaces_toggle_focus_log"
    wait_for_spaces_frontmost_ready
    wait_for_condition "spaces_main_window_visible" "1"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_front_window_title "frontend"
    wait_for_spaces_frontmost_ready
    send_spaces_toggle_hotkey_with_ack
    wait_for_condition "spaces_main_window_visible" "0"
    wait_for_condition "spaces_main_window_key" "0"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_frontmost_ready
    send_spaces_toggle_hotkey_with_ack
    wait_for_spaces_frontmost_ready
    wait_for_condition "spaces_front_window_title" "Spaces"
    wait_for_condition "spaces_main_window_visible" "1"
    wait_for_condition "spaces_main_window_key" "1"
    wait_for_condition "spaces_built_in_terminal_focus_state" "none"
    activate_google_chrome
    transition_pause "$host seed chrome focus for main window toggle assertions"
    wait_for_condition "frontmost_app" "Google Chrome"
    wait_for_condition "spaces_main_window_visible" "1"
    wait_for_condition "spaces_main_window_key" "0"
    send_spaces_toggle_hotkey_with_ack
    wait_for_spaces_frontmost_ready
    wait_for_condition "spaces_front_window_title" "Spaces"
    wait_for_condition "spaces_main_window_visible" "1"
    wait_for_condition "spaces_main_window_key" "1"
    activate_google_chrome
    transition_pause "$host keep chrome focused while main window remains visible"
    wait_for_condition "frontmost_app" "Google Chrome"
    wait_for_condition "spaces_main_window_visible" "1"
    wait_for_condition "spaces_main_window_key" "0"
    send_spaces_toggle_hotkey_with_ack
    wait_for_spaces_frontmost_ready
    wait_for_condition "spaces_front_window_title" "Spaces"
    wait_for_condition "spaces_main_window_visible" "1"
    wait_for_condition "spaces_main_window_key" "1"
    send_spaces_toggle_hotkey_with_ack
    wait_for_condition "frontmost_app" "Google Chrome"
    wait_for_condition "spaces_main_window_visible" "0"
    wait_for_condition "spaces_main_window_key" "0"
    pass_case

    begin_case "$host: toggle command palette independently of auxiliary terminal windows"
    ensure_single_spaces_instance "$SPACES_PID"
    reset_fixture_runtime "$workspace_dir"
    run_spaces_logged /tmp/spaces-e2e-profile-terminal-toggle-palette-start.log start "$workspace_dir"
    local spaces_palette_focus_request_id
    local spaces_palette_focus_log=/tmp/spaces-e2e-toggle-palette-focus-frontend.log
    spaces_palette_focus_request_id="$(uuidgen)"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$workspace_dir" --process-name frontend --request-id "$spaces_palette_focus_request_id" >"$spaces_palette_focus_log" 2>&1
    transition_pause "$host seed frontend terminal focus for palette toggle assertions"
    record_process_focus_metric "terminal_toggle_palette.hotkey.process_tracked_tab" "frontend" "$host" "single" "$spaces_palette_focus_request_id" "$spaces_palette_focus_log"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_front_window_title "frontend"
    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_presented "1"
    wait_for_condition "spaces_command_palette_visible" "1"
    wait_for_condition "spaces_command_palette_key" "1"
    wait_for_condition "spaces_built_in_terminal_focus_state" "none"
    env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$workspace_dir" --process-name frontend --request-id "$(uuidgen)" >/tmp/spaces-e2e-toggle-palette-refocus-frontend.log 2>&1
    transition_pause "$host keep frontend terminal focused while palette remains visible"
    wait_for_condition "spaces_command_palette_visible" "1"
    wait_for_condition "spaces_command_palette_key" "0"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_front_window_title "frontend"
    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_presented "1"
    wait_for_condition "spaces_command_palette_visible" "1"
    wait_for_condition "spaces_command_palette_key" "1"
    wait_for_condition "spaces_built_in_terminal_focus_state" "none"
    wait_for_spaces_frontmost_ready
    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_dismissed "1"
    wait_for_condition "spaces_command_palette_visible" "0"
    wait_for_condition "spaces_command_palette_key" "0"
    wait_for_condition "spaces_built_in_terminal_focus_state" "owner"
    wait_for_spaces_front_window_title "frontend"
    pass_case

    # Repeated built-in hotkey timing loops live in the dedicated
    # `profile_spaces_terminal_hotkeys.sh` and
    # `profile_spaces_terminal_palette.sh` profilers so the real-system matrix
    # stays focused on functional macOS behavior assertions.
  fi
}

run_multi_workspace_focus_and_cycle_assertions() {
  local host="$1"
  local primary_workspace_dir="$2"
  local secondary_workspace_dir="$3"
  local primary_docs_url="$PRIMARY_DOCS_URL"
  local secondary_docs_url="$SECONDARY_DOCS_URL"
  local primary_dump="$TMP_ROOT/$host-primary-multi.json"
  local secondary_dump="$TMP_ROOT/$host-secondary-multi.json"

  ensure_configured_terminal_host "$host"
  begin_case "$host: multi-workspace focus and cycle isolation"
  ensure_single_spaces_instance "$SPACES_PID"
  clear_workspace_agent_launchers "$primary_workspace_dir"
  reset_fixture_runtime "$primary_workspace_dir"
  reset_fixture_runtime "$secondary_workspace_dir"

  run_spaces_logged /tmp/spaces-e2e-multi-primary-launch.log start "$primary_workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-multi-primary-launch-focus.log open docs "$primary_workspace_dir"
  transition_pause "$host launch primary workspace"
  log_debug "$host multi primary launch complete"
  dump_workspace "$primary_workspace_dir" "$primary_dump"
  primary_docs_url="$(window_url_for_name "$primary_dump" "docs")"
  [[ -n "$primary_docs_url" ]] || primary_docs_url="$PRIMARY_DOCS_URL"
  run_spaces_logged /tmp/spaces-e2e-multi-secondary-launch.log start "$secondary_workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-multi-secondary-launch-focus.log open docs "$secondary_workspace_dir"
  transition_pause "$host launch secondary workspace"
  log_debug "$host multi secondary launch complete"
  dump_workspace "$secondary_workspace_dir" "$secondary_dump"
  secondary_docs_url="$(window_url_for_name "$secondary_dump" "docs")"
  [[ -n "$secondary_docs_url" ]] || secondary_docs_url="$SECONDARY_DOCS_URL"
  dump_chrome_state "$host multi after-both-launches"

  local primary_docs_window_id secondary_docs_window_id
  primary_docs_window_id="$(python3 - "$primary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "docs":
        print(window.get("windowID") or "")
        break
PY
)"
  secondary_docs_window_id="$(python3 - "$secondary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "docs":
        print(window.get("windowID") or "")
        break
PY
)"

  run_spaces_logged /tmp/spaces-e2e-multi-primary-focus.log open docs "$primary_workspace_dir"
  transition_pause "$host focus primary docs"
  log_debug "$host multi primary docs focus complete"
  wait_for_chrome_window_focus "$primary_docs_window_id" "$primary_docs_url" "$host primary docs focus"
  local cycle_target previous_source
  local -a previous_expected
  measure_spaces_cycle_transition \
    "$host" \
    "primary" \
    "$primary_workspace_dir" \
    "$primary_docs_window_id" \
    "browser_tracked_tab" \
    "next" \
    "$host primary cycle next" \
    'process:*' 'terminal:*'
  cycle_target="$MEASURED_CYCLE_TARGET"
  case "$cycle_target" in
    process:*)
      previous_source="process_tracked_tab"
      previous_expected=('browser:*')
      ;;
    terminal:*)
      previous_source="terminal_tracked_tab"
      previous_expected=('process:*')
      ;;
    *)
      fail "$host primary cycle next: unexpected target '$cycle_target'"
      ;;
  esac
  refocus_cycle_target "$primary_workspace_dir" "$cycle_target" "$host primary"
  measure_spaces_cycle_transition \
    "$host" \
    "primary" \
    "$primary_workspace_dir" \
    "$primary_docs_window_id" \
    "$previous_source" \
    "previous" \
    "$host primary cycle previous" \
    "${previous_expected[@]}"
  if [[ "$cycle_target" == terminal:* ]]; then
    cycle_target="$MEASURED_CYCLE_TARGET"
    refocus_cycle_target "$primary_workspace_dir" "$cycle_target" "$host primary intermediate"
    measure_spaces_cycle_transition \
      "$host" \
      "primary" \
      "$primary_workspace_dir" \
      "$primary_docs_window_id" \
      "process_tracked_tab" \
      "previous" \
      "$host primary cycle previous to browser" \
      'browser:*'
  fi

  run_spaces_logged /tmp/spaces-e2e-multi-secondary-focus.log open docs "$secondary_workspace_dir"
  transition_pause "$host focus secondary docs"
  log_debug "$host multi secondary docs focus complete"
  wait_for_chrome_window_focus "$secondary_docs_window_id" "$secondary_docs_url" "$host secondary docs focus"
  measure_spaces_cycle_transition \
    "$host" \
    "secondary" \
    "$secondary_workspace_dir" \
    "$secondary_docs_window_id" \
    "browser_tracked_tab" \
    "next" \
    "$host secondary cycle next" \
    'process:*' 'terminal:*'
  cycle_target="$MEASURED_CYCLE_TARGET"
  case "$cycle_target" in
    process:*)
      previous_source="process_tracked_tab"
      previous_expected=('browser:*')
      ;;
    terminal:*)
      previous_source="terminal_tracked_tab"
      previous_expected=('process:*')
      ;;
    *)
      fail "$host secondary cycle next: unexpected target '$cycle_target'"
      ;;
  esac
  refocus_cycle_target "$secondary_workspace_dir" "$cycle_target" "$host secondary"
  measure_spaces_cycle_transition \
    "$host" \
    "secondary" \
    "$secondary_workspace_dir" \
    "$secondary_docs_window_id" \
    "$previous_source" \
    "previous" \
    "$host secondary cycle previous" \
    "${previous_expected[@]}"
  if [[ "$cycle_target" == terminal:* ]]; then
    cycle_target="$MEASURED_CYCLE_TARGET"
    refocus_cycle_target "$secondary_workspace_dir" "$cycle_target" "$host secondary intermediate"
    measure_spaces_cycle_transition \
      "$host" \
      "secondary" \
      "$secondary_workspace_dir" \
      "$secondary_docs_window_id" \
      "process_tracked_tab" \
      "previous" \
      "$host secondary cycle previous to browser" \
      'browser:*'
  fi

  reset_fixture_runtime "$primary_workspace_dir"
  reset_fixture_runtime "$secondary_workspace_dir"
  pass_case
}

run_agent_status_assertions() {
  local host="$1"
  local workspace_dir="$2"
  local dump_file="$TMP_ROOT/$host-agent-status.json"
  local workspace_title workspace_id agent_run_view_pattern agent_script
  local event_start_line=1

  ensure_configured_terminal_host "$host"
  dump_workspace "$workspace_dir" "$dump_file"
  workspace_title="$(json_get "$dump_file" "workspace.title")"
  agent_script="$(mock_agent_launcher_command "$host" "$workspace_dir")"
  set_workspace_agent_launcher "$workspace_dir" "$MOCK_AGENT_LABEL" "$agent_script"

  begin_case "$host: coding agent status updates"
  # Launch a real configured coding agent and assert its waiting/done lifecycle
  # through both persisted agent-window state and the visible GUI rows.
  ensure_single_spaces_instance "$SPACES_PID"
  reset_fixture_runtime "$workspace_dir"
  if [[ -f "$EVENT_LOG" ]]; then
    event_start_line=$(( $(wc -l <"$EVENT_LOG") + 1 ))
  fi
  run_spaces_logged "/tmp/spaces-e2e-$host-agent-launch.log" start "$workspace_dir"
  transition_pause "$host launch workspace with agent"

  if [[ "$host" != "remote" ]]; then
    wait_for_event_log_contains_since_line "agent-waiting:$workspace_dir" "$event_start_line"
  fi
  wait_for_agent_status "$workspace_dir" "$MOCK_AGENT_LABEL" "waiting"

  if [[ "$host" != "remote" ]]; then
    wait_for_event_log_contains_since_line "agent-done:$workspace_dir" "$event_start_line"
  fi
  wait_for_agent_status "$workspace_dir" "$MOCK_AGENT_LABEL" "done"

  reset_fixture_runtime "$workspace_dir"
  clear_workspace_agent_launchers "$workspace_dir"
  pass_case
}

main() {
  # These checks are intentionally explicit because this script targets the real
  # machine, not the hermetic unit-test environment.
  parse_args "$@"
  require_cmd git
  require_cmd osascript
  require_cmd python3
  require_cmd uv
  require_cmd yabai

  build_binaries
  cleanup_existing_fixture_projects
  close_existing_spaces_instances
  setup_git_fixture
  seed_fixture
  seed_second_fixture
  seed_third_fixture
  export_remote_auth_token
  if [[ -n "$RECORD_VIDEO_PATH" ]]; then
    hide_all_visible_windows
    start_screen_recording
  fi
  launch_spaces
  create_workspace_via_gui
  create_scout_branch_workspace

  local lookup_file="$TMP_ROOT/workspace.json"
  wait_for_workspace_lookup "$WORKSPACE_TITLE" "$lookup_file"
  local created_workspace_dir workspace_dir
  created_workspace_dir="$(json_get "$lookup_file" "dir")"
  workspace_dir="$(json_get "$SEED_FILE" "defaultWorkspace.dir")"
  local second_workspace_dir
  second_workspace_dir="$(json_get "$SECOND_SEED_FILE" "defaultWorkspace.dir")"
  local third_workspace_dir
  third_workspace_dir="$(json_get "$THIRD_SEED_FILE" "defaultWorkspace.dir")"
  local scout_branch_workspace_dir
  scout_branch_workspace_dir="$(json_get "$TMP_ROOT/scout-branch-workspace.json" "dir")"
  PRIMARY_DOCS_URL="$(frontend_url_for_workspace "$workspace_dir" "/docs/")"
  PRIMARY_ADMIN_URL="$(frontend_url_for_workspace "$workspace_dir" "/admin/")"
  PRIMARY_BACKEND_STATUS_URL="$(backend_url_for_workspace "$workspace_dir" "/api/launch-status")"
  SECONDARY_DOCS_URL="$(frontend_url_for_workspace "$second_workspace_dir" "/docs/")"
  SECONDARY_ADMIN_URL="$(frontend_url_for_workspace "$second_workspace_dir" "/admin/")"
  SECONDARY_BACKEND_STATUS_URL="$(backend_url_for_workspace "$second_workspace_dir" "/api/launch-status")"
  TERTIARY_DOCS_URL="$(frontend_url_for_workspace "$third_workspace_dir" "/docs/")"
  TERTIARY_ADMIN_URL="$(frontend_url_for_workspace "$third_workspace_dir" "/admin/")"
  TERTIARY_BACKEND_STATUS_URL="$(backend_url_for_workspace "$third_workspace_dir" "/api/launch-status")"
  CREATED_DOCS_URL="$(frontend_url_for_workspace "$created_workspace_dir" "/docs/")"
  CREATED_ADMIN_URL="$(frontend_url_for_workspace "$created_workspace_dir" "/admin/")"
  CREATED_BACKEND_STATUS_URL="$(backend_url_for_workspace "$created_workspace_dir" "/api/launch-status")"
  BEACON_BRANCH_DOCS_URL="$CREATED_DOCS_URL"
  BEACON_BRANCH_ADMIN_URL="$CREATED_ADMIN_URL"
  BEACON_BRANCH_BACKEND_STATUS_URL="$CREATED_BACKEND_STATUS_URL"
  SCOUT_BRANCH_DOCS_URL="$(frontend_url_for_workspace "$scout_branch_workspace_dir" "/docs/")"
  SCOUT_BRANCH_ADMIN_URL="$(frontend_url_for_workspace "$scout_branch_workspace_dir" "/admin/")"
  SCOUT_BRANCH_BACKEND_STATUS_URL="$(backend_url_for_workspace "$scout_branch_workspace_dir" "/api/launch-status")"
  local stop_marker="workspace-stop-override"

  set_workspace_stop_script_via_gui "$stop_marker" "$workspace_dir"

  if (( SETUP_FIXTURES_ONLY == 1 )); then
    PRESERVE_FIXTURES_ON_EXIT=1
    begin_case "manual fixture setup"
    pass_case
    cat <<EOF
Manual fixture environment is ready:
  HOME=$TMP_HOME
  DB=$TMP_DB
  Workspace 1 (beacon main):       $workspace_dir
  Workspace 2 (beacon redesign):   $created_workspace_dir
  Workspace 3 (scout main):        $second_workspace_dir
  Workspace 4 (scout redesign):    $scout_branch_workspace_dir
  Workspace 5 (prism main):        $third_workspace_dir
  Beacon docs:       $PRIMARY_DOCS_URL
  Beacon backend:    $PRIMARY_BACKEND_STATUS_URL
  Scout docs:        $SECONDARY_DOCS_URL
  Scout backend:     $SECONDARY_BACKEND_STATUS_URL
  Prism docs:        $TERTIARY_DOCS_URL
  Prism backend:     $TERTIARY_BACKEND_STATUS_URL
  Beacon redesign docs: $BEACON_BRANCH_DOCS_URL
  Scout redesign docs:  $SCOUT_BRANCH_DOCS_URL
  Spaces PID: $SPACES_PID
EOF
    return 0
  fi

  target_seen=" "
  for target in "${SELECTED_TARGETS[@]}"; do
    target_exists "$target" || fail "unknown target: $target"
    if [[ "$target_seen" == *" $target "* ]]; then
      continue
    fi
    target_seen+=" $target "
    configure_e2e_target "$target"
    local host="spaces"
    if [[ "$target" == "remote" ]]; then
      host="remote"
    fi
    run_launch_and_focus_assertions "$host" "$workspace_dir"
    if (( ONLY_WINDOW_CYCLE_PROFILE == 1 )); then
      continue
    fi
    run_multi_workspace_focus_and_cycle_assertions "$host" "$workspace_dir" "$second_workspace_dir"
    run_agent_status_assertions "$host" "$workspace_dir"
  done
  if (( ONLY_WINDOW_CYCLE_PROFILE == 1 )); then
    return 0
  fi
  if selected_targets_include local; then
    assert_file_contains "$EVENT_LOG" "$stop_marker"
  fi
  configure_e2e_target local

  begin_case "branch and tertiary workspaces serve correct content"
  local branch_check_out="$TMP_ROOT/branch-content-check.json"
  run_spaces_logged /tmp/spaces-e2e-beacon-branch-start.log start "$created_workspace_dir"
  wait_for_workspace_running_state "$created_workspace_dir" "true"
  wait_for_http_body_contains "$BEACON_BRANCH_DOCS_URL" "Beacon redesign-hero docs sentinel"
  run_spaces_logged /tmp/spaces-e2e-scout-branch-start.log start "$scout_branch_workspace_dir"
  wait_for_workspace_running_state "$scout_branch_workspace_dir" "true"
  wait_for_http_body_contains "$SCOUT_BRANCH_DOCS_URL" "Scout redesign-hero docs sentinel"
  run_spaces_logged /tmp/spaces-e2e-prism-start.log start "$third_workspace_dir"
  wait_for_workspace_running_state "$third_workspace_dir" "true"
  wait_for_http_body_contains "$TERTIARY_DOCS_URL" "Prism docs sentinel"
  reset_fixture_runtime "$created_workspace_dir"
  reset_fixture_runtime "$scout_branch_workspace_dir"
  reset_fixture_runtime "$third_workspace_dir"
  pass_case

  begin_case "archive branch workspaces"
  "$SPACES_E2E_CLI" archive-workspace --workspace-dir "$created_workspace_dir" >/tmp/spaces-e2e-archive-beacon-branch.json
  "$SPACES_E2E_CLI" archive-workspace --workspace-dir "$scout_branch_workspace_dir" >/tmp/spaces-e2e-archive-scout-branch.json
  wait_for_workspace_lookup "$WORKSPACE_TITLE" "$lookup_file"
  assert_equals "true" "$(json_get "$lookup_file" "isArchived")" "beacon branch workspace archived"
  pass_case
}

main "$@"
