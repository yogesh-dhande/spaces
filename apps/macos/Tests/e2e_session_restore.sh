#!/usr/bin/env bash
# Verifies session restore (issue #715) against a real daemon, for both teardowns a device derives on its
# own: a coding agent whose daemon is killed outright is captured as restorable at the next daemon start,
# and a coding agent running when the daemon is asked to shut down (what a restart, a logout, and a
# `launchctl stop` deliver) is captured by that shutdown. Answering either offer with Restore brings the
# agent back resuming its own conversation, and a restored agent restores again on the same terms with one
# resume selector rather than a stack of them.
#
# Everything runs on a throwaway profile under a temporary HOME, with `spacesd` launched directly (as in
# e2e_daemon_signal_shutdown.sh) so this script can `kill -9` the daemon it owns without touching any
# other profile's. The fixture agent is a symlink to zsh named `opencode`: the name is what the spawn
# gate and the daemon's foreground classifier match on (the classifier reads argv[0], which carries the
# symlink path), and it reports a conversation id through `spaces agent signal --agent-session`, exactly
# as a real agent's hooks do.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_BIN="$BUILD_DIR/spacesd"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

TMP_ROOT="${TMPDIR:-/tmp}/spaces-session-restore-e2e.$$"
TMP_HOME="$TMP_ROOT/home"
TMP_RUNTIME_DIR="$TMP_ROOT/runtime"
TMP_DB="$TMP_ROOT/spaces.db"
FIXTURE_DIR="$TMP_ROOT/fixture-project"
FIXTURE_COMMAND=""

PROFILE_ENV=()
SERVICE_PID=""
DAEMON_SOCKET=""
DEVICE_API_PORT=""
DEVICE_API_FINGERPRINT=""
DEVICE_API_AUTH_TOKEN=""
WORKSPACE_ID=""
CAPTURED_SESSION_ID=""
ORPHANED_CHILD_PID=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

cleanup() {
  local exit_code=$?
  # The agent's shell is a child of a daemon this script killed outright, so it can outlive both.
  if [[ -n "$ORPHANED_CHILD_PID" ]]; then kill -9 "$ORPHANED_CHILD_PID" >/dev/null 2>&1 || true; fi
  # Stop the daemon this script owns and make sure it is gone: it serves a profile whose directory is
  # about to be deleted, so a daemon that takes its time with a graceful stop is escalated rather than
  # left behind.
  if [[ -n "$SERVICE_PID" ]]; then
    kill "$SERVICE_PID" >/dev/null 2>&1 || true
    local stop_deadline=$((SECONDS + 15))
    while kill -0 "$SERVICE_PID" >/dev/null 2>&1; do
      if [[ $SECONDS -ge $stop_deadline ]]; then
        kill -9 "$SERVICE_PID" >/dev/null 2>&1 || true
        break
      fi
      sleep 0.2
    done
    wait "$SERVICE_PID" >/dev/null 2>&1 || true
  fi
  if [[ $exit_code -eq 0 ]]; then
    rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
  else
    printf 'Preserved session-restore E2E temp root: %s\n' "$TMP_ROOT" >&2
  fi
}
trap cleanup EXIT

require_binaries() {
  [[ -x "$SPACES_CLI" ]] || fail "spaces CLI not found at $SPACES_CLI"
  [[ -x "$SPACES_E2E" ]] || fail "spacese2e not found at $SPACES_E2E"
  [[ -x "$SPACESD_BIN" ]] || fail "spacesd not found at $SPACESD_BIN"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required."
}

allocate_local_port() {
  python3 <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

json_field() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]) or "")' "$1" "$2"
}

# One column of one row, read straight from the profile database. The daemon is not always running when
# these are read (that is the point of the scenario), so they go to sqlite rather than through a client.
db_query() {
  python3 - "$TMP_DB" "$1" "${@:2}" <<'PY'
import sqlite3
import sys

db_path, sql = sys.argv[1], sys.argv[2]
with sqlite3.connect(db_path) as db:
    row = db.execute(sql, tuple(sys.argv[3:])).fetchone()
print("" if row is None or row[0] is None else row[0])
PY
}

# True once the daemon this script launched is the process bound to the profile's socket. Neither the
# socket file's presence nor a successful connection to it proves that: a session's child process
# inherits the daemon's listening socket, so a killed daemon's socket keeps accepting connections for as
# long as that child lives.
daemon_owns_socket() {
  lsof -a -p "$SERVICE_PID" -U 2>/dev/null | grep -Fq "$DAEMON_SOCKET"
}

start_daemon() {
  "${PROFILE_ENV[@]}" "$SPACESD_BIN" >>"$TMP_ROOT/spacesd.log" 2>&1 &
  SERVICE_PID=$!
  # Wait for this daemon on its own socket before running any client command: a client that finds no
  # daemon for the profile starts one of its own, detached, and this script has to own the daemon's pid
  # to be able to kill it outright.
  local deadline=$((SECONDS + 30))
  while ! daemon_owns_socket; do
    if ! kill -0 "$SERVICE_PID" >/dev/null 2>&1; then
      tail -n 40 "$TMP_ROOT/spacesd.log" >&2 || true
      fail "spacesd exited before binding its socket."
    fi
    [[ $SECONDS -lt $deadline ]] || fail "timed out waiting for spacesd to bind its socket."
    sleep 0.2
  done
  while ! "${PROFILE_ENV[@]}" "$SPACES_E2E" mobile-status >"$TMP_ROOT/mobile-status.json" 2>"$TMP_ROOT/mobile-status.log"; do
    [[ $SECONDS -lt $deadline ]] || fail "timed out waiting for spacesd to answer its Device API status."
    sleep 0.2
  done
}

pair_client() {
  "${PROFILE_ENV[@]}" "$SPACES_E2E" open-device-pairing-window --timeout-seconds 10 >"$TMP_ROOT/pairing-window.json"
  DEVICE_API_FINGERPRINT="$(json_field "$(cat "$TMP_ROOT/pairing-window.json")" 'd["certificateFingerprint"]')"
  local pair_request pair_response
  pair_request="$(python3 - "$TMP_ROOT/pairing-window.json" <<'PY'
import json
import sys
import urllib.parse

window = json.load(open(sys.argv[1]))
# Pairing is wire-version gated, so the client claims the version the daemon advertised in its link.
query = urllib.parse.parse_qs(urllib.parse.urlparse(window["pairingLink"]).query)
print(json.dumps({
    "command": {
        "pair": {
            "pairingCode": window["pairingCode"],
            "pairingNonce": window["pairingNonce"],
            "clientProtocolVersion": int(query["pv"][0]),
        }
    },
    "clientApp": {
        "installationID": "SESSION-RESTORE-E2E",
        "bundleID": "dev.usespaces.spacesmobile",
        "platform": "ios",
        "deviceName": "Session Restore E2E",
        "appVersion": "1.0",
    },
}, separators=(",", ":")))
PY
)"
  pair_response="$("$SPACES_E2E" mobile-request --host 127.0.0.1 --port "$DEVICE_API_PORT" \
    --certificate-fingerprint="$DEVICE_API_FINGERPRINT" --request-json "$pair_request")"
  DEVICE_API_AUTH_TOKEN="$(json_field "$pair_response" 'd["result"]["issuedAuthToken"]["authToken"]')"
  [[ -n "$DEVICE_API_AUTH_TOKEN" ]] || fail "pairing did not issue an auth token: $pair_response"
}

# Sends one Device API command as the paired client and prints the raw JSON response.
device_request() {
  local command="$1" payload="${2:-}" request
  [[ -n "$payload" ]] || payload='{}'
  request="$(python3 - "$DEVICE_API_AUTH_TOKEN" "$command" "$payload" <<'PY'
import json
import sys

auth_token, command, payload = sys.argv[1:4]
print(json.dumps({
    "authToken": auth_token,
    "clientApp": {
        "installationID": "SESSION-RESTORE-E2E",
        "bundleID": "dev.usespaces.spacesmobile",
        "platform": "ios",
        "deviceName": "Session Restore E2E",
        "appVersion": "1.0",
    },
    "command": {command: json.loads(payload)},
}, separators=(",", ":")))
PY
)"
  "$SPACES_E2E" mobile-request --host 127.0.0.1 --port "$DEVICE_API_PORT" \
    --certificate-fingerprint="$DEVICE_API_FINGERPRINT" --request-json "$request"
}

provision_fixture() {
  mkdir -p "$FIXTURE_DIR/bin"
  local register_json
  register_json="$("${PROFILE_ENV[@]}" "$SPACES_E2E" register-project --project-dir "$FIXTURE_DIR")"
  WORKSPACE_ID="$(json_field "$register_json" 'd["id"]')"
  [[ -n "$WORKSPACE_ID" ]] || fail "could not resolve the fixture workspace id from: $register_json"

  ln -sf /bin/zsh "$FIXTURE_DIR/bin/opencode"
  cat >"$FIXTURE_DIR/agent-probe.zsh" <<PROBE
# Reports a conversation id of its own the way a real agent's hooks do (a resumed agent reports the
# conversation it is on, which is what the next capture has to offer back), turns bracketed paste on the
# way an agent TUI does when it takes the terminal over (spawn reads that as the interface being ready for
# input), then blocks so the fixture stays the terminal's foreground process for detection to identify.
"$SPACES_CLI" agent signal --agent-session "restore-e2e-\$SPACES_TERMINAL_TRACKING_ID" working >/dev/null 2>&1 || true
print -rn -- \$'\\e[?2004h'
print -r -- "restore-e2e-agent-ready"
read || true
PROBE
  # The probe is sourced from a command string rather than passed as a script argument, so that the
  # resume argument a restore appends (`-s <conversation>`) lands in the positional parameters the probe
  # ignores instead of changing how the fixture runs.
  FIXTURE_COMMAND="$FIXTURE_DIR/bin/opencode -c 'source $FIXTURE_DIR/agent-probe.zsh'"
}

# The conversation id the fixture agent in `session_id` reports, matching the probe above.
conversation_id_for_session() {
  printf 'restore-e2e-%s\n' "$1"
}

# Blocks until the daemon holds both facts a capture of the named session needs: the conversation id its
# agent reported (what a restore resumes) and the agent kind its foreground classifier identified (what
# the offer shows). Both arrive on their own schedule after the session starts.
wait_for_identified_agent() {
  local session_id="$1" expected deadline stored=""
  expected="$(conversation_id_for_session "$session_id")/opencode"
  deadline=$((SECONDS + 60))
  while [[ $SECONDS -lt $deadline ]]; do
    stored="$(db_query \
      "SELECT session_key || '/' || COALESCE(detected_agent_kind, '') FROM agent_sessions WHERE terminal_session_id = ?" "$session_id")"
    [[ "$stored" == "$expected" ]] && return 0
    sleep 0.2
  done
  fail "the agent in session $session_id was never identified (holding '$stored', expected '$expected')"
}

spawn_fixture_agent() {
  local spawn_json
  spawn_json="$("${PROFILE_ENV[@]}" "$SPACES_CLI" agent spawn --workspace "$WORKSPACE_ID" --json \
    --command "$FIXTURE_COMMAND")" || fail "spawning the fixture agent failed: $spawn_json"
  CAPTURED_SESSION_ID="$(json_field "$spawn_json" 'd.get("terminalSessionID")')"
  [[ -n "$CAPTURED_SESSION_ID" ]] || fail "spawn returned no terminal session: $spawn_json"
  ORPHANED_CHILD_PID="$(db_query "SELECT child_pid FROM terminal_runtime_states WHERE session_id = ?" "$CAPTURED_SESSION_ID")"
  wait_for_identified_agent "$CAPTURED_SESSION_ID"
}

# Stops the daemon running the named session with `signal`. The daemon that owns a session is the one
# whose exit ends it, and the session's runtime row records that daemon's pid.
stop_daemon() {
  local signal="$1" session_id="$2" daemon_pid deadline
  daemon_pid="$(db_query "SELECT service_pid FROM terminal_runtime_states WHERE session_id = ?" "$session_id")"
  [[ -n "$daemon_pid" ]] || fail "the runtime row for session $session_id names no daemon pid to stop"
  kill "$signal" "$daemon_pid"
  # Reap the stopped job right away, so the shell does not report a signalled exit as a status line in
  # the middle of the run's output.
  wait "$SERVICE_PID" >/dev/null 2>&1 || true
  deadline=$((SECONDS + 30))
  while kill -0 "$daemon_pid" >/dev/null 2>&1; do
    [[ $SECONDS -lt $deadline ]] || fail "spacesd did not exit after $signal"
    sleep 0.2
  done
  SERVICE_PID=""
}

# The restorable record this device holds, as the paired client reads it: the row for `session_id` and the
# generation the answer has to name. Fails when the session is not offered.
assert_session_is_offered() {
  local session_id="$1" expected_conversation status_response
  expected_conversation="$(conversation_id_for_session "$session_id")"
  status_response="$(device_request daemonStatus)"
  python3 - "$status_response" "$session_id" "$WORKSPACE_ID" <<'PY' || fail "daemon status did not offer session $session_id: $status_response"
import json
import sys

response, session_id, workspace_id = sys.argv[1:4]
rows = json.loads(response)["result"]["daemonStatus"]["restorableSessions"]
row = next((r for r in rows if r["sessionID"] == session_id), None)
assert row is not None, f"session {session_id} is not offered: {rows}"
assert row["workspaceID"] == workspace_id, row
assert row["hasResumeKey"] is True, row
assert row["agentKind"] == "opencode", row
assert row["generation"], row
PY
  json_field "$status_response" 'd["result"]["daemonStatus"]["restorableSessions"][0]["generation"]'
}

# Answers the outstanding offer with Restore and prints the session that replaces `session_id`, after
# checking what the replacement runs and what it records: it runs a resume command naming that session's
# conversation exactly once, and records the command the agent was originally started with, so restoring
# it again rewrites the original rather than stacking a second resume selector onto the first.
restore_offered_session() {
  local session_id="$1" generation="$2" restore_response replacement conversation wrapped recorded selectors
  restore_response="$(device_request restoreSessions "{\"generation\":\"$generation\"}")"
  [[ "$(json_field "$restore_response" 'str(d["ok"])')" == "True" ]] || fail "restore failed: $restore_response"
  replacement="$(json_field "$restore_response" \
    'd["result"]["restoredSessions"]["newSessionIDsByCapturedSessionID"]["'"$session_id"'"]')"
  [[ -n "$replacement" ]] || fail "restore returned no replacement session: $restore_response"
  [[ "$replacement" != "$session_id" ]] || fail "restore reported the captured session as its own replacement"

  conversation="$(conversation_id_for_session "$session_id")"
  wrapped="$(db_query "SELECT command FROM terminal_sessions WHERE session_id = ?" "$replacement")"
  [[ "$wrapped" == *"-s $conversation"* ]] || fail "the restored agent was not asked to resume $conversation: '$wrapped'"
  selectors="$(printf '%s' "$wrapped" | grep -o -- "-s restore-e2e-" | wc -l | tr -d ' ')"
  [[ "$selectors" == "1" ]] || fail "the restored agent carries $selectors resume selectors: '$wrapped'"
  recorded="$(db_query "SELECT launch_command FROM terminal_sessions WHERE session_id = ?" "$replacement")"
  [[ "$recorded" == "$FIXTURE_COMMAND" ]] || fail "the restored session recorded '$recorded' instead of the original command"
  printf '%s\n' "$replacement"
}

main() {
  require_binaries
  mkdir -p "$TMP_HOME" "$TMP_RUNTIME_DIR" "$FIXTURE_DIR"
  if [[ "${SPACES_E2E_SKIP_GHOSTTYKIT_SETUP:-0}" != "1" ]]; then "$SETUP_GHOSTTYKIT" >/dev/null; fi
  DEVICE_API_PORT="$(allocate_local_port)"
  # Every binary this script drives reads the throwaway profile from these values, so each one is passed
  # explicitly rather than exported: an inherited binding would let a stray invocation reach a real profile.
  PROFILE_ENV=(
    env "HOME=$TMP_HOME" "SPACES_DB_PATH=$TMP_DB" "SPACES_RUNTIME_DIR=$TMP_RUNTIME_DIR"
    "SPACESD_EXECUTABLE=$SPACESD_BIN" "SPACES_DEVICE_API_PORT=$DEVICE_API_PORT"
  )
  DAEMON_SOCKET="$("${PROFILE_ENV[@]}" "$SPACES_E2E" profile-socket-paths \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["serviceSocketPath"])')"

  start_daemon
  pair_client
  provision_fixture
  spawn_fixture_agent
  pass "spawned a coding agent that reported its conversation id"

  # The unclean exit: the daemon is killed outright and derives what it stranded at its next start.
  stop_daemon -9 "$CAPTURED_SESSION_ID"
  start_daemon
  pass "the daemon was killed outright and restarted on the same profile"

  local generation restored_session_id
  generation="$(assert_session_is_offered "$CAPTURED_SESSION_ID")"
  pass "the restarted daemon offers the stranded agent for restore"

  local stale_response
  stale_response="$(device_request restoreSessions "{\"generation\":\"not-this-record\"}")"
  [[ "$(json_field "$stale_response" 'str(d["ok"])')" == "False" ]] \
    || fail "restoring with a stale generation was accepted: $stale_response"
  pass "an answer naming a record this device no longer holds is refused"

  restored_session_id="$(restore_offered_session "$CAPTURED_SESSION_ID" "$generation")"
  pass "restore relaunched the agent resuming its own conversation"

  local remaining
  remaining="$(db_query "SELECT COUNT(*) FROM restorable_sessions")"
  [[ "$remaining" == "0" ]] || fail "the offer survived being answered ($remaining rows left)"
  pass "answering the offer clears it"

  # The graceful shutdown: the daemon is asked to stop while the restored agent is running, which is what
  # a restart, a logout, and a `launchctl stop` deliver, and it captures before it ends the session.
  wait_for_identified_agent "$restored_session_id"
  stop_daemon -TERM "$restored_session_id"
  start_daemon
  pass "the daemon shut down gracefully with a live coding agent and restarted"

  local shutdown_generation second_restored_session_id
  shutdown_generation="$(assert_session_is_offered "$restored_session_id")"
  pass "the shutdown captured the running agent for restore"

  second_restored_session_id="$(restore_offered_session "$restored_session_id" "$shutdown_generation")"
  pass "a restored agent restores again resuming its newest conversation"

  # The exec-in-place update: the daemon replaces its own image at the same pid and keeps running its
  # sessions, so it has nothing to offer back and records nothing.
  wait_for_identified_agent "$second_restored_session_id"
  "${PROFILE_ENV[@]}" "$SPACES_CLI" daemon apply-update >/dev/null
  local deadline=$((SECONDS + 30))
  while ! daemon_owns_socket; do
    [[ $SECONDS -lt $deadline ]] || fail "the daemon never rebound its socket after the exec handoff"
    sleep 0.2
  done
  [[ "$(db_query "SELECT state FROM terminal_runtime_states WHERE session_id = ?" "$second_restored_session_id")" == "running" ]] \
    || fail "the coding agent did not survive the exec handoff"
  [[ "$(db_query "SELECT COUNT(*) FROM restorable_sessions")" == "0" ]] \
    || fail "the exec handoff recorded sessions to restore, which its successor is still running"
  pass "an exec handoff hands its agents to the successor instead of offering them back"

  "${PROFILE_ENV[@]}" "$SPACES_E2E" terminate-terminal-session "$second_restored_session_id" >/dev/null 2>&1 || true
  printf 'Spaces session-restore E2E passed\n'
}

main "$@"
