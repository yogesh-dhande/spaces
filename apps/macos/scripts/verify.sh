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
  "$root/scripts/swiftpm.sh" build
  "$root/Tests/release_bundle_signing.sh"
  spaces_profile_eval_shell_env "$root/.build/debug/spaces"
  stop_current_profile_runtime_for_tests
  unset SPACES_DEVICE_API_PORT
  "$root/scripts/coverage.sh"
  run_ios_tests
}

cleanup() {
  local exit_code=$?
  spaces_ios_simulator_shutdown_owned "$exit_code"
}

handle_interrupt() {
  exit 130
}

trap cleanup EXIT
trap handle_interrupt INT TERM

run_verify_steps
