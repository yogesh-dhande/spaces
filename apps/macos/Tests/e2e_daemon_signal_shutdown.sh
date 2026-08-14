#!/usr/bin/env bash
# Verifies that a plain SIGTERM to spacesd (what launchd, `kill`, and every other supervisor use to
# stop a process) runs the SAME graceful teardown as the control-socket `.shutdown` command and
# AppKit's `applicationWillTerminate`: per-core transcript flush, attachment finalization, and the
# durable runtime-state write that marks a session `exited` rather than leaving it stuck at
# `running` (see `SpacesDaemonController.shutdown()` / `shutdownOnce()` in
# `apps/macos/Sources/spacesd/SpacesdMain.swift`).
#
# spacesd is launched directly here (background job, stderr redirected to a log file) exactly as
# in e2e_daemon_exec_handoff.sh, both so we can send it a raw signal ourselves (rather than through
# a client's autolaunch/supervision path) and so we can assert on its stderr log line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_EXECUTABLE="$BUILD_DIR/spacesd"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d /tmp/spsig.XXXXXX)}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/rt}"
export SPACES_DEVICE_API_PORT="${SPACES_DEVICE_API_PORT:-0}"
DAEMON_LOG="$WORK_ROOT/spacesd.log"
SERVICE_PID=""
session_id=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$session_id" ]] && [[ -x "$SPACES_E2E" ]]; then
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" terminate-terminal-session "$session_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SERVICE_PID" ]]; then
    # A directly-launched spacesd is not under launchd/systemd supervision, so this harness owns
    # stopping it. Route through the graceful `.shutdown` socket command (falling back to
    # SIGTERM/SIGKILL by pid if the socket is unresponsive) rather than a raw `kill`, since that is
    # the supported stop and it reports/waits properly -- SIGTERM is what THIS script is testing,
    # not how it should clean up after itself.
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

# Generalized runtime-state column reader (service_pid, child_pid, state), keyed by the session's
# root directory the way `terminal_runtime_states` is.
runtime_state_column() {
  local session_id="$1"
  local column="$2"
  python3 - "$DB_PATH" "$RUNTIME_DIR/terminal/sessions/$session_id" "$column" <<'PY'
import os
import sqlite3
import sys

db_path = sys.argv[1]
root_directory = os.path.normpath(sys.argv[2])
column = sys.argv[3]
assert column in ("service_pid", "child_pid", "state")
with sqlite3.connect(db_path) as db:
    row = db.execute(
        f"SELECT {column} FROM terminal_runtime_states WHERE root_directory = ?",
        (root_directory,),
    ).fetchone()
if row and row[0] is not None:
    print(row[0])
else:
    raise SystemExit(f"missing {column} in terminal runtime state")
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

# Polls the runtime state row rather than reading it once: `command --command` returns as soon as
# the session is registered, which can race the daemon's own transition from `starting` to
# `running`. Signalling before that transition lands would make the discriminating assertion below
# meaningless (a `starting` row finalizing to `exited` proves nothing about the graceful-shutdown
# code path this script targets).
wait_for_runtime_state() {
  local session_id="$1"
  local expected="$2"
  local timeout="${3:-20}"
  local start
  local observed=""
  start="$(date +%s)"
  while true; do
    observed="$(runtime_state_column "$session_id" state 2>/dev/null || true)"
    [[ "$observed" == "$expected" ]] && return 0
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for session $session_id runtime state to reach '$expected' (last observed: '$observed')" >&2
      return 1
    fi
    sleep 0.2
  done
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

# Pure path computation (no daemon required) so we can poll for the socket file without ever
# calling `spaces`, which would autolaunch a daemon of its own before we get to launch ours.
DAEMON_SOCKET="$(terminal_service_socket_path_for_runtime_dir "$RUNTIME_DIR")"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACESD_EXECUTABLE" >"$DAEMON_LOG" 2>&1 </dev/null &
SERVICE_PID=$!

wait_for_daemon_socket 15
wait_for_terminal_list_success 15

# terminal create is workspace-scoped; register a fixture project and use its default workspace.
# register-project talks to the DB directly through spacese2e's in-process orchestrator, so it does
# not start or touch spacesd.
FIXTURE_PROJECT_DIR="$WORK_ROOT/terminal-fixture-project"
mkdir -p "$FIXTURE_PROJECT_DIR"
FIXTURE_WORKSPACE_JSON="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" register-project --project-dir "$FIXTURE_PROJECT_DIR")"
FIXTURE_WORKSPACE_ID="$(printf '%s' "$FIXTURE_WORKSPACE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

# A long-lived session so there is something for the graceful shutdown to flush and finalize:
# `terminate()` (invoked from `shutdown()`) enqueues an exited-runtime-state write per core, and
# that write landing (rather than the row staying `running`) is what this script discriminates on.
command_payload="python3 -c 'import time; print(\"__signal_shutdown_ready__\", flush=True); time.sleep(120)'"
command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal create --workspace "$FIXTURE_WORKSPACE_ID" --command "$command_payload" --title signal-shutdown-e2e)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse session ID from: $command_output" >&2; exit 1; }
wait_for_tail_contains "$session_id" "__signal_shutdown_ready__" 20

# Do not race the daemon: signal only once its own runtime-state row confirms the session reached
# `running`, so a post-signal `exited` row can only be explained by the graceful teardown path.
wait_for_runtime_state "$session_id" "running" 20

kill -TERM "$SERVICE_PID"

wait_for_log_contains "received SIGTERM; shutting down" 20

daemon_exit_deadline=$(( $(date +%s) + 20 ))
while kill -0 "$SERVICE_PID" >/dev/null 2>&1; do
  if (( $(date +%s) >= daemon_exit_deadline )); then
    echo "spacesd (pid $SERVICE_PID) did not exit within 20s of SIGTERM; see $DAEMON_LOG" >&2
    tail -n 40 "$DAEMON_LOG" >&2 || true
    exit 1
  fi
  sleep 0.2
done
SERVICE_PID=""

# The daemon is confirmed gone, so there is no live spacesd left to send a terminate command to --
# `terminate-terminal-session`'s `TerminalService.ensureRunning()` would autolaunch a fresh one for
# no reason (it is not tracking $SERVICE_PID and has nothing to reap it), leaking a daemon the rest
# of this script never stops. Clear session_id before `cleanup` runs so its terminate-then-stop
# sequence, which assumes a live daemon per e2e_daemon_exec_handoff.sh's ordering, is skipped;
# `terminal_runtime_states` is read directly below via sqlite3, not through the daemon.
terminated_session_id="$session_id"
session_id=""

# The discriminating assertion: graceful shutdown drains each core's persistence queue
# (`drainPersistenceForShutdown()`) before the process exits, which is what commits the durable
# exited-state write. Without a signal handler running that path, the row stays `running` forever
# -- exactly the residue issue #390 names.
final_state="$(runtime_state_column "$terminated_session_id" state)"
[[ "$final_state" == "exited" ]] || {
  echo "Session $terminated_session_id runtime state is '$final_state' (expected 'exited') after SIGTERM shutdown; a still-'running' row means the graceful teardown never ran. Daemon log:" >&2
  tail -n 40 "$DAEMON_LOG" >&2 || true
  exit 1
}

echo "Spaces daemon signal-shutdown E2E passed"
