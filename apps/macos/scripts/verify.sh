#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
source "$repo_root/scripts/spaces-profile-helpers.sh"

# A healthy full verify (build + SwiftPM coverage + iOS tests) completes well under this
# ceiling; a run that exceeds it is hung — typically a flaky test that deadlocks under the
# parallel coverage run — and must fail fast instead of blocking a commit indefinitely.
# Override with SPACES_VERIFY_TIMEOUT_SECONDS (0 disables, e.g. when attaching a debugger).
# The watchdog is armed at the end of this script; see run_verify_steps below.
verify_timeout_seconds="${SPACES_VERIFY_TIMEOUT_SECONDS:-900}"

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

ios_test_destination() {
  if [ -n "${SPACES_IOS_TEST_DESTINATION:-}" ]; then
    printf '%s\n' "$SPACES_IOS_TEST_DESTINATION"
    return
  fi

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
                print("platform=iOS Simulator,id={}".format(device.get("udid")))
                raise SystemExit(0)
    if candidates:
        print("platform=iOS Simulator,id={}".format(candidates[0].get("udid")))
        raise SystemExit(0)

raise SystemExit("No available iPhone simulator found for iOS tests.")
'
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

if [ "$verify_timeout_seconds" -le 0 ]; then
  run_verify_steps
  exit 0
fi

# Run the real work as a child so the watchdog — a sibling of that child, not part of its
# process tree — can force-kill the whole tree (swift-test/xcodebuild workers included) on
# timeout without needing to identify or exclude itself. A SIGKILLed child makes `wait`
# return non-zero, so the run exits with a failing status that aborts the commit.
run_verify_steps &
verify_work_pid=$!

(
  sleep "$verify_timeout_seconds"
  echo "verify.sh: exceeded ${verify_timeout_seconds}s ceiling; killing the run (likely a hung/flaky test)." >&2
  kill_process_tree "$verify_work_pid"
) &
verify_watchdog_pid=$!

# On interrupt, tear down both children so no orphaned build/test processes linger.
trap 'kill_process_tree "$verify_work_pid" 2>/dev/null; kill "$verify_watchdog_pid" 2>/dev/null || true' INT TERM

verify_status=0
wait "$verify_work_pid" || verify_status=$?

# Work finished (cleanly or via the watchdog's kill): stop the now-idle watchdog.
kill "$verify_watchdog_pid" 2>/dev/null || true
wait "$verify_watchdog_pid" 2>/dev/null || true

exit "$verify_status"
