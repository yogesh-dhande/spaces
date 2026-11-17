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
# The deadline is enforced by counting completed poll sleeps rather than reading elapsed
# wall-clock time. bash's builtin `SECONDS` looks like the obvious elapsed-time primitive, but it
# is only whole-second-accurate: reading it twice captures a *floor* of true elapsed time at each
# read, so two reads a few milliseconds apart can differ by 1 if a wall-clock second boundary
# falls between them. For a short deadline (this function is called with 1s in
# apps/macos/Tests/ios_simulator_lifecycle.sh) that error is the entire budget: a `SECONDS`-based
# 1s deadline can fire within tens of milliseconds of starting, SIGKILLing the mocked bootstatus
# hang before it writes its single-shot marker file and failing the wedge-recovery test. Sub-
# second-accurate wall-clock alternatives aren't available here either: macOS ships BSD `date`
# (no `%N`) and bash 3.2 (no `EPOCHREALTIME`, added in bash 5), and this function must stay in the
# caller's shell (see below) so it can't shell out to a subshell-based timer. Counting completed
# `sleep` calls sidesteps wall-clock reads entirely: each `sleep` blocks for at least its argument
# (modulo signal interruption), so N completed sleeps of the poll interval always represent at
# least N * interval seconds of real elapsed time -- the deadline can only fire late, never early.
spaces_ios_simulator_wait_for_boot() {
  local udid="$1"
  local boot_status_deadline="$2"
  local -r boot_status_poll_interval="0.2"
  local -r boot_status_polls_per_second=5
  local boot_status_max_polls=$(( boot_status_deadline * boot_status_polls_per_second ))
  local boot_status_polls=0
  local boot_status_pid

  xcrun simctl bootstatus "$udid" -b >&2 &
  boot_status_pid=$!

  while kill -0 "$boot_status_pid" 2>/dev/null; do
    if (( boot_status_polls >= boot_status_max_polls )); then
      echo "xcrun simctl bootstatus $udid exceeded ${boot_status_deadline}s; killing it as hung." >&2
      kill -KILL "$boot_status_pid" 2>/dev/null || true
      wait "$boot_status_pid" 2>/dev/null || true
      return 1
    fi
    sleep "$boot_status_poll_interval"
    boot_status_polls=$(( boot_status_polls + 1 ))
  done

  SPACES_IOS_SIMULATOR_LAST_BOOTSTATUS_EXIT=0
  wait "$boot_status_pid" || SPACES_IOS_SIMULATOR_LAST_BOOTSTATUS_EXIT=$?
  return 0
}

# Exit status of spaces_ios_simulator_boot_if_needed when the boot never completed within its
# deadline, distinct from a simulator in an unusable state or a failing bootstatus, so a caller can
# tell a wedged boot (infrastructure) from a real failure and recover or report it as such.
SPACES_IOS_SIMULATOR_BOOT_WEDGED_STATUS=75

# Boots `udid` if it is shut down and waits for it to finish. One attempt: a boot that exceeds its
# deadline returns SPACES_IOS_SIMULATOR_BOOT_WEDGED_STATUS and leaves recovery to the caller,
# because the right recovery depends on who owns the device (see spaces_ios_simulator_create_fresh_like).
spaces_ios_simulator_boot_if_needed() {
  local udid="$1"
  # Healthy boots take ~30-60s; 240s leaves ~4x headroom, and still lets a caller that recovers
  # from a wedge with a second boot fit both under a CI step's outer ceiling.
  local boot_status_deadline="${SPACES_IOS_SIMULATOR_BOOT_TIMEOUT:-240}"
  local state

  # Every step checks its own status instead of relying on `set -e`: a caller that branches on this
  # function's status (`f || status=$?`) runs it with errexit disabled throughout, and an ignored
  # failed boot would record a simulator another workflow booted as owned, to be shut down at teardown.
  state="$(spaces_ios_simulator_state "$udid")" || return

  case "$state" in
    Booted)
      ;;
    Shutdown)
      printf 'Booting iOS simulator %s...\n' "$udid" >&2
      local boot_status=0
      xcrun simctl boot "$udid" >&2 || boot_status=$?
      if (( boot_status != 0 )); then
        return "$boot_status"
      fi
      # Record ownership before waiting: the caller's EXIT trap (spaces_ios_simulator_shutdown_owned)
      # must shut this simulator down even if the wait wedges. Once per udid, so the trap shuts it
      # down exactly once however many times the caller boots it.
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
  return "$SPACES_IOS_SIMULATOR_BOOT_WEDGED_STATUS"
}

# Devices this process created (see spaces_ios_simulator_create_fresh_like), deleted at teardown.
SPACES_CREATED_IOS_SIMULATOR_UDIDS=""

SPACES_FRESH_IOS_SIMULATOR_UDID=""

# Creates a new, never-booted simulator of the same device type and runtime as `udid` and leaves its
# udid in SPACES_FRESH_IOS_SIMULATOR_UDID. This is the recovery for a boot that wedged: a CoreSimulator
# reset on the same device kept wedging in CI, while a device with no prior state is the thing that
# does not carry over whatever wedged. The original is left alone rather than erased or deleted, because it may be a
# developer's own simulator with installed apps; the new one is lane-owned and is deleted at
# teardown by spaces_ios_simulator_shutdown_owned. Not for callers that hold a device by udid
# across steps (paired mobile E2E): the replacement has a different udid.
spaces_ios_simulator_create_fresh_like() {
  local udid="$1"
  local device_type
  local runtime

  read -r device_type runtime < <(
    python3 - "$udid" <<'PY'
import json
import subprocess
import sys

udid = sys.argv[1]
payload = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
)
for runtime, runtime_devices in payload.get("devices", {}).items():
    for device in runtime_devices:
        if device.get("udid") == udid:
            print(device["deviceTypeIdentifier"], runtime)
            raise SystemExit(0)
raise SystemExit(f"Available simulator not found: {udid}")
PY
  ) || return

  # Command substitution runs in a subshell, so the udid is captured and then recorded in this
  # shell, where the caller's EXIT trap can read it.
  SPACES_FRESH_IOS_SIMULATOR_UDID="$(xcrun simctl create "Spaces iOS tests $$" "$device_type" "$runtime")" || return
  if [[ -n "$SPACES_CREATED_IOS_SIMULATOR_UDIDS" ]]; then
    SPACES_CREATED_IOS_SIMULATOR_UDIDS+=$'\n'
  fi
  SPACES_CREATED_IOS_SIMULATOR_UDIDS+="$SPACES_FRESH_IOS_SIMULATOR_UDID"
}

# Shuts down one test-owned simulator and drops it from the owned list, so teardown does not shut
# it down a second time (which would log a failure for a device that is already down).
spaces_ios_simulator_shutdown_one_owned() {
  local udid="$1"
  local remaining=""
  local owned

  printf 'Shutting down test-owned iOS simulator %s...\n' "$udid" >&2
  if ! xcrun simctl shutdown "$udid" >&2; then
    printf 'Failed to shut down test-owned iOS simulator %s.\n' "$udid" >&2
  fi
  while IFS= read -r owned; do
    [[ -n "$owned" && "$owned" != "$udid" ]] || continue
    remaining+="${remaining:+$'\n'}$owned"
  done <<<"$SPACES_OWNED_IOS_SIMULATOR_UDIDS"
  SPACES_OWNED_IOS_SIMULATOR_UDIDS="$remaining"
}

spaces_ios_simulator_shutdown_owned() {
  local exit_code="${1:-$?}"
  local owned_udids="$SPACES_OWNED_IOS_SIMULATOR_UDIDS"
  local created_udids="$SPACES_CREATED_IOS_SIMULATOR_UDIDS"
  local udid

  SPACES_CREATED_IOS_SIMULATOR_UDIDS=""
  while IFS= read -r udid; do
    [[ -n "$udid" ]] || continue
    spaces_ios_simulator_shutdown_one_owned "$udid"
  done <<<"$owned_udids"
  SPACES_OWNED_IOS_SIMULATOR_UDIDS=""

  while IFS= read -r udid; do
    [[ -n "$udid" ]] || continue
    printf 'Deleting test-created iOS simulator %s...\n' "$udid" >&2
    if ! xcrun simctl delete "$udid" >&2; then
      printf 'Failed to delete test-created iOS simulator %s.\n' "$udid" >&2
    fi
  done <<<"$created_udids"

  return "$exit_code"
}
