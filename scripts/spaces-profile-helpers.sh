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

# Prints one field of the resolved profile — `profileRoot`, `databasePath`, `runtimeDirectory`,
# `ipcObject`, `source` — for a script that needs a concrete path (sqlite inspection, log and socket
# locations). This is where scripts read paths from: a path is a fact to look up from the binary that
# resolved it, not a binding to put in the environment and have children inherit.
spaces_profile_field() {
  local cli="$1"
  local field="$2"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-show --json | python3 -c '
import json, sys
payload = json.load(sys.stdin)
value = payload.get(sys.argv[1])
if not value:
    raise SystemExit(f"profile-show --json has no {sys.argv[1]}")
print(value)
' "$field"
}

spaces_profile_app_owner_pid() {
  local cli="$1"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-app-owner --json | python3 -c '
import json, sys
payload = json.load(sys.stdin)
owner = payload.get("owner") or {}
pid = owner.get("pid")
if pid:
    print(pid)
'
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
  "$e2e_cli" profile-socket-paths | python3 -c '
import json, sys
payload = json.load(sys.stdin)
print(payload["serviceSocketPath"])
'
}

spaces_profile_terminal_session_control_socket_path() {
  local cli="$1"
  local session_id="$2"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-socket-paths --session-id "$session_id" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
path = payload.get("sessionControlSocketPath")
if not path:
    raise SystemExit("missing sessionControlSocketPath")
print(path)
'
}

spaces_profile_terminal_session_subscription_socket_path() {
  local cli="$1"
  local session_id="$2"
  local e2e_cli
  e2e_cli="$(spaces_profile_e2e_cli "$cli")"
  "$e2e_cli" profile-socket-paths --session-id "$session_id" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
path = payload.get("sessionSubscriptionSocketPath")
if not path:
    raise SystemExit("missing sessionSubscriptionSocketPath")
print(path)
'
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

spaces_profile_stop_terminal_service() {
  local cli="$1"
  local timeout="${2:-20}"
  local socket_paths
  if ! socket_paths="$(spaces_profile_terminal_service_socket_path "$cli")"; then
    return 0
  fi
  local socket_path=""
  local candidate_socket_path
  while IFS= read -r candidate_socket_path; do
    if [[ -e "$candidate_socket_path" ]]; then
      socket_path="$candidate_socket_path"
      break
    fi
  done <<<"$socket_paths"
  [[ -n "$socket_path" ]] || return 0

  local candidate_pids
  candidate_pids="$(spaces_profile_socket_owner_pids "$socket_path")"

  local shutdown_pid
  shutdown_pid="$(
    python3 - "$socket_path" <<'PY' || true
import json
import socket
import sys

socket_path = sys.argv[1]
payload = json.dumps({"command": {"shutdown": {}}}).encode("utf-8")
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
    response = json.loads(data.decode("utf-8")) if data else {}
    service_pid = response.get("servicePID")
    if service_pid:
        print(service_pid)
except OSError:
    pass
finally:
    try:
        client.close()
    except Exception:
        pass
PY
  )"
  if [[ -n "$shutdown_pid" ]]; then
    candidate_pids="$(printf '%s\n%s\n' "$candidate_pids" "$shutdown_pid" | awk 'NF' | sort -u)"
  fi
  if [[ -z "$candidate_pids" ]]; then
    rm -f "$socket_path"
    return 0
  fi

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
}

# Stops the profile's spacesd only when it owns no sessions, so a relaunch picks up a fresh
# daemon build without killing live terminal sessions or workspace processes. When sessions
# exist the daemon is left running and the relaunched app reattaches; a stale daemon build is
# replaced through the app's explicit daemon-restart flow. Never returns nonzero: the dev
# launch script runs under `set -e` and must proceed to relaunch in every outcome.
spaces_profile_stop_terminal_service_if_idle() {
  local cli="$1"
  local timeout="${2:-20}"
  local socket_paths
  if ! socket_paths="$(spaces_profile_terminal_service_socket_path "$cli")"; then
    return 0
  fi
  local socket_path=""
  local candidate_socket_path
  while IFS= read -r candidate_socket_path; do
    if [[ -e "$candidate_socket_path" ]]; then
      socket_path="$candidate_socket_path"
      break
    fi
  done <<<"$socket_paths"
  [[ -n "$socket_path" ]] || return 0

  local candidate_pids
  candidate_pids="$(spaces_profile_socket_owner_pids "$socket_path")"

  local outcome
  outcome="$(
    python3 - "$socket_path" <<'PY' || true
import json
import socket
import sys

socket_path = sys.argv[1]
payload = json.dumps({"command": {"shutdownIfIdle": {}}}).encode("utf-8")
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
    response = json.loads(data.decode("utf-8")) if data else {}
    service_pid = response.get("servicePID") or 0
    daemon_status = response.get("daemonStatus")
    if response.get("ok"):
        print(f"exiting {service_pid}")
    elif daemon_status is not None:
        # A busy daemon reports its status; a generic failure does not.
        print(f"busy {service_pid} {daemon_status.get('activeSessionCount', 0)}")
    else:
        print(f"error {response.get('message', 'no response')}")
except OSError:
    pass
finally:
    try:
        client.close()
    except Exception:
        pass
PY
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

  # The daemon confirmed it was idle, so escalating on a stuck exit cannot kill live sessions.
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
