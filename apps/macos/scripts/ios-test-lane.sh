#!/usr/bin/env bash
set -euo pipefail

# Runs the iOS unit test lane as a standalone process. verify.sh backgrounds this whole script
# (see run_verify_steps in verify.sh) so it can overlap with the SwiftPM/coverage lane in the
# foreground; a CI workflow can equally invoke it as its own job.

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
source "$repo_root/scripts/ios-simulator-lifecycle.sh"
source "$root/scripts/silence-watchdog.sh"

# Builds and coverage export can legitimately produce no output for long stretches. The silence
# watchdog therefore wraps only the already-built SwiftPM and iOS test processes, where a long
# silent interval means a test worker or simulator test launch is hung.
# Override with SPACES_VERIFY_STALL_SECONDS (0 disables, e.g. when attaching a debugger).
verify_stall_seconds="${SPACES_VERIFY_STALL_SECONDS:-600}"

# The iOS build-for-testing phase gets a larger budget than the test phase, but the budget is on
# SILENCE, not duration: a cold xcodebuild is slow yet still prints compile lines throughout, so a
# healthy build never approaches this. It must also stay well under the CI job's own step ceiling,
# or it can never fire first -- a budget larger than the remaining job time just lets the step time
# out with no diagnosis, which is the failure this guards against.
# Override with SPACES_VERIFY_IOS_BUILD_STALL_SECONDS (0 disables).
ios_build_stall_seconds="${SPACES_VERIFY_IOS_BUILD_STALL_SECONDS:-900}"

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

  # Not wrapped in run_with_silence_watchdog: that helper backgrounds its command in a subshell,
  # and spaces_ios_simulator_boot_if_needed's own ownership bookkeeping (it appends the udid it
  # booted to SPACES_OWNED_IOS_SIMULATOR_UDIDS, read later by run_ios_lane's EXIT trap) is a plain
  # bash variable mutation that would not propagate back out of that subshell -- the same
  # propagation hazard documented above run_ios_lane. Losing it would leak a booted simulator on
  # every run, which is worse than an unwrapped hang here.
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
  run_with_silence_watchdog "$ios_build_stall_seconds" xcodebuild "${xcodebuild_args[@]}" build-for-testing
  printf 'Running iOS unit tests on %s...\n' "$destination"
  run_with_silence_watchdog "$verify_stall_seconds" xcodebuild "${xcodebuild_args[@]}" test-without-building
}

# This script's own process is what verify.sh backgrounds (see the `ios-test-lane.sh ... &` call
# in run_verify_steps), so the EXIT trap below runs against this process's own exit -- ordinary
# bash trap semantics, no subshell-vs-bare-background wrinkle to worry about here.
#
# This lane is responsible for shutting down any simulator it booted: its
# SPACES_OWNED_IOS_SIMULATOR_UDIDS state (set by spaces_ios_simulator_boot_if_needed, sourced from
# ios-simulator-lifecycle.sh) lives only in this process and never reaches verify.sh's process, so
# verify.sh's own cleanup() trap and its spaces_ios_simulator_shutdown_owned call cannot see it.
# That top-level call is a no-op for this lane by design; it still covers a simulator booted
# directly by verify.sh's own foreground process, which does not happen today but costs nothing to
# keep symmetric.
run_ios_lane() {
  trap 'spaces_ios_simulator_shutdown_owned "$?"' EXIT
  trap 'exit 130' INT TERM
  run_ios_tests
}

cd "$root"
run_ios_lane
