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
