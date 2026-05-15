#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-cli.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
APP_LOG="$WORK_ROOT/spaces-app.log"
APP_PID=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_log_pattern() {
  local pattern="$1"
  local timeout="${2:-20}"
  local start
  start="$(date +%s)"
  while true; do
    if grep -Eq "$pattern" "$APP_LOG"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for log pattern: $pattern" >&2
      return 1
    fi
    sleep 0.2
  done
}

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

active_attachment_client_id() {
  local session_id="$1"
  local mode="$2"
  local attachments_path
  attachments_path="$(dirname "$DB_PATH")/terminal/sessions/$session_id/attachments.json"
  python3 - "$attachments_path" "$mode" <<'PY'
import json, sys
path = sys.argv[1]
mode = sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    attachments = json.load(handle)
for attachment in attachments:
    if attachment.get("mode") == mode and attachment.get("detachedAt") is None:
        print(attachment["clientID"])
        break
else:
    raise SystemExit(f"no active {mode} attachment found")
PY
}

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT" >/dev/null

pkill -x SpacesApp >/dev/null 2>&1 || true
pkill -f "$SPACES_APP" >/dev/null 2>&1 || true

env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

command_payload="stty raw -echo; python3 -c 'import os,sys,time; data=os.read(0,64); print(repr(data)); sys.stdout.flush(); time.sleep(2)'"
command_output="$(env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal command --backend ghostty-embedded --command "$command_payload" --title cli-e2e)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse session ID from: $command_output" >&2; exit 1; }

wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=owner"

env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal send "$session_id" "abc" >/dev/null
wait_for_log_pattern "spaces: perf metric=terminal_control_send .*target=session=${session_id} .*success=1"

env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal key "$session_id" up >/dev/null
env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal key "$session_id" enter >/dev/null

tail_output="$(env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal tail "$session_id" --lines 20)"
printf '%s\n' "$tail_output" | grep -Fq "b'abc\\x1b[A\\r'"

env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal show "$session_id" --viewer >/dev/null
wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=viewer"

viewer_client_id="$(active_attachment_client_id "$session_id" viewer)"
owner_client_id="$(active_attachment_client_id "$session_id" owner)"

env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal takeover "$session_id" "$viewer_client_id" >/dev/null
wait_for_log_pattern "spaces: perf metric=terminal_control_takeover .*target=session=${session_id} client=${viewer_client_id} .*success=1"

env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal takeover "$session_id" "$owner_client_id" >/dev/null
wait_for_log_pattern "spaces: perf metric=terminal_control_takeover .*target=session=${session_id} client=${owner_client_id} .*success=1"

echo "Ghostty terminal CLI E2E passed for session $session_id"
