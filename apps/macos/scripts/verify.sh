#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
source "$repo_root/scripts/spaces-profile-helpers.sh"
source "$repo_root/scripts/ios-simulator-lifecycle.sh"
source "$root/scripts/silence-watchdog.sh"

# Builds and coverage export can legitimately produce no output for long stretches. The silence
# watchdog therefore wraps only the already-built SwiftPM and iOS test processes, where a long
# silent interval means a test worker or simulator test launch is hung.
# Override with SPACES_VERIFY_STALL_SECONDS (0 disables, e.g. when attaching a debugger).
verify_stall_seconds="${SPACES_VERIFY_STALL_SECONDS:-600}"

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

select_ios_test_destination() {
  local simulator_arch
  local simulator_selection
  local simulator_id
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
    [device for device in devices if device.get("state") == "Shutdown"],
    [device for device in devices if device.get("state") == "Booted"],
    devices,
):
    for preferred_name in preferred_names:
        for device in candidates:
            if device.get("name") == preferred_name:
                print(device.get("udid"))
                raise SystemExit(0)
    if candidates:
        print(candidates[0].get("udid"))
        raise SystemExit(0)

raise SystemExit("No available iPhone simulator found for iOS tests.")
'
  )"
  simulator_id="$simulator_selection"

  spaces_ios_simulator_boot_if_needed "$simulator_id"
  destination="platform=iOS Simulator,id=$simulator_id,arch=$simulator_arch"
}

run_ios_tests() {
  local -a xcodebuild_args
  ios_root="$repo_root/apps/ios"
  ios_derived_data="$root/.build/ios-derived-data"
  select_ios_test_destination
  xcodebuild_args=(
    -project "$ios_root/SpacesMobile.xcodeproj"
    -scheme SpacesMobile
    -configuration Debug
    -destination "$destination"
    -derivedDataPath "$ios_derived_data"
    -only-testing:SpacesMobileTests
    -skip-testing:SpacesMobileUITests
  )

  unset $(git rev-parse --local-env-vars)
  printf 'Building iOS unit tests for %s...\n' "$destination"
  xcodebuild "${xcodebuild_args[@]}" build-for-testing
  printf 'Running iOS unit tests on %s...\n' "$destination"
  run_with_silence_watchdog "$verify_stall_seconds" xcodebuild "${xcodebuild_args[@]}" test-without-building
}

# PID of the backgrounded iOS lane subshell started by run_verify_steps, so
# handle_interrupt() can tear it down. Empty until that lane is launched.
ios_lane_pid=""

# Runs the iOS unit test lane for backgrounding alongside coverage.sh. This must be invoked as
# an explicit `( run_ios_lane ) &` subshell, not a bare `run_ios_lane &`: bash inherits this
# function's traps into either background form, but only fires a trap set *inside* the function
# body on that subshell's own exit when the call site itself is wrapped in explicit parentheses.
# A bare `run_ios_lane &` silently drops the EXIT trap below, so simulator shutdown is skipped for
# every run and this leaks a booted simulator on every invocation, not merely on interrupt.
#
# The EXIT trap makes this lane responsible for shutting down any simulator it booted: it runs in
# its own forked subshell, so its SPACES_OWNED_IOS_SIMULATOR_UDIDS state (set by
# spaces_ios_simulator_boot_if_needed, sourced from ios-simulator-lifecycle.sh) never propagates
# back to run_verify_steps's process. The top-level cleanup() trap's own
# spaces_ios_simulator_shutdown_owned call is therefore a no-op for this lane by design; it still
# covers a simulator booted directly by the foreground process, which does not happen today but
# costs nothing to keep symmetric.
run_ios_lane() {
  trap 'spaces_ios_simulator_shutdown_owned "$?"' EXIT
  trap 'exit 130' INT TERM
  run_ios_tests
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

  "$root/Tests/ios_simulator_lifecycle.sh"
  "$root/Tests/silence_watchdog.sh"
  "$root/Tests/setup_ghostty_xcode_mismatch_autobuild.sh"
  "$root/Tests/setup_ghostty_cache_restore.sh"
  # Sync the local GhosttyKit/libghostty-vt artifacts to the pinned submodule before building. CI
  # runs ensure_ghostty_artifacts.sh ahead of verify, but a local .local can drift from the pin
  # (worktree .local copies, iOS/Linux builds swapping artifacts), which makes embedded-terminal
  # tests silently run against the wrong libghostty and fail as if flaky. This is a no-op when the
  # installed manifest already matches the pin and self-heals from the cache otherwise.
  "$root/scripts/setup_ghostty.sh"
  "$root/scripts/lint.sh"
  # Build once, with the same flags coverage.sh's own build step passes
  # (--build-tests --enable-code-coverage). Toggling --enable-code-coverage between
  # builds invalidates SwiftPM's incremental state (it recompiles the whole package),
  # so a plain build here followed by coverage.sh's instrumented build compiled
  # everything twice. Building with the coverage flags here makes coverage.sh's
  # build an incremental no-op while still producing plain .build/debug/spaces,
  # SpacesApp, and spacesd binaries for release_bundle_signing.sh below.
  "$root/scripts/swiftpm.sh" build --build-tests --enable-code-coverage
  "$root/Tests/release_bundle_signing.sh"
  spaces_profile_eval_shell_env "$root/.build/debug/spaces"
  stop_current_profile_runtime_for_tests
  unset SPACES_DEVICE_API_PORT

  # The iOS lane only drives xcodebuild and its own DerivedData; it never calls swiftpm.sh, so it
  # does not contend with coverage.sh for the SwiftPM exec lock (see swiftpm.sh's acquire_lock).
  # Run it in the background while coverage.sh runs in the foreground so the two independent test
  # lanes overlap instead of adding end to end. The lane's own stdout/stderr go to a log file (not
  # the terminal) so they cannot interleave with coverage.sh's output; the log is tailed once the
  # lane finishes.
  local ios_log="$root/.build/ios-verify.log"
  : >"$ios_log"
  printf 'Starting iOS unit test lane in the background (log: %s)...\n' "$ios_log"
  ( run_ios_lane ) >"$ios_log" 2>&1 &
  ios_lane_pid=$!

  local coverage_status=0
  "$root/scripts/coverage.sh" || coverage_status=$?

  local ios_status=0
  wait "$ios_lane_pid" || ios_status=$?
  ios_lane_pid=""

  printf '\n--- iOS unit test lane log (last 60 lines) ---\n'
  tail -n 60 "$ios_log" || true
  printf -- '--- end iOS unit test lane log ---\n\n'
  if [ "$ios_status" -eq 0 ]; then
    echo "iOS unit test lane: PASSED"
  else
    echo "iOS unit test lane: FAILED (exit $ios_status)"
  fi

  if [ "$coverage_status" -ne 0 ]; then
    exit "$coverage_status"
  fi
  if [ "$ios_status" -ne 0 ]; then
    exit "$ios_status"
  fi
}

cleanup() {
  local exit_code=$?
  spaces_ios_simulator_shutdown_owned "$exit_code"
}

handle_interrupt() {
  if [ -n "$ios_lane_pid" ]; then
    # Force-kill (not just signal) the whole background iOS lane tree, including any still
    # running xcodebuild/watchdog process: this shell may currently be blocked inside a
    # synchronous nested subshell call (e.g. run_with_silence_watchdog), and a plain `kill -TERM`
    # of ios_lane_pid alone would not be noticed until that nested call returns on its own,
    # leaving xcodebuild running past this script's exit. kill_silence_watchdog_process_tree walks
    # descendants by PID, not by process group, so this only touches the iOS lane's own tree and
    # cannot reach coverage.sh's sibling processes under the main verify.sh process. It kills
    # leaf processes (e.g. xcodebuild) first, then its own SIGKILL of ios_lane_pid; because this
    # script runs under `set -e`, a killed child usually makes each enclosing subshell (including
    # run_ios_lane) exit through its own trap chain as soon as it notices, so simulator shutdown
    # below in run_ios_lane still generally runs. It is not guaranteed: the final SIGKILL of
    # ios_lane_pid can race ahead of that propagation, in which case a simulator booted by this
    # lane is left running. That residual gap mirrors any other hard-kill of verify.sh and is left
    # for a future pass if it proves disruptive in practice.
    kill_silence_watchdog_process_tree "$ios_lane_pid"
  fi
  exit 130
}

trap cleanup EXIT
trap handle_interrupt INT TERM

run_verify_steps
