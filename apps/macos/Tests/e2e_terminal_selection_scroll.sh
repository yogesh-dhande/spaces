#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"
source "$SCRIPT_DIR/e2e_ui_automation.sh"

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
    # A fresh profile launch can offer the coding-agents setup step; skip it or the window never becomes key.
    drive_coding_agents_setup_step_if_offered
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
# session while the app owns it must present the owner attachment's client ID.
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

# Refreshes `last_visible_text` with the last-observed value so the caller can inspect it
# after the wait.
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

# Waits for the pane's own selection (this client's, painted onto the mirror surface) to contain
# `needle`. Selection is per client and never reaches the daemon, so the pane dump is the only place
# it can be observed.
wait_for_surface_selection_contains() {
  local needle="$1"
  local deadline=$((SECONDS + 30))
  local selection=""
  while (( SECONDS < deadline )); do
    dump_terminal_state
    selection="$(dump_value surfaceSelectionText)"
    if printf '%s\n' "$selection" | grep -Fq -- "$needle"; then
      return 0
    fi
    sleep 0.2
  done
  printf '%s\n' "$selection" >&2
  fail "Timed out waiting for the pane's selection to contain '$needle'"
}

wait_for_surface_selection_empty() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    dump_terminal_state
    [[ -z "$(dump_value surfaceSelectionText)" ]] && return 0
    sleep 0.2
  done
  printf '%s\n' "$(cat "$DUMP_PATH")" >&2
  fail "Timed out waiting for the pane's selection to clear"
}

# Same polling shape as e2e_terminal_edit_shortcuts.sh.
wait_for_pbpaste_contains() {
  local needle="$1"
  local deadline=$((SECONDS + 10))
  local output=""
  while (( SECONDS < deadline )); do
    output="$(pbpaste)"
    if printf '%s\n' "$output" | grep -Fq -- "$needle"; then
      return 0
    fi
    sleep 0.1
  done
  printf '%s\n' "$output" >&2
  fail "Timed out waiting for pasteboard to contain: $needle"
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
SPACES_PID="$APP_PID"
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

# Step 1: the fresh grid has no scrollback yet, so every line lands within the visible viewport.
send_line "seq -f selline-%03g 1 5"
wait_for_visible_text "selline-005"

# Step 2: drag-select with the mouse. The drag starts low inside the surface and ends above the top of
# the content; Ghostty clamps a drag that leaves the surface to row 0, and with no scrollback yet that
# selects every row, selline-003 included. The selection belongs to this client alone: it is held in
# absolute rows and painted onto the pane, and the daemon is never told about it.
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
  drag-application-window --executable-name SpacesApp --application-pid "$APP_PID" \
  --start-normalized-x 0.9 --start-normalized-y 0.9 --end-normalized-x 0.1 --end-normalized-y 0.0 >/dev/null
wait_for_surface_selection_contains "selline-003"

# Step 3: output that scrolls selline-003 out of the viewport must not disturb the selection, and the
# pane's copy still reaches it.
send_line "seq -f fillline-%03g 1 200"
wait_for_visible_text "fillline-200" "selline-003"

# Copy while the selected row is off screen: the pane copies its own selection from its transcript, so
# the pasteboard receives selline-003 even though the viewport no longer shows it. The sentinel proves
# the pasteboard was written by this copy.
printf 'sentinel-%s\n' "$$" | pbcopy
focus_pane
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
  terminal-window-shortcut --session-id "$session_id" --action copy >/dev/null
wait_for_pbpaste_contains "selline-003"

# Step 4: scroll the pane back up until selline-003 is visible again. A plain shell session always
# routes a wheel gesture to this pane's own local replay of the transcript (only a full-screen or
# mouse-tracking program routes to the session's own viewport instead, see
# `RemoteGhosttySessionHost.scrollRoute`), and the pane paints its own selection onto that replay
# like any other frame, so the highlight is back on selline-003 once its row is on screen.
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
# Confirm the pane is actually in the mode this step means to exercise, so the checks below are not
# passing vacuously against the live frame.
[[ "$(dump_value isShowingLocalScrollbackFrame)" == "true" ]] || {
  printf '%s\n' "$(cat "$DUMP_PATH")" >&2
  fail "The pane must be showing its local replay once selline-003 is scrolled back into view"
}
wait_for_surface_selection_contains "selline-003"

# Step 5: a plain click on the replay clears the pane's own selection, and only the pane's: no
# selection request exists for it to send, so no other viewer's screen changes.
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
  click-application-window --executable-name SpacesApp --application-pid "$APP_PID" --normalized-x 0.5 --normalized-y 0.5 >/dev/null
wait_for_surface_selection_empty

echo "Spaces macOS per-client selection scrollback E2E passed for session $session_id"
