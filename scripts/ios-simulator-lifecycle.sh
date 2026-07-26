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

# Result slot for spaces_ios_simulator_wait_for_boot: on a non-timeout return, this holds
# bootstatus's own exit status for the caller to propagate.
SPACES_IOS_SIMULATOR_LAST_BOOTSTATUS_EXIT=""

# Waits for `simctl bootstatus -b` to report the simulator booted, bounded by a hard deadline.
# Returns 0 once the wait completes within the deadline (leaving bootstatus's real exit status
# in SPACES_IOS_SIMULATOR_LAST_BOOTSTATUS_EXIT) and 1 if the deadline fires first.
#
# `simctl bootstatus -b` blocks until the simulator finishes booting and has no ceiling of its
# own; CI has seen it wedge, hanging this call (and the whole step) to the runner's outer
# timeout (45+ minutes observed, with only "Booting..." in the log). Give it a hard deadline
# instead. Implemented as background-and-poll -- not GNU `timeout` (absent on macOS runners) --
# and run in-context rather than delegating to a subshell/watchdog: this function (like its
# caller, spaces_ios_simulator_boot_if_needed) executes in the CALLER's shell, and the udid
# ownership bookkeeping there already mutated that shell's SPACES_OWNED_IOS_SIMULATOR_UDIDS so
# the caller's EXIT trap (spaces_ios_simulator_shutdown_owned) can shut this simulator down; a
# subshell here would sever that and risk leaking the simulator on timeout.
# `SECONDS` (bash's builtin elapsed-time counter) tracks the deadline rather than an
# accumulate-by-poll-interval counter, so the poll interval below can stay short (fast
# simulators/tests finish in well under a second) without needing fractional-second bash
# integer arithmetic.
spaces_ios_simulator_wait_for_boot() {
  local udid="$1"
  local boot_status_deadline="$2"
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
  SPACES_IOS_SIMULATOR_LAST_BOOTSTATUS_EXIT=$?
  return 0
}

spaces_ios_simulator_boot_if_needed() {
  local udid="$1"
  # Healthy boots take ~30-60s; 240s leaves ~4x headroom for a single attempt while still
  # letting two attempts (see the retry loop below) fit under a CI step's outer ceiling.
  local boot_status_deadline="${SPACES_IOS_SIMULATOR_BOOT_TIMEOUT:-240}"
  local -r max_attempts=2
  local attempt
  local state

  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    state="$(spaces_ios_simulator_state "$udid")"

    case "$state" in
      Booted)
        ;;
      Shutdown)
        printf 'Booting iOS simulator %s...\n' "$udid" >&2
        xcrun simctl boot "$udid" >&2
        # Record ownership at most once: a retry below boots the same udid again, but the
        # caller's EXIT trap (spaces_ios_simulator_shutdown_owned) must shut it down exactly
        # once, not once per line recorded here.
        case $'\n'"$SPACES_OWNED_IOS_SIMULATOR_UDIDS"$'\n' in
          *$'\n'"$udid"$'\n'*)
            ;;
          *)
            if [[ -n "$SPACES_OWNED_IOS_SIMULATOR_UDIDS" ]]; then
              SPACES_OWNED_IOS_SIMULATOR_UDIDS+=$'\n'
            fi
            SPACES_OWNED_IOS_SIMULATOR_UDIDS+="$udid"
            ;;
        esac
        ;;
      *)
        printf 'iOS simulator %s is neither Shutdown nor Booted (state: %s).\n' "$udid" "$state" >&2
        return 1
        ;;
    esac

    if spaces_ios_simulator_wait_for_boot "$udid" "$boot_status_deadline"; then
      return "$SPACES_IOS_SIMULATOR_LAST_BOOTSTATUS_EXIT"
    fi

    if (( attempt == max_attempts )); then
      return 1
    fi

    # A wedged bootstatus wait usually means CoreSimulator itself is stuck, not that the boot
    # will ever complete on its own. Resetting the device (shutdown + erase) was tried first and
    # did not help: a wedged boot came back and failed the retry the same way, which says the stuck
    # layer is CoreSimulator itself rather than the device's contents. So reset the service --
    # shut every device down, then kill the daemon, which launchd respawns clean on the next simctl
    # call. Everything here tolerates failure: the device may already be down and the daemon may
    # already be gone, and either way the retry below is what we actually care about.
    printf 'iOS simulator %s appears wedged; resetting CoreSimulator before retrying...\n' "$udid" >&2
    xcrun simctl shutdown all >&2 || true
    killall -9 com.apple.CoreSimulator.CoreSimulatorService >/dev/null 2>&1 || true
  done
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
