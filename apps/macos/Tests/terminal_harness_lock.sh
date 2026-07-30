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

terminal_harness_spacese2e() {
  if [[ -n "${SPACES_E2E:-}" ]]; then
    printf '%s\n' "$SPACES_E2E"
    return 0
  fi
  if [[ -n "${SPACES_E2E_CLI:-}" ]]; then
    printf '%s\n' "$SPACES_E2E_CLI"
    return 0
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$(cd "$script_dir/.." && pwd)/.build/debug/spacese2e"
}

terminal_harness_profile_socket_path() {
  local runtime_dir="$1"
  local key="$2"
  local e2e_cli
  e2e_cli="$(terminal_harness_spacese2e)"
  SPACES_RUNTIME_DIR="$runtime_dir" "$e2e_cli" profile-socket-paths | python3 -c '
import json, sys
payload = json.load(sys.stdin)
print(payload[sys.argv[1]])
' "$key"
}

terminal_service_socket_path_for_runtime_dir() {
  terminal_harness_profile_socket_path "$1" serviceSocketPath
}

# Process IDs holding the given unix domain socket open.
#
# `lsof -t <path>` resolves regular files but not unix domain sockets on macOS, so it silently returns
# nothing for these; the socket appears only in the `-U` listing, whose NAME column is the path with an
# extra leading slash. Match that column exactly rather than by substring so a longer sibling socket
# path in the same directory can never be mistaken for this one.
terminal_harness_pids_owning_unix_socket() {
  local socket_path="$1"
  [[ -n "$socket_path" ]] || return 0
  lsof -nP -U 2>/dev/null | awk -v name="/$socket_path" '$NF == name { print $2 }' | sort -u
}

# Stops the Caddy router belonging to the profile at `runtime_dir`.
#
# The daemon spawns Caddy as a detached `Process().run()` child and reaps it only in its own shutdown
# teardown, so Caddy outlives every other way a daemon can end. On macOS that includes a plain
# `kill`: the daemon's termination handling hangs off NSApplication, and its SIGTERM/SIGINT signal
# sources are `#if canImport(Glibc)` (Linux only), so SIGTERM takes the default disposition and skips
# teardown entirely. Every harness step builds its own throwaway profile, so nothing ever adopts the
# orphan Caddy the way a restarted daemon on a persistent profile would, and one accumulates per step.
#
# After a clean daemon shutdown the admin socket is already unlinked and this is a no-op, which is what
# makes it a backstop rather than a second teardown path. Scoping is by that admin socket, whose name
# embeds a hash of this runtime directory: another worktree's profile and the installed profile own
# different sockets and are never reached.
stop_caddy_router_for_runtime_dir() {
  local runtime_dir="$1"
  local timeout="${2:-5}"
  [[ -n "$runtime_dir" ]] || return 0

  local admin_socket
  admin_socket="$(terminal_harness_profile_socket_path "$runtime_dir" routerAdminSocketPath)"
  [[ -S "$admin_socket" ]] || return 0

  local pids pid command
  pids="$(terminal_harness_pids_owning_unix_socket "$admin_socket")"
  for pid in $pids; do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"caddy"* ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done

  local waited=0
  local wait_steps=$((timeout * 4))
  while (( waited < wait_steps )); do
    local any_live=0
    for pid in $pids; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        any_live=1
        break
      fi
    done
    (( any_live == 0 )) && break
    sleep 0.25
    waited=$((waited + 1))
  done

  for pid in $pids; do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"caddy"* ]] || continue
    kill -9 "$pid" >/dev/null 2>&1 || true
  done
  rm -f "$admin_socket" >/dev/null 2>&1 || true
}

# Stops everything the profile at `runtime_dir` is running: its terminal service daemon and the Caddy
# router that daemon owns. Harness cleanup must route daemon teardown through here rather than
# `kill`ing the daemon's pid, because only the daemon's own graceful shutdown reaps its children --
# see stop_caddy_router_for_runtime_dir for why a bare SIGTERM does not.
stop_terminal_service_for_runtime_dir() {
  local runtime_dir="$1"
  local timeout="${2:-5}"
  [[ -n "$runtime_dir" ]] || return 0
  stop_terminal_service_daemon_for_runtime_dir "$runtime_dir" "$timeout"
  stop_caddy_router_for_runtime_dir "$runtime_dir" "$timeout"
}

stop_terminal_service_daemon_for_runtime_dir() {
  local runtime_dir="$1"
  local timeout="${2:-5}"

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
    client.sendall(json.dumps({"command": {"shutdown": {}}}).encode("utf-8"))
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
  pids="$(terminal_harness_pids_owning_unix_socket "$service_socket")"
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
