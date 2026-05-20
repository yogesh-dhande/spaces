#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/terminal_harness_lock.sh"
spaces_app="${SPACES_APP:-$repo_root/apps/macos/.build/debug/SpacesApp}"
spaces_cli="${SPACES_CLI:-$repo_root/apps/macos/.build/debug/spaces}"
spacese2e="${SPACES_E2E:-$repo_root/apps/macos/.build/debug/spacese2e}"
ghostty_xcframework="${SPACES_GHOSTTYKIT_XCFRAMEWORK:-$repo_root/apps/macos/.local/ghosttykit/GhosttyKit.xcframework}"
ghostty_resources="${SPACES_GHOSTTY_RESOURCES_DIR:-$repo_root/apps/macos/.local/ghosttykit/Resources/ghostty}"

pairing_code="${SPACES_MOBILE_DEMO_PAIRING_CODE:-246810}"
bridge_host="${SPACES_MOBILE_DEMO_HOST:-127.0.0.1}"
bridge_port="${SPACES_MOBILE_DEMO_PORT:-47071}"
workspace_title="${SPACES_MOBILE_DEMO_WORKSPACE_TITLE:-Spaces Demo}"
ipad_name="${SPACES_MOBILE_DEMO_IPAD_NAME:-iPad Pro 13-inch (M5)}"
iphone_name="${SPACES_MOBILE_DEMO_IPHONE_NAME:-iPhone 17 Pro}"
bundle_id="com.yogeshdhande.spacesmobile"
keep_root="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
app_path_override="${SPACES_MOBILE_DEMO_APP_PATH:-}"

app_pid=""
bridge_pid=""
temp_root=""
spaces_db_path=""
spaces_runtime_dir=""
project_dir=""
session_id=""
ipad_udid=""
iphone_udid=""
app_log=""
bridge_log=""
ipad_screenshot=""
iphone_screenshot=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$bridge_pid" ]]; then
    kill "$bridge_pid" >/dev/null 2>&1 || true
    wait "$bridge_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ipad_udid" ]]; then
    xcrun simctl terminate "$ipad_udid" "$bundle_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$iphone_udid" ]]; then
    xcrun simctl terminate "$iphone_udid" "$bundle_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$temp_root" && -d "$temp_root" && "$keep_root" != "1" ]]; then
    rm -rf "$temp_root"
  fi
}

handle_interrupt() {
  cleanup
  exit 130
}

trap cleanup EXIT
trap handle_interrupt INT TERM

acquire_terminal_harness_lock

fail_if_existing_spaces_app() {
  local existing
  existing="$(pgrep -x -a SpacesApp || true)"
  if [[ -n "$existing" ]]; then
    echo "Refusing to launch demo while another SpacesApp is running:" >&2
    echo "$existing" >&2
    echo "Quit the existing app and rerun this script." >&2
    exit 1
  fi
}

fail_if_bridge_port_in_use() {
  if lsof -nP -iTCP:"$bridge_port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Refusing to launch demo because port $bridge_port is already in use." >&2
    lsof -nP -iTCP:"$bridge_port" -sTCP:LISTEN >&2 || true
    exit 1
  fi
}

require_executable() {
  local path="$1"
  local label="$2"
  if [[ ! -x "$path" ]]; then
    echo "$label not found at $path" >&2
    exit 1
  fi
}

require_path() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    echo "$label not found at $path" >&2
    exit 1
  fi
}

resolve_ios_app_path() {
  if [[ -n "$app_path_override" ]]; then
    if [[ -d "$app_path_override" ]]; then
      printf '%s\n' "$app_path_override"
      return
    fi
    echo "SpacesMobile.app not found at $app_path_override" >&2
    exit 1
  fi

  python3 - <<'PY'
import os
import pathlib

candidates = sorted(
    pathlib.Path(os.path.expanduser("~/Library/Developer/Xcode/DerivedData")).glob(
        "SpacesMobile-*/Build/Products/Debug-iphonesimulator/SpacesMobile.app"
    ),
    key=lambda path: path.stat().st_mtime,
    reverse=True,
)
if not candidates:
    raise SystemExit("SpacesMobile.app not found in DerivedData. Build it with xcodebuild first.")
print(candidates[0])
PY
}

resolve_device_udid() {
  local name="$1"
  python3 - "$name" <<'PY'
import json
import subprocess
import sys

target_name = sys.argv[1]
payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
matches = []
for runtime_devices in payload.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("name") == target_name and device.get("isAvailable", True):
            matches.append(device["udid"])
if not matches:
    raise SystemExit(f"Simulator not found: {target_name}")
print(matches[0])
PY
}

boot_device() {
  local udid="$1"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
}

open_simulator_app() {
  open -a Simulator >/dev/null 2>&1 || true
}

wait_for_pid() {
  local pid="$1"
  local label="$2"
  local deadline=$((SECONDS + 30))
  while [[ $SECONDS -lt $deadline ]]; do
    if ps -p "$pid" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for $label (pid $pid)." >&2
  exit 1
}

wait_for_bridge_port() {
  python3 - "$bridge_host" "$bridge_port" <<'PY'
import socket
import sys
import time

host = sys.argv[1]
port = int(sys.argv[2])
last_error = None
for _ in range(60):
    try:
        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client.settimeout(1)
        client.connect((host, port))
        client.close()
        raise SystemExit(0)
    except Exception as exc:
        last_error = repr(exc)
        time.sleep(0.5)
raise SystemExit(f"bridge port not ready: {last_error}")
PY
}

discover_session_id() {
  python3 - "$spaces_runtime_dir" "$temp_root" <<'PY'
import pathlib
import sys

runtime_root = pathlib.Path(sys.argv[1])
legacy_root = pathlib.Path(sys.argv[2])
sessions_root = runtime_root / "terminal" / "sessions"
if not sessions_root.exists():
    sessions_root = legacy_root / "terminal" / "sessions"
if not sessions_root.exists():
    print("")
    raise SystemExit(0)
ids = sorted([path.name for path in sessions_root.iterdir() if path.is_dir()])
print(ids[-1] if ids else "")
PY
}

generate_installation_id() {
  python3 - <<'PY'
import uuid
print(str(uuid.uuid4()).upper())
PY
}

pair_devices() {
  local output_path="$1"
  local ipad_installation_id="$2"
  local iphone_installation_id="$3"
  python3 - "$output_path" "$pairing_code" "$bridge_host" "$bridge_port" "$bundle_id" "$ipad_installation_id" "$iphone_installation_id" <<'PY'
import json
import socket
import sys

output_path, pairing_code, host, port_text, bundle_id, ipad_installation_id, iphone_installation_id = sys.argv[1:]
port = int(port_text)

def send(request):
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect((host, port))
    client.sendall(json.dumps(request).encode("utf-8") + b"\n")
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        response.extend(chunk)
    client.close()
    return json.loads(response.decode("utf-8"))

def pair(installation_id, device_name):
    response = send({
        "command": "pair",
        "pairingCode": pairing_code,
        "clientApp": {
            "installationID": installation_id,
            "bundleID": bundle_id,
            "platform": "ios",
            "deviceName": device_name,
            "appVersion": "1.0",
        },
    })
    if not response.get("ok") or not response.get("issuedAuthToken"):
        raise SystemExit(f"pair failed for {device_name}: {response}")
    return response["issuedAuthToken"]

payload = {
    "ipad": {
        "installationID": ipad_installation_id,
        "authToken": pair(ipad_installation_id, "iPad Pro 13-inch (M5)"),
    },
    "iphone": {
        "installationID": iphone_installation_id,
        "authToken": pair(iphone_installation_id, "iPhone 17 Pro"),
    },
}
with open(output_path, "w") as handle:
    json.dump(payload, handle)
PY
}

write_simulator_settings() {
  local udid="$1"
  local installation_id="$2"
  local auth_token="$3"
  local ios_app_path="$4"

  xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$ios_app_path" >/dev/null

  python3 - "$udid" "$bundle_id" "$bridge_host" "$bridge_port" "$installation_id" "$auth_token" <<'PY'
import json
import pathlib
import plistlib
import subprocess
import sys

udid, bundle_id, host, port_text, installation_id, auth_token = sys.argv[1:]
port = int(port_text)
container = subprocess.check_output(["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"], text=True).strip()
prefs_path = pathlib.Path(container) / "Library" / "Preferences" / f"{bundle_id}.plist"
prefs_path.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "host": host,
    "port": port,
    "authToken": auth_token,
    "installationID": installation_id,
}
encoded = json.dumps(payload).encode("utf-8")
prefs = {}
if prefs_path.exists():
    with prefs_path.open("rb") as handle:
        prefs = plistlib.load(handle)
prefs["spaces.mobile.connection-settings"] = encoded
with prefs_path.open("wb") as handle:
    plistlib.dump(prefs, handle, fmt=plistlib.FMT_BINARY)
PY
}

print_summary() {
  python3 - "$temp_root" "$app_pid" "$bridge_pid" "$session_id" "$spaces_db_path" "$project_dir" "$app_log" "$bridge_log" "$ipad_screenshot" "$iphone_screenshot" "$ipad_udid" "$iphone_udid" "$bridge_host" "$bridge_port" "$workspace_title" <<'PY'
import json
import sys

(
    root,
    app_pid,
    bridge_pid,
    session_id,
    db_path,
    project_dir,
    app_log,
    bridge_log,
    ipad_screenshot,
    iphone_screenshot,
    ipad_udid,
    iphone_udid,
    bridge_host,
    bridge_port,
    workspace_title,
) = sys.argv[1:]
print(json.dumps({
    "root": root,
    "appPID": int(app_pid),
    "bridgePID": int(bridge_pid),
    "bridgeHost": bridge_host,
    "bridgePort": int(bridge_port),
    "sessionID": session_id,
    "workspaceTitle": workspace_title,
    "dbPath": db_path,
    "projectDir": project_dir,
    "appLog": app_log,
    "bridgeLog": bridge_log,
    "ipadSimulatorUDID": ipad_udid,
    "iphoneSimulatorUDID": iphone_udid,
    "ipadScreenshot": ipad_screenshot,
    "iphoneScreenshot": iphone_screenshot,
}, indent=2))
PY
}

require_executable "$spaces_app" "SpacesApp"
require_executable "$spaces_cli" "spaces CLI"
require_executable "$spacese2e" "spacese2e"
require_path "$ghostty_xcframework" "GhosttyKit.xcframework"
require_path "$ghostty_resources" "Ghostty resources"
fail_if_existing_spaces_app
fail_if_bridge_port_in_use

ios_app_path="$(resolve_ios_app_path)"
require_path "$ios_app_path" "SpacesMobile.app"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/spaces-mobile-demo.XXXXXX")"
spaces_db_path="$temp_root/spaces.db"
spaces_runtime_dir="$temp_root/runtime"
project_dir="$temp_root/project"
app_log="$temp_root/app.log"
bridge_log="$temp_root/bridge.log"
ipad_screenshot="$temp_root/ipad.png"
iphone_screenshot="$temp_root/iphone.png"
mkdir -p "$spaces_runtime_dir" "$project_dir" "$temp_root/home"

ipad_udid="$(resolve_device_udid "$ipad_name")"
iphone_udid="$(resolve_device_udid "$iphone_name")"
open_simulator_app
boot_device "$ipad_udid"
boot_device "$iphone_udid"

(
  cd "$project_dir"
  git init -q -b main
  printf '# Spaces Demo\n\nFresh demo repo.\n' > README.md
  mkdir -p src
  printf 'print("hello demo")\n' > src/demo.py
  git add README.md src/demo.py
  GIT_AUTHOR_NAME=Codex GIT_AUTHOR_EMAIL=codex@example.com \
    GIT_COMMITTER_NAME=Codex GIT_COMMITTER_EMAIL=codex@example.com \
    git commit -q -m 'Initial demo repo'
)

env \
  HOME="$temp_root/home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACES_GHOSTTYKIT_XCFRAMEWORK="$ghostty_xcframework" \
  SPACES_GHOSTTY_RESOURCES_DIR="$ghostty_resources" \
  "$spaces_app" >"$app_log" 2>&1 &
app_pid=$!
wait_for_pid "$app_pid" "SpacesApp"

env \
  HOME="$temp_root/home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACES_PROJECT_DIR="$repo_root" \
  "$spacese2e" seed-fixture \
    --project-dir "$project_dir" \
    --docs-url "http://127.0.0.1:20001" \
    --admin-url "http://127.0.0.1:20002" \
    --workspace-title "$workspace_title" >/dev/null

env \
  HOME="$temp_root/home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  "$spacese2e" open-workspace-terminal --workspace-dir "$project_dir" >/dev/null

for _ in $(seq 1 60); do
  session_id="$(discover_session_id)"
  if [[ -n "$session_id" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$session_id" ]]; then
  echo "Failed to discover terminal session." >&2
  exit 1
fi

env \
  HOME="$temp_root/home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  "$spaces_cli" mobile serve --host "$bridge_host" --port "$bridge_port" --pairing-code "$pairing_code" >"$bridge_log" 2>&1 &
bridge_pid=$!
wait_for_bridge_port

ipad_installation_id="$(generate_installation_id)"
iphone_installation_id="$(generate_installation_id)"
pairing_json="$temp_root/pairing.json"
pair_devices "$pairing_json" "$ipad_installation_id" "$iphone_installation_id"

ipad_token="$(python3 - "$pairing_json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["ipad"]["authToken"])
PY
)"
iphone_token="$(python3 - "$pairing_json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["iphone"]["authToken"])
PY
)"

write_simulator_settings "$ipad_udid" "$ipad_installation_id" "$ipad_token" "$ios_app_path"
write_simulator_settings "$iphone_udid" "$iphone_installation_id" "$iphone_token" "$ios_app_path"

xcrun simctl launch "$ipad_udid" "$bundle_id" >/dev/null
xcrun simctl launch "$iphone_udid" "$bundle_id" >/dev/null
sleep 4
xcrun simctl io "$ipad_udid" screenshot "$ipad_screenshot" >/dev/null
xcrun simctl io "$iphone_udid" screenshot "$iphone_screenshot" >/dev/null

print_summary
echo
echo "Demo is live. Press Ctrl+C to stop it."
echo "Mac app: $spaces_app"
echo "iPad simulator: $ipad_name"
echo "iPhone simulator: $iphone_name"

while true; do
  if ! ps -p "$app_pid" >/dev/null 2>&1; then
    echo "SpacesApp exited. Cleaning up demo." >&2
    exit 0
  fi
  if ! ps -p "$bridge_pid" >/dev/null 2>&1; then
    echo "Mobile bridge exited. Cleaning up demo." >&2
    exit 0
  fi
  sleep 1
done
