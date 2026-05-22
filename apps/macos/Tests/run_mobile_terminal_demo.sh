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
bridge_host="${SPACES_MOBILE_DEMO_HOST:-0.0.0.0}"
bridge_port="${SPACES_MOBILE_DEMO_PORT:-47071}"
workspace_title="${SPACES_MOBILE_DEMO_WORKSPACE_TITLE:-Spaces Demo}"
ipad_name="${SPACES_MOBILE_DEMO_IPAD_NAME:-iPad Pro 13-inch (M5)}"
iphone_name="${SPACES_MOBILE_DEMO_IPHONE_NAME:-iPhone 17 Pro}"
bundle_id="com.yogeshdhande.spacesmobile"
keep_root="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
app_path_override="${SPACES_MOBILE_DEMO_APP_PATH:-}"
demo_trace="${SPACES_MOBILE_DEMO_TRACE:-1}"

app_pid=""
bridge_pid=""
temp_root=""
spaces_db_path=""
spaces_runtime_dir=""
project_dir=""
session_id=""
secondary_session_id=""
ipad_udid=""
iphone_udid=""
app_log=""
bridge_log=""
ipad_screenshot=""
iphone_screenshot=""
ios_app_path=""
ios_build_log=""
ios_derived_data=""
ipad_app_stdout_log=""
ipad_app_stderr_log=""
iphone_app_stdout_log=""
iphone_app_stderr_log=""
manual_shell_path=""
ipad_launch_pid=""
iphone_launch_pid=""
performance_log_path=""

run_demo_env() {
  env \
    -u NO_COLOR \
    -u CLICOLOR \
    -u CLICOLOR_FORCE \
    -u CI \
    -u CODEX_CI \
    -u CODEX_MANAGED_BY_NPM \
    -u CODEX_MANAGED_PACKAGE_ROOT \
    -u CODEX_THREAD_ID \
    "$@"
}

stop_demo_workspace() {
  if [[ -z "$project_dir" || -z "$spaces_db_path" || -z "$spaces_runtime_dir" ]]; then
    return
  fi
  if [[ ! -e "$spaces_db_path" ]]; then
    return
  fi

  run_demo_env \
    HOME="$temp_root/home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    "$spacese2e" stop-workspace --workspace-dir "$project_dir" >/dev/null 2>&1 || true
}

cleanup() {
  stop_demo_workspace
  if [[ -n "$bridge_pid" ]]; then
    kill "$bridge_pid" >/dev/null 2>&1 || true
    wait "$bridge_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ipad_launch_pid" ]]; then
    kill "$ipad_launch_pid" >/dev/null 2>&1 || true
    wait "$ipad_launch_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$iphone_launch_pid" ]]; then
    kill "$iphone_launch_pid" >/dev/null 2>&1 || true
    wait "$iphone_launch_pid" >/dev/null 2>&1 || true
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
  release_terminal_harness_lock
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
  local built_app_path="${1:-}"
  if [[ -n "$app_path_override" ]]; then
    if [[ -d "$app_path_override" ]]; then
      printf '%s\n' "$app_path_override"
      return
    fi
    echo "SpacesMobile.app not found at $app_path_override" >&2
    exit 1
  fi

  if [[ -n "$built_app_path" && -d "$built_app_path" ]]; then
    printf '%s\n' "$built_app_path"
    return
  fi

  if [[ -n "$built_app_path" ]]; then
    echo "SpacesMobile.app not found at $built_app_path after xcodebuild." >&2
    exit 1
  fi

  echo "SpacesMobile.app path was not provided." >&2
  exit 1
}

build_ios_app() {
  local derived_data_path="$1"
  local build_log_path="$2"
  local destination_udid="$3"

  if [[ -n "$app_path_override" ]]; then
    return
  fi

  if ! xcodebuild \
    -project "$repo_root/apps/ios/SpacesMobile.xcodeproj" \
    -scheme SpacesMobile \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$destination_udid" \
    -derivedDataPath "$derived_data_path" \
    build >"$build_log_path" 2>&1; then
    keep_root=1
    echo "Failed to build SpacesMobile.app for the iPad and iPhone simulators." >&2
    echo "Build log: $build_log_path" >&2
    exit 1
  fi
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

launch_simulator_app() {
  local udid="$1"
  local stdout_log="$2"
  local stderr_log="$3"

  env SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_TRACE="$demo_trace" \
    SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$performance_log_path" \
    xcrun simctl launch --console-pty "$udid" "$bundle_id" \
    >"$stdout_log" 2>"$stderr_log" </dev/null &
  echo $!
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

discover_session_ids() {
  python3 - "$spaces_runtime_dir" "$temp_root" <<'PY'
import pathlib
import sys

runtime_root = pathlib.Path(sys.argv[1])
legacy_root = pathlib.Path(sys.argv[2])
sessions_root = runtime_root / "terminal" / "sessions"
if not sessions_root.exists():
    sessions_root = legacy_root / "terminal" / "sessions"
if not sessions_root.exists():
    raise SystemExit(0)
ids = sorted([path.name for path in sessions_root.iterdir() if path.is_dir()])
for session_id in ids:
    print(session_id)
PY
}

load_discovered_session_ids() {
  discovered_session_ids=()
  while IFS= read -r discovered_session_id; do
    if [[ -n "$discovered_session_id" ]]; then
      discovered_session_ids+=("$discovered_session_id")
    fi
  done < <(discover_session_ids)
}

discover_workspace_running_state() {
  local workspace_id="$1"
  python3 - "$spaces_db_path" "$workspace_id" <<'PY'
import sqlite3
import sys

db_path, workspace_id = sys.argv[1:]
connection = sqlite3.connect(db_path)
try:
    row = connection.execute("select is_running from workspaces where id = ?", (workspace_id,)).fetchone()
finally:
    connection.close()
print("" if row is None else row[0])
PY
}

open_demo_workspace_terminal() {
  run_demo_env \
    HOME="$temp_root/home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    "$spacese2e" open-workspace-terminal --workspace-dir "$project_dir"
}

extract_workspace_id() {
  python3 - "$1" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(payload.get("id", ""))
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
  python3 - "$temp_root" "$app_pid" "$bridge_pid" "$session_id" "$secondary_session_id" "$spaces_db_path" "$project_dir" "$app_log" "$bridge_log" "$performance_log_path" "$ipad_screenshot" "$iphone_screenshot" "$ipad_udid" "$iphone_udid" "$bridge_host" "$bridge_port" "$workspace_title" "$ios_app_path" "$ios_build_log" "$ios_derived_data" "$ipad_app_stdout_log" "$ipad_app_stderr_log" "$iphone_app_stdout_log" "$iphone_app_stderr_log" <<'PY'
import json
import sys

(
    root,
    app_pid,
    bridge_pid,
    session_id,
    secondary_session_id,
    db_path,
    project_dir,
    app_log,
    bridge_log,
    performance_log_path,
    ipad_screenshot,
    iphone_screenshot,
    ipad_udid,
    iphone_udid,
    bridge_host,
    bridge_port,
    workspace_title,
    ios_app_path,
    ios_build_log,
    ios_derived_data,
    ipad_app_stdout_log,
    ipad_app_stderr_log,
    iphone_app_stdout_log,
    iphone_app_stderr_log,
) = sys.argv[1:]
payload = {
    "root": root,
    "appPID": int(app_pid),
    "bridgePID": int(bridge_pid),
    "bridgeHost": bridge_host,
    "bridgePort": int(bridge_port),
    "sessionID": session_id,
    "secondarySessionID": secondary_session_id or None,
    "sessionIDs": [value for value in (session_id, secondary_session_id) if value],
    "workspaceTitle": workspace_title,
    "dbPath": db_path,
    "projectDir": project_dir,
    "appLog": app_log,
    "bridgeLog": bridge_log,
    "performanceLogPath": performance_log_path,
    "iosAppPath": ios_app_path,
    "ipadSimulatorUDID": ipad_udid,
    "iphoneSimulatorUDID": iphone_udid,
    "ipadScreenshot": ipad_screenshot,
    "iphoneScreenshot": iphone_screenshot,
    "ipadAppStdoutLog": ipad_app_stdout_log,
    "ipadAppStderrLog": ipad_app_stderr_log,
    "iphoneAppStdoutLog": iphone_app_stdout_log,
    "iphoneAppStderrLog": iphone_app_stderr_log,
}
if ios_build_log:
    payload["iosBuildLog"] = ios_build_log
if ios_derived_data:
    payload["iosDerivedDataPath"] = ios_derived_data
print(json.dumps(payload, indent=2))
PY
}

write_manual_shell_helper() {
  manual_shell_path="$temp_root/manual-demo-env.sh"
  cat >"$manual_shell_path" <<EOF
#!/usr/bin/env bash
export HOME=$(printf '%q' "$temp_root/home")
export SPACES_DB_PATH=$(printf '%q' "$spaces_db_path")
export SPACES_RUNTIME_DIR=$(printf '%q' "$spaces_runtime_dir")
export SPACES_DEMO_ROOT=$(printf '%q' "$temp_root")
export SPACES_DEMO_SESSION_ID=$(printf '%q' "$session_id")
export SPACES_DEMO_SECONDARY_SESSION_ID=$(printf '%q' "$secondary_session_id")
export SPACES_DEMO_PROJECT_DIR=$(printf '%q' "$project_dir")
export SPACES_DEMO_IPAD_UDID=$(printf '%q' "$ipad_udid")
export SPACES_DEMO_IPHONE_UDID=$(printf '%q' "$iphone_udid")
export SPACES_CLI=$(printf '%q' "$spaces_cli")
export SPACES_E2E=$(printf '%q' "$spacese2e")
export SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH=$(printf '%q' "$performance_log_path")

spaces_demo_list() {
  "\$SPACES_CLI" terminal list
}

spaces_demo_tail() {
  "\$SPACES_CLI" terminal tail "\$SPACES_DEMO_SESSION_ID"
}

spaces_demo_tail_secondary() {
  "\$SPACES_CLI" terminal tail "\$SPACES_DEMO_SECONDARY_SESSION_ID"
}

spaces_demo_send() {
  "\$SPACES_CLI" terminal send "\$SPACES_DEMO_SESSION_ID" "\$@"
}

spaces_demo_send_secondary() {
  "\$SPACES_CLI" terminal send "\$SPACES_DEMO_SECONDARY_SESSION_ID" "\$@"
}

spaces_demo_sendline() {
  "\$SPACES_CLI" terminal send "\$SPACES_DEMO_SESSION_ID" "\$1" --newline
}

spaces_demo_sendline_secondary() {
  "\$SPACES_CLI" terminal send "\$SPACES_DEMO_SECONDARY_SESSION_ID" "\$1" --newline
}

spaces_demo_enter() {
  "\$SPACES_CLI" terminal key "\$SPACES_DEMO_SESSION_ID" enter
}

spaces_demo_mac_takeover() {
  "\$SPACES_CLI" terminal show "\$SPACES_DEMO_SESSION_ID"
}

spaces_demo_reopen() {
  "\$SPACES_E2E" open-workspace-terminal --workspace-dir "\$SPACES_DEMO_PROJECT_DIR"
}

spaces_demo_tail_mac_log() {
  tail -f "\$SPACES_DEMO_ROOT/app.log"
}

spaces_demo_tail_bridge_log() {
  tail -f "\$SPACES_DEMO_ROOT/bridge.log"
}

spaces_demo_tail_ipad_stderr() {
  tail -f "\$SPACES_DEMO_ROOT/ipad-app.stderr.log"
}
EOF
  chmod +x "$manual_shell_path"
}

require_executable "$spaces_app" "SpacesApp"
require_executable "$spaces_cli" "spaces CLI"
require_executable "$spacese2e" "spacese2e"
require_path "$ghostty_xcframework" "GhosttyKit.xcframework"
require_path "$ghostty_resources" "Ghostty resources"
fail_if_existing_spaces_app
fail_if_bridge_port_in_use

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/spaces-mobile-demo.XXXXXX")"
spaces_db_path="$temp_root/spaces.db"
spaces_runtime_dir="$temp_root/runtime"
project_dir="$temp_root/project"
app_log="$temp_root/app.log"
bridge_log="$temp_root/bridge.log"
performance_log_path="$temp_root/mobile-terminal-performance.jsonl"
ipad_screenshot="$temp_root/ipad.png"
iphone_screenshot="$temp_root/iphone.png"
ipad_app_stdout_log="$temp_root/ipad-app.stdout.log"
ipad_app_stderr_log="$temp_root/ipad-app.stderr.log"
iphone_app_stdout_log="$temp_root/iphone-app.stdout.log"
iphone_app_stderr_log="$temp_root/iphone-app.stderr.log"
mkdir -p "$spaces_runtime_dir" "$project_dir" "$temp_root/home"

ipad_udid="$(resolve_device_udid "$ipad_name")"
iphone_udid="$(resolve_device_udid "$iphone_name")"

if [[ -n "$app_path_override" ]]; then
  ios_app_path="$(resolve_ios_app_path)"
else
  ios_build_log="$temp_root/ios-build.log"
  ios_derived_data="$temp_root/ios-derived-data"
  mkdir -p "$ios_derived_data"
  build_ios_app "$ios_derived_data" "$ios_build_log" "$ipad_udid"
  ios_app_path="$(resolve_ios_app_path "$ios_derived_data/Build/Products/Debug-iphonesimulator/SpacesMobile.app")"
fi

require_path "$ios_app_path" "SpacesMobile.app"
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

run_demo_env \
  HOME="$temp_root/home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACES_GHOSTTYKIT_XCFRAMEWORK="$ghostty_xcframework" \
  SPACES_GHOSTTY_RESOURCES_DIR="$ghostty_resources" \
  SPACES_MOBILE_TERMINAL_TRACE="$demo_trace" \
  SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$performance_log_path" \
  "$spaces_app" >"$app_log" 2>&1 &
app_pid=$!
wait_for_pid "$app_pid" "SpacesApp"

run_demo_env \
  HOME="$temp_root/home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACES_PROJECT_DIR="$repo_root" \
  "$spacese2e" seed-fixture \
    --project-dir "$project_dir" \
    --docs-url "http://127.0.0.1:20001" \
    --admin-url "http://127.0.0.1:20002" \
    --workspace-title "$workspace_title" >/dev/null

workspace_open_payload="$(open_demo_workspace_terminal)"
workspace_id="$(extract_workspace_id "$workspace_open_payload")"
discovered_session_ids=()
for attempt in $(seq 1 3); do
  for _ in $(seq 1 20); do
    load_discovered_session_ids
    if [[ ${#discovered_session_ids[@]} -ge 1 ]]; then
      session_id="${discovered_session_ids[0]}"
      break 2
    fi
    if [[ -n "$workspace_id" ]] && [[ "$(discover_workspace_running_state "$workspace_id")" == "1" ]]; then
      sleep 1
      continue
    fi
    sleep 1
  done
  if [[ "$attempt" -lt 3 ]]; then
    workspace_open_payload="$(open_demo_workspace_terminal)"
    workspace_id="$(extract_workspace_id "$workspace_open_payload")"
  fi
done

if [[ -z "$session_id" ]]; then
  echo "Failed to discover the primary terminal session." >&2
  exit 1
fi

for attempt in $(seq 1 3); do
  workspace_open_payload="$(open_demo_workspace_terminal)"
  workspace_id="$(extract_workspace_id "$workspace_open_payload")"
  for _ in $(seq 1 20); do
    load_discovered_session_ids
    if [[ ${#discovered_session_ids[@]} -ge 2 ]]; then
      for candidate_session_id in "${discovered_session_ids[@]}"; do
        if [[ "$candidate_session_id" != "$session_id" ]]; then
          secondary_session_id="$candidate_session_id"
          break
        fi
      done
      if [[ -n "$secondary_session_id" ]]; then
        break 2
      fi
    fi
    if [[ -n "$workspace_id" ]] && [[ "$(discover_workspace_running_state "$workspace_id")" == "1" ]]; then
      sleep 1
      continue
    fi
    sleep 1
  done
done

if [[ -z "$secondary_session_id" ]]; then
  echo "Failed to discover the secondary terminal session." >&2
  exit 1
fi

run_demo_env \
  HOME="$temp_root/home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACES_MOBILE_BRIDGE_TRACE="$demo_trace" \
  SPACES_MOBILE_TERMINAL_TRACE="$demo_trace" \
  SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$performance_log_path" \
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

ipad_launch_pid="$(launch_simulator_app "$ipad_udid" "$ipad_app_stdout_log" "$ipad_app_stderr_log")"
iphone_launch_pid="$(launch_simulator_app "$iphone_udid" "$iphone_app_stdout_log" "$iphone_app_stderr_log")"
sleep 4
xcrun simctl io "$ipad_udid" screenshot "$ipad_screenshot" >/dev/null
xcrun simctl io "$iphone_udid" screenshot "$iphone_screenshot" >/dev/null

write_manual_shell_helper
print_summary
echo
echo "Demo is live. Press Ctrl+C to stop it."
echo "Mac app: $spaces_app"
echo "iPad simulator: $ipad_name"
echo "iPhone simulator: $iphone_name"
printf -v demo_env_prefix 'HOME=%q SPACES_DB_PATH=%q SPACES_RUNTIME_DIR=%q' "$temp_root/home" "$spaces_db_path" "$spaces_runtime_dir"
echo "Manual demo env: $demo_env_prefix"
echo "Helper shell: source $manual_shell_path"
printf 'List sessions: %s %q terminal list\n' "$demo_env_prefix" "$spaces_cli"
printf 'Mac retakeover: %s %q terminal show %q\n' "$demo_env_prefix" "$spaces_cli" "$session_id"
printf 'Secondary session tail: %s %q terminal tail %q\n' "$demo_env_prefix" "$spaces_cli" "$secondary_session_id"
printf 'Workspace terminal reopen: %s %q open-workspace-terminal --workspace-dir %q\n' "$demo_env_prefix" "$spacese2e" "$project_dir"
echo "Helper commands after sourcing:"
echo "  spaces_demo_list"
echo "  spaces_demo_tail"
echo "  spaces_demo_tail_secondary"
echo "  spaces_demo_sendline 'pwd'"
echo "  spaces_demo_sendline_secondary 'pwd'"
echo "  spaces_demo_mac_takeover"
echo "  spaces_demo_reopen"
echo "  spaces_demo_tail_mac_log"
echo "  spaces_demo_tail_bridge_log"
echo "  spaces_demo_tail_ipad_stderr"

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
