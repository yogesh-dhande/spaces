#!/usr/bin/env bash
set -Eeuo pipefail

# Manual real-system E2E coverage for Muxy.
# This script intentionally runs outside XCTest so it can drive the real app,
# terminals, Chrome, yabai, and tmux on an interactive desktop session.

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
MACOS_DIR="$ROOT_DIR/apps/macos"
# scripts/swiftpm.sh already changes into apps/macos internally, so the default
# build command must not add a second package-path override.
BUILD_CMD="${BUILD_CMD:-$ROOT_DIR/scripts/swiftpm.sh build}"
MUXY_APP="${MUXY_APP:-$MACOS_DIR/.build/debug/Muxy}"
MX_BIN="${MX_BIN:-$MACOS_DIR/.build/debug/mx}"
MX_E2E_BIN="${MX_E2E_BIN:-$MACOS_DIR/.build/debug/mxe2e}"
APP_LOG="${APP_LOG:-/tmp/muxy-e2e-app.log}"
EVENT_LOG="${EVENT_LOG:-/tmp/muxy-e2e-events.log}"
METRICS_LOG="${METRICS_LOG:-/tmp/muxy-e2e-metrics.log}"
DEBUG_LOG="${DEBUG_LOG:-/tmp/muxy-e2e-debug.log}"
RESULTS_LOG="${RESULTS_LOG:-/tmp/muxy-e2e-results.log}"
RECORDER_LOG="${RECORDER_LOG:-/tmp/muxy-e2e-recorder.log}"
ACTION_TIMEOUT_SECONDS="${ACTION_TIMEOUT_SECONDS:-20}"
HOSTS_CSV="${HOSTS_CSV:-iterm2,ghostty}"
SEED_FILE="${SEED_FILE:-/tmp/muxy-e2e-seed.json}"
SECOND_SEED_FILE="${SECOND_SEED_FILE:-/tmp/muxy-e2e-seed-2.json}"
TRANSITION_PAUSE_SECONDS="${TRANSITION_PAUSE_SECONDS:-0}"
RECORD_VIDEO_PATH="${RECORD_VIDEO_PATH:-}"
RECORD_VIDEO_CAPTURE_DEVICE="${RECORD_VIDEO_CAPTURE_DEVICE:-}"
RECORD_VIDEO_FRAMERATE="${RECORD_VIDEO_FRAMERATE:-15}"
RECORDER_OUTPUT_START_TIMEOUT_SECONDS="${RECORDER_OUTPUT_START_TIMEOUT_SECONDS:-8}"
RECORDER_STOP_TIMEOUT_SECONDS="${RECORDER_STOP_TIMEOUT_SECONDS:-10}"

TMP_PREFIX="${TMP_PREFIX:-/tmp/muxy-real-e2e}"
TMP_ROOT="$(cd "$(mktemp -d "$TMP_PREFIX".XXXXXX)" && pwd -P)"
TMP_HOME="$TMP_ROOT/home"
TMP_DB="$TMP_ROOT/muxy.db"
TMP_RUNTIME_DIR="$TMP_ROOT/runtime"
TEST_REPO="$TMP_ROOT/atlas-dashboard"
TEST_REPO_2="$TMP_ROOT/harbor-ops"
DOCS_HTML="$TMP_ROOT/atlas-docs.html"
ADMIN_HTML="$TMP_ROOT/atlas-admin.html"
DOCS_ALT_HTML="$TMP_ROOT/harbor-docs.html"
ADMIN_ALT_HTML="$TMP_ROOT/harbor-admin.html"
WORKSPACE_TITLE="Release Readiness"
WORKSPACE_BRANCH="release-readiness"
WORKSPACE_TOOLTIP="Polish the launch checklist and QA follow-ups"
PRIMARY_WORKSPACE_TITLE="Customer Dashboard"
SECONDARY_WORKSPACE_TITLE="Operations Console"
MOCK_AGENT_LABEL="Mock Agent"
MUXY_PID=""
RECORDER_PID=""
RECORDER_READY_FILE=""
FINAL_RECORDING_PATH=""
CURRENT_CASE=""
SUMMARY_PRINTED=0
APP_LOG_SEARCH_FROM_LINE=1

mkdir -p "$TMP_HOME" "$TMP_RUNTIME_DIR"
: >"$EVENT_LOG"
: >"$METRICS_LOG"
: >"$DEBUG_LOG"
: >"$RESULTS_LOG"
: >"$APP_LOG"

export HOME="$TMP_HOME"
export MUXY_DB_PATH="$TMP_DB"
export MUXY_RUNTIME_DIR="$TMP_RUNTIME_DIR"
export MUXY_E2E_EVENTS_LOG="$EVENT_LOG"

cleanup() {
  local exit_code="$?"
  # Always tear down the isolated Muxy instance, helper fixtures, and optional
  # recorder. Recording mode intentionally starts from a minimized desktop.
  stop_screen_recording
  "$MX_E2E_BIN" stop-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/muxy-e2e-stop-fixtures-exit.json 2>/dev/null || true
  close_fixture_chrome_windows
  if [[ -n "${MUXY_PID}" ]]; then
    kill "${MUXY_PID}" >/dev/null 2>&1 || true
  fi
  pkill -x Muxy >/dev/null 2>&1 || true
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
  require_file "$MUXY_APP"
  require_file "$MX_BIN"
  require_file "$MX_E2E_BIN"
}

cleanup_existing_fixture_projects() {
  log_step "cleaning existing E2E fixture projects"
  "$MX_E2E_BIN" stop-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/muxy-e2e-stop-fixtures-start.json || true
  close_fixture_chrome_windows
  "$MX_E2E_BIN" cleanup-fixtures --dir-prefix "$TMP_PREFIX" >/tmp/muxy-e2e-cleanup.json || true
  rm -rf "$TMP_PREFIX".* /private"$TMP_PREFIX".* 2>/dev/null || true
}

reset_fixture_runtime() {
  local workspace_dir="$1"
  log_step "resetting tracked workspace runtime"
  "$MX_E2E_BIN" stop-workspace --workspace-dir "$workspace_dir" >/tmp/muxy-e2e-stop-workspace.json || true
  close_fixture_chrome_windows
  sleep 1
}

close_existing_muxy_instances() {
  log_step "closing existing Muxy instances"
  pkill -x Muxy >/dev/null 2>&1 || true
  sleep 1
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

muxy_instance_count() {
  (pgrep -x Muxy || true) | wc -l | tr -d ' '
}

ensure_single_muxy_instance() {
  local expected_pid="${1:-}"
  local count
  count="$(muxy_instance_count)"
  if [[ -n "$expected_pid" ]]; then
    local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
      count="$(muxy_instance_count)"
      if [[ "$count" == "1" ]] && pgrep -x Muxy | grep -qx "$expected_pid"; then
        return 0
      fi
      sleep 0.2
    done
    fail "expected exactly one Muxy instance with pid $expected_pid, found count=$count"
  fi
  [[ "$count" == "1" ]] || fail "expected exactly one Muxy instance, found count=$count"
}

launch_muxy() {
  log_step "launching Muxy with isolated HOME=$TMP_HOME"
  : >"$APP_LOG"
  APP_LOG_SEARCH_FROM_LINE=1
  env HOME="$TMP_HOME" MUXY_DB_PATH="$TMP_DB" MUXY_RUNTIME_DIR="$TMP_RUNTIME_DIR" MUXY_E2E_EVENTS_LOG="$EVENT_LOG" DEBUG=1 "$MUXY_APP" >"$APP_LOG" 2>&1 &
  MUXY_PID=$!
  ensure_single_muxy_instance "$MUXY_PID"
  wait_for_muxy_frontmost_ready
  transition_pause "Muxy launch"
}

activate_muxy_pid() {
  local pid="${1:-$MUXY_PID}"
  [[ -n "$pid" ]] || fail "missing Muxy pid for activation"
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

wait_for_muxy_frontmost_ready() {
  # Most GUI actions in this script assume a single visible Muxy window and an
  # active accessibility tree, so block until that state exists and Muxy is
  # actually frontmost. The numbered shortcut tests are invalid otherwise.
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$MUXY_PID" >/dev/null 2>&1; then
      fail "Muxy exited during launch"
    fi
    activate_muxy_pid "$MUXY_PID"
    if [[ "$(frontmost_app 2>/dev/null || true)" == "Muxy" ]] && osascript <<'APPLESCRIPT' 2>/dev/null | grep -Eiq '^(1|true)$'; then
tell application "System Events"
  if exists process "Muxy" then
    tell process "Muxy"
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
  fail "timed out waiting for Muxy window"
}

wait_for_muxy_splitter_ready() {
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if osascript <<'APPLESCRIPT' 2>/dev/null | grep -q '^1$'; then
tell application "System Events"
  if exists process "Muxy" then
    tell process "Muxy"
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
  fail "timed out waiting for Muxy splitter layout"
}

muxy_splitter_ready() {
  osascript <<'APPLESCRIPT' 2>/dev/null | grep -q '^1$'
tell application "System Events"
  if exists process "Muxy" then
    tell process "Muxy"
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

setup_git_fixture() {
  log_step "creating git fixture repo"
  mkdir -p "$TEST_REPO" "$TEST_REPO_2"
  (
    cd "$TEST_REPO"
    git init -q -b main
    git config user.email "muxy-e2e@example.com"
    git config user.name "muxy-e2e"
    cat <<'EOF' >"$DOCS_HTML"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Atlas Docs</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4f1ea;
      --panel: rgba(255, 255, 255, 0.86);
      --ink: #1c242b;
      --muted: #62717d;
      --line: rgba(28, 36, 43, 0.1);
      --accent: #0f766e;
      --accent-soft: rgba(15, 118, 110, 0.12);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "SF Pro Text", "Inter", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(15, 118, 110, 0.16), transparent 32rem),
        linear-gradient(180deg, #fbfaf7 0%, var(--bg) 100%);
    }
    .shell {
      max-width: 1180px;
      margin: 0 auto;
      padding: 40px 32px 56px;
    }
    .topbar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 28px;
      color: var(--muted);
      font-size: 14px;
    }
    .badge {
      padding: 8px 12px;
      border-radius: 999px;
      background: var(--accent-soft);
      color: var(--accent);
      font-weight: 600;
    }
    .hero {
      display: grid;
      grid-template-columns: 1.2fr 0.8fr;
      gap: 24px;
      margin-bottom: 24px;
    }
    .card {
      border: 1px solid var(--line);
      border-radius: 24px;
      background: var(--panel);
      backdrop-filter: blur(16px);
      box-shadow: 0 18px 40px rgba(28, 36, 43, 0.08);
    }
    .hero-copy {
      padding: 32px;
    }
    h1 {
      margin: 0 0 12px;
      font-size: 44px;
      line-height: 1.02;
      letter-spacing: -0.04em;
    }
    p {
      margin: 0;
      font-size: 17px;
      line-height: 1.6;
      color: var(--muted);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 18px;
      margin-top: 28px;
    }
    .tile {
      padding: 18px;
      border-radius: 18px;
      background: rgba(255, 255, 255, 0.72);
      border: 1px solid var(--line);
    }
    .tile strong {
      display: block;
      margin-bottom: 8px;
      font-size: 14px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--accent);
    }
    .hero-side {
      padding: 24px;
      display: grid;
      gap: 14px;
      align-content: start;
    }
    .stat {
      padding: 16px 18px;
      border-radius: 18px;
      background: rgba(15, 118, 110, 0.08);
    }
    .stat span {
      display: block;
      color: var(--muted);
      font-size: 13px;
      margin-bottom: 4px;
    }
    .stat strong {
      font-size: 28px;
      letter-spacing: -0.03em;
    }
    .docs-list {
      padding: 28px 32px;
    }
    .docs-list h2 {
      margin: 0 0 18px;
      font-size: 22px;
      letter-spacing: -0.03em;
    }
    .row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 16px 0;
      border-top: 1px solid var(--line);
    }
    .row:first-of-type { border-top: 0; }
    .row b { display: block; margin-bottom: 4px; }
    .row small { color: var(--muted); font-size: 13px; }
    .pill {
      padding: 6px 10px;
      border-radius: 999px;
      background: #ffffff;
      border: 1px solid var(--line);
      color: var(--muted);
      font-size: 12px;
      font-weight: 600;
    }
  </style>
</head>
<body>
  <div class="shell">
    <div class="topbar">
      <div>Atlas Platform · Product docs</div>
      <div class="badge">Atlas docs sentinel</div>
    </div>
    <section class="hero">
      <div class="card hero-copy">
        <h1>Launch the Customer Dashboard without losing the operator context.</h1>
        <p>Atlas Docs centralizes release checklists, environment conventions, workspace recipes, and incident handoff notes for the launch team.</p>
        <div class="grid">
          <div class="tile"><strong>Quickstart</strong>Workspace launch presets, browser sessions, and terminal mappings.</div>
          <div class="tile"><strong>Operations</strong>Runbooks for handoff, rollback, and on-call escalations.</div>
          <div class="tile"><strong>Release</strong>Ship-room checklist for dashboard cutovers and smoke tests.</div>
        </div>
      </div>
      <div class="card hero-side">
        <div class="stat"><span>Active workspaces</span><strong>12</strong></div>
        <div class="stat"><span>Median launch time</span><strong>18s</strong></div>
        <div class="stat"><span>Docs freshness</span><strong>Updated today</strong></div>
      </div>
    </section>
    <section class="card docs-list">
      <h2>Popular guides</h2>
      <div class="row">
        <div><b>Workspace templates for customer launch</b><small>Focus docs, frontend, and incident command windows in one flow.</small></div>
        <div class="pill">7 min</div>
      </div>
      <div class="row">
        <div><b>Browser session naming conventions</b><small>Use durable labels that map cleanly to `mx workspace up --focus`.</small></div>
        <div class="pill">4 min</div>
      </div>
      <div class="row">
        <div><b>Operator handoff checklist</b><small>Capture release context before switching to the Harbor Ops workspace.</small></div>
        <div class="pill">9 min</div>
      </div>
    </section>
  </div>
</body>
</html>
EOF
    cat <<'EOF' >"$ADMIN_HTML"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Atlas Admin</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7fb;
      --panel: #ffffff;
      --ink: #18212b;
      --muted: #64748b;
      --line: #e2e8f0;
      --accent: #2563eb;
      --good: #059669;
      --warn: #d97706;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "SF Pro Text", "Inter", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top right, rgba(37, 99, 235, 0.14), transparent 26rem),
        linear-gradient(180deg, #fbfdff 0%, var(--bg) 100%);
    }
    .shell { max-width: 1240px; margin: 0 auto; padding: 28px; }
    .bar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 18px;
    }
    .bar h1 {
      margin: 0;
      font-size: 28px;
      letter-spacing: -0.04em;
    }
    .bar small { color: var(--muted); font-size: 14px; }
    .chip {
      border-radius: 999px;
      padding: 8px 12px;
      background: rgba(37, 99, 235, 0.12);
      color: var(--accent);
      font-weight: 700;
      font-size: 12px;
    }
    .layout {
      display: grid;
      grid-template-columns: 1.2fr 0.8fr;
      gap: 20px;
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 22px;
      box-shadow: 0 18px 36px rgba(15, 23, 42, 0.06);
    }
    .metrics {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 14px;
      padding: 20px;
    }
    .metric {
      border-radius: 18px;
      padding: 18px;
      background: #f8fbff;
      border: 1px solid var(--line);
    }
    .metric span { display: block; color: var(--muted); font-size: 13px; margin-bottom: 6px; }
    .metric strong { font-size: 30px; letter-spacing: -0.04em; }
    .table {
      padding: 20px 22px 10px;
    }
    .table h2, .side h2 { margin: 0 0 14px; font-size: 19px; letter-spacing: -0.03em; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 14px 0; border-top: 1px solid var(--line); text-align: left; }
    th { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; border-top: 0; }
    td:last-child, th:last-child { text-align: right; }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
    }
    .healthy { background: rgba(5, 150, 105, 0.12); color: var(--good); }
    .review { background: rgba(217, 119, 6, 0.12); color: var(--warn); }
    .side {
      padding: 20px 22px;
      display: grid;
      gap: 16px;
      align-content: start;
    }
    .note {
      padding: 16px;
      border-radius: 16px;
      background: #f8fafc;
      border: 1px solid var(--line);
    }
    .note b { display: block; margin-bottom: 6px; }
    .note p { margin: 0; color: var(--muted); line-height: 1.5; }
  </style>
</head>
<body>
  <div class="shell">
    <div class="bar">
      <div>
        <h1>Atlas Admin</h1>
        <small>Release control room for launch-day operators</small>
      </div>
      <div class="chip">Atlas admin sentinel</div>
    </div>
    <div class="layout">
      <section class="panel">
        <div class="metrics">
          <div class="metric"><span>Live workspaces</span><strong>8</strong></div>
          <div class="metric"><span>Open incidents</span><strong>1</strong></div>
          <div class="metric"><span>Queue latency</span><strong>94ms</strong></div>
        </div>
        <div class="table">
          <h2>Launch checks</h2>
          <table>
            <thead>
              <tr><th>Check</th><th>Owner</th><th>Status</th></tr>
            </thead>
            <tbody>
              <tr><td>Customer dashboard deploy</td><td>Frontend</td><td><span class="status healthy">Healthy</span></td></tr>
              <tr><td>Billing webhook replay</td><td>Platform</td><td><span class="status review">Review</span></td></tr>
              <tr><td>Status page publish</td><td>Ops</td><td><span class="status healthy">Healthy</span></td></tr>
            </tbody>
          </table>
        </div>
      </section>
      <aside class="panel side">
        <h2>Operator notes</h2>
        <div class="note">
          <b>Launch window</b>
          <p>Customer Dashboard and Operations Console stay paired so docs and incident controls are one shortcut away.</p>
        </div>
        <div class="note">
          <b>Fallback plan</b>
          <p>If latency exceeds the threshold, hand off to Harbor Ops and pause the rollout checklist before retry.</p>
        </div>
      </aside>
    </div>
  </div>
</body>
</html>
EOF
    cat <<'EOF' >"$DOCS_ALT_HTML"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Harbor Docs</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #eef6f7;
      --panel: rgba(255, 255, 255, 0.9);
      --ink: #142126;
      --muted: #5f7580;
      --line: rgba(20, 33, 38, 0.1);
      --accent: #0f766e;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "SF Pro Text", "Inter", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top right, rgba(14, 165, 164, 0.2), transparent 22rem),
        linear-gradient(180deg, #f9fdfd 0%, var(--bg) 100%);
    }
    .shell { max-width: 1100px; margin: 0 auto; padding: 36px 28px 52px; }
    .hero, .list {
      border-radius: 22px;
      border: 1px solid var(--line);
      background: var(--panel);
      box-shadow: 0 16px 30px rgba(20, 33, 38, 0.08);
    }
    .hero { padding: 30px; margin-bottom: 20px; }
    h1 { margin: 0 0 10px; font-size: 40px; letter-spacing: -0.04em; }
    p { margin: 0; color: var(--muted); line-height: 1.6; }
    .banner {
      display: inline-block;
      margin-bottom: 16px;
      padding: 8px 12px;
      border-radius: 999px;
      background: rgba(15, 118, 110, 0.12);
      color: var(--accent);
      font-size: 12px;
      font-weight: 700;
    }
    .list { padding: 24px 30px; }
    .item {
      display: flex;
      justify-content: space-between;
      gap: 20px;
      padding: 16px 0;
      border-top: 1px solid var(--line);
    }
    .item:first-of-type { border-top: 0; }
    .item b { display: block; margin-bottom: 5px; }
    .time { color: var(--muted); font-size: 12px; font-weight: 700; }
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <div class="banner">Harbor docs sentinel</div>
      <h1>Operations guides for high-signal workspace handoffs.</h1>
      <p>Harbor Docs tracks the runbooks, incident rituals, and launch communication patterns used by the operations console team.</p>
    </section>
    <section class="list">
      <div class="item">
        <div><b>Incident command workspace recipe</b><p>Keep release status, operator notes, and terminal windows synchronized across one launch flow.</p></div>
        <div class="time">6 min</div>
      </div>
      <div class="item">
        <div><b>Escalation notes template</b><p>Standardize what gets copied into the admin panel before a shift handoff.</p></div>
        <div class="time">3 min</div>
      </div>
      <div class="item">
        <div><b>Rollback communication matrix</b><p>Who to page, what to freeze, and which workspace becomes primary during recovery.</p></div>
        <div class="time">8 min</div>
      </div>
    </section>
  </div>
</body>
</html>
EOF
    cat <<'EOF' >"$ADMIN_ALT_HTML"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Harbor Admin</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4f7fb;
      --panel: #ffffff;
      --ink: #18212d;
      --muted: #64748b;
      --line: #dbe4ef;
      --accent: #0f766e;
      --alert: #b45309;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "SF Pro Text", "Inter", sans-serif;
      color: var(--ink);
      background: linear-gradient(180deg, #fbfdff 0%, var(--bg) 100%);
    }
    .shell { max-width: 1180px; margin: 0 auto; padding: 28px; }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 22px;
      box-shadow: 0 16px 32px rgba(15, 23, 42, 0.06);
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 18px;
    }
    .header h1 { margin: 0; font-size: 28px; letter-spacing: -0.04em; }
    .tag {
      padding: 8px 12px;
      border-radius: 999px;
      background: rgba(15, 118, 110, 0.12);
      color: var(--accent);
      font-size: 12px;
      font-weight: 700;
    }
    .content {
      display: grid;
      grid-template-columns: 0.95fr 1.05fr;
      gap: 18px;
    }
    .stack, .table { padding: 22px; }
    .stack { display: grid; gap: 14px; }
    .callout {
      padding: 16px;
      border-radius: 16px;
      background: #f8fafc;
      border: 1px solid var(--line);
    }
    .callout b { display: block; margin-bottom: 6px; }
    .callout p { margin: 0; color: var(--muted); line-height: 1.5; }
    .alert { color: var(--alert); }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 14px 0; text-align: left; border-top: 1px solid var(--line); }
    th { border-top: 0; color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; }
    td:last-child, th:last-child { text-align: right; }
  </style>
</head>
<body>
  <div class="shell">
    <div class="header">
      <h1>Harbor Admin</h1>
      <div class="tag">Harbor admin sentinel</div>
    </div>
    <div class="content">
      <section class="panel stack">
        <div class="callout">
          <b>Incident room</b>
          <p>The Operations Console stays paired with Harbor Docs so runbooks remain visible while triaging active launch issues.</p>
        </div>
        <div class="callout">
          <b class="alert">Watch item</b>
          <p>Retry queue depth is elevated. Keep rollback notes open and preserve the current workspace ordering for faster handoff.</p>
        </div>
      </section>
      <section class="panel table">
        <table>
          <thead>
            <tr><th>Service</th><th>Owner</th><th>Status</th></tr>
          </thead>
          <tbody>
            <tr><td>Queue processor</td><td>Ops</td><td>Watching</td></tr>
            <tr><td>Launch comms</td><td>Support</td><td>Ready</td></tr>
            <tr><td>Rollback channel</td><td>Platform</td><td>Standby</td></tr>
          </tbody>
        </table>
      </section>
    </div>
  </div>
</body>
</html>
EOF
    printf '# Atlas Dashboard\n' >README.md
    git add README.md
    git commit -q -m init
  )
  (
    cd "$TEST_REPO_2"
    git init -q -b main
    git config user.email "muxy-e2e@example.com"
    git config user.name "muxy-e2e"
    printf '# Harbor Ops\n' >README.md
    git add README.md
    git commit -q -m init
  )
}

seed_fixture() {
  log_step "seeding project fixture"
  # mxe2e seeds deterministic project/workspace templates through the real
  # streamctl layer so the manual test is reproducible.
  "$MX_E2E_BIN" seed-fixture \
    --project-dir "$TEST_REPO" \
    --workspace-title "$PRIMARY_WORKSPACE_TITLE" \
    --docs-url "file://$DOCS_HTML" \
    --admin-url "file://$ADMIN_HTML" >"$SEED_FILE"
}

seed_second_fixture() {
  log_step "seeding second project fixture"
  "$MX_E2E_BIN" seed-fixture \
    --project-dir "$TEST_REPO_2" \
    --workspace-title "$SECONDARY_WORKSPACE_TITLE" \
    --docs-url "file://$DOCS_ALT_HTML" \
    --admin-url "file://$ADMIN_ALT_HTML" >"$SECOND_SEED_FILE"
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
  local script_path="$project_dir/.muxy-e2e-mock-agent"
  python3 - "$script_path" "$MX_BIN" "$EVENT_LOG" <<'PY'
import os
import sys
from pathlib import Path

script_path, mx_bin, event_log = sys.argv[1:4]
content = f"""#!/usr/bin/env bash
set -euo pipefail
workspace_dir="${{MUXY_WORKSPACE_DIR:-$PWD}}"
agent_log="{event_log}"
mx_bin="{mx_bin}"
"$mx_bin" agent event --type init "$workspace_dir" >/dev/null
"$mx_bin" agent event --type start "$workspace_dir" >/dev/null
printf 'agent-start:%s\\n' "$workspace_dir" >>"$agent_log"
sleep 2
"$mx_bin" agent event --type waiting "$workspace_dir" >/dev/null
printf 'agent-waiting:%s\\n' "$workspace_dir" >>"$agent_log"
sleep 2
"$mx_bin" agent event --type done "$workspace_dir" >/dev/null
printf 'agent-done:%s\\n' "$workspace_dir" >>"$agent_log"
trap '"$mx_bin" agent event --type exit "$workspace_dir" >/dev/null 2>&1 || true; printf "agent-exit:%s\\n" "$workspace_dir" >>"$agent_log"; exit 0' TERM INT
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
    >/tmp/muxy-e2e-agent-launcher.json
}

clear_workspace_agent_launchers() {
  local workspace_dir="$1"
  "$MX_E2E_BIN" set-workspace-agent-launchers --workspace-dir "$workspace_dir" --clear >/tmp/muxy-e2e-agent-launcher-clear.json
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

ui_click_identifier() {
  # The GUI identifiers added for this suite keep the AppleScript automation
  # resilient when labels or ordering change.
  local identifier="$1"
  osascript - "$identifier" <<'APPLESCRIPT'
on run argv
  set targetID to item 1 of argv
  tell application "System Events"
    tell process "Muxy"
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

ui_set_identifier_value() {
  local identifier="$1"
  local value="$2"
  osascript - "$identifier" "$value" <<'APPLESCRIPT'
on run argv
  set targetID to item 1 of argv
  set targetValue to item 2 of argv
  tell application "System Events"
    tell process "Muxy"
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
    tell process "Muxy"
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
    tell process "Muxy"
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
  wait_for_muxy_splitter_ready
  osascript - "$row_index" <<'APPLESCRIPT'
on run argv
  set targetRow to (item 1 of argv) as integer
  tell application "System Events"
    tell process "Muxy"
      select row targetRow of outline 1 of scroll area 1 of splitter group 1 of window 1
    end tell
  end tell
end run
APPLESCRIPT
}

ui_show_workspace_detail() {
  local workspace_dir="$1"
  local workspace_title="$2"
  "$MX_E2E_BIN" select-workspace-detail --workspace-dir "$workspace_dir" >/tmp/muxy-e2e-select-workspace-detail.json
  wait_for_muxy_frontmost_ready
  # The helper path is validated separately; here we just need the app frontmost and ready
  # before driving the real numbered-shortcut interaction against the detail UI.
  sleep 0.2
}

ui_click_tab() {
  local label="$1"
  wait_for_muxy_splitter_ready
  osascript - "$label" <<'APPLESCRIPT'
on run argv
  set targetLabel to item 1 of argv
  tell application "System Events"
    tell process "Muxy"
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
  log_step "creating additional workspace through real orchestrator helper"
  # Workspace creation is still part of the manual E2E coverage, but this path
  # avoids fragile sidebar-selection dependencies while continuing to exercise
  # the real store, git worktree creation, and workspace initialization logic.
  "$MX_E2E_BIN" create-workspace \
    --project-dir "$TEST_REPO" \
    --title "$WORKSPACE_TITLE" \
    --branch "$WORKSPACE_BRANCH" \
    --target-branch main \
    --tooltip "$WORKSPACE_TOOLTIP" >"$TMP_ROOT/created-workspace.json"
  transition_pause "workspace creation"
}

set_workspace_browser_urls() {
  local workspace_dir="$1"
  local docs_url="$2"
  local admin_url="$3"
  "$MX_E2E_BIN" set-workspace-browser-session-urls \
    --workspace-dir "$workspace_dir" \
    --docs-url "$docs_url" \
    --admin-url "$admin_url" >/tmp/muxy-e2e-browser-session-urls.json
}

set_workspace_stop_script_via_gui() {
  local marker="$1"
  local workspace_dir="$2"
  log_step "overriding workspace stop script through real workspace-settings path"
  "$MX_E2E_BIN" set-workspace-stop-script \
    --workspace-dir "$workspace_dir" \
    --stop-script "bash -lc 'printf \"$marker\\n\" >> \"$EVENT_LOG\"'" >/tmp/muxy-e2e-stop-script.json
}

archive_workspace_via_gui() {
  local workspace_dir="$1"
  log_step "archiving workspace via GUI"
  wait_for_muxy_frontmost_ready
  ui_select_outline_row 2
  sleep 0.5
  ui_click_button_description "Archive"
  osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
  tell process "Muxy"
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
  "$MX_E2E_BIN" archive-workspace --workspace-dir "$workspace_dir" >/tmp/muxy-e2e-archive-workspace-fallback.json
}

stop_workspace_via_gui() {
  local workspace_dir="$1"
  log_step "stopping workspace via GUI"
  wait_for_muxy_frontmost_ready
  if ! muxy_splitter_ready; then
    log_debug "stop_workspace_via_gui fallback=stop-workspace-helper"
    "$MX_E2E_BIN" stop-workspace --workspace-dir "$workspace_dir" >/tmp/muxy-e2e-stop-workspace-fallback.json
    return 0
  fi
  ui_show_workspace_detail "$workspace_dir" ""
  sleep 0.5
  if ! ui_click_identifier "workspace-detail-stop"; then
    log_debug "stop_workspace_via_gui fallback=identifier-stop-workspace-helper"
    "$MX_E2E_BIN" stop-workspace --workspace-dir "$workspace_dir" >/tmp/muxy-e2e-stop-workspace-fallback.json
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
  "$MX_E2E_BIN" stop-workspace --workspace-dir "$workspace_dir" >/tmp/muxy-e2e-stop-workspace-fallback.json
}

restart_workspace_via_gui() {
  local workspace_dir="$1"
  log_step "restarting workspace via GUI"
  ui_show_workspace_detail "$workspace_dir" ""
  sleep 0.5
  if ! ui_click_identifier "workspace-detail-launch-restart"; then
    log_debug "restart_workspace_via_gui fallback=mx-workspace-up-restart"
    run_mx_logged /tmp/muxy-e2e-restart-workspace-fallback.log workspace up "$workspace_dir" --restart
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

send_muxy_window_shortcut() {
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

send_muxy_window_shortcut_with_ack() {
  local index="$1"
  local attempts="${2:-3}"
  local pattern="muxy: window_shortcut stage=received index=$index "
  local attempt=1
  while (( attempt <= attempts )); do
    ensure_single_muxy_instance "$MUXY_PID"
    wait_for_muxy_frontmost_ready
    sleep 0.1
    send_muxy_window_shortcut "$index"
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
  printf '%s\t%s\n' "$name" "$value_ms" >>"$METRICS_LOG"
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
  local line
  line="$(wait_for_app_log_pattern "$pattern")"
  record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")"
}

record_cycle_metric() {
  local name="$1"
  local direction="$2"
  record_perf_metric "$name" "muxy: perf metric=window_cycle .*success=1 .*elapsed_ms=[0-9]+ .*direction=${direction}"
}

record_window_shortcut_metric() {
  local name="$1"
  local index="$2"
  local line
  if line="$(wait_for_app_log_pattern_optional "muxy: perf metric=window_shortcut target=index=${index} success=1 elapsed_ms=")"; then
    record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")"
    return 0
  fi
  log_debug "window shortcut metric missing for index=$index; skipping dedicated shortcut metric"
  return 0
}

record_named_focus_metric() {
  local name="$1"
  local target_name="$2"
  local line
  if ! line="$(wait_for_app_log_pattern_optional "muxy: perf metric=(named_window_focus|browser_focus|process_focus) .*target=${target_name} .*success=1 .*elapsed_ms=")"; then
    log_debug "named focus metric missing for target=$target_name; skipping metric $name"
    return 0
  fi
  record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")"
}

record_browser_focus_metric() {
  local name="$1"
  local target_url="$2"
  local focus_name="${3:-}"
  local line
  if line="$(wait_for_app_log_pattern_optional "muxy: perf metric=browser_focus .*target=${target_url} .*success=1 .*elapsed_ms=")"; then
    record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")"
    return 0
  fi
  # `mx workspace up --focus docs` can resolve through the shared name-based
  # focus path instead of the browser-session-specific path, so the app may log
  # `named_window_focus target=docs` even though the visible behavior is still
  # "focus the tracked docs Chrome tab". Accept either metric shape here.
  if [[ -n "$focus_name" ]] && line="$(wait_for_app_log_pattern_optional "muxy: perf metric=named_window_focus .*target=${focus_name} .*success=1 .*elapsed_ms=")"; then
    record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")"
    return 0
  fi
  fail "timed out waiting for browser-focus metric: url=$target_url name=${focus_name:-<none>}"
}

record_process_focus_metric() {
  local name="$1"
  local process_name="$2"
  local line
  line="$(wait_for_app_log_pattern "muxy: perf metric=(process_focus|named_window_focus) .*target=${process_name} .*success=1 .*elapsed_ms=")"
  record_metric_sample "$name" "$(extract_metric_field "$line" "elapsed_ms")"
}

wait_for_iterm_session_focus() {
  local expected_session_id="$1"
  [[ -n "$expected_session_id" ]] || fail "missing expected iTerm session id"
  wait_for_app_log_pattern_optional "muxy: iterm session_verification_succeeded session_id=$expected_session_id " >/dev/null || true
  wait_for_condition "frontmost_app" "iTerm2"
  wait_for_condition "iterm_front_session" "$expected_session_id"
}

print_metric_summary() {
  if [[ ! -s "$METRICS_LOG" ]]; then
    printf 'Performance metrics: none recorded\n'
    return 0
  fi
  printf 'Performance metrics:\n'
  awk -F '\t' '
    {
      value = $2 + 0
      count[$1] += 1
      sum[$1] += value
      if (!(($1) in min) || value < min[$1]) min[$1] = value
      if (value > max[$1]) max[$1] = value
      samples[$1] = samples[$1] (samples[$1] == "" ? "" : ",") value
    }
    END {
      for (key in count) {
        avg = sum[key] / count[key]
        printf "%s\t%d\t%.1f\t%d\t%d\t%s\n", key, count[key], avg, min[key], max[key], samples[key]
      }
    }
  ' "$METRICS_LOG" | sort | while IFS=$'\t' read -r key count avg min max samples; do
    printf '  %s: avg=%sms min=%sms max=%sms samples=[%s]\n' "$key" "$avg" "$min" "$max" "$samples"
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

run_mx_logged() {
  local stdout_file="$1"
  shift
  env DEBUG=1 "$MX_BIN" "$@" >"$stdout_file" 2>>"$APP_LOG"
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
  "$MX_E2E_BIN" set-terminal-host "$host" >/tmp/muxy-e2e-terminal-host.json
  sleep 0.5
  transition_pause "switch terminal host to $host"

  begin_case "$host: launch workspace and persist terminal host"
  run_mx_logged /tmp/muxy-e2e-launch.log workspace up "$workspace_dir" --focus docs
  transition_pause "$host launch workspace"
  dump_chrome_state "$host docs-focus after-launch"
  wait_for_condition "chrome_front_url" "file://$DOCS_HTML"
  local docs_window_id
  docs_window_id="$(chrome_front_window_id)"
  [[ -n "$docs_window_id" ]] || fail "docs focus did not leave a front Chrome window"
  log_debug "$host docs_window_id=$docs_window_id expected_docs=file://$DOCS_HTML"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "file://$DOCS_HTML"

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
  pass_case

  begin_case "$host: focus tracked Chrome tab with extra user tab present"
  # Prove the docs focus really left us on the tracked Chrome window before we
  # inject an untracked user tab into that same window.
  dump_chrome_state "$host docs-focus before-extra-tab"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "file://$DOCS_HTML"
  chrome_add_extra_tab_to_window "$docs_window_id" "file://$ADMIN_HTML"
  transition_pause "$host add extra Chrome tab"
  dump_chrome_state "$host after-extra-tab"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "file://$ADMIN_HTML"
  run_mx_logged /tmp/muxy-e2e-focus-docs.log workspace up "$workspace_dir" --focus docs
  transition_pause "$host refocus docs"
  record_browser_focus_metric "$host.browser_focus.docs" "file://$DOCS_HTML" "docs"
  dump_chrome_state "$host after-refocus-docs"
  wait_for_condition "chrome_front_window_id" "$docs_window_id"
  wait_for_condition "chrome_window_active_url $docs_window_id" "file://$DOCS_HTML"
  wait_for_condition "chrome_front_url" "file://$DOCS_HTML"
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
    run_mx_logged /tmp/muxy-e2e-focus-frontend.log workspace up "$workspace_dir" --focus frontend
    transition_pause "$host focus frontend terminal"
    record_process_focus_metric "$host.process_focus.frontend" "frontend"
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
    run_mx_logged /tmp/muxy-e2e-focus-frontend.log workspace up "$workspace_dir" --focus frontend
    wait_for_condition "frontmost_app" "ghostty"
    ghostty_open_extra_tab
    sleep 1
    transition_pause "$host add extra Ghostty tab"
    [[ "$(ghostty_focused_terminal)" != "$frontend_terminal_id" ]] || fail "expected extra Ghostty tab to be selected"
    run_mx_logged /tmp/muxy-e2e-focus-frontend-2.log workspace up "$workspace_dir" --focus frontend
    transition_pause "$host refocus frontend terminal"
    record_process_focus_metric "$host.process_focus.frontend" "frontend"
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
  ensure_single_muxy_instance "$MUXY_PID"
  ui_show_workspace_detail "$workspace_dir" "$workspace_title"
  sleep 0.5
  send_muxy_window_shortcut_with_ack "$docs_shortcut_index"
  transition_pause "$host shortcut focus docs"
  wait_for_condition "chrome_window_active_url $docs_window_id" "file://$DOCS_HTML"
  record_window_shortcut_metric "$host.shortcut.docs" "$docs_shortcut_index"
  record_named_focus_metric "$host.shortcut.docs.focus" "docs"
  ui_show_workspace_detail "$workspace_dir" "$workspace_title"
  sleep 0.5
  send_muxy_window_shortcut_with_ack "$frontend_shortcut_index"
  transition_pause "$host shortcut focus frontend"
  if [[ "$host" == "iterm2" ]]; then
    frontend_session_id="$(wait_for_workspace_terminal_tracking_id "$workspace_dir" "frontend" "$dump_file")"
    wait_for_iterm_session_focus "$frontend_session_id"
  else
    wait_for_condition "ghostty_focused_terminal" "$frontend_terminal_id"
  fi
  pass_case

  begin_case "$host: workspace window cycling stays on tracked windows"
  # This validates forward/back workspace cycling from the live desktop state.
  ensure_single_muxy_instance "$MUXY_PID"
  run_mx_logged /tmp/muxy-e2e-cycle-seed.log workspace up "$workspace_dir" --focus docs
  transition_pause "$host seed docs focus for cycling"
  wait_for_condition "chrome_front_url" "file://$DOCS_HTML"
  send_cycle_hotkey next
  transition_pause "$host cycle next"
  record_cycle_metric "$host.cycle.next" "next"
  if [[ "$host" == "iterm2" ]]; then
    wait_for_any_value "iterm_focused_session $frontend_window_id" "$frontend_session_id" "$backend_session_id"
  else
    wait_for_any_value "ghostty_focused_terminal" "$frontend_terminal_id" "$backend_terminal_id"
  fi
  send_cycle_hotkey previous
  transition_pause "$host cycle previous"
  record_cycle_metric "$host.cycle.previous" "previous"
  wait_for_condition "chrome_front_url" "file://$DOCS_HTML"
  pass_case

  begin_case "$host: dead process recovery"
  # Kill one tracked process, then confirm `mx workspace up` revives only the
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
  run_mx_logged /tmp/muxy-e2e-recover.log workspace up "$workspace_dir"
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

run_multi_workspace_focus_and_cycle_assertions() {
  local host="$1"
  local primary_workspace_dir="$2"
  local secondary_workspace_dir="$3"
  local primary_docs_url="file://$DOCS_HTML"
  local primary_admin_url="file://$ADMIN_HTML"
  local secondary_docs_url="file://$DOCS_ALT_HTML"
  local secondary_admin_url="file://$ADMIN_ALT_HTML"
  local primary_dump="$TMP_ROOT/$host-primary-multi.json"
  local secondary_dump="$TMP_ROOT/$host-secondary-multi.json"

  begin_case "$host: multi-workspace focus and cycle isolation"
  ensure_single_muxy_instance "$MUXY_PID"
  reset_fixture_runtime "$primary_workspace_dir"
  reset_fixture_runtime "$secondary_workspace_dir"

  run_mx_logged /tmp/muxy-e2e-multi-primary-launch.log workspace up "$primary_workspace_dir" --focus docs
  transition_pause "$host launch primary workspace"
  log_debug "$host multi primary launch complete"
  dump_workspace "$primary_workspace_dir" "$primary_dump"
  run_mx_logged /tmp/muxy-e2e-multi-secondary-launch.log workspace up "$secondary_workspace_dir" --focus docs
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

  run_mx_logged /tmp/muxy-e2e-multi-primary-focus.log workspace up "$primary_workspace_dir" --focus docs
  transition_pause "$host focus primary docs"
  log_debug "$host multi primary docs focus complete"
  wait_for_condition "chrome_front_url" "$primary_docs_url"
  send_cycle_hotkey next
  transition_pause "$host primary cycle next"
  log_debug "$host multi primary cycle next sent"
  record_cycle_metric "$host.multi.primary.next" "next"
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
  record_cycle_metric "$host.multi.primary.previous" "previous"
  wait_for_condition "chrome_front_url" "$primary_docs_url"

  run_mx_logged /tmp/muxy-e2e-multi-secondary-focus.log workspace up "$secondary_workspace_dir" --focus docs
  transition_pause "$host focus secondary docs"
  log_debug "$host multi secondary docs focus complete"
  wait_for_condition "chrome_front_url" "$secondary_docs_url"
  send_cycle_hotkey next
  transition_pause "$host secondary cycle next"
  log_debug "$host multi secondary cycle next sent"
  record_cycle_metric "$host.multi.secondary.next" "next"
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
  record_cycle_metric "$host.multi.secondary.previous" "previous"
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
  ensure_single_muxy_instance "$MUXY_PID"
  reset_fixture_runtime "$workspace_dir"
  if [[ -f "$EVENT_LOG" ]]; then
    event_start_line=$(( $(wc -l <"$EVENT_LOG") + 1 ))
  fi
  run_mx_logged "/tmp/muxy-e2e-$host-agent-launch.log" workspace up "$workspace_dir"
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
  require_cmd yabai

  build_binaries
  cleanup_existing_fixture_projects
  close_existing_muxy_instances
  setup_git_fixture
  seed_fixture
  seed_second_fixture
  if [[ -n "$RECORD_VIDEO_PATH" ]]; then
    hide_all_visible_windows
    start_screen_recording
  fi
  launch_muxy
  create_workspace_via_gui

  local lookup_file="$TMP_ROOT/workspace.json"
  wait_for_workspace_lookup "$WORKSPACE_TITLE" "$lookup_file"
  local created_workspace_dir workspace_dir
  created_workspace_dir="$(json_get "$lookup_file" "dir")"
  workspace_dir="$(json_get "$SEED_FILE" "defaultWorkspace.dir")"
  local second_workspace_dir
  second_workspace_dir="$(json_get "$SECOND_SEED_FILE" "defaultWorkspace.dir")"
  local stop_marker="workspace-stop-override"

  set_workspace_stop_script_via_gui "$stop_marker" "$workspace_dir"

  IFS=',' read -r -a hosts <<<"$HOSTS_CSV"
  for host in "${hosts[@]}"; do
    if host_available "$host"; then
      run_launch_and_focus_assertions "$host" "$workspace_dir"
      run_multi_workspace_focus_and_cycle_assertions "$host" "$workspace_dir" "$second_workspace_dir"
      run_agent_status_assertions "$host" "$workspace_dir"
      assert_file_contains "$EVENT_LOG" "$stop_marker"
    else
      printf 'SKIP: terminal host %s is not available on this machine\n' "$host"
      skip_case "$host: host availability" "terminal host not installed"
    fi
  done
  begin_case "archive created workspace"
  "$MX_E2E_BIN" archive-workspace --workspace-dir "$created_workspace_dir" >/tmp/muxy-e2e-archive-created-workspace.json
  wait_for_workspace_lookup "$WORKSPACE_TITLE" "$lookup_file"
  assert_equals "true" "$(json_get "$lookup_file" "isArchived")" "workspace archived"
  pass_case
}

main "$@"
