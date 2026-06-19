#!/usr/bin/env bash

terminal_harness_lock_dir="${SPACES_TERMINAL_HARNESS_LOCK_DIR:-${TMPDIR:-/tmp}/spaces-terminal-harness.lock}"
terminal_harness_lock_acquired=0

acquire_terminal_harness_lock() {
  local waited=0
  while ! mkdir "$terminal_harness_lock_dir" 2>/dev/null; do
    if [[ -f "$terminal_harness_lock_dir/pid" ]]; then
      local owner_pid
      owner_pid="$(cat "$terminal_harness_lock_dir/pid" 2>/dev/null || true)"
      if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
        rm -rf "$terminal_harness_lock_dir"
        continue
      fi
    fi
    sleep 0.2
    waited=$((waited + 1))
    if (( waited == 50 )); then
      echo "Waiting for terminal harness lock at $terminal_harness_lock_dir" >&2
    fi
  done
  printf '%s\n' "$$" >"$terminal_harness_lock_dir/pid"
  terminal_harness_lock_acquired=1
}

release_terminal_harness_lock() {
  if (( terminal_harness_lock_acquired == 1 )); then
    rm -rf "$terminal_harness_lock_dir"
    terminal_harness_lock_acquired=0
  fi
}

terminal_service_socket_path_for_runtime_dir() {
  local runtime_dir="$1"
  SPACES_RUNTIME_DIR="$runtime_dir" python3 - <<'PY'
import os
import pathlib

terminal_root = str((pathlib.Path(os.environ["SPACES_RUNTIME_DIR"]).resolve() / "terminal"))
hash_value = 5381
for byte in terminal_root.encode("utf-8"):
    hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
print(f"/tmp/spaces-terminal-sockets/service-{hash_value:016x}.sock")
PY
}

stop_terminal_service_for_runtime_dir() {
  local runtime_dir="$1"
  local timeout="${2:-5}"
  [[ -n "$runtime_dir" ]] || return 0

  local service_socket
  service_socket="$(terminal_service_socket_path_for_runtime_dir "$runtime_dir")"
  [[ -S "$service_socket" ]] || return 0

  python3 - "$service_socket" <<'PY' >/dev/null 2>&1 || true
import json
import socket
import sys

socket_path = sys.argv[1]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(1)
    client.connect(socket_path)
    client.sendall(json.dumps({"command": "shutdown"}).encode("utf-8"))
    client.shutdown(socket.SHUT_WR)
    client.recv(65536)
PY

  local waited=0
  local wait_steps=$((timeout * 4))
  while (( waited < wait_steps )); do
    [[ ! -S "$service_socket" ]] && return 0
    sleep 0.25
    waited=$((waited + 1))
  done

  local pids
  pids="$(lsof -nP -t "$service_socket" 2>/dev/null | sort -u || true)"
  if [[ -z "$pids" ]]; then
    rm -f "$service_socket" >/dev/null 2>&1 || true
    return 0
  fi

  local pid
  for pid in $pids; do
    local command
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"spacesd"* ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done

  waited=0
  while (( waited < wait_steps )); do
    local any_live=0
    for pid in $pids; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        any_live=1
        break
      fi
    done
    (( any_live == 0 )) && return 0
    sleep 0.25
    waited=$((waited + 1))
  done

  for pid in $pids; do
    local command
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"spacesd"* ]] || continue
    kill -9 "$pid" >/dev/null 2>&1 || true
  done
  rm -f "$service_socket" >/dev/null 2>&1 || true
}
