#!/usr/bin/env bash
set -euo pipefail

# Builds the iOS app, installs it on a connected physical device, and attempts
# to launch it. Device-specific values live in .env so they stay local.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${SPACES_ENV_FILE:-$REPO_ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

IOS_PROJECT="$REPO_ROOT/apps/ios/SpacesMobile.xcodeproj"
SCHEME="${SPACES_IOS_SCHEME:-SpacesMobile}"
CONFIGURATION="${SPACES_IOS_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${SPACES_IOS_DERIVED_DATA_PATH:-$REPO_ROOT/.build/ios-device-derived-data}"
BUNDLE_ID="${SPACES_IOS_BUNDLE_ID:-com.yogeshdhande.spacesmobile}"
SHOULD_LAUNCH="${SPACES_IOS_LAUNCH:-1}"
DEVICE_UDID="${SPACES_IOS_DEVICE_UDID:-}"
DEVELOPMENT_TEAM="${SPACES_IOS_DEVELOPMENT_TEAM:-}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos/SpacesMobile.app"
LOG_DIR="$DERIVED_DATA_PATH/Logs/install-ios-device"

usage() {
  cat <<EOF
Usage: scripts/install-ios-device.sh

Required:
  SPACES_IOS_DEVICE_UDID  Physical iPhone/iPad UDID, usually set in .env

Optional:
  SPACES_ENV_FILE                  Path to an env file (default: .env)
  SPACES_IOS_DEVELOPMENT_TEAM      Xcode development team override
  SPACES_IOS_DERIVED_DATA_PATH     DerivedData path (default: .build/ios-device-derived-data)
  SPACES_IOS_CONFIGURATION         Xcode configuration (default: Debug)
  SPACES_IOS_LAUNCH                1 to launch after install, 0 to skip (default: 1)

Find connected device UDIDs:
  xcrun xctrace list devices
EOF
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Error: required command '$name' was not found in PATH." >&2
    exit 1
  fi
}

require_python() {
  if [[ ! -x /usr/bin/python3 ]]; then
    echo "Error: /usr/bin/python3 is required to parse devicectl device JSON." >&2
    exit 1
  fi
}

run_with_log() {
  local label="$1"
  local log_path="$2"
  shift 2

  mkdir -p "$(dirname "$log_path")"
  echo "$label"
  set +e
  "$@" 2>&1 | tee "$log_path"
  local status=${PIPESTATUS[0]}
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "Log: $log_path" >&2
  fi
  return "$status"
}

print_device_inventory() {
  local json_path="$1"
  /usr/bin/python3 - "$json_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

devices = data.get("result", {}).get("devices", [])
if not devices:
    print("No devices are visible to Xcode.")
    sys.exit(0)

for device in devices:
    properties = device.get("deviceProperties", {})
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    name = properties.get("name", "(unnamed)")
    udid = hardware.get("udid", "(no UDID)")
    identifier = device.get("identifier", "(no CoreDevice identifier)")
    platform = hardware.get("platform", "(unknown platform)")
    reality = hardware.get("reality", "(unknown reality)")
    tunnel = connection.get("tunnelState", "(no tunnel state)")
    pairing = connection.get("pairingState", "(no pairing state)")
    developer_mode = properties.get("developerModeStatus", "(no developer mode state)")
    print(f"- {name}: UDID={udid}, CoreDevice={identifier}, platform={platform}, {reality}, tunnel={tunnel}, pairing={pairing}, Developer Mode={developer_mode}")
PY
}

check_configured_device() {
  local devices_json
  local status_path
  devices_json="$(mktemp "${TMPDIR:-/tmp}/spaces-ios-devices.XXXXXX.json")"
  status_path="$(mktemp "${TMPDIR:-/tmp}/spaces-ios-device-status.XXXXXX")"

  if ! xcrun devicectl list devices --json-output "$devices_json" --quiet; then
    echo "Error: unable to query connected devices with devicectl." >&2
    echo "Check that Xcode is installed, the device is plugged in, trusted, and Developer Mode is enabled." >&2
    rm -f "$devices_json" "$status_path"
    exit 1
  fi

  /usr/bin/python3 - "$devices_json" "$DEVICE_UDID" >"$status_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

needle = sys.argv[2]
devices = data.get("result", {}).get("devices", [])

def device_values(device):
    properties = device.get("deviceProperties", {})
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    values = [
        device.get("identifier", ""),
        hardware.get("udid", ""),
        hardware.get("serialNumber", ""),
        properties.get("name", ""),
    ]
    values.extend(connection.get("localHostnames", []))
    values.extend(connection.get("potentialHostnames", []))
    return {value for value in values if value}

for device in devices:
    if needle not in device_values(device):
        continue
    properties = device.get("deviceProperties", {})
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    fields = [
        "FOUND",
        properties.get("name", ""),
        hardware.get("udid", ""),
        device.get("identifier", ""),
        connection.get("tunnelState", ""),
        connection.get("pairingState", ""),
        properties.get("developerModeStatus", ""),
        properties.get("osVersionNumber", ""),
        hardware.get("marketingName", ""),
    ]
    print("\t".join(fields))
    sys.exit(0)

print("MISSING")
sys.exit(0)
PY

  local status name udid identifier tunnel_state pairing_state developer_mode os_version marketing_name
  IFS=$'\t' read -r status name udid identifier tunnel_state pairing_state developer_mode os_version marketing_name <"$status_path"

  if [[ "$status" != "FOUND" ]]; then
    echo "Error: configured iOS device was not detected: $DEVICE_UDID" >&2
    echo "" >&2
    echo "Connected devices visible to Xcode:" >&2
    print_device_inventory "$devices_json" >&2
    echo "" >&2
    echo "Update SPACES_IOS_DEVICE_UDID in $ENV_FILE, then rerun:" >&2
    echo "  xcrun xctrace list devices" >&2
    echo "  \$EDITOR $ENV_FILE" >&2
    rm -f "$devices_json" "$status_path"
    exit 1
  fi

  if [[ -n "$pairing_state" && "$pairing_state" != "paired" ]]; then
    echo "Error: $name is visible but is not paired with this Mac (pairingState=$pairing_state)." >&2
    echo "Unlock the device, reconnect it, and accept the Trust This Computer prompt." >&2
    rm -f "$devices_json" "$status_path"
    exit 1
  fi

  if [[ -n "$developer_mode" && "$developer_mode" != "enabled" ]]; then
    echo "Error: $name is visible but Developer Mode is not enabled (developerModeStatus=$developer_mode)." >&2
    echo "Enable Developer Mode on the device, let it restart if requested, then rerun this script." >&2
    rm -f "$devices_json" "$status_path"
    exit 1
  fi

  if [[ -n "$tunnel_state" && "$tunnel_state" != "connected" ]]; then
    echo "Error: $name is visible but Xcode does not have an active device tunnel (tunnelState=$tunnel_state)." >&2
    echo "Unlock the device, keep it connected, and rerun this script." >&2
    rm -f "$devices_json" "$status_path"
    exit 1
  fi

  echo "Using $name ($marketing_name, iOS $os_version), UDID $udid, CoreDevice $identifier."
  rm -f "$devices_json" "$status_path"
}

explain_build_failure() {
  local log_path="$1"
  echo "" >&2
  echo "Build failed." >&2
  if grep -Eiq "requires a development team|No signing certificate|No profiles for|Provisioning profile|Signing for .* requires|No Accounts|doesn't include the currently selected device" "$log_path"; then
    echo "This looks like an Xcode signing or provisioning issue." >&2
    echo "Set SPACES_IOS_DEVELOPMENT_TEAM in $ENV_FILE, or open apps/ios/SpacesMobile.xcodeproj and enable automatic signing for the SpacesMobile target." >&2
  elif grep -Eiq "Unable to find a destination|not eligible|not available|device.*not.*found|destination specifier" "$log_path"; then
    echo "Xcode could not use the configured device as a build destination." >&2
    echo "Confirm the device is unlocked, trusted, connected, and listed by xcrun xctrace list devices." >&2
  else
    echo "Review the xcodebuild log above for the compiler or package error." >&2
  fi
  echo "Full log: $log_path" >&2
}

explain_install_failure() {
  local log_path="$1"
  echo "" >&2
  echo "Install failed." >&2
  if grep -Eiq "locked|could not be unlocked|passcode" "$log_path"; then
    echo "The device appears to be locked. Unlock it and rerun the script." >&2
  elif grep -Eiq "Developer Mode|developer mode" "$log_path"; then
    echo "Developer Mode is not available or not enabled on the device." >&2
    echo "Enable Developer Mode on the device and reconnect it." >&2
  elif grep -Eiq "not paired|pairing|Trust This Computer|not trusted" "$log_path"; then
    echo "The device is not trusted or paired with this Mac." >&2
    echo "Unlock the device, reconnect it, and accept the Trust This Computer prompt." >&2
  elif grep -Eiq "No such device|not found|was not found|Unable to locate|device.*unavailable" "$log_path"; then
    echo "The configured device was disconnected or is no longer visible to Xcode." >&2
    echo "Check the cable/Wi-Fi connection and update SPACES_IOS_DEVICE_UDID in $ENV_FILE if the device changed." >&2
  else
    echo "Review the devicectl install log above for the device-side error." >&2
  fi
  echo "Full log: $log_path" >&2
}

explain_launch_failure() {
  local log_path="$1"
  echo "" >&2
  if grep -Eiq "Locked|could not be unlocked|device was not.*unlocked|passcode" "$log_path"; then
    echo "Installed $BUNDLE_ID, but the device is locked so iOS refused to launch it." >&2
    echo "Unlock the device and tap SpacesMobile, or rerun this script after unlocking." >&2
    return 0
  fi

  echo "Installed $BUNDLE_ID, but launch failed." >&2
  if grep -Eiq "not found|No such application|Application.*not.*found" "$log_path"; then
    echo "The bundle identifier was not found on the device. Confirm SPACES_IOS_BUNDLE_ID is $BUNDLE_ID or leave it unset." >&2
  else
    echo "Review the devicectl launch log above for the device-side error." >&2
  fi
  echo "Full log: $log_path" >&2
  return 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "Error: SPACES_IOS_DEVICE_UDID is required. Set it in $ENV_FILE." >&2
  echo "" >&2
  usage >&2
  exit 1
fi

if [[ ! -d "$IOS_PROJECT" ]]; then
  echo "Error: iOS project not found at $IOS_PROJECT" >&2
  exit 1
fi

require_command xcodebuild
require_command xcrun
require_python
check_configured_device

xcodebuild_args=(
  -project "$IOS_PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "id=$DEVICE_UDID"
  -derivedDataPath "$DERIVED_DATA_PATH"
  build
  CODE_SIGN_STYLE=Automatic
)

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  xcodebuild_args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

build_log="$LOG_DIR/xcodebuild.log"
if ! run_with_log "Building $SCHEME ($CONFIGURATION) for device $DEVICE_UDID..." "$build_log" xcodebuild "${xcodebuild_args[@]}"; then
  explain_build_failure "$build_log"
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: built app not found at $APP_PATH" >&2
  echo "Expected xcodebuild output at: $APP_PATH" >&2
  echo "Build log: $build_log" >&2
  exit 1
fi

install_log="$LOG_DIR/devicectl-install.log"
if ! run_with_log "Installing $APP_PATH on device $DEVICE_UDID..." "$install_log" xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"; then
  explain_install_failure "$install_log"
  exit 1
fi

if [[ "$SHOULD_LAUNCH" == "1" ]]; then
  launch_log="$LOG_DIR/devicectl-launch.log"
  if ! run_with_log "Launching $BUNDLE_ID on device $DEVICE_UDID..." "$launch_log" xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID"; then
    if ! explain_launch_failure "$launch_log"; then
      exit 1
    fi
  fi
else
  echo "Skipping launch because SPACES_IOS_LAUNCH=$SHOULD_LAUNCH."
fi
