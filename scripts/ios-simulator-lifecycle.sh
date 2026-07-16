#!/usr/bin/env bash

SPACES_OWNED_IOS_SIMULATOR_UDIDS=""

spaces_ios_simulator_state() {
  local udid="$1"
  python3 - "$udid" <<'PY'
import json
import subprocess
import sys

udid = sys.argv[1]
payload = json.loads(
    subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        text=True,
    )
)
for runtime_devices in payload.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("udid") == udid:
            print(device.get("state", ""))
            raise SystemExit(0)
raise SystemExit(f"Available simulator not found: {udid}")
PY
}

spaces_ios_simulator_boot_if_needed() {
  local udid="$1"
  local state
  state="$(spaces_ios_simulator_state "$udid")"

  case "$state" in
    Booted)
      ;;
    Shutdown)
      printf 'Booting iOS simulator %s...\n' "$udid" >&2
      xcrun simctl boot "$udid" >&2
      if [[ -n "$SPACES_OWNED_IOS_SIMULATOR_UDIDS" ]]; then
        SPACES_OWNED_IOS_SIMULATOR_UDIDS+=$'\n'
      fi
      SPACES_OWNED_IOS_SIMULATOR_UDIDS+="$udid"
      ;;
    *)
      printf 'iOS simulator %s is neither Shutdown nor Booted (state: %s).\n' "$udid" "$state" >&2
      return 1
      ;;
  esac

  xcrun simctl bootstatus "$udid" -b >&2
}

spaces_ios_simulator_shutdown_owned() {
  local exit_code="${1:-$?}"
  local owned_udids="$SPACES_OWNED_IOS_SIMULATOR_UDIDS"
  local udid

  SPACES_OWNED_IOS_SIMULATOR_UDIDS=""
  while IFS= read -r udid; do
    [[ -n "$udid" ]] || continue
    printf 'Shutting down test-owned iOS simulator %s...\n' "$udid" >&2
    if ! xcrun simctl shutdown "$udid" >&2; then
      printf 'Failed to shut down test-owned iOS simulator %s.\n' "$udid" >&2
    fi
  done <<<"$owned_udids"

  return "$exit_code"
}
