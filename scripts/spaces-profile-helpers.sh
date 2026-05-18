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
