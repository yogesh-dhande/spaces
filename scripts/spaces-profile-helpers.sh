#!/usr/bin/env bash

spaces_profile_e2e_cli() {
  local cli="$1"
  if [[ -n "${SPACES_E2E_CLI:-}" ]]; then
    printf '%s\n' "$SPACES_E2E_CLI"
    return 0
  fi
  if [[ -n "${SPACES_E2E:-}" ]]; then
    printf '%s\n' "$SPACES_E2E"
    return 0
  fi
  local cli_dir
  cli_dir="$(cd "$(dirname "$cli")" && pwd)"
  printf '%s\n' "$cli_dir/spacese2e"
}

# Clears an inherited SPACES_DB_PATH / SPACES_RUNTIME_DIR from the CALLING shell. Every entry point below
# calls this before it resolves or touches a profile.
#
# A profile's identity is where its binary sits, so an inherited binding at an entry point is never what the
# caller wants -- it is left over from a shell someone bound earlier, and it is actively harmful in both
# directions. Pointing inside ~/.spaces or ~/.spaces-dev/profiles, profile resolution refuses it and the
# script aborts (under `set -e`, before any work). Pointing at some unrelated throwaway root, it silently
# retargets the whole run at a profile nobody asked for.
#
# Clearing outright is the single intended path: there is deliberately no attempt to interpret, validate, or
# re-target the inherited value. A run that genuinely wants a throwaway profile sets one AFTER this, which is
# what SPACES_DEV_DB_PATH and the mobile demo's isolated mode do.
spaces_profile_clear_inherited_binding() {
  unset SPACES_DB_PATH SPACES_RUNTIME_DIR
}

# Reads one value out of a JSON object piped in on stdin, `payload` in scope for the Python
# expression in `$1` (e.g. `payload.get("field")` or a nested lookup). A falsy value (missing,
# empty, zero, None) is treated as absent: with `$2` given, that raises it as the failure message
# (matching a script under `set -e`); without it, the function just prints nothing and exits 0,
# for a caller that only wants a value when one exists (`spaces_profile_app_owner_pid`).
#
# This is the one shared body behind every field/expression readout below; each caller supplies
# the JSON source and the expression, not another copy of the load/lookup/print boilerplate.
_spaces_profile_json_field() {
  local expr="$1"
  local missing_message="${2:-}"
  python3 -c '
import json, sys

data = sys.stdin.read()
payload = json.loads(data) if data.strip() else {}
expr = sys.argv[1]
missing_message = sys.argv[2] if len(sys.argv) > 2 else ""
value = eval(expr, {"payload": payload})
if not value:
    if missing_message:
        raise SystemExit(missing_message)
    raise SystemExit(0)
print(value)
' "$expr" "$missing_message"
}

# Prints one field of the resolved profile — `profileRoot`, `databasePath`, `runtimeDirectory`,
# `ipcObject`, `source` — for a script that needs a concrete path (sqlite inspection, log and socket
# locations). This is where scripts read paths from: a path is a fact to look up from the binary that
# resolved it, not a binding to put in the environment and have children inherit.
spaces_profile_field() {
  local cli="$1"
  local field="$2"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-show --json | _spaces_profile_json_field "payload.get(\"$field\")" "profile-show --json has no $field"
}

spaces_profile_app_owner_pid() {
  local cli="$1"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-app-owner --json | _spaces_profile_json_field '(payload.get("owner") or {}).get("pid")'
}

spaces_profile_stop_running_app() {
  local cli="$1"
  local timeout="${2:-20}"
  local owner_pid
  owner_pid="$(spaces_profile_app_owner_pid "$cli")"
  [[ -n "$owner_pid" ]] || return 0

  kill "$owner_pid" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$owner_pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "Timed out waiting for Spaces profile app pid $owner_pid to exit" >&2
  return 1
}

spaces_profile_terminal_service_socket_path() {
  local cli="$1"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-socket-paths | _spaces_profile_json_field 'payload["serviceSocketPath"]'
}

spaces_profile_terminal_session_control_socket_path() {
  local cli="$1"
  local session_id="$2"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-socket-paths --session-id "$session_id" | _spaces_profile_json_field 'payload.get("sessionControlSocketPath")' "missing sessionControlSocketPath"
}

spaces_profile_terminal_session_subscription_socket_path() {
  local cli="$1"
  local session_id="$2"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-socket-paths --session-id "$session_id" | _spaces_profile_json_field 'payload.get("sessionSubscriptionSocketPath")' "missing sessionSubscriptionSocketPath"
}

spaces_profile_mac_client_installation_id() {
  local cli="$1"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" mac-client-installation-id
}

spaces_profile_socket_owner_pids() {
  local socket_path="$1"
  if [[ -e "$socket_path" ]]; then
    /usr/sbin/lsof -nP -U 2>/dev/null | awk -v path="$socket_path" 'index($0, path) { print $2 }' | sort -u || true
  fi
}

# Resolves the terminal service's socket path and prints it only if the file actually exists,
# so both stop functions below start from the same "is there anything to stop" check instead of
# each re-walking `profile-socket-paths`' newline-separated candidates. Returns 1 (nothing to
# print) when resolution fails or no candidate exists on disk, matching the `return 0` early-out
# every caller used to write out by hand.
_spaces_profile_terminal_service_existing_socket_path() {
  local cli="$1"
  local socket_paths
  socket_paths="$(spaces_profile_terminal_service_socket_path "$cli")" || return 1
  local candidate_socket_path
  while IFS= read -r candidate_socket_path; do
    if [[ -e "$candidate_socket_path" ]]; then
      printf '%s\n' "$candidate_socket_path"
      return 0
    fi
  done <<<"$socket_paths"
  return 1
}

# Sends `{"command": {<cmd>: {}}}` to the terminal service's control socket and prints the raw
# JSON response verbatim (nothing if the daemon never answers). This is the one socket-IO body
# behind both `shutdown` and `shutdownIfIdle`; a daemon that is not listening, or that trips over
# on the connect/send/recv, is a normal outcome here (a stale socket, a daemon mid-exit), not a
# script failure, so an `OSError` is swallowed rather than propagated.
_spaces_profile_service_command() {
  local socket_path="$1"
  local cmd="$2"
  python3 - "$socket_path" "$cmd" <<'PY' || true
import json
import socket
import sys

socket_path = sys.argv[1]
cmd = sys.argv[2]
payload = json.dumps({"command": {cmd: {}}}).encode("utf-8")
try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1)
    client.connect(socket_path)
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    data = b""
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
    if data:
        sys.stdout.write(data.decode("utf-8"))
except OSError:
    pass
finally:
    try:
        client.close()
    except Exception:
        pass
PY
}

# Shared teardown once a stop function has decided which pids to wait out: poll for the pids to
# exit and the socket to disappear, escalate to SIGTERM once `timeout` elapses, then SIGKILL after
# a further grace period. Identical in both `spaces_profile_stop_terminal_service` (unconditional)
# and `spaces_profile_stop_terminal_service_if_idle` (only reached once the daemon has confirmed
# it is idle, so escalating here cannot kill a live session). Always returns 0: the callers run
# under `set -e` and must proceed regardless of whether the daemon actually exited in time.
_spaces_profile_wait_for_exit_and_escalate() {
  local socket_path="$1"
  local timeout="$2"
  local candidate_pids="$3"

  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    local live_pids=""
    local pid
    for pid in $candidate_pids; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        live_pids="${live_pids}${live_pids:+ }$pid"
      fi
    done
    if [[ -z "$live_pids" && ! -e "$socket_path" ]]; then
      return 0
    fi
    if [[ -z "$live_pids" && -z "$(spaces_profile_socket_owner_pids "$socket_path")" ]]; then
      rm -f "$socket_path"
      return 0
    fi
    sleep 0.2
  done

  local pid
  for pid in $candidate_pids; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  deadline=$((SECONDS + 3))
  while (( SECONDS < deadline )); do
    local any_live=0
    for pid in $candidate_pids; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        any_live=1
      fi
    done
    [[ "$any_live" -eq 0 ]] && return 0
    sleep 0.2
  done

  for pid in $candidate_pids; do
    kill -9 "$pid" >/dev/null 2>&1 || true
  done
  return 0
}

spaces_profile_stop_terminal_service() {
  local cli="$1"
  local timeout="${2:-20}"
  local socket_path
  if ! socket_path="$(_spaces_profile_terminal_service_existing_socket_path "$cli")"; then
    return 0
  fi

  local candidate_pids
  candidate_pids="$(spaces_profile_socket_owner_pids "$socket_path")"

  local shutdown_pid
  shutdown_pid="$(_spaces_profile_service_command "$socket_path" shutdown | _spaces_profile_json_field 'payload.get("servicePID")' || true)"
  if [[ -n "$shutdown_pid" ]]; then
    candidate_pids="$(printf '%s\n%s\n' "$candidate_pids" "$shutdown_pid" | awk 'NF' | sort -u)"
  fi
  if [[ -z "$candidate_pids" ]]; then
    rm -f "$socket_path"
    return 0
  fi

  _spaces_profile_wait_for_exit_and_escalate "$socket_path" "$timeout" "$candidate_pids"
}

# Stops the profile's spacesd only when it owns no sessions, so a relaunch picks up a fresh
# daemon build without killing live terminal sessions or workspace processes. When sessions
# exist the daemon is left running and the relaunched app reattaches; a stale daemon build is
# replaced through the app's explicit daemon-restart flow. Never returns nonzero: the dev
# launch script runs under `set -e` and must proceed to relaunch in every outcome.
spaces_profile_stop_terminal_service_if_idle() {
  local cli="$1"
  local timeout="${2:-20}"
  local socket_path
  if ! socket_path="$(_spaces_profile_terminal_service_existing_socket_path "$cli")"; then
    return 0
  fi

  local candidate_pids
  candidate_pids="$(spaces_profile_socket_owner_pids "$socket_path")"

  local response
  response="$(_spaces_profile_service_command "$socket_path" shutdownIfIdle)"

  # `shutdownIfIdle` reports one of three shapes: `ok` (exiting, possibly with the pid that is
  # doing so), a busy `daemonStatus` (left running, with a session count worth telling the
  # caller about), or neither (no reply, or a failure response with just a message). Turning
  # that into one `outcome` line here is response *interpretation*, not the socket IO the two
  # stop functions share, so it stays local to this function rather than in
  # `_spaces_profile_service_command`.
  local outcome
  outcome="$(
    printf '%s' "$response" | python3 -c '
import json, sys

data = sys.stdin.read()
response = json.loads(data) if data.strip() else {}
service_pid = response.get("servicePID") or 0
daemon_status = response.get("daemonStatus")
if response.get("ok"):
    print(f"exiting {service_pid}")
elif daemon_status is not None:
    # A busy daemon reports its status; a generic failure does not.
    sessions = daemon_status.get("activeSessionCount", 0)
    print(f"busy {service_pid} {sessions}")
else:
    message = response.get("message", "no response")
    print(f"error {message}")
' || true
  )"

  case "$outcome" in
    busy\ *)
      local busy_pid busy_sessions
      busy_pid="$(printf '%s' "$outcome" | awk '{print $2}')"
      busy_sessions="$(printf '%s' "$outcome" | awk '{print $3}')"
      echo "spacesd left running with $busy_sessions live session(s) (pid $busy_pid); the relaunched app reattaches, and a stale daemon build is replaced via the app's daemon-restart prompt."
      return 0
      ;;
    exiting\ *)
      local exiting_pid
      exiting_pid="$(printf '%s' "$outcome" | awk '{print $2}')"
      if [[ "$exiting_pid" != "0" ]]; then
        candidate_pids="$(printf '%s\n%s\n' "$candidate_pids" "$exiting_pid" | awk 'NF' | sort -u)"
      fi
      ;;
    *)
      # No reply or a generic failure. Without socket owners this is a stale socket file;
      # with owners, killing is unsafe (a hung daemon may still hold live PTY children).
      if [[ -z "$candidate_pids" ]]; then
        rm -f "$socket_path"
      else
        echo "spacesd (pid(s) ${candidate_pids//$'\n'/ }) did not answer shutdownIfIdle; leaving it running. Use spaces_profile_stop_terminal_service to force-stop it." >&2
      fi
      return 0
      ;;
  esac

  if [[ -z "$candidate_pids" ]]; then
    rm -f "$socket_path"
    return 0
  fi

  # The daemon confirmed it was idle, so escalating on a stuck exit cannot kill live sessions.
  _spaces_profile_wait_for_exit_and_escalate "$socket_path" "$timeout" "$candidate_pids"
}

spaces_profile_wait_for_owner_pid() {
  local cli="$1"
  local expected_pid="$2"
  local timeout="${3:-20}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    local owner_pid
    owner_pid="$(spaces_profile_app_owner_pid "$cli")"
    if [[ "$owner_pid" == "$expected_pid" ]]; then
      return 0
    fi
    sleep 0.2
  done
  echo "Timed out waiting for Spaces profile owner pid $expected_pid" >&2
  return 1
}

spaces_wait_for_desktop_control() {
  local cli="$1"
  shift
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-wait-for-desktop-control "$@"
}
