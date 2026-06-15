#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"

BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-edit-shortcuts.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
DUMP_PATH="$WORK_ROOT/terminal-window.json"
SESSION_TITLE="terminal-edit-shortcuts"
APP_PID=""
SERVICE_PID=""
session_id=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$session_id" ]] && [[ -x "$SPACES_E2E" ]]; then
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" terminate-terminal-session "$session_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SERVICE_PID" ]] && kill -0 "$SERVICE_PID" >/dev/null 2>&1; then
    kill "$SERVICE_PID" >/dev/null 2>&1 || true
    wait "$SERVICE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

fail() {
  echo "$*" >&2
  exit 1
}

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || fail "Missing binary: $path"
}

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

terminal_service_pid() {
  local target_session_id="$1"
  python3 - "$DB_PATH" "$RUNTIME_DIR/terminal/sessions/$target_session_id" <<'PY'
import os
import sqlite3
import sys

db_path = sys.argv[1]
root_directory = os.path.normpath(sys.argv[2])
with sqlite3.connect(db_path) as db:
    row = db.execute(
        "SELECT service_pid FROM terminal_runtime_states WHERE root_directory = ?",
        (root_directory,),
    ).fetchone()
if row:
    print(row[0])
else:
    raise SystemExit("missing terminal runtime state")
PY
}

wait_for_spaces_frontmost_ready() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if [[ -n "$session_id" ]]; then
      env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
        dump-terminal-session-window-state --session-id "$session_id" --output-path "$DUMP_PATH" >/dev/null
      if [[ -s "$DUMP_PATH" ]] && [[ "$(dump_value found)" == "true" ]] && [[ "$(dump_value showsTerminalSurface)" == "true" ]]; then
        return 0
      fi
    fi
    sleep 0.2
  done
  fail "Timed out waiting for terminal window to become key"
}

focus_terminal_window_for_input() {
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal show "$session_id" >/dev/null
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    focus-terminal-session-window --session-id "$session_id" >/dev/null
  wait_for_spaces_frontmost_ready
  dump_terminal_state
}

send_command_key_code() {
  local key_code="$1"
  local with_shift="${2:-0}"
  focus_terminal_window_for_input
  local action=""
  case "$key_code:$with_shift" in
    "9:0") action="paste" ;;
    "8:0") action="copy" ;;
    "3:0") action="find" ;;
    "5:0") action="find-next" ;;
    "5:1") action="find-previous" ;;
    *) fail "Unsupported terminal shortcut key code: $key_code shift=$with_shift" ;;
  esac
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    terminal-window-shortcut --session-id "$session_id" --action "$action" >/dev/null
}

send_escape_key() {
  focus_terminal_window_for_input
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    terminal-window-shortcut --session-id "$session_id" --action escape >/dev/null
}

type_text() {
  local text="$1"
  focus_terminal_window_for_input
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    terminal-window-shortcut --session-id "$session_id" --action search --text "$text" >/dev/null
}

wait_for_tail_contains() {
  local needle="$1"
  local timeout="${2:-20}"
  local start
  local output=""
  start="$(date +%s)"
  while true; do
    output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal tail "$session_id" --lines 80)"
    if printf '%s\n' "$output" | grep -Fq "$needle"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      printf '%s\n' "$output" >&2
      fail "Timed out waiting for terminal tail to contain: $needle"
    fi
    sleep 0.2
  done
}

dump_terminal_state() {
  local start
  start="$(date +%s)"
  rm -f "$DUMP_PATH"
  while (( "$(date +%s)" - start < 10 )); do
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
      dump-terminal-session-window-state --session-id "$session_id" --output-path "$DUMP_PATH" >/dev/null
    local attempt_start
    attempt_start="$(date +%s)"
    while (( "$(date +%s)" - attempt_start < 2 )); do
      [[ -s "$DUMP_PATH" ]] && return 0
      sleep 0.1
    done
    [[ -s "$DUMP_PATH" ]] && return 0
  done
  fail "Timed out waiting for terminal state dump"
}

dump_value() {
  local field="$1"
  python3 - "$DUMP_PATH" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    value = json.load(handle).get(sys.argv[2])
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

wait_for_terminal_window_ready() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    dump_terminal_state
    if [[ "$(dump_value found)" == "true" ]] && [[ "$(dump_value showsTerminalSurface)" == "true" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "Timed out waiting for terminal window readiness"
}

wait_for_search_state() {
  local expected_visible="$1"
  local expected_query="${2:-}"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    dump_terminal_state
    local visible
    local query
    visible="$(dump_value searchVisible)"
    query="$(dump_value searchQuery)"
    if [[ "$visible" == "$expected_visible" ]] && { [[ -z "$expected_query" ]] || [[ "$query" == "$expected_query" ]]; }; then
      return 0
    fi
    sleep 0.2
  done
  fail "Timed out waiting for searchVisible=$expected_visible searchQuery=$expected_query"
}

wait_for_rendered_output_contains() {
  local needle="$1"
  local timeout="${2:-10}"
  local start
  local output=""
  start="$(date +%s)"
  while true; do
    dump_terminal_state
    output="$(dump_value renderedOutput)"
    if printf '%s\n' "$output" | grep -Fq "$needle"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      printf '%s\n' "$output" >&2
      fail "Timed out waiting for rendered terminal output to contain: $needle"
    fi
    sleep 0.2
  done
}

wait_for_pbpaste_contains() {
  local needle="$1"
  local timeout="${2:-5}"
  local start
  local output=""
  start="$(date +%s)"
  while true; do
    output="$(pbpaste)"
    if printf '%s\n' "$output" | grep -Fq "$needle"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      printf '%s\n' "$output" >&2
      fail "Timed out waiting for pasteboard to contain: $needle"
    fi
    sleep 0.1
  done
}

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
require_binary "$SPACES_E2E"

mkdir -p "$(dirname "$DB_PATH")" "$RUNTIME_DIR"
touch "$APP_LOG"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT" >/dev/null

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command --backend ghostty-embedded --command cat --title "$SESSION_TITLE")"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || fail "Failed to parse session ID from: $command_output"
SERVICE_PID="$(terminal_service_pid "$session_id")"

focus_terminal_window_for_input
wait_for_terminal_window_ready

paste_token="spaces-paste-token-$(uuidgen)"
printf '%s\n' "$paste_token" | pbcopy
send_command_key_code 9
wait_for_tail_contains "$paste_token"
wait_for_rendered_output_contains "$paste_token"

: | pbcopy
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
  terminal-window-shortcut --session-id "$session_id" --action select-all >/dev/null
send_command_key_code 8
wait_for_pbpaste_contains "$paste_token"

send_command_key_code 3
wait_for_search_state true
sleep 3
type_text "$paste_token"
wait_for_search_state true "$paste_token"
send_command_key_code 5
send_command_key_code 5 1
wait_for_search_state true "$paste_token"
send_escape_key
wait_for_search_state false

echo "Spaces terminal edit shortcut E2E passed for session $session_id"
