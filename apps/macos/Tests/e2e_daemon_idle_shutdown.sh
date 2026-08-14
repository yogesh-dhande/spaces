#!/usr/bin/env bash
# Verifies the idle-only daemon stop used by scripts/dev-build-and-launch.sh: a spacesd with a
# live session survives spaces_profile_stop_terminal_service_if_idle (sessions and their child
# processes keep running for the relaunched app to reattach), and an idle spacesd exits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_EXECUTABLE="$BUILD_DIR/spacesd"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d /tmp/spidle.XXXXXX)}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/rt}"
export SPACES_DEVICE_API_PORT="${SPACES_DEVICE_API_PORT:-0}"
SERVICE_PID=""
session_id=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$session_id" ]] && [[ -x "$SPACES_E2E" ]]; then
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" terminate-terminal-session "$session_id" >/dev/null 2>&1 || true
  fi
  stop_terminal_service_for_runtime_dir "$RUNTIME_DIR"
}
trap cleanup EXIT

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | sed -nE 's/^Started terminal session ([0-9A-F-]{36})([[:space:]].*)?$/\1/p' | tail -n 1
}

runtime_state_pid() {
  local session_id="$1"
  local column="$2"
  python3 - "$DB_PATH" "$RUNTIME_DIR/terminal/sessions/$session_id" "$column" <<'PY'
import os
import sqlite3
import sys

db_path = sys.argv[1]
root_directory = os.path.normpath(sys.argv[2])
column = sys.argv[3]
assert column in ("service_pid", "child_pid")
with sqlite3.connect(db_path) as db:
    row = db.execute(
        f"SELECT {column} FROM terminal_runtime_states WHERE root_directory = ?",
        (root_directory,),
    ).fetchone()
if row and row[0]:
    print(row[0])
else:
    raise SystemExit(f"missing {column} in terminal runtime state")
PY
}

wait_for_session_absent_from_list() {
  local session_id="$1"
  local timeout="${2:-20}"
  local start
  start="$(date +%s)"
  while true; do
    if ! env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal list | grep -Fq "$session_id"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for session $session_id to leave terminal list" >&2
      return 1
    fi
    sleep 0.2
  done
}

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

mkdir -p "$(dirname "$DB_PATH")"

require_binary "$SPACES_CLI"
require_binary "$SPACES_E2E"
require_binary "$SPACESD_EXECUTABLE"
export SPACESD_EXECUTABLE

cd "$REPO_ROOT"
acquire_terminal_harness_lock
if [[ "${SPACES_E2E_SKIP_GHOSTTYKIT_SETUP:-0}" != "1" ]]; then
  "$SETUP_GHOSTTYKIT" >/dev/null
fi

# terminal create is workspace-scoped; register a fixture project and use its default workspace.
# register-project talks to the DB directly through spacese2e's in-process orchestrator, so it
# does not start or touch spacesd and cannot interfere with the idle-shutdown assertions below.
FIXTURE_PROJECT_DIR="$WORK_ROOT/terminal-fixture-project"
mkdir -p "$FIXTURE_PROJECT_DIR"
FIXTURE_WORKSPACE_JSON="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" register-project --project-dir "$FIXTURE_PROJECT_DIR")"
FIXTURE_WORKSPACE_ID="$(printf '%s' "$FIXTURE_WORKSPACE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

command_payload="python3 -c 'import time; print(\"__idle_shutdown_ready__\", flush=True); time.sleep(120)'"
command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal create --workspace "$FIXTURE_WORKSPACE_ID" --command "$command_payload" --title idle-shutdown-e2e)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse session ID from: $command_output" >&2; exit 1; }
SERVICE_PID="$(runtime_state_pid "$session_id" service_pid)"
CHILD_PID="$(runtime_state_pid "$session_id" child_pid)"

# Busy phase: the idle-only stop must leave a daemon with a live session untouched.
busy_output="$(SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_terminal_service_if_idle "$SPACES_CLI")"
printf '%s\n' "$busy_output" | grep -Fq "spacesd left running with 1 live session(s) (pid $SERVICE_PID)" || {
  echo "Idle-only stop did not report the busy daemon; output: $busy_output" >&2
  exit 1
}
sleep 1
kill -0 "$SERVICE_PID" >/dev/null 2>&1 || { echo "spacesd (pid $SERVICE_PID) died despite a live session" >&2; exit 1; }
kill -0 "$CHILD_PID" >/dev/null 2>&1 || { echo "Session child (pid $CHILD_PID) died despite the idle-only stop" >&2; exit 1; }
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal list | grep -Fq "$session_id" || {
  echo "Live session $session_id disappeared from terminal list after the idle-only stop" >&2
  exit 1
}

# Idle phase: with no sessions left, the same stop must shut the daemon down.
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" terminate-terminal-session "$session_id" >/dev/null
wait_for_session_absent_from_list "$session_id"
session_id=""
SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_terminal_service_if_idle "$SPACES_CLI"
kill -0 "$SERVICE_PID" >/dev/null 2>&1 && { echo "spacesd (pid $SERVICE_PID) still running after idle stop" >&2; exit 1; }
service_socket_path="$(SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_terminal_service_socket_path "$SPACES_CLI")"
[[ ! -e "$service_socket_path" ]] || { echo "Service socket still present after idle stop: $service_socket_path" >&2; exit 1; }
SERVICE_PID=""

echo "Spaces daemon idle-shutdown E2E passed"
