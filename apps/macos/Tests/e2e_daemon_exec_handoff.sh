#!/usr/bin/env bash
# Verifies the daemon's exec-in-place update handoff: spacesd quiesces its sessions, execs a
# newly staged binary at the same pid, and resumes those sessions -- so a "daemon update" never
# kills a running shell, coding agent, or workspace process.
#
# Two on-disk copies of the SAME built spacesd sit behind a `bin/spacesd` symlink. Flipping the
# symlink and poking the daemon (`spaces daemon apply-update`) is the same version-injection
# mechanism the real installer uses (SpacesdMain resolves its exec target from raw, unresolved
# argv[0], so an autolaunched/dev daemon always re-execs whatever path launched it -- see
# `apps/macos/Sources/spacesd/SpacesdMain.swift` `absoluteLaunchExecutablePath()`). Both copies
# report the same AppVersion.current, so this script's two consecutive same-version handoffs stay
# well clear of the generation guard, which only refuses a 4th consecutive same-version handoff.
#
# spacesd is launched directly here (background job, stderr redirected to a log file) rather than
# relying on the client's autolaunch: TerminalService's autolaunch (see `resolveExecutableURL` /
# `ensureRunning` in apps/macos/Sources/spacesterminalcore/TerminalService.swift) pipes the
# daemon's stderr to /dev/null, which would swallow the `handoff_exec`/`handoff_resume` log lines
# this script asserts on.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_BUILT="$BUILD_DIR/spacesd"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d /tmp/spexec.XXXXXX)}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/rt}"
export SPACES_DEVICE_API_PORT="${SPACES_DEVICE_API_PORT:-0}"
BIN_ROOT="$WORK_ROOT/bin"
DAEMON_LOG="$WORK_ROOT/spacesd.log"
SPACESD_SYMLINK="$BIN_ROOT/spacesd"
MARKER="__exec_handoff_marker__"
SERVICE_PID=""
CHILD_PID=""
session_id=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$session_id" ]] && [[ -x "$SPACES_E2E" ]]; then
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" terminate-terminal-session "$session_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SERVICE_PID" ]]; then
    # A directly-launched spacesd is not under launchd/systemd supervision, so this harness owns
    # stopping it. Route through the same graceful `.shutdown` socket command
    # terminal_harness_lock.sh's other callers use (falling back to SIGTERM/SIGKILL by pid if the
    # socket is unresponsive) rather than a raw `kill`: a plain SIGTERM to spacesd on macOS does not
    # run its NSApplication termination delegate, so shared child services it started (e.g. the
    # Caddy router) would otherwise leak as orphans.
    stop_terminal_service_for_runtime_dir "$RUNTIME_DIR" >/dev/null 2>&1 || true
    wait "$SERVICE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_ROOT"
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

assert_no_failed_runtime_states() {
  python3 - "$DB_PATH" <<'PY'
import sqlite3
import sys

db_path = sys.argv[1]
with sqlite3.connect(db_path) as db:
    rows = db.execute("SELECT session_id, root_directory FROM terminal_runtime_states WHERE state = 'failed'").fetchall()
if rows:
    raise SystemExit(f"found failed runtime state rows after handoff: {rows}")
PY
}

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

wait_for_daemon_socket() {
  local timeout="${1:-15}"
  local start
  start="$(date +%s)"
  while [[ ! -S "$DAEMON_SOCKET" ]]; do
    if ! kill -0 "$SERVICE_PID" >/dev/null 2>&1; then
      echo "spacesd (pid $SERVICE_PID) exited before creating its socket; see $DAEMON_LOG" >&2
      cat "$DAEMON_LOG" >&2 || true
      return 1
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for daemon socket at $DAEMON_SOCKET" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_terminal_list_success() {
  local timeout="${1:-20}"
  local start
  start="$(date +%s)"
  while ! env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal list >/dev/null 2>&1; do
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for spacesd to answer terminal list" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_log_contains() {
  local needle="$1"
  local timeout="${2:-20}"
  local start
  start="$(date +%s)"
  while ! grep -Fq "$needle" "$DAEMON_LOG" 2>/dev/null; do
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for daemon log ($DAEMON_LOG) to contain: $needle" >&2
      tail -n 40 "$DAEMON_LOG" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

wait_for_session_in_list() {
  local needle_session_id="$1"
  local timeout="${2:-20}"
  local start
  start="$(date +%s)"
  while true; do
    if env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal list | grep -Fq "$needle_session_id"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for session $needle_session_id to appear in terminal list" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_tail_contains() {
  local needle_session_id="$1"
  local needle="$2"
  local timeout="${3:-20}"
  local start
  local output=""
  start="$(date +%s)"
  while true; do
    output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal tail "$needle_session_id" --lines 200)"
    if printf '%s\n' "$output" | grep -Fq "$needle"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for tail of $needle_session_id to contain: $needle" >&2
      printf '%s\n' "$output" >&2
      return 1
    fi
    sleep 0.2
  done
}

# Flips the `bin/spacesd` symlink to the given on-disk copy, pokes the running daemon, and asserts
# the full set of "nothing was disturbed" invariants: the daemon answers again, its pid did not
# change (exec, not a supervisor respawn), the session's child survived with its pid unchanged, the
# expected handoff_resume generation was logged, the session and its pre-handoff scrollback marker
# are both still present, no runtime state landed `.failed`, and a freshly sent command still
# round-trips live through the adopted PTY.
run_handoff_round() {
  local target_binary="$1"
  local expected_generation="$2"
  local post_marker="$3"

  ln -sfn "$target_binary" "$SPACESD_SYMLINK"
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" daemon apply-update

  wait_for_terminal_list_success 20
  wait_for_log_contains "handoff_resume generation=$expected_generation" 20

  local resumed_service_pid
  resumed_service_pid="$(runtime_state_pid "$session_id" service_pid)"
  [[ "$resumed_service_pid" == "$SERVICE_PID" ]] || {
    echo "service_pid changed across the handoff (was $SERVICE_PID, now $resumed_service_pid); exec must keep the same pid" >&2
    exit 1
  }

  kill -0 "$CHILD_PID" >/dev/null 2>&1 || { echo "session child (pid $CHILD_PID) died across the handoff" >&2; exit 1; }
  local resumed_child_pid
  resumed_child_pid="$(runtime_state_pid "$session_id" child_pid)"
  [[ "$resumed_child_pid" == "$CHILD_PID" ]] || {
    echo "child_pid changed across the handoff (was $CHILD_PID, now $resumed_child_pid)" >&2
    exit 1
  }

  wait_for_session_in_list "$session_id" 20
  wait_for_tail_contains "$session_id" "$MARKER" 20
  assert_no_failed_runtime_states

  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal send text "$session_id" "$post_marker" --newline >/dev/null
  wait_for_tail_contains "$session_id" "$post_marker" 20

  echo "Handoff round OK: generation=$expected_generation pid=$SERVICE_PID child=$CHILD_PID"
}

mkdir -p "$(dirname "$DB_PATH")" "$BIN_ROOT"

echo "==> Building spacesd, spaces, spacese2e"
"$REPO_ROOT/scripts/swiftpm.sh" build --product spacesd
"$REPO_ROOT/scripts/swiftpm.sh" build --product spaces
"$REPO_ROOT/scripts/swiftpm.sh" build --product spacese2e

require_binary "$SPACES_CLI"
require_binary "$SPACES_E2E"
require_binary "$SPACESD_BUILT"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
if [[ "${SPACES_E2E_SKIP_GHOSTTYKIT_SETUP:-0}" != "1" ]]; then
  "$SETUP_GHOSTTYKIT" >/dev/null
fi

# Two copies of the SAME build stand in for "old" and "new" staged binaries. `bin/spacesd` is the
# stable symlink whose target flips between them -- SpacesdMain re-execs raw argv[0], so launching
# the daemon through this symlink (not a resolved path) is what makes the flip take effect.
cp "$SPACESD_BUILT" "$BIN_ROOT/spacesd-a"
cp "$SPACESD_BUILT" "$BIN_ROOT/spacesd-b"
chmod +x "$BIN_ROOT/spacesd-a" "$BIN_ROOT/spacesd-b"
ln -sfn spacesd-a "$SPACESD_SYMLINK"
export SPACESD_EXECUTABLE="$SPACESD_SYMLINK"

# Pure path computation (no daemon required) so we can poll for the socket file without ever
# calling `spaces`, which would autolaunch a daemon of its own before we get to launch ours.
DAEMON_SOCKET="$(terminal_service_socket_path_for_runtime_dir "$RUNTIME_DIR")"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACESD_SYMLINK" >"$DAEMON_LOG" 2>&1 </dev/null &
SERVICE_PID=$!

wait_for_daemon_socket 15
wait_for_terminal_list_success 15

# terminal command is workspace-scoped; register a fixture project and use its default workspace.
# register-project talks to the DB directly through spacese2e's in-process orchestrator, so it does
# not start or touch spacesd.
FIXTURE_PROJECT_DIR="$WORK_ROOT/terminal-fixture-project"
mkdir -p "$FIXTURE_PROJECT_DIR"
FIXTURE_WORKSPACE_JSON="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" register-project --project-dir "$FIXTURE_PROJECT_DIR")"
FIXTURE_WORKSPACE_ID="$(printf '%s' "$FIXTURE_WORKSPACE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

# A long-lived shell loop: prints the pre-handoff marker once, then keeps producing output so live
# I/O through the PTY can be observed both before and after each handoff.
command_payload='printf "%s\n" "'"$MARKER"'"; i=0; while true; do i=$((i+1)); printf "tick %s\n" "$i"; sleep 1; done'
command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command --workspace "$FIXTURE_WORKSPACE_ID" --command "$command_payload" --title exec-handoff-e2e)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse session ID from: $command_output" >&2; exit 1; }

resumed_service_pid="$(runtime_state_pid "$session_id" service_pid)"
[[ "$resumed_service_pid" == "$SERVICE_PID" ]] || {
  echo "session's recorded service_pid ($resumed_service_pid) does not match the directly-launched daemon pid ($SERVICE_PID)" >&2
  exit 1
}
CHILD_PID="$(runtime_state_pid "$session_id" child_pid)"
wait_for_tail_contains "$session_id" "$MARKER" 20

# First handoff: flip to the "new" copy. Same-version handoffs are allowed through generation 2.
run_handoff_round spacesd-b 1 "__exec_handoff_post_marker_gen1__"

# Second handoff: flip back to the original copy. The generation guard only refuses a same-version
# handoff once `handoffGeneration` has already reached 3 (see `refusesExecByGenerationGuard` in
# apps/macos/Sources/spacesterminalcore/DaemonHandoff.swift) -- i.e. a 4th consecutive same-version
# handoff, not this 2nd one -- so a refusal check is intentionally not exercised here.
run_handoff_round spacesd-a 2 "__exec_handoff_post_marker_gen2__"

echo "Spaces daemon exec-in-place handoff E2E passed"
