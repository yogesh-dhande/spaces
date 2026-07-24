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

  # `simctl bootstatus -b` blocks until the simulator finishes booting and has no ceiling of
  # its own; CI has seen it wedge, hanging this call (and the whole step) to the runner's
  # outer timeout (45+ minutes observed, with only "Booting..." in the log). Give it a hard
  # deadline instead. Implemented as background-and-poll -- not GNU `timeout` (absent on
  # macOS runners) -- and run in-context rather than delegating to a subshell/watchdog: this
  # function executes in the CALLER's shell, and the udid ownership bookkeeping above already
  # mutated that shell's SPACES_OWNED_IOS_SIMULATOR_UDIDS so the caller's EXIT trap
  # (spaces_ios_simulator_shutdown_owned) can shut this simulator down; a subshell here would
  # sever that and risk leaking the simulator on timeout.
  # `SECONDS` (bash's builtin elapsed-time counter) tracks the deadline rather than an
  # accumulate-by-poll-interval counter, so the poll interval below can stay short (fast
  # simulators/tests finish in well under a second) without needing fractional-second bash
  # integer arithmetic.
  local boot_status_deadline="${SPACES_IOS_SIMULATOR_BOOT_TIMEOUT:-600}"
  local boot_status_start_seconds="$SECONDS"
  local boot_status_pid

  xcrun simctl bootstatus "$udid" -b >&2 &
  boot_status_pid=$!

  while kill -0 "$boot_status_pid" 2>/dev/null; do
    if (( SECONDS - boot_status_start_seconds >= boot_status_deadline )); then
      echo "xcrun simctl bootstatus $udid exceeded ${boot_status_deadline}s; killing it as hung." >&2
      kill -KILL "$boot_status_pid" 2>/dev/null || true
      wait "$boot_status_pid" 2>/dev/null || true
      return 1
    fi
    sleep 0.2
  done

  wait "$boot_status_pid"
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
