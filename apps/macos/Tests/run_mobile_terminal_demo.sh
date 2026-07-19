#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$repo_root/scripts/spaces-e2e-env.sh"
spaces_e2e_load_env "$repo_root"
source "$script_dir/terminal_harness_lock.sh"
source "$script_dir/e2e_fixture_repos.sh"
source "$repo_root/scripts/spaces-profile-helpers.sh"
source "$repo_root/scripts/ios-simulator-lifecycle.sh"
spaces_app="${SPACES_APP:-$repo_root/apps/macos/.build/debug/SpacesApp}"
spaces_cli="${SPACES_CLI:-$repo_root/apps/macos/.build/debug/spaces}"
spacese2e="${SPACES_E2E:-$repo_root/apps/macos/.build/debug/spacese2e}"
terminal_service="${SPACESD_EXECUTABLE:-$repo_root/apps/macos/.build/debug/spacesd}"
ghostty_xcframework="${SPACES_GHOSTTYKIT_XCFRAMEWORK:-$repo_root/apps/macos/.local/ghosttykit/GhosttyKit.xcframework}"
ghostty_resources="${SPACES_GHOSTTY_RESOURCES_DIR:-$repo_root/apps/macos/.local/ghosttykit/Resources/ghostty}"
fixture_template_dir="$repo_root/apps/macos/Tests/fixtures/e2e_demo"
user_home="${HOME:?}"
source_xdg_config_home="${SPACES_MOBILE_GHOSTTY_XDG_CONFIG_HOME:-${XDG_CONFIG_HOME:-$user_home/.config}}"
profile_mode="${SPACES_MOBILE_DEMO_PROFILE_MODE:-isolated}"
demo_root_parent="${SPACES_MOBILE_DEMO_ROOT_PARENT:-$user_home/.spaces-dev/mobile-demo}"

device_api_bind_host="${SPACES_MOBILE_DEMO_BIND_HOST:-0.0.0.0}"
device_api_host="${SPACES_MOBILE_DEMO_HOST:-127.0.0.1}"
device_api_port="${SPACES_MOBILE_DEMO_PORT:-47847}"
remote_ssh_host="${SPACES_E2E_REMOTE_SSH_HOST:-}"
remote_ssh_user="${SPACES_E2E_REMOTE_SSH_USER:-}"
remote_ssh_port="${SPACES_E2E_REMOTE_SSH_PORT:-}"
remote_demo_daemon_port="${SPACES_E2E_REMOTE_DAEMON_PORT:-47847}"
remote_demo_device_root="${SPACES_E2E_REMOTE_DEVICE_ROOT:-~/.spaces/remote-device-e2e}"
remote_demo_workspace_root="${SPACES_E2E_REMOTE_WORKSPACE_ROOT:-~/.spaces/e2e-workspaces}"
if [[ "${SPACES_E2E_RUN_REMOTE:-0}" == "1" ]]; then
  spaces_e2e_require_remote_host_env "$repo_root"
  remote_ssh_host="${SPACES_E2E_REMOTE_SSH_HOST:-}"
  remote_ssh_user="${SPACES_E2E_REMOTE_SSH_USER:-}"
  remote_ssh_port="${SPACES_E2E_REMOTE_SSH_PORT:-}"
fi
remote_pairing_json=""
remote_pairing_window_json=""
pairing_link=""
pairing_code=""
pairing_nonce=""
certificate_fingerprint=""
remote_pairing_link=""
remote_certificate_fingerprint=""
remote_forward_pid=""
remote_forward_host="127.0.0.1"
remote_forward_port=""
remote_project_dir=""
remote_workspace_id=""
workspace_title="${SPACES_MOBILE_DEMO_WORKSPACE_TITLE:-Local Demo}"
secondary_workspace_title="${SPACES_MOBILE_DEMO_SECONDARY_WORKSPACE_TITLE:-Secondary Demo}"
ipad_name="${SPACES_MOBILE_DEMO_IPAD_NAME:-iPad Pro 13-inch (M5)}"
iphone_name="${SPACES_MOBILE_DEMO_IPHONE_NAME:-iPhone 17 Pro}"
bundle_id="dev.usespaces.spacesmobile"
keep_root="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
app_path_override="${SPACES_MOBILE_DEMO_APP_PATH:-}"
demo_trace="${SPACES_MOBILE_DEMO_TRACE:-1}"
build_macos="${SPACES_MOBILE_DEMO_BUILD_MACOS:-1}"
app_pid=""
device_api_pid=""
temp_root=""
spaces_db_path=""
spaces_runtime_dir=""
spaces_client_db_path=""
spaces_client_secret_dir=""
project_dir=""
local_project_dir=""
secondary_project_dir=""
session_id=""
local_session_id=""
secondary_session_id=""
ipad_udid=""
iphone_udid=""
app_log=""
device_api_log=""
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
remote_device_id=""
remote_device_name=""
remote_device_host=""
remote_device_port=""
ipad_launch_pid=""
iphone_launch_pid=""
terminal_service_pid=""
performance_log_path=""
ghostty_demo_xdg_config_home=""
demo_home=""

run_demo_env() {
  local -a env_args=(
    -u NO_COLOR \
    -u CLICOLOR \
    -u CLICOLOR_FORCE \
    -u CI \
    -u CODEX_CI \
    -u CODEX_MANAGED_BY_NPM \
    -u CODEX_MANAGED_PACKAGE_ROOT \
    -u CODEX_THREAD_ID
  )
  if [[ -n "$ghostty_demo_xdg_config_home" ]]; then
    env_args+=(XDG_CONFIG_HOME="$ghostty_demo_xdg_config_home")
  fi
  if [[ -n "$spaces_client_db_path" ]]; then
    env_args+=(SPACES_CLIENT_DB_PATH="$spaces_client_db_path")
  fi
  if [[ -n "$spaces_client_secret_dir" ]]; then
    env_args+=(SPACES_CLIENT_SECRET_DIR="$spaces_client_secret_dir")
  fi
  env "${env_args[@]}" "$@"
}

json_get() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1:3]
with open(path) as fh:
    value = json.load(fh)
for part in expr.split("."):
    if part:
        value = value[part]
print("" if value is None else value)
PY
}

prepare_ghostty_demo_config() {
  ghostty_demo_xdg_config_home="$source_xdg_config_home"
}

stop_demo_workspace_dir() {
  local workspace_dir="$1"
  if [[ -z "$workspace_dir" || -z "$spaces_db_path" || -z "$spaces_runtime_dir" ]]; then
    return
  fi
  if [[ ! -e "$spaces_db_path" ]]; then
    return
  fi

  run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    SPACESD_EXECUTABLE="$terminal_service" \
    SPACES_DEVICE_API_HOST="$device_api_bind_host" \
    SPACES_DEVICE_API_PORT="$device_api_port" \
    "$spacese2e" stop-workspace --workspace-dir "$workspace_dir" >/dev/null 2>&1 || true
}

stop_demo_workspace() {
  stop_demo_workspace_dir "$local_project_dir"
  stop_demo_workspace_dir "$secondary_project_dir"
}

discover_terminal_service_pid() {
  if [[ -z "$spaces_runtime_dir" ]]; then
    return
  fi
  local service_socket_path
  service_socket_path="$(terminal_service_socket_path_for_runtime_dir "$spaces_runtime_dir")"
  if [[ ! -S "$service_socket_path" ]]; then
    return
  fi
  lsof -nP -t "$service_socket_path" 2>/dev/null | head -n 1 || true
}

stop_terminal_service() {
  if [[ -z "$spaces_runtime_dir" ]]; then
    return
  fi
  stop_terminal_service_for_runtime_dir "$spaces_runtime_dir" 5
}

stop_device_api() {
  if [[ -n "$device_api_pid" && "$device_api_pid" != "$terminal_service_pid" ]]; then
    kill "$device_api_pid" >/dev/null 2>&1 || true
    wait "$device_api_pid" >/dev/null 2>&1 || true
    device_api_pid=""
  fi
}

cleanup() {
  local exit_code=$?
  stop_demo_workspace
  stop_device_api
  stop_terminal_service
  if [[ -n "$remote_forward_pid" ]]; then
    terminate_pid "$remote_forward_pid" "remote Device API SSH forward"
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
    for _ in {1..20}; do
      if ! ps -p "$app_pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    kill -9 "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ipad_udid" ]]; then
    xcrun simctl terminate "$ipad_udid" "$bundle_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$iphone_udid" ]]; then
    xcrun simctl terminate "$iphone_udid" "$bundle_id" >/dev/null 2>&1 || true
  fi
  spaces_ios_simulator_shutdown_owned "$exit_code" || true
  if [[ -n "$temp_root" && -d "$temp_root" && "$keep_root" != "1" ]]; then
    rm -rf "$temp_root"
  fi
  release_terminal_harness_lock
  return "$exit_code"
}

handle_interrupt() {
  exit 130
}

trap cleanup EXIT
trap handle_interrupt INT TERM

acquire_terminal_harness_lock

validate_profile_mode() {
  case "$profile_mode" in
    user|isolated)
      ;;
    *)
      echo "SPACES_MOBILE_DEMO_PROFILE_MODE must be 'user' or 'isolated', got: $profile_mode" >&2
      exit 1
      ;;
  esac
}

require_remote_demo_config() {
  if [[ "${SPACES_E2E_RUN_REMOTE:-0}" == "1" && -z "$remote_ssh_host" ]]; then
    echo "Remote mobile demo requires SPACES_E2E_REMOTE_SSH_HOST. Set remote E2E config in .env or the environment." >&2
    exit 1
  fi
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
}

canonical_path() {
  python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve())
PY
}

create_demo_root() {
  mkdir -p "$demo_root_parent"
  temp_root="$(mktemp -d "$demo_root_parent/run.XXXXXX")"
}

resolve_user_profile_paths() {
  local profile_exports
  if ! profile_exports="$(run_demo_env "$spacese2e" profile-show --shell)"; then
    echo "Failed to resolve Spaces profile paths with $spacese2e profile-show --shell." >&2
    exit 1
  fi
  eval "$profile_exports"
  spaces_db_path="${SPACES_DB_PATH:-}"
  spaces_runtime_dir="${SPACES_RUNTIME_DIR:-}"
  if [[ -z "$spaces_db_path" || -z "$spaces_runtime_dir" ]]; then
    echo "Failed to resolve SPACES_DB_PATH and SPACES_RUNTIME_DIR for the demo profile." >&2
    exit 1
  fi
}

prepare_demo_profile() {
  demo_home="$user_home"
  spaces_client_db_path="$temp_root/client/spaces-client.db"
  spaces_client_secret_dir="$temp_root/client/secrets"
  mkdir -p "$(dirname "$spaces_client_db_path")" "$spaces_client_secret_dir"
  if [[ "$profile_mode" == "isolated" ]]; then
    spaces_db_path="$temp_root/spaces.db"
    spaces_runtime_dir="$temp_root/runtime"
    mkdir -p "$spaces_runtime_dir" "$project_dir"
  else
    resolve_user_profile_paths
    mkdir -p "$spaces_runtime_dir" "$(dirname "$spaces_db_path")" "$project_dir"
  fi
  spaces_runtime_dir="$(canonical_path "$spaces_runtime_dir")"

  prepare_ghostty_demo_config
}

stop_existing_demo_profile_services() {
  if [[ "$profile_mode" == "isolated" ]]; then
    stop_terminal_service_for_runtime_dir "$spaces_runtime_dir" 5
    return
  fi

  (
    export HOME="$demo_home"
    export SPACES_DB_PATH="$spaces_db_path"
    export SPACES_RUNTIME_DIR="$spaces_runtime_dir"
    spaces_profile_stop_terminal_service "$spaces_cli"
  )
}

parse_profile_app_owner_pid() {
  python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

owner = payload.get("owner")
if not owner:
    raise SystemExit(1)
pid = owner.get("pid")
if not isinstance(pid, int) or pid <= 0:
    raise SystemExit(1)
print(pid)
'
}

terminate_pid() {
  local pid="$1"
  local label="$2"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  kill "$pid" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! ps -p "$pid" >/dev/null 2>&1; then
      return
    fi
    sleep 0.25
  done
  echo "Force stopping stale $label pid $pid." >&2
  kill -9 "$pid" >/dev/null 2>&1 || true
}

find_free_local_port() {
  python3 <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

wait_for_tcp_connect() {
  local host="$1"
  local port="$2"
  local label="$3"
  python3 - "$host" "$port" "$label" <<'PY'
import socket
import sys
import time

host, port, label = sys.argv[1], int(sys.argv[2]), sys.argv[3]
deadline = time.time() + 15
last_error = None
while time.time() < deadline:
    try:
        with socket.create_connection((host, port), timeout=0.5):
            raise SystemExit(0)
    except OSError as exc:
        last_error = exc
        time.sleep(0.2)
raise SystemExit(f"Timed out waiting for {label} at {host}:{port}: {last_error}")
PY
}

stop_existing_profile_app_owner() {
  [[ -n "$spaces_db_path" && -n "$spaces_runtime_dir" ]] || return 0
  local owner_json owner_pid command
  if ! owner_json="$(run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    "$spacese2e" profile-app-owner --json 2>/dev/null)"; then
    return 0
  fi
  owner_pid="$(printf '%s' "$owner_json" | parse_profile_app_owner_pid 2>/dev/null || true)"
  [[ -n "$owner_pid" ]] || return 0
  command="$(process_command "$owner_pid")"
  if [[ "$command" != *"SpacesApp"* ]]; then
    echo "Skipping stale profile app-owner pid $owner_pid because it is not SpacesApp: $command" >&2
    return 0
  fi
  echo "Stopping existing SpacesApp owner for demo profile pid $owner_pid." >&2
  terminate_pid "$owner_pid" "SpacesApp owner"
}

stop_device_api_port_listeners() {
  if [[ "$device_api_port" == "0" ]]; then
    return
  fi
  local pid command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(process_command "$pid")"
    if [[ "$command" != *"$repo_root"* || ( "$command" != *"spacesd"* && "$command" != *"SpacesApp"* ) ]]; then
      echo "Refusing to stop non-Spaces listener on mobile demo port $device_api_port: pid=$pid command=$command" >&2
      lsof -nP -iTCP:"$device_api_port" -sTCP:LISTEN >&2 || true
      exit 1
    fi
    echo "Stopping stale Spaces listener on mobile demo port $device_api_port: pid=$pid." >&2
    terminate_pid "$pid" "device API listener"
  done < <(lsof -tiTCP:"$device_api_port" -sTCP:LISTEN 2>/dev/null || true)
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

build_macos_debug_products() {
  if [[ "$build_macos" == "0" ]]; then
    return
  fi

  echo "Building macOS debug products..."
  run_demo_env "$repo_root/scripts/swiftpm.sh" build
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
from urllib.parse import parse_qs, urlparse

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

open_simulator_app() {
  open -a Simulator >/dev/null 2>&1 || true
}

launch_simulator_app() {
  local udid="$1"
  local stdout_log="$2"
  local stderr_log="$3"
  local installation_id="${4:-}"
  local device_seed_json="${5:-}"

  local -a launch_env=(
    "SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_TRACE=$demo_trace"
    "SIMCTL_CHILD_SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH=$performance_log_path"
    # DEBUG-only paywall bypass so the demo reaches the app shell without an active subscription.
    "SIMCTL_CHILD_SPACES_MOBILE_PAYWALL_BYPASS=1"
  )
  if [[ -n "$installation_id" ]]; then
    launch_env+=("SIMCTL_CHILD_SPACES_MOBILE_TEST_INSTALLATION_ID=$installation_id")
  fi
  if [[ -n "$device_seed_json" ]]; then
    launch_env+=("SIMCTL_CHILD_SPACES_MOBILE_TEST_DEVICE_SEED_JSON=$device_seed_json")
  fi

  env "${launch_env[@]}" xcrun simctl launch --console-pty "$udid" "$bundle_id" \
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

wait_for_spaces_app_ready() {
  local deadline=$((SECONDS + 30))
  while [[ $SECONDS -lt $deadline ]]; do
    if ! ps -p "$app_pid" >/dev/null 2>&1; then
      echo "SpacesApp exited before Device UI IPC observers were ready." >&2
      tail -n 120 "$app_log" >&2 || true
      exit 1
    fi
    if grep -q 'spaces: startup stage=ipc_observers_ready' "$app_log" 2>/dev/null; then
      return
    fi
    sleep 0.2
  done
  echo "Timed out waiting for SpacesApp Device UI IPC observers." >&2
  tail -n 160 "$app_log" >&2 || true
  exit 1
}

process_command() {
  local pid="$1"
  ps -p "$pid" -o command= 2>/dev/null || true
}

wait_for_device_api_port() {
  python3 - "$device_api_host" "$device_api_port" <<'PY'
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
raise SystemExit(f"Device API port not ready: {last_error}")
PY
}

open_device_pairing_window() {
  local window_json
  if ! window_json="$(
    run_demo_env \
      HOME="$demo_home" \
      SPACES_DB_PATH="$spaces_db_path" \
      SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
      SPACESD_EXECUTABLE="$terminal_service" \
      SPACES_DEVICE_API_HOST="$device_api_bind_host" \
      SPACES_DEVICE_API_PORT="$device_api_port" \
      "$spacese2e" open-device-pairing-window
  )"; then
    echo "Failed to open daemon device pairing window." >&2
    cat "$device_api_log" >&2 || true
    exit 1
  fi

  local parsed_status
  parsed_status="$(
    python3 - "$window_json" <<'PY'
import json
import shlex
import sys

payload = json.loads(sys.argv[1])
print(f"device_api_port={shlex.quote(str(payload['port']))}")
print(f"pairing_link={shlex.quote(payload['pairingLink'])}")
print(f"pairing_code={shlex.quote(payload['pairingCode'])}")
print(f"pairing_nonce={shlex.quote(payload['pairingNonce'])}")
print(f"certificate_fingerprint={shlex.quote(payload['certificateFingerprint'])}")
print(f"expires_at={shlex.quote(payload['expiresAt'])}")
PY
  )"
  eval "$parsed_status"
  printf 'Spaces device pairing window\thost=%s\tport=%s\tpairing_link=%s\tpairing_code=%s\texpires_at=%s\n' \
    "$device_api_bind_host" "$device_api_port" "$pairing_link" "$pairing_code" "$expires_at" >>"$device_api_log"
}

start_device_api() {
  if ! run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    SPACESD_EXECUTABLE="$terminal_service" \
    SPACES_DEVICE_API_HOST="$device_api_bind_host" \
    SPACES_DEVICE_API_PORT="$device_api_port" \
    SPACES_DEVICE_API_TRACE="${SPACES_DEVICE_API_TRACE:-1}" \
    "$spacese2e" mobile-status >"$device_api_log" 2>&1; then
    echo "Timed out waiting for daemon device API readiness." >&2
    cat "$device_api_log" >&2 || true
    exit 1
  fi

  open_device_pairing_window
}

pair_remote_demo_device() {
  if [[ "${SPACES_E2E_RUN_REMOTE:-0}" != "1" ]]; then
    echo "Skipping remote demo device pairing for the selected scenario." >&2
    return
  fi

  local -a args=(pair-remote-device --ssh-host "$remote_ssh_host")
  if [[ -n "$remote_ssh_user" ]]; then
    args+=(--ssh-user "$remote_ssh_user")
  fi
  if [[ -n "$remote_ssh_port" ]]; then
    args+=(--ssh-port "$remote_ssh_port")
  fi

  remote_pairing_json="$temp_root/remote-device-pairing.json"
  prepare_remote_demo_daemon
  echo "Pairing Mac client with remote spacesd at $remote_ssh_host..."
  if ! run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    "$spacese2e" "${args[@]}" >"$remote_pairing_json"; then
    echo "Failed to pair remote demo device over SSH." >&2
    cat "$remote_pairing_json" >&2 || true
    exit 1
  fi

  local parsed
  parsed="$(
    python3 - "$remote_pairing_json" <<'PY'
import json
import shlex
import sys
payload = json.load(open(sys.argv[1]))
print(f"remote_device_id={shlex.quote(payload['deviceID'])}")
print(f"remote_device_name={shlex.quote(payload['name'])}")
print(f"remote_device_host={shlex.quote(payload['host'])}")
print(f"remote_device_port={shlex.quote(str(payload['port']))}")
PY
  )"
  eval "$parsed"
  start_remote_device_forward
  update_remote_demo_device_endpoint
}

remote_ssh_destination() {
  if [[ -n "$remote_ssh_user" ]]; then
    printf '%s@%s' "$remote_ssh_user" "$remote_ssh_host"
  else
    printf '%s' "$remote_ssh_host"
  fi
}

remote_ssh_args() {
  printf '%s\n' -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes
  if [[ -n "$remote_ssh_port" ]]; then
    printf '%s\n' -p "$remote_ssh_port"
  fi
}

remote_ssh() {
  local -a args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(remote_ssh_args)
  ssh "${args[@]}" "$(remote_ssh_destination)" "$@"
}

remote_expand_path() {
  local quoted
  quoted="$(shell_quote "$1")"
  remote_ssh "python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' $quoted"
}

wait_for_remote_demo_daemon() {
  local quoted_port
  quoted_port="$(shell_quote "$remote_demo_daemon_port")"
  remote_ssh "python3 - $quoted_port" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
deadline = time.time() + 60
last_error = None
while time.time() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            raise SystemExit(0)
    except OSError as exc:
        last_error = exc
        time.sleep(0.5)
raise SystemExit(f"remote demo daemon port {port} did not open: {last_error}")
PY
}

prepare_remote_demo_daemon() {
  [[ "$remote_demo_daemon_port" =~ ^[0-9]+$ ]] || {
    echo "SPACES_E2E_REMOTE_DAEMON_PORT must be numeric, got: $remote_demo_daemon_port" >&2
    exit 1
  }
  command -v ssh >/dev/null 2>&1 || {
    echo "ssh is required to prepare the remote demo daemon." >&2
    exit 1
  }

  local artifact_assignments artifact_url archive_path install_root quoted_archive quoted_install
  echo "Preparing remote demo spacesd at $remote_ssh_host..."
  SPACES_E2E_REMOTE_DAEMON_PORT="$remote_demo_daemon_port" \
    SPACES_E2E_REMOTE_WORKSPACE_ROOT="$remote_demo_workspace_root" \
    SPACES_E2E_REMOTE_INSTALL_ROOT="$remote_demo_device_root" \
    SPACES_E2E_REMOTE_DEVICE_ROOT="$remote_demo_device_root" \
    "$repo_root/apps/macos/scripts/cleanup_linux_spacesd_e2e.sh" >/dev/null

  artifact_assignments="$("$repo_root/apps/macos/scripts/deploy_linux_spacesd_e2e.sh")"
  eval "$artifact_assignments"
  artifact_url="${artifact_url:-}"
  [[ "$artifact_url" == file://* ]] || {
    echo "Remote demo artifact URL must be file://, got: $artifact_url" >&2
    exit 1
  }

  archive_path="${artifact_url#file://}"
  install_root="$(remote_expand_path "$remote_demo_device_root/install")"
  quoted_archive="$(shell_quote "$archive_path")"
  quoted_install="$(shell_quote "$install_root")"
  remote_ssh "rm -rf $quoted_install && mkdir -p $quoted_install && tar -xzf $quoted_archive -C $quoted_install --strip-components=1 && SPACES_DEVICE_API_HOST=0.0.0.0 SPACES_DEVICE_API_PORT=$remote_demo_daemon_port $quoted_install/install.sh" >/dev/null
  wait_for_remote_demo_daemon
}

start_remote_device_forward() {
  [[ -n "$remote_device_host" && -n "$remote_device_port" ]] || return 0
  command -v ssh >/dev/null 2>&1 || {
    echo "ssh is required to forward the remote demo Device API." >&2
    exit 1
  }

  remote_forward_port="$(find_free_local_port)"
  local destination
  destination="$(remote_ssh_destination)"
  local -a ssh_args=(
    -N
    -o BatchMode=yes
    -o ExitOnForwardFailure=yes
    -o StrictHostKeyChecking=yes
    -L "$remote_forward_host:$remote_forward_port:127.0.0.1:$remote_device_port"
  )
  if [[ -n "$remote_ssh_port" ]]; then
    ssh_args+=(-p "$remote_ssh_port")
  fi

  echo "Forwarding remote Device API $remote_device_host:$remote_device_port through $remote_forward_host:$remote_forward_port..."
  ssh "${ssh_args[@]}" "$destination" &
  remote_forward_pid=$!
  if ! wait_for_tcp_connect "$remote_forward_host" "$remote_forward_port" "remote Device API SSH forward"; then
    terminate_pid "$remote_forward_pid" "remote Device API SSH forward"
    remote_forward_pid=""
    exit 1
  fi
}

rewrite_pairing_link_endpoint() {
  local link="$1"
  python3 - "$link" "$remote_forward_host" "$remote_forward_port" <<'PY'
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

link, host, port = sys.argv[1:4]
parts = urlsplit(link)
query = dict(parse_qsl(parts.query, keep_blank_values=True))
query["host"] = host
query["port"] = port
print(urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment)))
PY
}

update_remote_demo_device_endpoint() {
  [[ -n "$remote_forward_port" ]] || return 0
  remote_device_host="$remote_forward_host"
  remote_device_port="$remote_forward_port"
  if [[ -n "$remote_pairing_link" ]]; then
    remote_pairing_link="$(rewrite_pairing_link_endpoint "$remote_pairing_link")"
  fi
  python3 - "$spaces_client_db_path" "$remote_device_id" "$remote_device_host" "$remote_device_port" <<'PY'
import sqlite3
import sys
from datetime import datetime, timezone

db_path, device_id, host, port = sys.argv[1:5]
updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with sqlite3.connect(db_path) as db:
    db.execute(
        "UPDATE paired_devices SET host = ?, port = ?, updated_at = ? WHERE id = ?",
        (host, int(port), updated_at, device_id),
    )
PY
}

open_remote_device_pairing_window() {
  [[ -n "$remote_device_id" ]] || return 1

  local -a args=(open-remote-device-pairing-window --ssh-host "$remote_ssh_host")
  if [[ -n "$remote_ssh_user" ]]; then
    args+=(--ssh-user "$remote_ssh_user")
  fi
  if [[ -n "$remote_ssh_port" ]]; then
    args+=(--ssh-port "$remote_ssh_port")
  fi

  remote_pairing_window_json="$temp_root/remote-device-pairing-window.json"
  if ! run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    "$spacese2e" "${args[@]}" >"$remote_pairing_window_json"; then
    echo "Failed to open remote demo device pairing window over SSH." >&2
    cat "$remote_pairing_window_json" >&2 || true
    exit 1
  fi

  local parsed
  parsed="$(
    python3 - "$remote_pairing_window_json" <<'PY'
import json
import shlex
import sys

payload = json.load(open(sys.argv[1]))
print(f"remote_pairing_link={shlex.quote(payload['pairingLink'])}")
print(f"remote_certificate_fingerprint={shlex.quote(payload['certificateFingerprint'])}")
print(f"remote_device_host={shlex.quote(payload['host'])}")
print(f"remote_device_port={shlex.quote(str(payload['port']))}")
PY
  )"
  eval "$parsed"
  update_remote_demo_device_endpoint
}

# Creates a project (and its default workspace) on the paired remote demo daemon so the remote
# mobile-UI e2e scenarios have a workspace to open a terminal in — the remote mirror of the local
# demo projects. The project directory is created on the remote host and registered through the
# remote daemon's Device API (over the SSH forward) using the just-paired iPhone client credentials.
# Sets remote_project_dir and remote_workspace_id.
create_remote_demo_project() {
  [[ -n "$remote_forward_port" && -n "$iphone_remote_token" ]] || {
    echo "Cannot create the remote demo project without a paired remote device." >&2
    exit 1
  }
  local run_suffix project_root
  run_suffix="$(basename "$temp_root")"
  project_root="$(remote_expand_path "$remote_demo_workspace_root/mobile-ui-project-$run_suffix")"
  remote_ssh "python3 - $(shell_quote "$project_root")" <<'PY'
import pathlib
import shutil
import subprocess
import sys

project_root = pathlib.Path(sys.argv[1])
shutil.rmtree(project_root, ignore_errors=True)
project_root.mkdir(parents=True, exist_ok=True)
(project_root / "README.txt").write_text("remote mobile-ui demo sentinel\n")

def git(*args):
    subprocess.run(["git", "-C", str(project_root), *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

git("init")
git("config", "user.email", "spaces-e2e@example.invalid")
git("config", "user.name", "Spaces E2E")
git("add", "README.txt")
git("commit", "-m", "Initial remote mobile-ui demo fixture")
PY
  remote_project_dir="$project_root"
  remote_workspace_id="$(
    run_demo_env \
      HOME="$demo_home" \
      SPACES_DB_PATH="$spaces_db_path" \
      SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
      python3 - "$spacese2e" "$bundle_id" "$remote_forward_host" "$remote_forward_port" "$remote_certificate_fingerprint" "$iphone_remote_token" "$iphone_installation_id" "$remote_project_dir" <<'PY'
import json
import subprocess
import sys

spacese2e, bundle_id, host, port, certificate_fingerprint, auth_token, installation_id, project_dir = sys.argv[1:]
request = {
    "authToken": auth_token,
    "clientApp": {
        "installationID": installation_id,
        "bundleID": bundle_id,
        "platform": "ios",
        "deviceName": "Remote Demo Setup",
        "appVersion": "1.0",
    },
    "command": {"createProject": {"projectDir": project_dir, "gitURL": None}},
}
try:
    completed = subprocess.run(
        [spacese2e, "mobile-request", "--host", host, "--port", port, "--certificate-fingerprint=" + certificate_fingerprint, "--request-json", json.dumps(request)],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
except subprocess.CalledProcessError as error:
    raise SystemExit(f"createProject request failed (exit {error.returncode}): {(error.stderr or error.stdout or '').strip()}")
payload = json.loads(completed.stdout)
mutation = ((payload.get("result") or {}).get("mutation") or {})
workspace_id = mutation.get("workspaceID")
if not payload.get("ok") or not workspace_id:
    raise SystemExit(f"createProject did not return a workspaceID: {json.dumps(payload)}")
print(workspace_id)
PY
  )"
}

wait_for_session_owner() {
  local owner_session_id="$1"
  python3 - "$spaces_db_path" "$owner_session_id" <<'PY'
import sqlite3
import sys
import time

db_path = sys.argv[1]
session_id = sys.argv[2]
deadline = time.time() + 30
last_snapshot = ""
while time.time() < deadline:
    with sqlite3.connect(db_path) as db:
        rows = db.execute(
            """
            SELECT client_id, mode, COALESCE(detached_at, '')
            FROM terminal_attachments
            WHERE session_id = ?
            ORDER BY attached_at, id
            """,
            (session_id,),
        ).fetchall()
    last_snapshot = repr(rows)
    if any(mode == "owner" and not detached_at for _, mode, detached_at in rows):
        raise SystemExit(0)
    time.sleep(0.1)
raise SystemExit(f"Timed out waiting for active owner attachment for {session_id}.\n{last_snapshot}")
PY
}

show_session_on_mac() {
  local owner_session_id="$1"
  run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    SPACESD_EXECUTABLE="$terminal_service" \
    SPACES_DEVICE_API_HOST="$device_api_bind_host" \
    SPACES_DEVICE_API_PORT="$device_api_port" \
    "$spaces_cli" terminal show "$owner_session_id" >/dev/null
}

open_demo_workspace_terminal() {
  local workspace_dir="$1"
  run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    SPACESD_EXECUTABLE="$terminal_service" \
    SPACES_DEVICE_API_HOST="$device_api_bind_host" \
    SPACES_DEVICE_API_PORT="$device_api_port" \
    "$spacese2e" start-workspace-terminal-session --workspace-dir "$workspace_dir"
}

extract_terminal_session_id() {
  python3 - "$1" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(payload.get("sessionID") or payload.get("id") or "")
PY
}

open_workspace_terminal_session() {
  local workspace_dir="$1"
  local label="$2"
  local session_payload session_id

  session_payload="$(open_demo_workspace_terminal "$workspace_dir")"
  session_id="$(extract_terminal_session_id "$session_payload")"
  if [[ -n "$session_id" ]]; then
    printf '%s\n' "$session_id"
    return 0
  fi

  echo "Failed to create the $label terminal session." >&2
  exit 1
}

generate_installation_id() {
  python3 - <<'PY'
import uuid
print(str(uuid.uuid4()).upper())
PY
}

pair_device() {
  local device_pairing_link="$1"
  local installation_id="$2"
  local device_name="$3"
  local host_override="${4:-}"
  python3 - "$device_pairing_link" "$spacese2e" "$host_override" "$bundle_id" "$installation_id" "$device_name" <<'PY'
import json
import subprocess
import sys
from urllib.parse import parse_qs, urlparse

(
    pairing_link,
    spacese2e,
    host_override,
    bundle_id,
    installation_id,
    device_name,
) = sys.argv[1:]

def send(pairing_link, request):
    args = [
        spacese2e,
        "mobile-request",
        "--pairing-link",
        pairing_link,
        "--request-json",
        json.dumps(request),
    ]
    if host_override:
        args[4:4] = ["--host", host_override]
    completed = subprocess.run(
        args,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout)

def pair(pairing_link, installation_id, device_name):
    query = parse_qs(urlparse(pairing_link).query)
    pairing_code = query.get("code", [""])[0]
    pairing_nonce = query.get("nonce", [""])[0]
    protocol_version = query.get("pv", [""])[0]
    if not pairing_code or not pairing_nonce or not protocol_version:
        raise SystemExit(f"pairing link missing code, nonce, or pv: {pairing_link}")
    response = send(pairing_link, {
        # Version-gated pairing: echo the daemon's advertised wire-protocol version (pv from the v3 link).
        "command": {"pair": {"pairingCode": pairing_code, "pairingNonce": pairing_nonce, "clientProtocolVersion": int(protocol_version)}},
        "clientApp": {
            "installationID": installation_id,
            "bundleID": bundle_id,
            "platform": "ios",
            "deviceName": device_name,
            "appVersion": "1.0",
        },
    })
    auth_token = (((response.get("result") or {}).get("issuedAuthToken") or {}).get("authToken"))
    if not response.get("ok") or not auth_token:
        raise SystemExit(f"pair failed for {device_name}: {response}")
    return auth_token

print(pair(pairing_link, installation_id, device_name))
PY
}

make_device_seed_json() {
  local local_auth_token="$1"
  local remote_auth_token="${2:-}"
  python3 - "$device_api_host" "$device_api_port" "$certificate_fingerprint" "$local_auth_token" "$remote_device_name" "$remote_device_host" "$remote_device_port" "$remote_certificate_fingerprint" "$remote_auth_token" <<'PY'
import json
import sys

(
    local_host,
    local_port,
    local_certificate_fingerprint,
    local_auth_token,
    remote_name,
    remote_host,
    remote_port,
    remote_certificate_fingerprint,
    remote_auth_token,
) = sys.argv[1:]

devices = [
    {
        "name": "This Mac",
        "host": local_host,
        "port": int(local_port),
        "certificateFingerprint": local_certificate_fingerprint,
        "authToken": local_auth_token,
    }
]
if remote_auth_token and remote_host and remote_port and remote_certificate_fingerprint:
    devices.append({
        "name": remote_name or f"Spaces {remote_host}",
        "host": remote_host,
        "port": int(remote_port),
        "certificateFingerprint": remote_certificate_fingerprint,
        "authToken": remote_auth_token,
    })

print(json.dumps({"devices": devices}, separators=(",", ":")))
PY
}

write_pairing_json() {
  local output_path="$1"
  local ipad_installation_id="$2"
  local ipad_token="$3"
  local iphone_installation_id="$4"
  local iphone_token="$5"
  python3 - "$output_path" "$certificate_fingerprint" "$ipad_installation_id" "$ipad_token" "$iphone_installation_id" "$iphone_token" \
    "$remote_forward_host" "$remote_forward_port" "$remote_certificate_fingerprint" "$remote_project_dir" "$remote_workspace_id" \
    "$ipad_remote_token" "$iphone_remote_token" <<'PY'
import json
import sys

(
    output_path,
    certificate_fingerprint,
    ipad_installation_id,
    ipad_token,
    iphone_installation_id,
    iphone_token,
    remote_host,
    remote_port,
    remote_certificate_fingerprint,
    remote_project_dir,
    remote_workspace_id,
    ipad_remote_token,
    iphone_remote_token,
) = sys.argv[1:]
payload = {
    "ipad": {
        "installationID": ipad_installation_id,
        "authToken": ipad_token,
        "certificateFingerprint": certificate_fingerprint,
    },
    "iphone": {
        "installationID": iphone_installation_id,
        "authToken": iphone_token,
        "certificateFingerprint": certificate_fingerprint,
    },
}
# The remote section is the mirror of the per-device local creds, but for the paired remote demo
# daemon reached over the SSH forward, plus the shared remote project/workspace the mobile-UI
# scenarios open a terminal in. Present only when the demo paired a remote device.
if remote_workspace_id:
    payload["remote"] = {
        "host": remote_host,
        "port": int(remote_port),
        "certificateFingerprint": remote_certificate_fingerprint,
        "projectDir": remote_project_dir,
        "workspaceID": remote_workspace_id,
        "ipad": {"installationID": ipad_installation_id, "authToken": ipad_remote_token},
        "iphone": {"installationID": iphone_installation_id, "authToken": iphone_remote_token},
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

  python3 - "$udid" "$bundle_id" "$device_api_host" "$device_api_port" "$certificate_fingerprint" "$installation_id" "$auth_token" <<'PY'
import json
import pathlib
import plistlib
import subprocess
import sys

udid, bundle_id, host, port_text, certificate_fingerprint, installation_id, auth_token = sys.argv[1:]
port = int(port_text)
container = subprocess.check_output(["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"], text=True).strip()
prefs_path = pathlib.Path(container) / "Library" / "Preferences" / f"{bundle_id}.plist"
prefs_path.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "host": host,
    "port": port,
    "certificateFingerprint": certificate_fingerprint,
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
  python3 - "$temp_root" "$profile_mode" "$demo_home" "$app_pid" "$device_api_pid" "$terminal_service_pid" "$local_session_id" "$secondary_session_id" "$spaces_db_path" "$spaces_runtime_dir" "$local_project_dir" "$secondary_project_dir" "$app_log" "$device_api_log" "$performance_log_path" "$ipad_screenshot" "$iphone_screenshot" "$ipad_udid" "$iphone_udid" "$device_api_bind_host" "$device_api_host" "$device_api_port" "$workspace_title" "$secondary_workspace_title" "$ios_app_path" "$ios_build_log" "$ios_derived_data" "$ipad_app_stdout_log" "$ipad_app_stderr_log" "$iphone_app_stdout_log" "$iphone_app_stderr_log" "$remote_device_id" "$remote_device_name" "$remote_device_host" "$remote_device_port" <<'PY'
import json
import sys

(
    root,
    profile_mode,
    home,
    app_pid,
    device_api_pid,
    terminal_service_pid,
    local_session_id,
    secondary_session_id,
    db_path,
    runtime_dir,
    local_project_dir,
    secondary_project_dir,
    app_log,
    device_api_log,
    performance_log_path,
    ipad_screenshot,
    iphone_screenshot,
    ipad_udid,
    iphone_udid,
    device_api_bind_host,
    device_api_host,
    device_api_port,
    workspace_title,
    secondary_workspace_title,
    ios_app_path,
    ios_build_log,
    ios_derived_data,
    ipad_app_stdout_log,
    ipad_app_stderr_log,
    iphone_app_stdout_log,
    iphone_app_stderr_log,
    remote_device_id,
    remote_device_name,
    remote_device_host,
    remote_device_port,
) = sys.argv[1:]
payload = {
    "root": root,
    "profileMode": profile_mode,
    "home": home,
    "appPID": int(app_pid),
    "deviceAPIPID": int(device_api_pid),
    "terminalServicePID": int(terminal_service_pid) if terminal_service_pid else None,
    "deviceAPIBindHost": device_api_bind_host,
    "deviceAPIHost": device_api_host,
    "deviceAPIPort": int(device_api_port),
    "sessionID": local_session_id,
    "localSessionID": local_session_id,
    "secondarySessionID": secondary_session_id or None,
    "sessionIDs": [value for value in (local_session_id, secondary_session_id) if value],
    "workspaceTitle": workspace_title,
    "localWorkspaceTitle": workspace_title,
    "secondaryWorkspaceTitle": secondary_workspace_title,
    "dbPath": db_path,
    "runtimeDir": runtime_dir,
    "projectDir": local_project_dir,
    "localProjectDir": local_project_dir,
    "secondaryProjectDir": secondary_project_dir,
    "appLog": app_log,
    "deviceAPILog": device_api_log,
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
if remote_device_id:
    payload["remoteDevice"] = {
        "id": remote_device_id,
        "name": remote_device_name,
        "host": remote_device_host,
        "port": int(remote_device_port),
    }
print(json.dumps(payload, indent=2))
PY
}

write_manual_shell_helper() {
  manual_shell_path="$temp_root/manual-demo-env.sh"
  cat >"$manual_shell_path" <<EOF
#!/usr/bin/env bash
export HOME=$(printf '%q' "$demo_home")
export XDG_CONFIG_HOME=$(printf '%q' "$ghostty_demo_xdg_config_home")
export SPACES_DB_PATH=$(printf '%q' "$spaces_db_path")
export SPACES_RUNTIME_DIR=$(printf '%q' "$spaces_runtime_dir")
export SPACES_CLIENT_DB_PATH=$(printf '%q' "$spaces_client_db_path")
export SPACES_CLIENT_SECRET_DIR=$(printf '%q' "$spaces_client_secret_dir")
export SPACESD_EXECUTABLE=$(printf '%q' "$terminal_service")
export SPACES_DEVICE_API_HOST=$(printf '%q' "$device_api_bind_host")
export SPACES_DEVICE_API_PORT=$(printf '%q' "$device_api_port")
export SPACES_MOBILE_PAIRING_LINK=$(printf '%q' "$pairing_link")
export SPACES_MOBILE_CERTIFICATE_FINGERPRINT=$(printf '%q' "$certificate_fingerprint")
export SPACES_DEMO_ROOT=$(printf '%q' "$temp_root")
export SPACES_DEMO_SESSION_ID=$(printf '%q' "$local_session_id")
export SPACES_DEMO_LOCAL_SESSION_ID=$(printf '%q' "$local_session_id")
export SPACES_DEMO_SECONDARY_SESSION_ID=$(printf '%q' "$secondary_session_id")
export SPACES_DEMO_PROJECT_DIR=$(printf '%q' "$local_project_dir")
export SPACES_DEMO_LOCAL_PROJECT_DIR=$(printf '%q' "$local_project_dir")
export SPACES_DEMO_SECONDARY_PROJECT_DIR=$(printf '%q' "$secondary_project_dir")
export SPACES_DEMO_REMOTE_DEVICE_ID=$(printf '%q' "$remote_device_id")
export SPACES_DEMO_REMOTE_DEVICE_NAME=$(printf '%q' "$remote_device_name")
export SPACES_DEMO_REMOTE_DEVICE_HOST=$(printf '%q' "$remote_device_host")
export SPACES_DEMO_REMOTE_DEVICE_PORT=$(printf '%q' "$remote_device_port")
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
  "\$SPACES_CLI" terminal send text "\$SPACES_DEMO_SESSION_ID" "\$@"
}

spaces_demo_send_secondary() {
  "\$SPACES_CLI" terminal send text "\$SPACES_DEMO_SECONDARY_SESSION_ID" "\$@"
}

spaces_demo_sendline() {
  "\$SPACES_CLI" terminal send text "\$SPACES_DEMO_SESSION_ID" "\$1" --newline
}

spaces_demo_sendline_secondary() {
  "\$SPACES_CLI" terminal send text "\$SPACES_DEMO_SECONDARY_SESSION_ID" "\$1" --newline
}

spaces_demo_enter() {
  "\$SPACES_CLI" terminal send bytes "\$SPACES_DEMO_SESSION_ID" 13
}

spaces_demo_mac_takeover() {
  "\$SPACES_CLI" terminal show "\$SPACES_DEMO_SESSION_ID"
}

spaces_demo_secondary_mac_takeover() {
  "\$SPACES_CLI" terminal show "\$SPACES_DEMO_SECONDARY_SESSION_ID"
}

spaces_demo_reopen() {
  "\$SPACES_E2E" open-workspace-terminal --workspace-dir "\$SPACES_DEMO_PROJECT_DIR"
}

spaces_demo_reopen_secondary() {
  "\$SPACES_E2E" open-workspace-terminal --workspace-dir "\$SPACES_DEMO_SECONDARY_PROJECT_DIR"
}

spaces_demo_tail_mac_log() {
  tail -f "\$SPACES_DEMO_ROOT/app.log"
}

spaces_demo_tail_device_api_log() {
  tail -f "\$SPACES_DEMO_ROOT/device-api.log"
}

spaces_demo_mobile_status() {
  "\$SPACES_E2E" mobile-status
}

spaces_demo_tail_ipad_stderr() {
  tail -f "\$SPACES_DEMO_ROOT/ipad-app.stderr.log"
}
EOF
  chmod +x "$manual_shell_path"
}

require_path "$ghostty_xcframework" "GhosttyKit.xcframework"
require_path "$ghostty_resources" "Ghostty resources"
validate_profile_mode
require_remote_demo_config
build_macos_debug_products
require_executable "$spaces_app" "SpacesApp"
require_executable "$spaces_cli" "spaces CLI"
require_executable "$spacese2e" "spacese2e"
require_executable "$terminal_service" "spacesd"

create_demo_root
project_dir="$temp_root/beacon-status"
local_project_dir="$project_dir"
secondary_project_dir="$temp_root/scout-errors"
app_log="$temp_root/app.log"
device_api_log="$temp_root/device-api.log"
performance_log_path="$temp_root/mobile-terminal-performance.jsonl"
ipad_screenshot="$temp_root/ipad.png"
iphone_screenshot="$temp_root/iphone.png"
ipad_app_stdout_log="$temp_root/ipad-app.stdout.log"
ipad_app_stderr_log="$temp_root/ipad-app.stderr.log"
iphone_app_stdout_log="$temp_root/iphone-app.stdout.log"
iphone_app_stderr_log="$temp_root/iphone-app.stderr.log"
prepare_demo_profile
stop_existing_profile_app_owner
stop_existing_demo_profile_services
stop_device_api_port_listeners

spaces_e2e_create_beacon_fixture_repo "$fixture_template_dir" "$local_project_dir"
spaces_e2e_create_scout_fixture_repo "$fixture_template_dir" "$secondary_project_dir"

run_demo_env \
  HOME="$demo_home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACESD_EXECUTABLE="$terminal_service" \
  SPACES_DEVICE_API_HOST="$device_api_bind_host" \
  SPACES_DEVICE_API_PORT="$device_api_port" \
  SPACES_PROJECT_DIR="$repo_root" \
  "$spacese2e" seed-fixture \
    --project-dir "$local_project_dir" \
    --docs-url 'http://localhost:$SPACES_APP_PORT/docs/' \
    --admin-url 'http://localhost:$SPACES_APP_PORT/admin/' >/dev/null

run_demo_env \
  HOME="$demo_home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACESD_EXECUTABLE="$terminal_service" \
  SPACES_DEVICE_API_HOST="$device_api_bind_host" \
  SPACES_DEVICE_API_PORT="$device_api_port" \
  SPACES_PROJECT_DIR="$repo_root" \
  "$spacese2e" seed-fixture \
    --project-dir "$secondary_project_dir" \
    --docs-url 'http://localhost:$SPACES_APP_PORT/docs/' \
    --admin-url 'http://localhost:$SPACES_APP_PORT/admin/' >/dev/null

run_demo_env \
  HOME="$demo_home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACESD_EXECUTABLE="$terminal_service" \
  "$spacese2e" hide-workspace --workspace-dir "$temp_root/scout-errors" >/dev/null

ipad_udid="$(resolve_device_udid "$ipad_name")"
iphone_udid="$(resolve_device_udid "$iphone_name")"

if [[ -n "$app_path_override" ]]; then
  ios_app_path="$(resolve_ios_app_path)"
else
  ios_build_log="$temp_root/ios-build.log"
  ios_derived_data="$temp_root/ios-derived-data"
  mkdir -p "$ios_derived_data"
  build_ios_app "$ios_derived_data" "$ios_build_log" "$iphone_udid"
  ios_app_path="$(resolve_ios_app_path "$ios_derived_data/Build/Products/Debug-iphonesimulator/SpacesMobile.app")"
fi

require_path "$ios_app_path" "SpacesMobile.app"
pair_remote_demo_device
spaces_ios_simulator_boot_if_needed "$ipad_udid"
spaces_ios_simulator_boot_if_needed "$iphone_udid"
open_simulator_app

env \
  -u NO_COLOR \
  -u CLICOLOR \
  -u CLICOLOR_FORCE \
  -u CI \
  -u CODEX_CI \
  -u CODEX_MANAGED_BY_NPM \
  -u CODEX_MANAGED_PACKAGE_ROOT \
  -u CODEX_THREAD_ID \
  HOME="$demo_home" \
  XDG_CONFIG_HOME="$ghostty_demo_xdg_config_home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACES_CLIENT_DB_PATH="$spaces_client_db_path" \
  SPACES_CLIENT_SECRET_DIR="$spaces_client_secret_dir" \
  SPACESD_EXECUTABLE="$terminal_service" \
  SPACES_DEVICE_API_HOST="$device_api_bind_host" \
  SPACES_DEVICE_API_PORT="$device_api_port" \
  SPACES_STARTUP_PROFILE=1 \
  SPACES_GHOSTTYKIT_XCFRAMEWORK="$ghostty_xcframework" \
  SPACES_GHOSTTY_RESOURCES_DIR="$ghostty_resources" \
  SPACES_MOBILE_TERMINAL_TRACE="$demo_trace" \
  SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$performance_log_path" \
  "$spaces_app" >"$app_log" 2>&1 &
app_pid=$!
wait_for_pid "$app_pid" "SpacesApp"
wait_for_spaces_app_ready

local_session_id="$(open_workspace_terminal_session "$local_project_dir" "local")"
session_id="$local_session_id"
show_session_on_mac "$local_session_id"
wait_for_session_owner "$local_session_id"

secondary_session_id="$(open_workspace_terminal_session "$secondary_project_dir" "secondary")"
show_session_on_mac "$secondary_session_id"
wait_for_session_owner "$secondary_session_id"

start_device_api
wait_for_device_api_port
terminal_service_pid="$(discover_terminal_service_pid || true)"
if [[ -z "$terminal_service_pid" ]]; then
  echo "Failed to discover the spacesd process." >&2
  exit 1
fi
device_api_pid="$terminal_service_pid"
{
  echo "bind_host=$device_api_bind_host"
  echo "client_host=$device_api_host"
  echo "pairing_link=$pairing_link"
  echo "device_api_pid=$device_api_pid"
  echo "terminal_service_pid=$terminal_service_pid"
} >>"$device_api_log"

ipad_installation_id="$(generate_installation_id)"
iphone_installation_id="$(generate_installation_id)"
pairing_json="$temp_root/pairing.json"
ipad_pairing_link="$pairing_link"
ipad_token="$(pair_device "$ipad_pairing_link" "$ipad_installation_id" "$ipad_name" "$device_api_host")"
open_device_pairing_window
iphone_pairing_link="$pairing_link"
iphone_token="$(pair_device "$iphone_pairing_link" "$iphone_installation_id" "$iphone_name" "$device_api_host")"

ipad_remote_token=""
iphone_remote_token=""
if [[ -n "$remote_device_id" ]]; then
  open_remote_device_pairing_window
  ipad_remote_token="$(pair_device "$remote_pairing_link" "$ipad_installation_id" "$ipad_name")"
  open_remote_device_pairing_window
  iphone_remote_token="$(pair_device "$remote_pairing_link" "$iphone_installation_id" "$iphone_name")"
  create_remote_demo_project
fi
write_pairing_json "$pairing_json" "$ipad_installation_id" "$ipad_token" "$iphone_installation_id" "$iphone_token"
ipad_device_seed_json="$(make_device_seed_json "$ipad_token" "$ipad_remote_token")"
iphone_device_seed_json="$(make_device_seed_json "$iphone_token" "$iphone_remote_token")"

write_simulator_settings "$ipad_udid" "$ipad_installation_id" "$ipad_token" "$ios_app_path"
write_simulator_settings "$iphone_udid" "$iphone_installation_id" "$iphone_token" "$ios_app_path"

ipad_launch_pid="$(launch_simulator_app "$ipad_udid" "$ipad_app_stdout_log" "$ipad_app_stderr_log" "$ipad_installation_id" "$ipad_device_seed_json")"
iphone_launch_pid="$(launch_simulator_app "$iphone_udid" "$iphone_app_stdout_log" "$iphone_app_stderr_log" "$iphone_installation_id" "$iphone_device_seed_json")"
sleep 4
xcrun simctl io "$ipad_udid" screenshot "$ipad_screenshot" >/dev/null
xcrun simctl io "$iphone_udid" screenshot "$iphone_screenshot" >/dev/null

write_manual_shell_helper
print_summary
echo
echo "Demo is live. Press Ctrl+C to stop it."
echo "Mac app: $spaces_app"
if [[ -n "$remote_device_id" ]]; then
  echo "Remote device: $remote_device_name ($remote_device_host:$remote_device_port)"
fi
echo "iPad simulator: $ipad_name"
echo "iPhone simulator: $iphone_name"
printf -v demo_env_prefix 'HOME=%q XDG_CONFIG_HOME=%q SPACES_DB_PATH=%q SPACES_RUNTIME_DIR=%q SPACES_CLIENT_DB_PATH=%q SPACES_CLIENT_SECRET_DIR=%q' \
  "$demo_home" "$ghostty_demo_xdg_config_home" "$spaces_db_path" "$spaces_runtime_dir" "$spaces_client_db_path" "$spaces_client_secret_dir"
echo "Manual demo env: $demo_env_prefix"
echo "Helper shell: source $manual_shell_path"
printf 'List sessions: %s %q terminal list\n' "$demo_env_prefix" "$spaces_cli"
printf 'Local Mac retakeover: %s %q terminal show %q\n' "$demo_env_prefix" "$spaces_cli" "$local_session_id"
printf 'Secondary Mac retakeover: %s %q terminal show %q\n' "$demo_env_prefix" "$spaces_cli" "$secondary_session_id"
printf 'Secondary session tail: %s %q terminal tail %q\n' "$demo_env_prefix" "$spaces_cli" "$secondary_session_id"
printf 'Local workspace terminal reopen: %s %q open-workspace-terminal --workspace-dir %q\n' "$demo_env_prefix" "$spacese2e" "$local_project_dir"
printf 'Secondary workspace terminal reopen: %s %q open-workspace-terminal --workspace-dir %q\n' "$demo_env_prefix" "$spacese2e" "$secondary_project_dir"
echo "Helper commands after sourcing:"
echo "  spaces_demo_list"
echo "  spaces_demo_tail"
echo "  spaces_demo_tail_secondary"
echo "  spaces_demo_sendline 'pwd'"
echo "  spaces_demo_sendline_secondary 'pwd'"
echo "  spaces_demo_mac_takeover"
echo "  spaces_demo_secondary_mac_takeover"
echo "  spaces_demo_reopen"
echo "  spaces_demo_reopen_secondary"
echo "  spaces_demo_tail_mac_log"
echo "  spaces_demo_tail_device_api_log"
echo "  spaces_demo_mobile_status"
echo "  spaces_demo_tail_ipad_stderr"

while true; do
  if ! ps -p "$app_pid" >/dev/null 2>&1; then
    echo "SpacesApp exited. Cleaning up demo." >&2
    exit 0
  fi
  if [[ -n "$device_api_pid" && "$device_api_pid" != "$app_pid" ]] && ! ps -p "$device_api_pid" >/dev/null 2>&1; then
    echo "spacesd exited. Cleaning up demo." >&2
    exit 0
  fi
  sleep 1
done
