#!/usr/bin/env bash

spaces_profile_eval_shell_env() {
  local cli="$1"
  eval "$("$cli" profile show --shell)"
}

spaces_profile_app_owner_pid() {
  local cli="$1"
  "$cli" profile app-owner --json | python3 -c '
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
  local runtime_dir="${SPACES_RUNTIME_DIR:-}"
  if [[ -z "$runtime_dir" ]]; then
    local profile_exports
    profile_exports="$("$cli" profile show --shell)"
    runtime_dir="$(
      PROFILE_EXPORTS="$profile_exports" python3 - <<'PY'
import os
import shlex

for token in shlex.split(os.environ["PROFILE_EXPORTS"]):
    if token.startswith("SPACES_RUNTIME_DIR="):
        print(token.split("=", 1)[1])
        break
PY
    )"
  fi
  [[ -n "$runtime_dir" ]] || return 1

  python3 - "$runtime_dir" <<'PY'
import pathlib
import sys

terminal_root = pathlib.Path(sys.argv[1]) / "terminal"
hash_value = 5381
for byte in str(terminal_root).encode():
    hash_value = (((hash_value << 5) + hash_value) + byte) & 0xFFFFFFFFFFFFFFFF
print(f"/tmp/spaces-terminal-sockets/service-{hash_value:016x}.sock")
PY
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
  local socket_path
  if ! socket_path="$(spaces_profile_terminal_service_socket_path "$cli")"; then
    return 0
  fi
  [[ -e "$socket_path" ]] || return 0

  local candidate_pids
  candidate_pids="$(spaces_profile_socket_owner_pids "$socket_path")"

  local shutdown_pid
  shutdown_pid="$(
    python3 - "$socket_path" <<'PY' || true
import json
import socket
import sys

socket_path = sys.argv[1]
payload = json.dumps({"command": "shutdown"}).encode("utf-8")
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
  "$cli" profile wait-for-desktop-control "$@"
}
