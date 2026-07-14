#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
source "$repo_root/scripts/spaces-profile-helpers.sh"
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
  local -a xcodebuild_args
  ios_root="$repo_root/apps/ios"
  ios_derived_data="${SPACES_IOS_DERIVED_DATA:-$root/.build/ios-derived-data}"
  destination="$(ios_test_destination)"
  xcodebuild_args=(
    -project "$ios_root/SpacesMobile.xcodeproj"
    -scheme SpacesMobile
    -configuration Debug
    -destination "$destination"
    -derivedDataPath "$ios_derived_data"
    -only-testing:SpacesMobileTests
    -skip-testing:SpacesMobileUITests
  )

  rm -rf "$ios_derived_data"
  unset $(git rev-parse --local-env-vars)
  printf 'Building iOS unit tests for %s...\n' "$destination"
  xcodebuild "${xcodebuild_args[@]}" build-for-testing
  printf 'Running iOS unit tests on %s...\n' "$destination"
  run_with_silence_watchdog "$verify_stall_seconds" xcodebuild "${xcodebuild_args[@]}" test-without-building
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

  "$root/Tests/silence_watchdog.sh"
  "$root/Tests/setup_ghostty_xcode_mismatch_autobuild.sh"
  "$root/Tests/setup_ghostty_cache_restore.sh"
  "$root/scripts/lint.sh"
  "$root/scripts/swiftpm.sh" build
  "$root/Tests/release_bundle_signing.sh"
  spaces_profile_eval_shell_env "$root/.build/debug/spaces"
  stop_current_profile_runtime_for_tests
  unset SPACES_DEVICE_API_PORT
  "$root/scripts/coverage.sh"
  run_ios_tests
}

run_verify_steps
