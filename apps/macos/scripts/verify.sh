#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"

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

cd "$root"

"$root/scripts/lint.sh"
"$root/scripts/swiftpm.sh" build
"$root/scripts/coverage.sh"
run_ios_tests
