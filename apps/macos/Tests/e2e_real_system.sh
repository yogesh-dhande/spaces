#!/usr/bin/env bash
set -Eeuo pipefail

# Manual real-system E2E coverage for Spaces.
# This script intentionally runs outside XCTest so it can drive the real app,
# terminals, Chrome, yabai, and tmux on an interactive desktop session.

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
MACOS_DIR="$ROOT_DIR/apps/macos"
# scripts/swiftpm.sh already changes into apps/macos internally, so the default
# build command must not add a second package-path override.
BUILD_CMD="${BUILD_CMD:-$ROOT_DIR/scripts/swiftpm.sh build}"
SPACES_APP="${SPACES_APP:-$MACOS_DIR/.build/debug/SpacesApp}"
MX_BIN="${MX_BIN:-$MACOS_DIR/.build/debug/spaces}"
MX_E2E_BIN="${MX_E2E_BIN:-$MACOS_DIR/.build/debug/spacese2e}"
APP_LOG="${APP_LOG:-/tmp/spaces-e2e-app.log}"
EVENT_LOG="${EVENT_LOG:-/tmp/spaces-e2e-events.log}"
METRICS_LOG="${METRICS_LOG:-/tmp/spaces-e2e-metrics.log}"
DEBUG_LOG="${DEBUG_LOG:-/tmp/spaces-e2e-debug.log}"
RESULTS_LOG="${RESULTS_LOG:-/tmp/spaces-e2e-results.log}"
RECORDER_LOG="${RECORDER_LOG:-/tmp/spaces-e2e-recorder.log}"
ACTION_TIMEOUT_SECONDS="${ACTION_TIMEOUT_SECONDS:-20}"
HOSTS_CSV="${HOSTS_CSV:-iterm2,ghostty}"
SEED_FILE="${SEED_FILE:-/tmp/spaces-e2e-seed.json}"
SECOND_SEED_FILE="${SECOND_SEED_FILE:-/tmp/spaces-e2e-seed-2.json}"
THIRD_SEED_FILE="${THIRD_SEED_FILE:-/tmp/spaces-e2e-seed-3.json}"
TRANSITION_PAUSE_SECONDS="${TRANSITION_PAUSE_SECONDS:-0}"
RECORD_VIDEO_PATH="${RECORD_VIDEO_PATH:-}"
RECORD_VIDEO_CAPTURE_DEVICE="${RECORD_VIDEO_CAPTURE_DEVICE:-}"
RECORD_VIDEO_FRAMERATE="${RECORD_VIDEO_FRAMERATE:-15}"
RECORDER_OUTPUT_START_TIMEOUT_SECONDS="${RECORDER_OUTPUT_START_TIMEOUT_SECONDS:-8}"
RECORDER_STOP_TIMEOUT_SECONDS="${RECORDER_STOP_TIMEOUT_SECONDS:-10}"
REAL_SYSTEM_PROFILE_REPETITIONS="${REAL_SYSTEM_PROFILE_REPETITIONS:-5}"
PROFILE_ARTIFACT_DIR="${PROFILE_ARTIFACT_DIR:-$MACOS_DIR/.artifacts/real-system-profiles}"
PROFILE_HISTORY_CSV="${PROFILE_HISTORY_CSV:-$PROFILE_ARTIFACT_DIR/metrics-history.csv}"
PROFILE_REPORT_HTML="${PROFILE_REPORT_HTML:-$PROFILE_ARTIFACT_DIR/report.html}"
PROFILE_RENDER_SCRIPT="${PROFILE_RENDER_SCRIPT:-$MACOS_DIR/Tests/render_profile_report.py}"
WORKSPACE_SERVICE_CONTENT_TIMEOUT_SECONDS="${WORKSPACE_SERVICE_CONTENT_TIMEOUT_SECONDS:-60}"

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
SETUP_FIXTURES_ONLY=0
PRESERVE_FIXTURES_ON_EXIT=0
APP_PORT_NAME="SPACES_E2E_APP_PORT"
API_PORT_NAME="SPACES_E2E_API_PORT"
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
  "$MX_E2E_BIN" stop-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/spaces-e2e-stop-fixtures-exit.json 2>/dev/null || true
  close_fixture_chrome_windows
  if [[ -n "${SPACES_PID}" ]]; then
    kill "${SPACES_PID}" >/dev/null 2>&1 || true
    wait "${SPACES_PID}" >/dev/null 2>&1 || true
  fi
  pkill -x SpacesApp >/dev/null 2>&1 || true
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

fail() {
  echo "FAIL: $*" >&2
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
  CURRENT_CASE="$1"
  log_step "$CURRENT_CASE"
}

pass_case() {
  record_case_result "PASS" "$CURRENT_CASE"
  CURRENT_CASE=""
}

skip_case() {
  local name="$1"
  local detail="$2"
  record_case_result "SKIP" "$name" "$detail"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_file() {
  [[ -x "$1" ]] || fail "missing executable: $1"
}

print_usage() {
  cat <<'EOF'
Usage: apps/macos/Tests/e2e_real_system.sh [options]

Options:
  --record-video PATH            Capture the full run to PATH with ScreenCaptureKit.
  --capture-device DEVICE        Legacy option. Ignored by native recording.
  --capture-framerate FPS        Screen recording frame rate. Default: 15.
  --pause-transitions            Add a 1 second pause after visible transitions.
  --setup-fixtures-only          Create projects/workspaces and leave the manual test environment running.
  --transition-pause-seconds N   Override the transition pause duration.
  --help                         Show this help text.
EOF
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
}

transition_pause() {
  local label="${1:-transition}"
  if ! awk -v seconds="$TRANSITION_PAUSE_SECONDS" 'BEGIN { exit(seconds + 0 > 0 ? 0 : 1) }'; then
    return 0
  fi
  log_debug "transition pause ${TRANSITION_PAUSE_SECONDS}s: $label"
  sleep "$TRANSITION_PAUSE_SECONDS"
}

build_binaries() {
  log_step "building macOS binaries"
  (cd "$ROOT_DIR" && eval "$BUILD_CMD") >/dev/null
  require_file "$SPACES_APP"
  require_file "$MX_BIN"
  require_file "$MX_E2E_BIN"
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
  stop_stale_fixture_port_listeners
  "$MX_E2E_BIN" stop-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/spaces-e2e-stop-fixtures-start.json || true
  close_fixture_chrome_windows
  "$MX_E2E_BIN" cleanup-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/spaces-e2e-cleanup.json || true
  rm -rf "$TMP_PREFIX".* /private"$TMP_PREFIX".* 2>/dev/null || true
  ensure_fixture_ports_free
}

reset_fixture_runtime() {
  local workspace_dir="$1"
  log_step "resetting tracked workspace runtime"
  "$MX_E2E_BIN" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace.json 2>/dev/null || true
  close_fixture_chrome_windows
  stop_stale_fixture_port_listeners
  sleep 1
  ensure_fixture_ports_free
}

close_existing_spaces_instances() {
  log_step "closing existing Spaces instances"
  pkill -x SpacesApp >/dev/null 2>&1 || true
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "$(spaces_instance_count)" == "0" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for existing Spaces instances to exit"
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
  "$MX_E2E_BIN" record-screen \
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

spaces_instance_count() {
  (pgrep -x SpacesApp || true) | wc -l | tr -d ' '
}

ensure_single_spaces_instance() {
  local expected_pid="${1:-}"
  local count
  count="$(spaces_instance_count)"
  if [[ -n "$expected_pid" ]]; then
    local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
      count="$(spaces_instance_count)"
      if [[ "$count" == "1" ]] && pgrep -x SpacesApp | grep -qx "$expected_pid"; then
        return 0
      fi
      sleep 0.2
    done
    fail "expected exactly one Spaces instance with pid $expected_pid, found count=$count"
  fi
  [[ "$count" == "1" ]] || fail "expected exactly one Spaces instance, found count=$count"
}

launch_spaces() {
  log_step "launching Spaces with isolated HOME=$TMP_HOME"
  : >"$APP_LOG"
  APP_LOG_SEARCH_FROM_LINE=1
  env HOME="$TMP_HOME" SPACES_DB_PATH="$TMP_DB" SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" SPACES_E2E_EVENTS_LOG="$EVENT_LOG" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
  SPACES_PID=$!
  ensure_single_spaces_instance "$SPACES_PID"
  wait_for_spaces_frontmost_ready
  transition_pause "Spaces launch"
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
    if [[ "$(frontmost_app 2>/dev/null || true)" == "SpacesApp" ]] && osascript <<'APPLESCRIPT' 2>/dev/null | grep -Eiq '^(1|true)$'; then
tell application "System Events"
  if exists process "SpacesApp" then
    tell process "SpacesApp"
      return (count of windows) > 0
    end tell
  end if
end tell
return false
APPLESCRIPT
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces window"
}

wait_for_spaces_splitter_ready() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if osascript <<'APPLESCRIPT' 2>/dev/null | grep -q '^1$'; then
tell application "System Events"
  if exists process "SpacesApp" then
    tell process "SpacesApp"
      if (count of windows) is 0 then return 0
      try
        set _ to splitter group 1 of window 1
        return 1
      on error
        return 0
      end try
    end tell
  end if
end tell
return 0
APPLESCRIPT
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces splitter layout"
}

spaces_splitter_ready() {
  osascript <<'APPLESCRIPT' 2>/dev/null | grep -q '^1$'
tell application "System Events"
  if exists process "SpacesApp" then
    tell process "SpacesApp"
      if (count of windows) is 0 then return 0
      try
        set _ to splitter group 1 of window 1
        return 1
      on error
        return 0
      end try
    end tell
  end if
end tell
return 0
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
    cp -R "$FIXTURE_TEMPLATE_DIR/templates/$variant/site" .spaces-e2e-demo/site
    git add .spaces-e2e-demo/site
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
  "$MX_E2E_BIN" seed-fixture \
    --project-dir "$TEST_REPO" \
    --workspace-title "$PRIMARY_WORKSPACE_TITLE" \
    --docs-url "http://localhost:\$${APP_PORT_NAME}/docs/" \
    --admin-url "http://localhost:\$${APP_PORT_NAME}/admin/" >"$SEED_FILE"
}

seed_second_fixture() {
  log_step "seeding second project fixture (scout-errors)"
  "$MX_E2E_BIN" seed-fixture \
    --project-dir "$TEST_REPO_2" \
    --workspace-title "$SECONDARY_WORKSPACE_TITLE" \
    --docs-url "http://localhost:\$${APP_PORT_NAME}/docs/" \
    --admin-url "http://localhost:\$${APP_PORT_NAME}/admin/" >"$SECOND_SEED_FILE"
}

seed_third_fixture() {
  log_step "seeding third project fixture (prism-analytics)"
  "$MX_E2E_BIN" seed-fixture \
    --project-dir "$TEST_REPO_3" \
    --workspace-title "$TERTIARY_WORKSPACE_TITLE" \
    --docs-url "http://localhost:\$${APP_PORT_NAME}/docs/" \
    --admin-url "http://localhost:\$${APP_PORT_NAME}/admin/" >"$THIRD_SEED_FILE"
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
  local docs_url="$1"
  local docs_expected="$2"
  local backend_url="$3"
  local backend_expected="$4"
  local timeout_seconds="${5:-$WORKSPACE_SERVICE_CONTENT_TIMEOUT_SECONDS}"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if http_body_contains "$docs_url" "$docs_expected" && http_body_contains "$backend_url" "$backend_expected"; then
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
  python3 - "$script_path" "$MX_BIN" "$EVENT_LOG" <<'PY'
import os
import sys
from pathlib import Path

script_path, mx_bin, event_log = sys.argv[1:4]
content = f"""#!/usr/bin/env bash
set -euo pipefail
workspace_dir="${{SPACES_WORKSPACE_DIR:-$PWD}}"
agent_log="{event_log}"
mx_bin="{mx_bin}"
"$mx_bin" signal init "$workspace_dir" >/dev/null
"$mx_bin" signal start "$workspace_dir" >/dev/null
printf 'agent-start:%s\\n' "$workspace_dir" >>"$agent_log"
sleep 2
"$mx_bin" signal waiting "$workspace_dir" >/dev/null
printf 'agent-waiting:%s\\n' "$workspace_dir" >>"$agent_log"
sleep 2
"$mx_bin" signal done "$workspace_dir" >/dev/null
printf 'agent-done:%s\\n' "$workspace_dir" >>"$agent_log"
trap '"$mx_bin" signal exit "$workspace_dir" >/dev/null 2>&1 || true; printf "agent-exit:%s\\n" "$workspace_dir" >>"$agent_log"; exit 0' TERM INT
while true; do sleep 5; done
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
  "$MX_E2E_BIN" set-workspace-agent-launchers --workspace-dir "$workspace_dir" --name "$launcher_name" --command "$launcher_command" \
    >/tmp/spaces-e2e-agent-launcher.json
}

clear_workspace_agent_launchers() {
  local workspace_dir="$1"
  "$MX_E2E_BIN" set-workspace-agent-launchers --workspace-dir "$workspace_dir" --clear >/tmp/spaces-e2e-agent-launcher-clear.json
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
  "$MX_E2E_BIN" dump-workspace --workspace-dir "$1" >"$2"
}

dump_focusable_window_names() {
  "$MX_E2E_BIN" focusable-window-names --workspace-dir "$1" >"$2"
}

lookup_workspace() {
  "$MX_E2E_BIN" lookup-workspace --project-dir "$TEST_REPO" --title "$1" >"$2"
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

ui_click_identifier() {
  # The GUI identifiers added for this suite keep the AppleScript automation
  # resilient when labels or ordering change.
  local identifier="$1"
  osascript - "$identifier" <<'APPLESCRIPT'
on run argv
  set targetID to item 1 of argv
  tell application "System Events"
    tell process "SpacesApp"
      repeat with targetElement in entire contents of window 1
        try
          if (value of attribute "AXIdentifier" of targetElement) is targetID then
            click targetElement
            return
          end if
        end try
      end repeat
    end tell
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}

ui_click_workspace_detail_header_button() {
  local description="$1"
  osascript - "$description" <<'APPLESCRIPT'
on run argv
  set targetDescription to item 1 of argv
  tell application "System Events"
    tell process "SpacesApp"
      tell scroll area 2 of splitter group 1 of window 1
        repeat with targetButton in buttons
          try
            if (description of targetButton) is targetDescription then
              click targetButton
              return
            end if
          end try
        end repeat
      end tell
    end tell
  end tell
  error "workspace-detail header button not found: " & targetDescription
end run
APPLESCRIPT
}

ui_set_identifier_value() {
  local identifier="$1"
  local value="$2"
  osascript - "$identifier" "$value" <<'APPLESCRIPT'
on run argv
  set targetID to item 1 of argv
  set targetValue to item 2 of argv
  tell application "System Events"
    tell process "SpacesApp"
      repeat with targetElement in entire contents of window 1
        try
          if (value of attribute "AXIdentifier" of targetElement) is targetID then
            set value of targetElement to targetValue
            return
          end if
        end try
      end repeat
    end tell
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}

ui_select_popup_identifier() {
  local identifier="$1"
  local value="$2"
  osascript - "$identifier" "$value" <<'APPLESCRIPT'
on run argv
  set targetID to item 1 of argv
  set targetValue to item 2 of argv
  tell application "System Events"
    tell process "SpacesApp"
      repeat with targetElement in entire contents of window 1
        try
          if (value of attribute "AXIdentifier" of targetElement) is targetID then
            click targetElement
            click menu item targetValue of menu 1 of targetElement
            return
          end if
        end try
      end repeat
    end tell
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}

ui_double_click_identifier() {
  local identifier="$1"
  osascript - "$identifier" <<'APPLESCRIPT'
on run argv
  set targetID to item 1 of argv
  tell application "System Events"
    tell process "SpacesApp"
      repeat with targetElement in entire contents of window 1
        try
          if (value of attribute "AXIdentifier" of targetElement) is targetID then
            perform action "AXPress" of targetElement
            delay 0.1
            perform action "AXPress" of targetElement
            return
          end if
        end try
      end repeat
    end tell
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}

ui_select_outline_row() {
  local row_index="$1"
  wait_for_spaces_splitter_ready
  osascript - "$row_index" <<'APPLESCRIPT'
on run argv
  set targetRow to (item 1 of argv) as integer
  tell application "System Events"
    tell process "SpacesApp"
      select row targetRow of outline 1 of scroll area 1 of splitter group 1 of window 1
    end tell
  end tell
end run
APPLESCRIPT
}

ui_show_workspace_detail() {
  local workspace_dir="$1"
  local workspace_title="$2"
  "$MX_E2E_BIN" select-workspace-detail --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-select-workspace-detail.json
  wait_for_spaces_frontmost_ready
  # The helper path is validated separately; here we just need the app frontmost and ready
  # before driving the real numbered-shortcut interaction against the detail UI.
  sleep 0.2
}

ui_click_tab() {
  local label="$1"
  wait_for_spaces_splitter_ready
  osascript - "$label" <<'APPLESCRIPT'
on run argv
  set targetLabel to item 1 of argv
  tell application "System Events"
    tell process "SpacesApp"
      repeat with targetElement in (entire contents of window 1)
        try
          if (role of targetElement) is "AXRadioButton" and (title of targetElement) is targetLabel then
            click targetElement
            return
          end if
        end try
      end repeat
    end tell
  end tell
  error "tab not found: " & targetLabel
end run
APPLESCRIPT
}

create_workspace_via_gui() {
  log_step "creating beacon hero-redesign branch workspace through real orchestrator helper"
  # Workspace creation exercises the real store, git worktree creation, and
  # workspace initialization logic against a branch with distinct HTML content.
  "$MX_E2E_BIN" create-workspace \
    --project-dir "$TEST_REPO" \
    --title "$WORKSPACE_TITLE" \
    --branch "$WORKSPACE_BRANCH" \
    --target-branch main \
    --notes "$WORKSPACE_NOTES" >"$TMP_ROOT/created-workspace.json"
  transition_pause "workspace creation"
}

create_scout_branch_workspace() {
  log_step "creating scout hero-redesign branch workspace"
  "$MX_E2E_BIN" create-workspace \
    --project-dir "$TEST_REPO_2" \
    --title "$SCOUT_BRANCH_WORKSPACE_TITLE" \
    --branch "$SCOUT_BRANCH_WORKSPACE_BRANCH" \
    --target-branch main \
    --notes "$SCOUT_BRANCH_WORKSPACE_NOTES" >"$TMP_ROOT/scout-branch-workspace.json"
  transition_pause "scout branch workspace creation"
}

set_workspace_browser_urls() {
  local workspace_dir="$1"
  local docs_url="$2"
  local admin_url="$3"
  "$MX_E2E_BIN" set-workspace-browser-session-urls \
    --workspace-dir "$workspace_dir" \
    --docs-url "$docs_url" \
    --admin-url "$admin_url" >/tmp/spaces-e2e-browser-session-urls.json
}

set_workspace_stop_script_via_gui() {
  local marker="$1"
  local workspace_dir="$2"
  log_step "overriding workspace stop script through real workspace-settings path"
  "$MX_E2E_BIN" set-workspace-stop-script \
    --workspace-dir "$workspace_dir" \
    --stop-script "bash -lc 'printf \"$marker\\n\" >> \"$EVENT_LOG\"'" >/tmp/spaces-e2e-stop-script.json
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
  "$MX_E2E_BIN" archive-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-archive-workspace-fallback.json
}

stop_workspace_via_gui() {
  local workspace_dir="$1"
  log_step "stopping workspace via GUI"
  wait_for_spaces_frontmost_ready
  if ! spaces_splitter_ready; then
    log_debug "stop_workspace_via_gui fallback=stop-workspace-helper"
    "$MX_E2E_BIN" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace-fallback.json
    return 0
  fi
  ui_show_workspace_detail "$workspace_dir" ""
  sleep 0.5
  if ! ui_click_workspace_detail_header_button "Stop"; then
    log_debug "stop_workspace_via_gui fallback=identifier-stop-workspace-helper"
    "$MX_E2E_BIN" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace-fallback.json
    return 0
  fi
  local out="$TMP_ROOT/stop-workspace-state.json"
  local deadline=$((SECONDS + 4))
  while (( SECONDS < deadline )); do
    dump_workspace "$workspace_dir" "$out"
    if [[ "$(json_get "$out" "workspace.isRunning")" == "false" ]]; then
      return 0
    fi
    sleep 0.5
  done
  log_debug "stop_workspace_via_gui fallback=post-click-stop-workspace-helper"
  "$MX_E2E_BIN" stop-workspace --workspace-dir "$workspace_dir" >/tmp/spaces-e2e-stop-workspace-fallback.json
}

restart_workspace_via_gui() {
  local workspace_dir="$1"
  log_step "restarting workspace via GUI"
  ui_show_workspace_detail "$workspace_dir" ""
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

spaces_command_palette_visible() {
  osascript <<'APPLESCRIPT' 2>/dev/null | tr -d '\n'
tell application "System Events"
  if exists process "SpacesApp" then
    tell process "SpacesApp"
      repeat with targetWindow in windows
        try
          repeat with targetElement in entire contents of targetWindow
            try
              if (value of attribute "AXIdentifier" of targetElement) is "command-palette-search" then return "1"
            end try
          end repeat
        end try
      end repeat
    end tell
  end if
end tell
return "0"
APPLESCRIPT
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

iterm_open_extra_tab() {
  local window_id="$1"
  osascript - "$window_id" <<'APPLESCRIPT'
on run argv
  set targetWindowID to (item 1 of argv) as integer
  tell application "iTerm2"
    activate
    repeat with w in windows
      if id of w is targetWindowID then
        tell w
          create tab with default profile
        end tell
        return
      end if
    end repeat
  end tell
end run
APPLESCRIPT
}

iterm_focused_session() {
  local window_id="$1"
  osascript - "$window_id" <<'APPLESCRIPT'
on run argv
  set targetWindowID to (item 1 of argv) as integer
  tell application "iTerm2"
    repeat with w in windows
      if id of w is targetWindowID then
        return (id of current session of w) as string
      end if
    end repeat
  end tell
  return ""
end run
APPLESCRIPT
}

iterm_front_session() {
  osascript <<'APPLESCRIPT'
tell application "iTerm2"
  try
    return (id of current session of current window) as string
  on error
    return ""
  end try
end tell
APPLESCRIPT
}

ghostty_open_extra_tab() {
  osascript <<'APPLESCRIPT'
tell application id "com.mitchellh.ghostty" to activate
tell application "System Events"
  keystroke "t" using command down
end tell
APPLESCRIPT
}

ghostty_focused_terminal() {
  osascript <<'APPLESCRIPT'
tell application id "com.mitchellh.ghostty"
  if (count of windows) is 0 then return ""
  return id of focused terminal of selected tab of front window
end tell
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
    wait_for_spaces_frontmost_ready
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

extract_metric_field() {
  local line="$1"
  local key="$2"
  sed -E "s/.*${key}=([0-9]+).*/\\1/" <<<"$line"
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
  if ! line="$(wait_for_app_log_pattern_optional "spaces: perf metric=(named_window_focus|browser_focus|process_focus) .*target=${target_name} .*success=1 .*elapsed_ms=")"; then
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
  local line
  if line="$(wait_for_app_log_pattern_optional "spaces: perf metric=browser_focus .*target=${target_url} .*success=1 .*elapsed_ms=")"; then
    record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")" "$terminal_host" "$workspace_scope"
    return 0
  fi
  # `spaces open docs` can resolve through the shared name-based
  # focus path instead of the browser-session-specific path, so the app may log
  # `named_window_focus target=docs` even though the visible behavior is still
  # "focus the tracked docs Chrome tab". Accept either metric shape here.
  if [[ -n "$focus_name" ]] && line="$(wait_for_app_log_pattern_optional "spaces: perf metric=named_window_focus .*target=${focus_name} .*success=1 .*elapsed_ms=")"; then
    record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")" "$terminal_host" "$workspace_scope"
    return 0
  fi
  fail "timed out waiting for browser-focus metric: url=$target_url name=${focus_name:-<none>}"
}

record_process_focus_metric() {
  local name="$1"
  local process_name="$2"
  local terminal_host="$3"
  local workspace_scope="${4:-single}"
  local line
  line="$(wait_for_app_log_pattern "spaces: perf metric=(process_focus|named_window_focus) .*target=${process_name} .*success=1 .*elapsed_ms=")"
  record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")" "$terminal_host" "$workspace_scope"
}

wait_for_iterm_session_focus() {
  local expected_session_id="$1"
  [[ -n "$expected_session_id" ]] || fail "missing expected iTerm session id"
  wait_for_app_log_pattern_optional "spaces: iterm session_verification_succeeded session_id=$expected_session_id " >/dev/null || true
  wait_for_condition "frontmost_app" "iTerm2"
  wait_for_condition "iterm_front_session" "$expected_session_id"
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

wait_for_event_log_contains() {
  local pattern="$1"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
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
for record in data.get("agentWindows", []):
    if (record.get("label") or "") == sys.argv[2]:
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
      printf '%s\t%s\n' "$recovered_pid" "$recovered_status"
      return 0
    fi
    sleep 0.2
  done
  fail "$process_name process did not recover"
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

dump_iterm_state() {
  local label="$1"
  {
    printf '\n[%s] iterm-state %s\n' "$(date +%H:%M:%S)" "$label"
    osascript <<'APPLESCRIPT'
tell application "iTerm2"
  set out to ""
  set out to out & "window_count=" & (count of windows) & linefeed
  repeat with w in windows
    set out to out & "window " & (id of w as string)
    try
      set out to out & " current_session=" & (id of current session of w as string)
    on error
      set out to out & " current_session="
    end try
    set out to out & linefeed
  end repeat
  return out
end tell
APPLESCRIPT
  } >>"$DEBUG_LOG" 2>&1 || true
}

run_spaces_logged() {
  local stdout_file="$1"
  shift
  env DEBUG=1 "$MX_BIN" "$@" >"$stdout_file" 2>>"$APP_LOG"
}

ensure_workspace_http_ready() {
  local workspace_dir="$1"
  local docs_url="$2"
  local docs_expected="$3"
  local backend_url="$4"
  local backend_expected="$5"
  local docs_port backend_port
  docs_port="$(url_port "$docs_url")"
  backend_port="$(url_port "$backend_url")"

  wait_for_workspace_process_status "$workspace_dir" "frontend" "running"
  wait_for_workspace_process_status "$workspace_dir" "backend" "running"
  wait_for_tcp_listener_port "$docs_port"
  wait_for_tcp_listener_port "$backend_port"

  if wait_for_workspace_http_content_optional \
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

run_launch_and_focus_assertions() {
  # Run the same functional checks against each supported default terminal host.
  local host="$1"
  local workspace_dir="$2"
  local dump_file="$TMP_ROOT/$host-dump.json"

  reset_fixture_runtime "$workspace_dir"
  log_step "switching terminal host to $host"
  "$MX_E2E_BIN" set-terminal-host "$host" >/tmp/spaces-e2e-terminal-host.json
  sleep 0.5
  transition_pause "switch terminal host to $host"

  begin_case "$host: launch workspace and persist terminal host"
  run_spaces_logged /tmp/spaces-e2e-launch.log start "$workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-launch-focus.log open docs "$workspace_dir"
  wait_for_workspace_running_state "$workspace_dir" "true"
  transition_pause "$host launch workspace"
  dump_chrome_state "$host docs-focus after-launch"
  wait_for_condition "chrome_front_url" "$PRIMARY_DOCS_URL"
  local docs_window_id
  docs_window_id="$(chrome_front_window_id)"
  [[ -n "$docs_window_id" ]] || fail "docs focus did not leave a front Chrome window"
  log_debug "$host docs_window_id=$docs_window_id expected_docs=$PRIMARY_DOCS_URL"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$PRIMARY_DOCS_URL"

  dump_workspace "$workspace_dir" "$dump_file"
  local workspace_id
  local workspace_title
  workspace_id="$(json_get "$dump_file" "workspace.id")"
  workspace_title="$(json_get "$dump_file" "workspace.title")"
  assert_equals "$host" "$(json_get "$dump_file" "appTerminalHost")" "terminal host persisted"
  local terminal_app
  terminal_app="$(json_get "$dump_file" "runningProcesses[0].terminalApp")"
  if [[ "$host" == "iterm2" ]]; then
    assert_equals "iTerm2" "$terminal_app" "iTerm2 launch"
  else
    assert_equals "Ghostty" "$terminal_app" "Ghostty launch"
  fi
  ensure_workspace_http_ready "$workspace_dir" "$PRIMARY_DOCS_URL" "Beacon docs sentinel" "$PRIMARY_BACKEND_STATUS_URL" '"workspace": "beacon-status"'
  pass_case

  begin_case "$host: focus tracked Chrome tab with extra user tab present"
  # Prove the docs focus really left us on the tracked Chrome window before we
  # inject an untracked user tab into that same window.
  local extra_user_tab_url="https://usespaces.dev/"
  dump_chrome_state "$host docs-focus before-extra-tab"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$PRIMARY_DOCS_URL"
  chrome_add_extra_tab_to_window "$docs_window_id" "$extra_user_tab_url"
  transition_pause "$host add extra Chrome tab"
  dump_chrome_state "$host after-extra-tab"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$extra_user_tab_url"
  run_spaces_logged /tmp/spaces-e2e-focus-docs.log open docs "$workspace_dir"
  transition_pause "$host refocus docs"
  record_browser_focus_metric "browser_untracked_tab.cli_window_focus.browser_tracked_tab" "$PRIMARY_DOCS_URL" "docs" "$host" "single"
  dump_chrome_state "$host after-refocus-docs"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$PRIMARY_DOCS_URL"
  wait_for_condition "chrome_front_url" "$PRIMARY_DOCS_URL"
  pass_case

  dump_workspace "$workspace_dir" "$dump_file"
  if [[ "$host" == "iterm2" ]]; then
    begin_case "$host: focus tracked iTerm2 tab with extra user tab present"
    local frontend_window_id frontend_session_id backend_window_id backend_session_id
    frontend_window_id="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window["windowID"])
        break
PY
)"
    frontend_session_id="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window["terminalTrackingID"] or "")
        break
PY
)"
    backend_window_id="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "backend":
        print(window["windowID"])
        break
PY
)"
    backend_session_id="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "backend":
        print(window["terminalTrackingID"] or "")
        break
PY
)"
    iterm_open_extra_tab "$frontend_window_id"
    sleep 1
    transition_pause "$host add extra iTerm2 tab"
    wait_for_condition "frontmost_app" "iTerm2"
    [[ "$(iterm_front_session)" != "$frontend_session_id" ]] || fail "expected extra iTerm2 tab to be selected"
    run_spaces_logged /tmp/spaces-e2e-focus-frontend.log open frontend "$workspace_dir"
    transition_pause "$host focus frontend terminal"
    record_process_focus_metric "terminal_untracked_tab.cli_window_focus.process_tracked_tab" "frontend" "$host" "single"
    frontend_session_id="$(wait_for_workspace_terminal_tracking_id "$workspace_dir" "frontend" "$dump_file")"
    wait_for_iterm_session_focus "$frontend_session_id"
    pass_case
  else
    begin_case "$host: focus tracked Ghostty tab with extra user tab present"
    local frontend_terminal_id backend_terminal_id
    frontend_terminal_id="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window["terminalNativeID"] or "")
        break
PY
)"
    backend_terminal_id="$(python3 - "$dump_file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "backend":
        print(window["terminalNativeID"] or "")
        break
PY
)"
    run_spaces_logged /tmp/spaces-e2e-focus-frontend.log open frontend "$workspace_dir"
    wait_for_condition "frontmost_app" "ghostty"
    ghostty_open_extra_tab
    sleep 1
    transition_pause "$host add extra Ghostty tab"
    [[ "$(ghostty_focused_terminal)" != "$frontend_terminal_id" ]] || fail "expected extra Ghostty tab to be selected"
    run_spaces_logged /tmp/spaces-e2e-focus-frontend-2.log open frontend "$workspace_dir"
    transition_pause "$host refocus frontend terminal"
    record_process_focus_metric "terminal_untracked_tab.cli_window_focus.process_tracked_tab" "frontend" "$host" "single"
    wait_for_condition "ghostty_focused_terminal" "$frontend_terminal_id"
    pass_case
  fi

  # The Run tab numbers shortcuts in on-screen order:
  # Browser Tabs -> Processes -> Coding Agents.
  # This fixture always defines two browser sessions (`docs`, `admin`) and
  # then the tracked terminal processes (`frontend`, `backend`), so the
  # numbered shortcuts we care about are stable here: docs=1, frontend=3.
  local docs_shortcut_index=1
  local frontend_shortcut_index=3

  begin_case "$host: workspace detail numbered shortcuts focus correct window"
  # These are the workspace-detail focus cases the user asked for, using the
  # real detail-pane shortcuts instead of direct CLI focus.
  ensure_single_spaces_instance "$SPACES_PID"
  ui_show_workspace_detail "$workspace_dir" "$workspace_title"
  sleep 0.5
  send_spaces_window_shortcut_with_ack "$docs_shortcut_index"
  transition_pause "$host shortcut focus docs"
  wait_for_condition "chrome_window_active_url $docs_window_id" "$PRIMARY_DOCS_URL"
  record_browser_focus_metric "spaces_detail_ui.keyboard_window_shortcut.browser_tracked_tab" "$PRIMARY_DOCS_URL" "docs" "$host" "single"
  ui_show_workspace_detail "$workspace_dir" "$workspace_title"
  sleep 0.5
  send_spaces_window_shortcut_with_ack "$frontend_shortcut_index"
  transition_pause "$host shortcut focus frontend"
  record_process_focus_metric "spaces_detail_ui.keyboard_window_shortcut.process_tracked_tab" "frontend" "$host" "single"
  if [[ "$host" == "iterm2" ]]; then
    frontend_session_id="$(wait_for_workspace_terminal_tracking_id "$workspace_dir" "frontend" "$dump_file")"
    wait_for_iterm_session_focus "$frontend_session_id"
  else
    wait_for_condition "ghostty_focused_terminal" "$frontend_terminal_id"
  fi
  pass_case

  begin_case "$host: workspace window cycling stays on tracked windows"
  # This validates forward/back workspace cycling from the live desktop state.
  ensure_single_spaces_instance "$SPACES_PID"
  run_spaces_logged /tmp/spaces-e2e-cycle-seed.log open docs "$workspace_dir"
  transition_pause "$host seed docs focus for cycling"
  wait_for_condition "chrome_front_url" "$PRIMARY_DOCS_URL"
  send_cycle_hotkey next
  transition_pause "$host cycle next"
  record_cycle_metric "terminal_tracked_tab.keyboard_cycle_next.browser_tracked_tab" "next" "$host" "single"
  if [[ "$host" == "iterm2" ]]; then
    wait_for_any_value "iterm_focused_session $frontend_window_id" "$frontend_session_id" "$backend_session_id"
  else
    wait_for_any_value "ghostty_focused_terminal" "$frontend_terminal_id" "$backend_terminal_id"
  fi
  send_cycle_hotkey previous
  transition_pause "$host cycle previous"
  record_cycle_metric "browser_tracked_tab.keyboard_cycle_previous.terminal_tracked_tab" "previous" "$host" "single"
  wait_for_condition "chrome_front_url" "$PRIMARY_DOCS_URL"
  pass_case

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
  kill "$frontend_pid"
  local dead_pid_deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < dead_pid_deadline )); do
    if ! kill -0 "$frontend_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  run_spaces_logged /tmp/spaces-e2e-recover.log start "$workspace_dir"
  transition_pause "$host recover dead process"
  local recovery_state recovered_pid recovered_status
  recovery_state="$(wait_for_process_running_recovery "$workspace_dir" "frontend" "$frontend_pid")"
  recovered_pid="${recovery_state%%$'\t'*}"
  recovered_status="${recovery_state#*$'\t'}"
  ! kill -0 "$frontend_pid" >/dev/null 2>&1 || fail "killed frontend pid is still alive after recovery"
  pass_case

  begin_case "$host: workspace restart and stop lifecycle"
  restart_workspace_via_gui "$workspace_dir"
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

run_hotkey_visibility_profiling() {
  local host="$1"
  local workspace_dir="$2"
  local iteration

  begin_case "$host: profile repeated app visibility toggle"
  ensure_single_spaces_instance "$SPACES_PID"
  reset_fixture_runtime "$workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-profile-window-toggle-start.log start "$workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-profile-window-toggle.log open docs "$workspace_dir"
  transition_pause "$host seed docs focus for app toggle profiling"
  wait_for_condition "chrome_front_url" "$PRIMARY_DOCS_URL"
  wait_for_condition "frontmost_app" "Google Chrome"
  for (( iteration = 1; iteration <= REAL_SYSTEM_PROFILE_REPETITIONS; iteration++ )); do
    send_spaces_toggle_hotkey_with_ack
    wait_for_spaces_frontmost_ready
    record_toggle_window_metric "external_app.keyboard_toggle_main_window.main_window" "show" "0" "$host" "single"
    send_spaces_toggle_hotkey_with_ack
    wait_for_condition "frontmost_app" "Google Chrome"
    record_toggle_window_metric "main_window.keyboard_toggle_main_window.external_app" "hide" "1" "$host" "single"
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
    wait_for_spaces_command_palette_presented
    record_toggle_palette_metric "external_app.keyboard_toggle_palette.palette" "show" "0" "$host" "single"

    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_dismissed
    wait_for_condition "frontmost_app" "Google Chrome"
    record_toggle_palette_metric "palette.keyboard_toggle_palette.external_app" "hide" "1" "$host" "single"

    send_spaces_toggle_hotkey_with_ack
    wait_for_spaces_frontmost_ready
    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_presented "1"
    record_toggle_palette_metric "main_window.keyboard_toggle_palette.palette" "show" "1" "$host" "single"

    send_spaces_command_palette_hotkey_with_ack
    wait_for_spaces_command_palette_dismissed "1"
    wait_for_spaces_frontmost_ready
    record_toggle_palette_metric "palette.keyboard_toggle_palette.main_window" "hide" "1" "$host" "single"

    send_spaces_toggle_hotkey_with_ack
    wait_for_condition "frontmost_app" "Google Chrome"
  done
  pass_case
}

run_multi_workspace_focus_and_cycle_assertions() {
  local host="$1"
  local primary_workspace_dir="$2"
  local secondary_workspace_dir="$3"
  local primary_docs_url="$PRIMARY_DOCS_URL"
  local secondary_docs_url="$SECONDARY_DOCS_URL"
  local primary_dump="$TMP_ROOT/$host-primary-multi.json"
  local secondary_dump="$TMP_ROOT/$host-secondary-multi.json"

  begin_case "$host: multi-workspace focus and cycle isolation"
  ensure_single_spaces_instance "$SPACES_PID"
  reset_fixture_runtime "$primary_workspace_dir"
  reset_fixture_runtime "$secondary_workspace_dir"

  run_spaces_logged /tmp/spaces-e2e-multi-primary-launch.log start "$primary_workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-multi-primary-launch-focus.log open docs "$primary_workspace_dir"
  transition_pause "$host launch primary workspace"
  log_debug "$host multi primary launch complete"
  dump_workspace "$primary_workspace_dir" "$primary_dump"
  run_spaces_logged /tmp/spaces-e2e-multi-secondary-launch.log start "$secondary_workspace_dir"
  run_spaces_logged /tmp/spaces-e2e-multi-secondary-launch-focus.log open docs "$secondary_workspace_dir"
  transition_pause "$host launch secondary workspace"
  log_debug "$host multi secondary launch complete"
  dump_workspace "$secondary_workspace_dir" "$secondary_dump"
  dump_chrome_state "$host multi after-both-launches"
  if [[ "$host" == "iterm2" ]]; then
    dump_iterm_state "$host multi after-both-launches"
  fi

  local primary_frontend_window_id primary_frontend_session_id primary_frontend_terminal_id primary_backend_session_id primary_backend_terminal_id
  local secondary_frontend_window_id secondary_frontend_session_id secondary_frontend_terminal_id secondary_backend_session_id secondary_backend_terminal_id
  primary_frontend_window_id="$(python3 - "$primary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window.get("windowID") or "")
        break
PY
)"
  primary_frontend_session_id="$(python3 - "$primary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window.get("terminalTrackingID") or "")
        break
PY
)"
  primary_frontend_terminal_id="$(python3 - "$primary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window.get("terminalNativeID") or "")
        break
PY
)"
  primary_backend_session_id="$(python3 - "$primary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "backend":
        print(window.get("terminalTrackingID") or "")
        break
PY
)"
  primary_backend_terminal_id="$(python3 - "$primary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "backend":
        print(window.get("terminalNativeID") or "")
        break
PY
)"
  secondary_frontend_window_id="$(python3 - "$secondary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window.get("windowID") or "")
        break
PY
)"
  secondary_frontend_session_id="$(python3 - "$secondary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window.get("terminalTrackingID") or "")
        break
PY
)"
  secondary_frontend_terminal_id="$(python3 - "$secondary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "frontend":
        print(window.get("terminalNativeID") or "")
        break
PY
)"
  secondary_backend_session_id="$(python3 - "$secondary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "backend":
        print(window.get("terminalTrackingID") or "")
        break
PY
)"
  secondary_backend_terminal_id="$(python3 - "$secondary_dump" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for window in data["windows"]:
    if window["name"] == "backend":
        print(window.get("terminalNativeID") or "")
        break
PY
)"

  run_spaces_logged /tmp/spaces-e2e-multi-primary-focus.log open docs "$primary_workspace_dir"
  transition_pause "$host focus primary docs"
  log_debug "$host multi primary docs focus complete"
  wait_for_condition "chrome_front_url" "$primary_docs_url"
  send_cycle_hotkey next
  transition_pause "$host primary cycle next"
  log_debug "$host multi primary cycle next sent"
  record_cycle_metric "terminal_tracked_tab.keyboard_cycle_next.browser_tracked_tab" "next" "$host" "primary"
  if [[ "$host" == "iterm2" ]]; then
    dump_iterm_state "$host multi after-primary-next"
  fi
  if [[ "$host" == "iterm2" ]]; then
    wait_for_condition "frontmost_app" "iTerm2"
    wait_for_any_value "iterm_front_session" "$primary_frontend_session_id" "$primary_backend_session_id"
  else
    wait_for_any_value "ghostty_focused_terminal" "$primary_frontend_terminal_id" "$primary_backend_terminal_id"
  fi
  send_cycle_hotkey previous
  transition_pause "$host primary cycle previous"
  log_debug "$host multi primary cycle previous sent"
  record_cycle_metric "browser_tracked_tab.keyboard_cycle_previous.terminal_tracked_tab" "previous" "$host" "primary"
  wait_for_condition "chrome_front_url" "$primary_docs_url"

  run_spaces_logged /tmp/spaces-e2e-multi-secondary-focus.log open docs "$secondary_workspace_dir"
  transition_pause "$host focus secondary docs"
  log_debug "$host multi secondary docs focus complete"
  wait_for_condition "chrome_front_url" "$secondary_docs_url"
  send_cycle_hotkey next
  transition_pause "$host secondary cycle next"
  log_debug "$host multi secondary cycle next sent"
  record_cycle_metric "terminal_tracked_tab.keyboard_cycle_next.browser_tracked_tab" "next" "$host" "secondary"
  if [[ "$host" == "iterm2" ]]; then
    dump_iterm_state "$host multi after-secondary-next"
  fi
  if [[ "$host" == "iterm2" ]]; then
    wait_for_condition "frontmost_app" "iTerm2"
    wait_for_any_value "iterm_front_session" "$secondary_frontend_session_id" "$secondary_backend_session_id"
  else
    wait_for_any_value "ghostty_focused_terminal" "$secondary_frontend_terminal_id" "$secondary_backend_terminal_id"
  fi
  send_cycle_hotkey previous
  transition_pause "$host secondary cycle previous"
  log_debug "$host multi secondary cycle previous sent"
  record_cycle_metric "browser_tracked_tab.keyboard_cycle_previous.terminal_tracked_tab" "previous" "$host" "secondary"
  wait_for_condition "chrome_front_url" "$secondary_docs_url"

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

  dump_workspace "$workspace_dir" "$dump_file"
  workspace_title="$(json_get "$dump_file" "workspace.title")"
  agent_script="$(create_mock_agent_script "$workspace_dir")"
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

  wait_for_event_log_contains_since_line "agent-waiting:$workspace_dir" "$event_start_line"
  wait_for_agent_status "$workspace_dir" "$MOCK_AGENT_LABEL" "waiting"

  wait_for_event_log_contains_since_line "agent-done:$workspace_dir" "$event_start_line"
  wait_for_agent_status "$workspace_dir" "$MOCK_AGENT_LABEL" "done"

  reset_fixture_runtime "$workspace_dir"
  clear_workspace_agent_launchers "$workspace_dir"
  pass_case
}

host_available() {
  local host="$1"
  local out="$TMP_ROOT/terminal-host-available-$host.json"
  "$MX_E2E_BIN" terminal-host-available "$host" >"$out" 2>/dev/null || return 1
  [[ "$(json_get "$out" "available")" == "true" ]]
}

main() {
  # These checks are intentionally explicit because this script targets the real
  # machine, not the hermetic unit-test environment.
  parse_args "$@"
  require_cmd git
  require_cmd osascript
  require_cmd python3
  require_cmd tmux
  require_cmd uv
  require_cmd yabai

  build_binaries
  cleanup_existing_fixture_projects
  close_existing_spaces_instances
  setup_git_fixture
  seed_fixture
  seed_second_fixture
  seed_third_fixture
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

  IFS=',' read -r -a hosts <<<"$HOSTS_CSV"
  for host in "${hosts[@]}"; do
    if host_available "$host"; then
      run_launch_and_focus_assertions "$host" "$workspace_dir"
      run_hotkey_visibility_profiling "$host" "$workspace_dir"
      run_multi_workspace_focus_and_cycle_assertions "$host" "$workspace_dir" "$second_workspace_dir"
      run_agent_status_assertions "$host" "$workspace_dir"
      assert_file_contains "$EVENT_LOG" "$stop_marker"
    else
      printf 'SKIP: terminal host %s is not available on this machine\n' "$host"
      skip_case "$host: host availability" "terminal host not installed"
    fi
  done

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
  "$MX_E2E_BIN" archive-workspace --workspace-dir "$created_workspace_dir" >/tmp/spaces-e2e-archive-beacon-branch.json
  "$MX_E2E_BIN" archive-workspace --workspace-dir "$scout_branch_workspace_dir" >/tmp/spaces-e2e-archive-scout-branch.json
  wait_for_workspace_lookup "$WORKSPACE_TITLE" "$lookup_file"
  assert_equals "true" "$(json_get "$lookup_file" "isArchived")" "beacon branch workspace archived"
  pass_case
}

main "$@"
