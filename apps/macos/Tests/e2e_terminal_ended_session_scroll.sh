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

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-ended-scroll.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
export SPACES_DEVICE_API_PORT="${SPACES_DEVICE_API_PORT:-0}"
APP_LOG="$WORK_ROOT/spaces-app.log"
DUMP_PATH="$WORK_ROOT/terminal-window.json"
SESSION_TITLE="terminal-ended-session-scroll"
# The ended pane prints 300 uniquely numbered lines and then exits on its own so the
# session ends (banner appears, pane persists). The last screenful shows endedline-300;
# endedline-001 lives only in the persisted transcript until a scroll replays it.
SESSION_COMMAND="seq -f endedline-%03g 1 300"
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
  # The scroll's endpoint recovery relaunches spacesd on a fresh port, and SERVICE_PID still names
  # the daemon the scenario stopped, so stop whichever daemon serves the profile now that the
  # session is terminated and the app is gone -- unconditionally, not only when idle, since a
  # failure path can leave the daemon still hosting the session.
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

terminal_service_pid() {
  local target_session_id="$1"
  python3 - "$DB_PATH" "$RUNTIME_DIR/terminal/sessions/$target_session_id" <<'PY'
import os
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    row = db.execute(
        "SELECT service_pid FROM terminal_runtime_states WHERE root_directory = ?",
        (os.path.normpath(sys.argv[2]),),
    ).fetchone()
if not row:
    raise SystemExit("missing terminal runtime state")
print(row[0])
PY
}

# Runtime state of the session as recorded by spacesd. Reading the persisted
# terminal_runtime_states row is the same detection e2e_mobile.sh uses to observe a
# session reaching `exited`; the terminal service may shut down once its child exits,
# so the DB row is the durable signal.
terminal_runtime_state() {
  python3 - "$DB_PATH" "$session_id" <<'PY'
import sqlite3
import sys

db_path, target_session_id = sys.argv[1], sys.argv[2]
with sqlite3.connect(db_path) as db:
    row = db.execute(
        "SELECT state FROM terminal_runtime_states WHERE session_id = ?",
        (target_session_id,),
    ).fetchone()
print(row[0] if row else "")
PY
}

wait_for_session_exited() {
  local deadline=$((SECONDS + 30))
  local state=""
  while (( SECONDS < deadline )); do
    state="$(terminal_runtime_state)"
    if [[ "$state" == "exited" ]]; then
      return 0
    fi
    sleep 0.2
  done
  fail "Timed out waiting for terminal session to exit (last state: '${state:-<none>}')"
}

# Confirmation that the hosting daemon really left after the explicit idle-only stop below: spacesd is
# the profile's resident Device API server and never exits on its own when the last session ends, so the
# stop is what produces the dead-endpoint condition. Poll the session's recorded service_pid until it is
# gone before continuing, so the scroll below runs against a genuinely dead endpoint.
wait_for_daemon_exited() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$SERVICE_PID" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  fail "Timed out waiting for the hosting daemon (pid $SERVICE_PID) to idle-shut-down after the session ended"
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
# (visibleSurfaceOutput) and fall back to renderedOutput, matching how the mobile and
# edit-shortcut e2e scripts read terminal content out of the window state dump.
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
  fail "Timed out waiting for the ended terminal pane surface to become available"
}

focus_ended_pane() {
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal show "$session_id" >/dev/null
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    focus-terminal-session-window --session-id "$session_id" >/dev/null
}

# Reports whether the rendered pane text still shows a given endedline token. Numbers are
# parsed tolerant of zero padding so the check is robust regardless of seq's formatting.
visible_text_contains_line() {
  local text="$1"
  local number="$2"
  printf '%s\n' "$text" | grep -Eq "endedline-0*${number}([^0-9]|$)"
}

# Smallest endedline-NNN number currently visible in the rendered pane text, or empty when
# none is present. The text is passed as an argv argument (mirroring dump_value/dump_visible_text),
# not piped to stdin: a `cmd | python3 - <<'PY'` heredoc overrides the pipe for python's stdin, so
# piped text never reaches the script — reading it from sys.stdin would always come back empty.
min_visible_line() {
  python3 - "$1" <<'PY'
import re
import sys

numbers = [int(match) for match in re.findall(r"endedline-0*([0-9]+)", sys.argv[1])]
print(min(numbers) if numbers else "")
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
    --workspace "$FIXTURE_WORKSPACE_ID" --command "$SESSION_COMMAND" --title "$SESSION_TITLE"
)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || fail "Failed to parse session ID from: $command_output"
SERVICE_PID="$(terminal_service_pid "$session_id")"

# The command exits on its own; wait until spacesd records the session as exited so the
# pane is showing its final render behind the "Session ended" banner.
wait_for_session_exited

# The run deliberately takes the daemon down under the open ended pane. spacesd is the profile's
# resident Device API server and stays up with zero sessions, so the test stops it explicitly with the
# same idle-only stop the dev relaunch uses; the ended session's core is already out of the daemon, so
# the daemon reports itself idle and exits. Killing it here is what makes the scroll below exercise the
# transcript path's own endpoint recovery — the app's model is left pointing at the dead Device API
# port, and only the fetch-side recovery can reach the daemon that `spaces terminal show` restarts on a
# fresh ephemeral port. How the daemon went down does not affect the recovery under test.
SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_terminal_service_if_idle "$SPACES_CLI"
wait_for_daemon_exited

focus_ended_pane
wait_for_terminal_surface_ready

# Baseline: the ended pane's final render shows the tail of the output (endedline-300) and
# not the very first line, confirming the persisted final frame is on screen before any scroll.
baseline_text="$(dump_visible_text)"
[[ -n "$baseline_text" ]] || fail "Ended pane rendered no text before scrolling"
visible_text_contains_line "$baseline_text" 300 || {
  printf '%s\n' "$baseline_text" >&2
  fail "Ended pane did not show the final line endedline-300 before scrolling"
}
if visible_text_contains_line "$baseline_text" 1; then
  printf '%s\n' "$baseline_text" >&2
  fail "Ended pane unexpectedly showed endedline-001 before scrolling into scrollback"
fi

# Scroll up into the ended session's scrollback. A positive vertical wheel delta scrolls up:
# scroll-application-window posts a precise/continuous CGEvent whose positive wheel1 becomes a
# positive scrollingDeltaY, which the ended-session scroll normalizer maps to a negative row
# delta (older lines) and replays from the persisted transcript. Poll after each burst until an
# early line (< 100) is revealed and the final line has scrolled out of view.
early_line_reached=0
last_text=""
for _ in $(seq 1 40); do
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
    scroll-application-window --executable-name SpacesApp --normalized-x 0.5 --normalized-y 0.5 --delta-y 120 --repetitions 8 >/dev/null
  dump_terminal_state
  last_text="$(dump_visible_text)"
  [[ -n "$last_text" ]] || continue
  min_line="$(min_visible_line "$last_text")"
  if [[ -n "$min_line" ]] && (( min_line < 100 )) && ! visible_text_contains_line "$last_text" 300; then
    early_line_reached=1
    break
  fi
done

if (( early_line_reached != 1 )); then
  printf '%s\n' "$last_text" >&2
  fail "Scrolling the ended session never revealed an early scrollback line (< 100) with the final line hidden"
fi

echo "Spaces macOS ended-session scrollback scroll E2E passed for session $session_id"
