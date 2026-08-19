#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"

BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_EXECUTABLE="$BUILD_DIR/spacesd"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-selection-scroll.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
export SPACES_DEVICE_API_PORT="${SPACES_DEVICE_API_PORT:-0}"
APP_LOG="$WORK_ROOT/spaces-app.log"
DUMP_PATH="$WORK_ROOT/terminal-window.json"
SESSION_TITLE="terminal-selection-scroll"
APP_PID=""
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
  stop_terminal_service_for_runtime_dir "$RUNTIME_DIR"
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
  printf '%s\n' "$output" | sed -nE 's/^Started terminal session ([0-9A-F-]{36})([[:space:]].*)?$/\1/p' | tail -n 1
}

dump_terminal_state() {
  local start
  start="$(date +%s)"
  rm -f "$DUMP_PATH"
  while (( "$(date +%s)" - start < 10 )); do
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
      dump-terminal-session-window-state --session-id "$session_id" --output-path "$DUMP_PATH" --viewer >/dev/null
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

# The pane's currently rendered text: prefer the ghostty surface's visible grid
# (visibleSurfaceOutput) and fall back to renderedOutput, matching the ended-session and
# edit-shortcut e2e scripts' way of reading terminal content out of the window state dump.
dump_visible_text() {
  python3 - "$DUMP_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
print(data.get("visibleSurfaceOutput") or data.get("renderedOutput") or "")
PY
}

wait_for_terminal_surface_ready() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    dump_terminal_state
    if [[ "$(dump_value found)" == "true" ]] && [[ "$(dump_value showsTerminalSurface)" == "true" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "Timed out waiting for the terminal pane surface to become available"
}

focus_pane() {
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal show "$session_id" >/dev/null
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    focus-terminal-session-window --session-id "$session_id" >/dev/null
}

# `send` is owner-gated (TerminalControlCommand.requiresOwnerClientID), so typing into the
# session while the app owns it must present the owner attachment's client ID. The ID is read
# from the profile database the same way e2e_mobile.sh does.
owner_client_id() {
  # Match the session root by suffix: the daemon canonicalizes the stored root_directory
  # (e.g. /private/tmp becomes /tmp), so an exact match against this script's RUNTIME_DIR
  # spelling can miss. The session UUID makes the suffix unique.
  local deadline=$((SECONDS + 30))
  local client_id=""
  while (( SECONDS < deadline )); do
    client_id="$(sqlite3 "$DB_PATH" \
      "SELECT client_id FROM terminal_attachments WHERE root_directory LIKE '%/terminal/sessions/$session_id' AND mode = 'owner' AND detached_at IS NULL ORDER BY attached_at DESC LIMIT 1")"
    if [[ -n "$client_id" ]]; then
      printf '%s\n' "$client_id"
      return 0
    fi
    sleep 0.2
  done
  fail "Timed out waiting for the session's owner attachment client ID"
}

send_line() {
  local text="$1"
  local response
  response="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    terminal-service-control --session-id "$session_id" --command send --client-id "$OWNER_CLIENT_ID" --text "$text" --append-newline)"
  [[ "$(json_field "$response" ok)" == "true" ]] || {
    printf '%s\n' "$response" >&2
    fail "send was rejected for text: $text"
  }
}

# Polls the pane dump until the visible surface contains `include` and (when given) no longer
# contains `exclude`, refreshing `last_visible_text` with the last-observed value so the caller
# can inspect it after the wait (matching how the ended-session lane keeps `last_text` around).
wait_for_visible_text() {
  local include="$1"
  local exclude="${2:-}"
  local deadline=$((SECONDS + 30))
  last_visible_text=""
  while (( SECONDS < deadline )); do
    dump_terminal_state
    last_visible_text="$(dump_visible_text)"
    if printf '%s\n' "$last_visible_text" | grep -Fq -- "$include"; then
      if [[ -z "$exclude" ]] || ! printf '%s\n' "$last_visible_text" | grep -Fq -- "$exclude"; then
        return 0
      fi
    fi
    sleep 0.2
  done
  printf '%s\n' "$last_visible_text" >&2
  if [[ -n "$exclude" ]]; then
    fail "Timed out waiting for visible surface output to contain '$include' without '$exclude'"
  fi
  fail "Timed out waiting for visible surface output to contain '$include'"
}

# The 0-based row index of the visible line whose content is exactly `selline-003` (trailing
# spaces from the grid's fixed-width padding stripped, per GhosttyTerminalSnapshotGrid.fullPlainText).
# With no scrollback yet, a fresh session's viewport starts at absolute row 0, so this visible
# index doubles as the absolute row `setSelection` expects -- guarded by comparing the visible
# line count against the dump's own surfaceRows so a taller/shorter grid fails loudly instead of
# silently picking the wrong row.
selection_target_row() {
  local text="$1"
  local surface_rows="$2"
  python3 - "$text" "$surface_rows" <<'PY'
import sys

text, surface_rows = sys.argv[1], sys.argv[2]
lines = text.split("\n")
if not surface_rows.strip():
    raise SystemExit("dump reported no surfaceRows")
surface_rows = int(surface_rows)
if len(lines) > surface_rows:
    raise SystemExit(f"visible line count {len(lines)} exceeds surfaceRows {surface_rows}; no-scrollback assumption broken")
target = next((index for index, line in enumerate(lines) if line.rstrip() == "selline-003"), None)
if target is None:
    raise SystemExit("selline-003 was not found as an exact visible line")
print(target)
PY
}

control_command() {
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    terminal-service-control --session-id "$session_id" "$@"
}

json_field() {
  local json="$1"
  local field="$2"
  python3 - "$json" "$field" <<'PY'
import json
import sys

value = json.loads(sys.argv[1]).get(sys.argv[2])
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
require_binary "$SPACESD_EXECUTABLE"
require_binary "$SPACES_E2E"
export SPACESD_EXECUTABLE

mkdir -p "$(dirname "$DB_PATH")" "$RUNTIME_DIR"
touch "$APP_LOG"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
if [[ "${SPACES_E2E_SKIP_GHOSTTYKIT_SETUP:-0}" != "1" ]]; then
  "$SETUP_GHOSTTYKIT" >/dev/null
fi
SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"

FIXTURE_PROJECT_DIR="$WORK_ROOT/terminal-fixture-project"
mkdir -p "$FIXTURE_PROJECT_DIR"
FIXTURE_WORKSPACE_JSON="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" register-project --project-dir "$FIXTURE_PROJECT_DIR")"
FIXTURE_WORKSPACE_ID="$(printf '%s' "$FIXTURE_WORKSPACE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

command_output="$(
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal create \
    --workspace "$FIXTURE_WORKSPACE_ID" --command "/bin/sh" --title "$SESSION_TITLE"
)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || fail "Failed to parse session ID from: $command_output"

focus_pane
wait_for_terminal_surface_ready
OWNER_CLIENT_ID="$(owner_client_id)"

# Step 1: type five uniquely numbered lines. The fresh grid has no scrollback yet, so every
# line lands within the visible viewport.
send_line "seq -f selline-%03g 1 5"
wait_for_visible_text "selline-005"
selline_text="$last_visible_text"

surface_rows="$(dump_value surfaceRows)"
selection_row="$(selection_target_row "$selline_text" "$surface_rows")" || {
  printf '%s\n' "$selline_text" >&2
  fail "Failed to resolve the absolute row for selline-003"
}

# Step 2: set the shared selection to span selline-003 (columns 0-10 cover its 11 characters).
set_response="$(control_command --command setSelection \
  --selection-start-column 0 --selection-start-row "$selection_row" \
  --selection-end-column 10 --selection-end-row "$selection_row")"
[[ "$(json_field "$set_response" ok)" == "true" ]] || {
  printf '%s\n' "$set_response" >&2
  fail "setSelection reported failure"
}
[[ "$(json_field "$set_response" selectionText)" == "selline-003" ]] || {
  printf '%s\n' "$set_response" >&2
  fail "setSelection returned an unexpected selectionText"
}

# Step 3: reading the selection right back must agree.
read_response="$(control_command --command readSelectionText)"
[[ "$(json_field "$read_response" ok)" == "true" ]] || {
  printf '%s\n' "$read_response" >&2
  fail "readSelectionText reported failure"
}
[[ "$(json_field "$read_response" selectionText)" == "selline-003" ]] || {
  printf '%s\n' "$read_response" >&2
  fail "readSelectionText returned an unexpected selectionText before scrolling"
}

# Step 4: push selline-003 into scrollback with 200 more lines.
send_line "seq -f fillline-%03g 1 200"
wait_for_visible_text "fillline-200" "selline-003"

# Step 5: the daemon keeps the selection anchored to its content, so it survives the scroll
# even though selline-003 is no longer on screen.
read_response="$(control_command --command readSelectionText)"
[[ "$(json_field "$read_response" ok)" == "true" ]] || {
  printf '%s\n' "$read_response" >&2
  fail "readSelectionText reported failure after scrollback growth"
}
[[ "$(json_field "$read_response" selectionText)" == "selline-003" ]] || {
  printf '%s\n' "$read_response" >&2
  fail "readSelectionText lost the selection after selline-003 scrolled into scrollback"
}

# Step 6: scroll the pane back up until selline-003 is visible again, then confirm the mirror
# paints the daemon-projected selection while it is scrolled into scrollback.
selection_revealed=0
for _ in $(seq 1 40); do
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    scroll-application-window --executable-name SpacesApp --application-pid "$APP_PID" --normalized-x 0.5 --normalized-y 0.5 --delta-y 120 --repetitions 8 >/dev/null
  dump_terminal_state
  scrolled_text="$(dump_visible_text)"
  [[ -n "$scrolled_text" ]] || continue
  if printf '%s\n' "$scrolled_text" | grep -Fq -- "selline-003"; then
    selection_revealed=1
    break
  fi
done
(( selection_revealed == 1 )) || {
  printf '%s\n' "${scrolled_text:-}" >&2
  fail "Scrolling never revealed selline-003 in scrollback"
}
[[ "$(dump_value surfaceSelectionText)" == "selline-003" ]] || {
  printf '%s\n' "$(cat "$DUMP_PATH")" >&2
  fail "Mirror surface did not paint the shared selection while scrolled into scrollback"
}

# Step 7: a plain click clears the shared selection because part of it is visible in this viewer.
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
  click-application-window --executable-name SpacesApp --application-pid "$APP_PID" --normalized-x 0.5 --normalized-y 0.5 >/dev/null

selection_cleared=0
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  read_response="$(control_command --command readSelectionText)"
  if [[ "$(json_field "$read_response" ok)" == "true" ]] && [[ -z "$(json_field "$read_response" selectionText)" ]]; then
    selection_cleared=1
    break
  fi
  sleep 0.2
done
(( selection_cleared == 1 )) || {
  printf '%s\n' "$read_response" >&2
  fail "readSelectionText never reported the selection cleared after the click"
}

dump_cleared=0
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  dump_terminal_state
  if [[ -z "$(dump_value surfaceSelectionText)" ]]; then
    dump_cleared=1
    break
  fi
  sleep 0.2
done
(( dump_cleared == 1 )) || {
  printf '%s\n' "$(cat "$DUMP_PATH")" >&2
  fail "Pane dump still reported a painted selection after the click cleared it"
}

echo "Spaces macOS shared-selection scrollback E2E passed for session $session_id"
