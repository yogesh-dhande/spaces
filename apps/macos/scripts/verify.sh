#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
source "$repo_root/scripts/spaces-profile-helpers.sh"

# The watchdog fires on silence, not on total elapsed time. Total elapsed time cannot tell a hung
# run from a healthy one: a cold verify spends most of its wall clock compiling — the SwiftPM
# coverage step rebuilds every test target under instrumentation — so any ceiling loose enough to
# survive a cold build is far too loose to catch a test that deadlocks on a warm one. What actually
# separates the two is output. Every phase here streams progress (per-target compile lines, per-test
# lines, xcodebuild activity); a deadlocked test or a wedged build streams nothing. So the gate is
# the gap since the last byte of output, which catches a hang anywhere in the run — including in a
# build — while never penalising a slow-but-healthy one.
#
# The threshold must clear the longest legitimately silent stretch, which is a link or an
# `llvm-cov export` over the full test binary, not any single compile.
# Override with SPACES_VERIFY_STALL_SECONDS (0 disables, e.g. when attaching a debugger).
# The watchdog is armed at the end of this script; see run_verify_steps below.
verify_stall_seconds="${SPACES_VERIFY_STALL_SECONDS:-600}"
verify_stall_poll_seconds=5

# Recursively SIGKILL a process and all of its descendants. macOS has no `timeout(1)` and
# ships bash 3.2 (no $BASHPID), so the watchdog runs the real work as a separate child and
# kills that child's tree — the watchdog is a sibling of that tree, so no self-exclusion is
# needed. Depth-first so children die before their parent can spawn more.
kill_process_tree() {
  local pid="$1"
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_process_tree "$child"
  done
  kill -KILL "$pid" 2>/dev/null || true
}

ios_simulator_arch() {
  local host_arch
  host_arch="$(uname -m)"
  case "$host_arch" in
    arm64 | x86_64)
      printf '%s\n' "$host_arch"
      ;;
    *)
      printf 'Unsupported iOS simulator host architecture: %s\n' "$host_arch" >&2
      return 1
      ;;
  esac
}

ios_test_destination() {
  if [ -n "${SPACES_IOS_TEST_DESTINATION:-}" ]; then
    printf '%s\n' "$SPACES_IOS_TEST_DESTINATION"
    return
  fi

  local simulator_arch
  local simulator_selection
  local simulator_id
  local simulator_state
  simulator_arch="$(ios_simulator_arch)"

  simulator_selection="$(
    xcrun simctl list devices available -j | python3 -c '
import json
import sys

data = json.load(sys.stdin)
preferred_names = ("iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro")
devices = []
for runtime, runtime_devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in runtime_devices:
        name = device.get("name", "")
        if device.get("isAvailable") and name.startswith("iPhone"):
            devices.append(device)

for candidates in (
    [device for device in devices if device.get("state") != "Booted"],
    [device for device in devices if device.get("state") == "Booted"],
    devices,
):
    for preferred_name in preferred_names:
        for device in candidates:
            if device.get("name") == preferred_name:
                print("{}\t{}".format(device.get("udid"), device.get("state")))
                raise SystemExit(0)
    if candidates:
        print("{}\t{}".format(candidates[0].get("udid"), candidates[0].get("state")))
        raise SystemExit(0)

raise SystemExit("No available iPhone simulator found for iOS tests.")
'
  )"
  IFS=$'\t' read -r simulator_id simulator_state <<<"$simulator_selection"

  if [ "$simulator_state" != "Booted" ]; then
    printf 'Booting iOS simulator %s...\n' "$simulator_id" >&2
    xcrun simctl boot "$simulator_id" >&2
  fi
  xcrun simctl bootstatus "$simulator_id" -b >&2
  printf 'platform=iOS Simulator,id=%s,arch=%s\n' "$simulator_id" "$simulator_arch"
}

run_ios_tests() {
  ios_root="$repo_root/apps/ios"
  ios_derived_data="${SPACES_IOS_DERIVED_DATA:-$root/.build/ios-derived-data}"
  destination="$(ios_test_destination)"

  rm -rf "$ios_derived_data"
  unset $(git rev-parse --local-env-vars)
  printf 'Running iOS unit tests on %s...\n' "$destination"
  xcodebuild \
    -project "$ios_root/SpacesMobile.xcodeproj" \
    -scheme SpacesMobile \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$ios_derived_data" \
    -only-testing:SpacesMobileTests \
    -skip-testing:SpacesMobileUITests \
    test
}

stop_current_profile_runtime_for_tests() {
  if [ "${SPACES_VERIFY_KEEP_PROFILE_RUNTIME:-0}" = "1" ]; then
    echo "Keeping current Spaces profile runtime for verification (SPACES_VERIFY_KEEP_PROFILE_RUNTIME=1)"
    return
  fi

  local cli="$root/.build/debug/spaces"
  if [ ! -x "$cli" ]; then
    return
  fi

  echo "Stopping current Spaces profile app and spacesd daemon before SwiftPM coverage..."
  (
    spaces_profile_stop_running_app "$cli" "${SPACES_VERIFY_PROFILE_STOP_TIMEOUT:-20}"
    spaces_profile_stop_terminal_service "$cli" "${SPACES_VERIFY_PROFILE_STOP_TIMEOUT:-20}"
  )
}

run_verify_steps() {
  cd "$root"

  "$root/Tests/setup_ghostty_xcode_mismatch_autobuild.sh"
  "$root/Tests/setup_ghostty_cache_restore.sh"
  "$root/scripts/lint.sh"
  "$root/scripts/swiftpm.sh" build
  spaces_profile_eval_shell_env "$root/.build/debug/spaces"
  stop_current_profile_runtime_for_tests
  unset SPACES_DEVICE_API_PORT
  "$root/scripts/coverage.sh"
  run_ios_tests
}

if [ "$verify_stall_seconds" -le 0 ]; then
  run_verify_steps
  exit 0
fi

# The run's output is mirrored to a log whose modification time is the liveness signal the
# watchdog polls. A FIFO plus an explicit `tee` child, rather than `> >(tee ...)`: bash 3.2 does
# not set `$!` for a process substitution, and the tee PID is needed to wait for its flush before
# exiting — otherwise a failing run could lose the very output that explains the failure.
verify_output_dir="$(mktemp -d -t spaces-verify)"
verify_fifo="$verify_output_dir/output"
verify_log="$verify_output_dir/output.log"
mkfifo "$verify_fifo"
: >"$verify_log"
trap 'rm -rf "$verify_output_dir"' EXIT

# Start the reader first: opening a FIFO for writing blocks until a reader has it open.
tee "$verify_log" <"$verify_fifo" &
verify_tee_pid=$!

# Run the real work as a child so the watchdog — a sibling of that child, not part of its
# process tree — can force-kill the whole tree (swift-test/xcodebuild workers included) on
# timeout without needing to identify or exclude itself. A SIGKILLed child makes `wait`
# return non-zero, so the run exits with a failing status that aborts the commit.
run_verify_steps >"$verify_fifo" 2>&1 &
verify_work_pid=$!

(
  while :; do
    sleep "$verify_stall_poll_seconds"
    kill -0 "$verify_work_pid" 2>/dev/null || exit 0
    last_output_epoch="$(stat -f %m "$verify_log" 2>/dev/null || true)"
    # An unreadable log is not evidence of a stall; wait for the next poll rather than kill a
    # healthy run over a failed stat.
    case "$last_output_epoch" in
      '' | *[!0-9]*) continue ;;
    esac
    if [ "$(($(date +%s) - last_output_epoch))" -ge "$verify_stall_seconds" ]; then
      echo "verify.sh: no output for ${verify_stall_seconds}s; killing the run (likely a hung/flaky test)." >&2
      kill_process_tree "$verify_work_pid"
      exit 0
    fi
  done
) &
verify_watchdog_pid=$!

# On interrupt, tear down both children so no orphaned build/test processes linger.
trap 'kill_process_tree "$verify_work_pid" 2>/dev/null; kill_process_tree "$verify_watchdog_pid" 2>/dev/null' INT TERM

verify_status=0
wait "$verify_work_pid" || verify_status=$?

# Work finished (cleanly or via the watchdog's kill): disarm the now-idle watchdog. Kill its
# whole tree, not just the subshell — bash does not forward the signal to its foreground
# `sleep`, so signalling the subshell alone would orphan that sleep until the next poll.
kill_process_tree "$verify_watchdog_pid" 2>/dev/null
wait "$verify_watchdog_pid" 2>/dev/null || true

# The work child closed the FIFO's write end, so `tee` sees EOF and exits once it has flushed
# every buffered line to the terminal.
wait "$verify_tee_pid" 2>/dev/null || true

exit "$verify_status"
