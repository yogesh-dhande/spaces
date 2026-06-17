#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$repo_root/scripts/spaces-e2e-env.sh"
spaces_e2e_load_env "$repo_root"
source "$script_dir/terminal_harness_lock.sh"
source "$script_dir/e2e_fixture_repos.sh"
source "$repo_root/scripts/spaces-profile-helpers.sh"
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

bridge_bind_host="${SPACES_MOBILE_DEMO_BIND_HOST:-0.0.0.0}"
bridge_host="${SPACES_MOBILE_DEMO_HOST:-127.0.0.1}"
bridge_port="${SPACES_MOBILE_DEMO_PORT:-47847}"
pairing_link=""
pairing_code=""
pairing_nonce=""
transport_key=""
certificate_fingerprint=""
workspace_title="${SPACES_MOBILE_DEMO_WORKSPACE_TITLE:-Local Demo}"
remote_workspace_title="${SPACES_MOBILE_DEMO_REMOTE_WORKSPACE_TITLE:-Remote Demo}"
ipad_name="${SPACES_MOBILE_DEMO_IPAD_NAME:-iPad Pro 13-inch (M5)}"
iphone_name="${SPACES_MOBILE_DEMO_IPHONE_NAME:-iPhone 17 Pro}"
bundle_id="dev.usespaces.spacesmobile"
keep_root="${SPACES_MOBILE_DEMO_KEEP_ROOT:-0}"
app_path_override="${SPACES_MOBILE_DEMO_APP_PATH:-}"
demo_trace="${SPACES_MOBILE_DEMO_TRACE:-1}"
build_macos="${SPACES_MOBILE_DEMO_BUILD_MACOS:-1}"
remote_host_id="${SPACES_E2E_REMOTE_HOST_ID:-mobile-demo-remote}"
remote_host_name="${SPACES_E2E_REMOTE_NAME:-Mobile Demo Remote}"
remote_ssh_host="${SPACES_E2E_REMOTE_SSH_HOST:-}"
remote_ssh_user="${SPACES_E2E_REMOTE_SSH_USER:-}"
remote_ssh_port="${SPACES_E2E_REMOTE_SSH_PORT:-}"
remote_workspace_root="${SPACES_E2E_REMOTE_WORKSPACE_ROOT:-~/.spaces/workspaces}"
remote_daemon_host="${SPACES_E2E_REMOTE_DAEMON_HOST:-$remote_ssh_host}"
remote_daemon_port="${SPACES_E2E_REMOTE_DAEMON_PORT:-7443}"
remote_auth_token="${SPACES_E2E_REMOTE_AUTH_TOKEN:-}"
remote_git_root="${SPACES_E2E_REMOTE_GIT_ROOT:-~/.spaces/e2e-git}"

app_pid=""
bridge_pid=""
temp_root=""
spaces_db_path=""
spaces_runtime_dir=""
project_dir=""
local_project_dir=""
remote_project_dir=""
session_id=""
local_session_id=""
remote_session_id=""
secondary_session_id=""
ipad_udid=""
iphone_udid=""
app_log=""
bridge_log=""
app_recovery_state_path=""
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
terminal_service_pid=""
performance_log_path=""
ghostty_demo_xdg_config_home=""
demo_home=""
app_recovery_wait_logged=0

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
  if [[ -n "$remote_auth_token" ]]; then
    env_args+=("$(remote_auth_token_env_key)=$remote_auth_token" "SPACES_E2E_REMOTE_AUTH_TOKEN=$remote_auth_token")
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
    SPACES_MOBILE_BRIDGE_HOST="$bridge_bind_host" \
    SPACES_MOBILE_BRIDGE_PORT="$bridge_port" \
    "$spacese2e" stop-workspace --workspace-dir "$workspace_dir" >/dev/null 2>&1 || true
}

stop_demo_workspace() {
  stop_demo_workspace_dir "$local_project_dir"
  stop_demo_workspace_dir "$remote_project_dir"
}

terminal_service_socket_path() {
  python3 - "$spaces_runtime_dir" <<'PY'
import pathlib
import sys

runtime_dir = pathlib.Path(sys.argv[1])
terminal_root = runtime_dir / "terminal"
hash_value = 5381
for byte in str(terminal_root).encode("utf-8"):
    hash_value = ((hash_value << 5) + hash_value + byte) & 0xFFFFFFFFFFFFFFFF
print(f"/tmp/spaces-terminal-sockets/service-{hash_value:016x}.sock")
PY
}

discover_terminal_service_pid() {
  local service_socket_path
  service_socket_path="$(terminal_service_socket_path)"
  if [[ ! -S "$service_socket_path" ]]; then
    return
  fi
  lsof -nP -t "$service_socket_path" 2>/dev/null | head -n 1 || true
}

stop_terminal_service() {
  if [[ -z "$spaces_runtime_dir" ]]; then
    return
  fi
  local service_pid
  service_pid="$(discover_terminal_service_pid || true)"
  if [[ -n "$service_pid" && "$service_pid" != "$app_pid" ]]; then
    kill "$service_pid" >/dev/null 2>&1 || true
    wait "$service_pid" >/dev/null 2>&1 || true
  fi
}

stop_mobile_bridge() {
  if [[ -n "$bridge_pid" && "$bridge_pid" != "$terminal_service_pid" ]]; then
    kill "$bridge_pid" >/dev/null 2>&1 || true
    wait "$bridge_pid" >/dev/null 2>&1 || true
    bridge_pid=""
  fi
}

cleanup() {
  stop_demo_workspace
  stop_mobile_bridge
  stop_terminal_service
  cleanup_remote_e2e_host
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

require_remote_configuration() {
  if [[ -z "$remote_ssh_host" ]]; then
    echo "SPACES_E2E_REMOTE_SSH_HOST is required for the mixed local/remote mobile demo." >&2
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

remote_ssh_destination() {
  if [[ -n "$remote_ssh_user" ]]; then
    printf '%s@%s' "$remote_ssh_user" "$remote_ssh_host"
  else
    printf '%s' "$remote_ssh_host"
  fi
}

remote_ssh() {
  require_remote_configuration
  local destination
  destination="$(remote_ssh_destination)"
  local -a args=(-o BatchMode=yes)
  if [[ -n "$remote_ssh_port" ]]; then
    args+=(-p "$remote_ssh_port")
  fi
  ssh "${args[@]}" "$destination" "$@"
}

remote_expand_path() {
  local raw_path="$1"
  local quoted
  quoted="$(shell_quote "$raw_path")"
  remote_ssh "python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' $quoted"
}

remote_push_url_for_path() {
  local remote_path="$1"
  local user_prefix=""
  local port_part=""
  if [[ -n "$remote_ssh_user" ]]; then
    user_prefix="$remote_ssh_user@"
  fi
  if [[ -n "$remote_ssh_port" ]]; then
    port_part=":$remote_ssh_port"
  fi
  printf 'ssh://%s%s%s%s\n' "$user_prefix" "$remote_ssh_host" "$port_part" "$remote_path"
}

remote_auth_token_env_key() {
  printf 'SPACESD_AUTH_TOKEN_%s\n' "$(printf '%s' "$remote_host_id" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')"
}

export_remote_auth_token() {
  [[ -n "$remote_auth_token" ]] || return 0
  local key
  key="$(remote_auth_token_env_key)"
  export "$key=$remote_auth_token"
}

prepare_remote_managed_artifact() {
  require_remote_configuration
  "$repo_root/apps/macos/scripts/deploy_linux_spacesd_e2e.sh"
}

cleanup_remote_e2e_host() {
  [[ -n "$remote_ssh_host" ]] || return 0
  "$repo_root/apps/macos/scripts/cleanup_linux_spacesd_e2e.sh" >/dev/null 2>&1 || true
}

prepare_remote_git_origin() {
  local project_dir_for_origin="$1"
  local slug="$2"
  local git_root
  git_root="$(remote_expand_path "$remote_git_root")" || return
  local remote_origin="$git_root/$slug.git"
  local quoted_root quoted_origin
  quoted_root="$(shell_quote "$git_root")"
  quoted_origin="$(shell_quote "$remote_origin")"
  remote_ssh "mkdir -p $quoted_root && rm -rf $quoted_origin && git init --bare -q $quoted_origin" || return
  local push_url
  push_url="$(remote_push_url_for_path "$remote_origin")"
  local ssh_command="ssh"
  if [[ -n "$remote_ssh_port" ]]; then
    ssh_command+=" -p $remote_ssh_port"
  fi
  git -C "$project_dir_for_origin" remote remove origin >/dev/null 2>&1 || true
  git -C "$project_dir_for_origin" remote add origin "$remote_origin" || return
  git -C "$project_dir_for_origin" -c core.sshCommand="$ssh_command" push -q "$push_url" --all || return
  printf '%s\n' "$remote_origin"
}

configure_demo_compute_hosts() {
  require_remote_configuration
  export_remote_auth_token
  local artifact_id artifact_url artifact_sha256 artifact_arch
  local artifact_assignments
  artifact_assignments="$(prepare_remote_managed_artifact)" || {
    echo "Remote managed artifact preparation failed." >&2
    exit 1
  }
  eval "$artifact_assignments" || {
    echo "Remote managed artifact assignment parsing failed." >&2
    exit 1
  }

  local slug
  slug="$(basename "$temp_root" | tr -cd 'A-Za-z0-9_.-')"
  [[ -n "$slug" ]] || slug="mobile-demo"
  prepare_remote_git_origin "$remote_project_dir" "mobile-demo-$slug-scout" >>"$temp_root/remote-git-origin.log" 2>&1 \
    || {
      echo "Remote git fixture setup failed. See $temp_root/remote-git-origin.log" >&2
      exit 1
    }

  local -a args=(
    remote-compute-host-smoke
    --project-dir "$remote_project_dir"
    --host-id "$remote_host_id"
    --name "$remote_host_name"
    --ssh-host "$remote_ssh_host"
    --workspace-root "$remote_workspace_root"
    --daemon-port "$remote_daemon_port"
    --managed-artifact-id "$artifact_id"
    --managed-artifact-url "$artifact_url"
    --managed-artifact-sha256 "$artifact_sha256"
  )
  if [[ -n "$remote_ssh_user" ]]; then args+=(--ssh-user "$remote_ssh_user"); fi
  if [[ -n "$remote_ssh_port" ]]; then args+=(--ssh-port "$remote_ssh_port"); fi
  if [[ -n "$remote_daemon_host" ]]; then args+=(--daemon-host "$remote_daemon_host"); fi
  if [[ -n "$remote_auth_token" ]]; then args+=(--auth-token "$remote_auth_token"); fi
  run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    SPACESD_EXECUTABLE="$terminal_service" \
    "$spacese2e" "${args[@]}" >"$temp_root/remote-compute-host-smoke.json" 2>"$temp_root/remote-compute-host-smoke.stderr.log" \
    || {
      echo "Remote compute host smoke failed. See $temp_root/remote-compute-host-smoke.stderr.log" >&2
      exit 1
    }
  remote_project_dir="$(json_get "$temp_root/remote-compute-host-smoke.json" "workspace.dir")"
  if [[ -z "$remote_project_dir" ]]; then
    echo "Remote compute host smoke did not return a workspace directory." >&2
    exit 1
  fi
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
  if [[ "$profile_mode" == "isolated" ]]; then
    spaces_db_path="$temp_root/spaces.db"
    spaces_runtime_dir="$temp_root/runtime"
    mkdir -p "$spaces_runtime_dir" "$project_dir"
  else
    resolve_user_profile_paths
    mkdir -p "$spaces_runtime_dir" "$(dirname "$spaces_db_path")" "$project_dir"
  fi

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

stop_bridge_port_listeners() {
  if [[ "$bridge_port" == "0" ]]; then
    return
  fi
  local pid command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(process_command "$pid")"
    if [[ "$command" != *"$repo_root"* || ( "$command" != *"spacesd"* && "$command" != *"SpacesApp"* ) ]]; then
      echo "Refusing to stop non-Spaces listener on mobile demo port $bridge_port: pid=$pid command=$command" >&2
      lsof -nP -iTCP:"$bridge_port" -sTCP:LISTEN >&2 || true
      exit 1
    fi
    echo "Stopping stale Spaces listener on mobile demo port $bridge_port: pid=$pid." >&2
    terminate_pid "$pid" "mobile bridge listener"
  done < <(lsof -tiTCP:"$bridge_port" -sTCP:LISTEN 2>/dev/null || true)
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

read_recovered_app_pid() {
  [[ -n "$app_recovery_state_path" && -f "$app_recovery_state_path" ]] || return 1
  python3 - "$app_recovery_state_path" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    payload = json.loads(path.read_text())
except Exception:
    raise SystemExit(1)
pid = payload.get("newAppPID")
if not isinstance(pid, int) or pid <= 0:
    raise SystemExit(1)
print(pid)
PY
}

process_command() {
  local pid="$1"
  ps -p "$pid" -o command= 2>/dev/null || true
}

continue_after_app_recovery_if_needed() {
  [[ -n "$app_recovery_state_path" && -f "$app_recovery_state_path" ]] || return 1

  local recovered_pid
  if ! recovered_pid="$(read_recovered_app_pid)"; then
    if [[ "$app_recovery_wait_logged" != "1" ]]; then
      echo "SpacesApp exited during app recovery. Waiting for recovered app owner." >&2
      app_recovery_wait_logged=1
    fi
    return 0
  fi

  local command
  command="$(process_command "$recovered_pid")"
  if [[ -z "$command" || "$command" != *"SpacesApp"* ]]; then
    if [[ "$app_recovery_wait_logged" != "1" ]]; then
      echo "SpacesApp recovery marker has no live SpacesApp replacement yet. Waiting." >&2
      app_recovery_wait_logged=1
    fi
    return 0
  fi

  app_pid="$recovered_pid"
  app_recovery_wait_logged=0
  rm -f "$app_recovery_state_path" >/dev/null 2>&1 || true
  echo "SpacesApp recovered with pid $app_pid. Continuing demo." >&2
  return 0
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

open_mobile_pairing_window() {
  local window_json
  if ! window_json="$(
    run_demo_env \
      HOME="$demo_home" \
      SPACES_DB_PATH="$spaces_db_path" \
      SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
      SPACESD_EXECUTABLE="$terminal_service" \
      SPACES_MOBILE_BRIDGE_HOST="$bridge_bind_host" \
      SPACES_MOBILE_BRIDGE_PORT="$bridge_port" \
      "$spacese2e" open-mobile-pairing-window
  )"; then
    echo "Failed to open daemon mobile pairing window." >&2
    cat "$bridge_log" >&2 || true
    exit 1
  fi

  local parsed_status
  parsed_status="$(
    python3 - "$window_json" <<'PY'
import json
import shlex
import sys

payload = json.loads(sys.argv[1])
print(f"bridge_port={shlex.quote(str(payload['port']))}")
print(f"pairing_link={shlex.quote(payload['pairingLink'])}")
print(f"pairing_code={shlex.quote(payload['pairingCode'])}")
print(f"pairing_nonce={shlex.quote(payload['pairingNonce'])}")
print(f"transport_key={shlex.quote(payload['transportKey'])}")
print(f"certificate_fingerprint={shlex.quote(payload['certificateFingerprint'])}")
print(f"expires_at={shlex.quote(payload['expiresAt'])}")
PY
  )"
  eval "$parsed_status"
  printf 'Spaces mobile pairing window\thost=%s\tport=%s\tpairing_link=%s\tpairing_code=%s\texpires_at=%s\n' \
    "$bridge_bind_host" "$bridge_port" "$pairing_link" "$pairing_code" "$expires_at" >>"$bridge_log"
}

start_mobile_bridge() {
  local -a bridge_remote_auth_env=()
  if [[ -n "$remote_auth_token" ]]; then
    bridge_remote_auth_env=("$(remote_auth_token_env_key)=$remote_auth_token" "SPACES_E2E_REMOTE_AUTH_TOKEN=$remote_auth_token")
  fi

  if ! run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    SPACESD_EXECUTABLE="$terminal_service" \
    SPACES_MOBILE_BRIDGE_HOST="$bridge_bind_host" \
    SPACES_MOBILE_BRIDGE_PORT="$bridge_port" \
    SPACES_MOBILE_BRIDGE_TRACE="${SPACES_MOBILE_BRIDGE_TRACE:-1}" \
    "${bridge_remote_auth_env[@]}" \
    "$spacese2e" mobile-status >"$bridge_log" 2>&1; then
    echo "Timed out waiting for daemon mobile bridge readiness." >&2
    cat "$bridge_log" >&2 || true
    exit 1
  fi

  open_mobile_pairing_window
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

wait_for_session_owner() {
  local owner_session_id="$1"
  python3 - "$spaces_db_path" "$spaces_runtime_dir" "$owner_session_id" <<'PY'
import os
import sqlite3
import sys
import time

db_path = sys.argv[1]
root_directory = os.path.normpath(os.path.join(sys.argv[2], "terminal", "sessions", sys.argv[3]))
session_id = sys.argv[3]
deadline = time.time() + 30
last_snapshot = ""
while time.time() < deadline:
    with sqlite3.connect(db_path) as db:
        rows = db.execute(
            """
            SELECT client_id, mode, COALESCE(detached_at, '')
            FROM terminal_attachments
            WHERE root_directory = ?
            ORDER BY attached_at, id
            """,
            (root_directory,),
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
    SPACES_MOBILE_BRIDGE_HOST="$bridge_bind_host" \
    SPACES_MOBILE_BRIDGE_PORT="$bridge_port" \
    "$spaces_cli" terminal show "$owner_session_id" >/dev/null
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
  local workspace_dir="$1"
  run_demo_env \
    HOME="$demo_home" \
    SPACES_DB_PATH="$spaces_db_path" \
    SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
    SPACESD_EXECUTABLE="$terminal_service" \
    SPACES_MOBILE_BRIDGE_HOST="$bridge_bind_host" \
    SPACES_MOBILE_BRIDGE_PORT="$bridge_port" \
    "$spacese2e" open-workspace-terminal --workspace-dir "$workspace_dir"
}

extract_workspace_id() {
  python3 - "$1" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(payload.get("id", ""))
PY
}

new_session_id_since() {
  local before_file="$1"
  python3 - "$spaces_runtime_dir" "$before_file" <<'PY'
import pathlib
import sys

runtime_dir = pathlib.Path(sys.argv[1])
before_path = pathlib.Path(sys.argv[2])
known = {line.strip() for line in before_path.read_text().splitlines() if line.strip()} if before_path.exists() else set()
sessions_root = runtime_dir / "terminal" / "sessions"
if not sessions_root.exists():
    raise SystemExit(1)
for path in sorted(sessions_root.iterdir(), key=lambda item: item.stat().st_mtime, reverse=True):
    if path.is_dir() and path.name not in known:
        print(path.name)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

open_workspace_terminal_session() {
  local workspace_dir="$1"
  local label="$2"
  local before_file="$temp_root/$label-session-ids-before.txt"
  local workspace_open_payload workspace_id discovered_session_id

  discover_session_ids >"$before_file"
  workspace_open_payload="$(open_demo_workspace_terminal "$workspace_dir")"
  workspace_id="$(extract_workspace_id "$workspace_open_payload")"
  for attempt in $(seq 1 3); do
    for _ in $(seq 1 20); do
      discovered_session_id="$(new_session_id_since "$before_file" 2>/dev/null || true)"
      if [[ -n "$discovered_session_id" ]]; then
        printf '%s\n' "$discovered_session_id"
        return 0
      fi
      if [[ -n "$workspace_id" ]] && [[ "$(discover_workspace_running_state "$workspace_id")" == "1" ]]; then
        sleep 1
        continue
      fi
      sleep 1
    done
    if [[ "$attempt" -lt 3 ]]; then
      workspace_open_payload="$(open_demo_workspace_terminal "$workspace_dir")"
      workspace_id="$(extract_workspace_id "$workspace_open_payload")"
    fi
  done

  echo "Failed to discover the $label terminal session." >&2
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
  python3 - "$device_pairing_link" "$spacese2e" "$bridge_host" "$bundle_id" "$installation_id" "$device_name" <<'PY'
import json
import subprocess
import sys

(
    pairing_link,
    spacese2e,
    host,
    bundle_id,
    installation_id,
    device_name,
) = sys.argv[1:]

def send(pairing_link, request):
    completed = subprocess.run(
        [
            spacese2e,
            "mobile-request",
            "--pairing-link",
            pairing_link,
            "--host",
            host,
            "--request-json",
            json.dumps(request),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout)

def pair(pairing_link, installation_id, device_name):
    response = send(pairing_link, {
        "command": "pair",
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

print(pair(pairing_link, installation_id, device_name))
PY
}

write_pairing_json() {
  local output_path="$1"
  local ipad_installation_id="$2"
  local ipad_token="$3"
  local iphone_installation_id="$4"
  local iphone_token="$5"
  python3 - "$output_path" "$transport_key" "$certificate_fingerprint" "$ipad_installation_id" "$ipad_token" "$iphone_installation_id" "$iphone_token" <<'PY'
import json
import sys

output_path, transport_key, certificate_fingerprint, ipad_installation_id, ipad_token, iphone_installation_id, iphone_token = sys.argv[1:]
payload = {
    "ipad": {
        "installationID": ipad_installation_id,
        "authToken": ipad_token,
        "transportKey": transport_key,
        "certificateFingerprint": certificate_fingerprint,
    },
    "iphone": {
        "installationID": iphone_installation_id,
        "authToken": iphone_token,
        "transportKey": transport_key,
        "certificateFingerprint": certificate_fingerprint,
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

  python3 - "$udid" "$bundle_id" "$bridge_host" "$bridge_port" "$transport_key" "$certificate_fingerprint" "$installation_id" "$auth_token" <<'PY'
import json
import pathlib
import plistlib
import subprocess
import sys

udid, bundle_id, host, port_text, transport_key, certificate_fingerprint, installation_id, auth_token = sys.argv[1:]
port = int(port_text)
container = subprocess.check_output(["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"], text=True).strip()
prefs_path = pathlib.Path(container) / "Library" / "Preferences" / f"{bundle_id}.plist"
prefs_path.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "host": host,
    "port": port,
    "transportKey": transport_key,
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
  python3 - "$temp_root" "$profile_mode" "$demo_home" "$app_pid" "$bridge_pid" "$terminal_service_pid" "$local_session_id" "$remote_session_id" "$spaces_db_path" "$spaces_runtime_dir" "$local_project_dir" "$remote_project_dir" "$app_log" "$bridge_log" "$performance_log_path" "$ipad_screenshot" "$iphone_screenshot" "$ipad_udid" "$iphone_udid" "$bridge_bind_host" "$bridge_host" "$bridge_port" "$workspace_title" "$remote_workspace_title" "$ios_app_path" "$ios_build_log" "$ios_derived_data" "$ipad_app_stdout_log" "$ipad_app_stderr_log" "$iphone_app_stdout_log" "$iphone_app_stderr_log" <<'PY'
import json
import sys

(
    root,
    profile_mode,
    home,
    app_pid,
    bridge_pid,
    terminal_service_pid,
    local_session_id,
    remote_session_id,
    db_path,
    runtime_dir,
    local_project_dir,
    remote_project_dir,
    app_log,
    bridge_log,
    performance_log_path,
    ipad_screenshot,
    iphone_screenshot,
    ipad_udid,
    iphone_udid,
    bridge_bind_host,
    bridge_host,
    bridge_port,
    workspace_title,
    remote_workspace_title,
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
    "profileMode": profile_mode,
    "home": home,
    "appPID": int(app_pid),
    "bridgePID": int(bridge_pid),
    "terminalServicePID": int(terminal_service_pid) if terminal_service_pid else None,
    "bridgeBindHost": bridge_bind_host,
    "bridgeHost": bridge_host,
    "bridgePort": int(bridge_port),
    "sessionID": local_session_id,
    "localSessionID": local_session_id,
    "remoteSessionID": remote_session_id,
    "secondarySessionID": remote_session_id or None,
    "sessionIDs": [value for value in (local_session_id, remote_session_id) if value],
    "workspaceTitle": workspace_title,
    "localWorkspaceTitle": workspace_title,
    "remoteWorkspaceTitle": remote_workspace_title,
    "dbPath": db_path,
    "runtimeDir": runtime_dir,
    "projectDir": local_project_dir,
    "localProjectDir": local_project_dir,
    "remoteProjectDir": remote_project_dir,
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
export HOME=$(printf '%q' "$demo_home")
export XDG_CONFIG_HOME=$(printf '%q' "$ghostty_demo_xdg_config_home")
export SPACES_DB_PATH=$(printf '%q' "$spaces_db_path")
export SPACES_RUNTIME_DIR=$(printf '%q' "$spaces_runtime_dir")
export SPACESD_EXECUTABLE=$(printf '%q' "$terminal_service")
export SPACES_MOBILE_BRIDGE_HOST=$(printf '%q' "$bridge_bind_host")
export SPACES_MOBILE_BRIDGE_PORT=$(printf '%q' "$bridge_port")
export SPACES_MOBILE_PAIRING_LINK=$(printf '%q' "$pairing_link")
export SPACES_MOBILE_TRANSPORT_KEY=$(printf '%q' "$transport_key")
export SPACES_DEMO_ROOT=$(printf '%q' "$temp_root")
export SPACES_DEMO_SESSION_ID=$(printf '%q' "$local_session_id")
export SPACES_DEMO_LOCAL_SESSION_ID=$(printf '%q' "$local_session_id")
export SPACES_DEMO_REMOTE_SESSION_ID=$(printf '%q' "$remote_session_id")
export SPACES_DEMO_SECONDARY_SESSION_ID=$(printf '%q' "$remote_session_id")
export SPACES_DEMO_PROJECT_DIR=$(printf '%q' "$local_project_dir")
export SPACES_DEMO_LOCAL_PROJECT_DIR=$(printf '%q' "$local_project_dir")
export SPACES_DEMO_REMOTE_PROJECT_DIR=$(printf '%q' "$remote_project_dir")
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
  "\$SPACES_CLI" terminal tail "\$SPACES_DEMO_REMOTE_SESSION_ID"
}

spaces_demo_send() {
  "\$SPACES_CLI" terminal send "\$SPACES_DEMO_SESSION_ID" "\$@"
}

spaces_demo_send_secondary() {
  "\$SPACES_CLI" terminal send "\$SPACES_DEMO_REMOTE_SESSION_ID" "\$@"
}

spaces_demo_sendline() {
  "\$SPACES_CLI" terminal send "\$SPACES_DEMO_SESSION_ID" "\$1" --newline
}

spaces_demo_sendline_secondary() {
  "\$SPACES_CLI" terminal send "\$SPACES_DEMO_REMOTE_SESSION_ID" "\$1" --newline
}

spaces_demo_enter() {
  "\$SPACES_CLI" terminal key "\$SPACES_DEMO_SESSION_ID" enter
}

spaces_demo_mac_takeover() {
  "\$SPACES_CLI" terminal show "\$SPACES_DEMO_SESSION_ID"
}

spaces_demo_remote_mac_takeover() {
  "\$SPACES_CLI" terminal show "\$SPACES_DEMO_REMOTE_SESSION_ID"
}

spaces_demo_reopen() {
  "\$SPACES_E2E" open-workspace-terminal --workspace-dir "\$SPACES_DEMO_PROJECT_DIR"
}

spaces_demo_reopen_remote() {
  "\$SPACES_E2E" open-workspace-terminal --workspace-dir "\$SPACES_DEMO_REMOTE_PROJECT_DIR"
}

spaces_demo_tail_mac_log() {
  tail -f "\$SPACES_DEMO_ROOT/app.log"
}

spaces_demo_tail_bridge_log() {
  tail -f "\$SPACES_DEMO_ROOT/bridge.log"
}

spaces_demo_mobile_status() {
  "\$SPACES_E2E" mobile-status
}

spaces_demo_tail_ipad_stderr() {
  tail -f "\$SPACES_DEMO_ROOT/ipad-app.stderr.log"
}
EOF
  if [[ -n "$remote_auth_token" ]]; then
    local remote_auth_key
    remote_auth_key="$(remote_auth_token_env_key)"
    printf 'export %s=%q\n' "$remote_auth_key" "$remote_auth_token" >>"$manual_shell_path"
  fi
  chmod +x "$manual_shell_path"
}

require_path "$ghostty_xcframework" "GhosttyKit.xcframework"
require_path "$ghostty_resources" "Ghostty resources"
validate_profile_mode
require_remote_configuration
build_macos_debug_products
require_executable "$spaces_app" "SpacesApp"
require_executable "$spaces_cli" "spaces CLI"
require_executable "$spacese2e" "spacese2e"
require_executable "$terminal_service" "spacesd"

create_demo_root
project_dir="$temp_root/beacon-status"
local_project_dir="$project_dir"
remote_project_dir="$temp_root/scout-errors"
app_log="$temp_root/app.log"
bridge_log="$temp_root/bridge.log"
app_recovery_state_path="$temp_root/app-recovery-state.json"
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
stop_bridge_port_listeners

spaces_e2e_create_beacon_fixture_repo "$fixture_template_dir" "$local_project_dir"
spaces_e2e_create_scout_fixture_repo "$fixture_template_dir" "$remote_project_dir"

run_demo_env \
  HOME="$demo_home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACESD_EXECUTABLE="$terminal_service" \
  SPACES_MOBILE_BRIDGE_HOST="$bridge_bind_host" \
  SPACES_MOBILE_BRIDGE_PORT="$bridge_port" \
  SPACES_PROJECT_DIR="$repo_root" \
  "$spacese2e" seed-fixture \
    --project-dir "$local_project_dir" \
    --docs-url "http://127.0.0.1:20001" \
    --admin-url "http://127.0.0.1:20002" \
    --workspace-title "$workspace_title" >/dev/null

run_demo_env \
  HOME="$demo_home" \
  SPACES_DB_PATH="$spaces_db_path" \
  SPACES_RUNTIME_DIR="$spaces_runtime_dir" \
  SPACESD_EXECUTABLE="$terminal_service" \
  SPACES_MOBILE_BRIDGE_HOST="$bridge_bind_host" \
  SPACES_MOBILE_BRIDGE_PORT="$bridge_port" \
  SPACES_PROJECT_DIR="$repo_root" \
  "$spacese2e" seed-fixture \
    --project-dir "$remote_project_dir" \
    --docs-url "http://127.0.0.1:20003" \
    --admin-url "http://127.0.0.1:20004" \
    --workspace-title "$remote_workspace_title" >/dev/null

configure_demo_compute_hosts

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
open_simulator_app
boot_device "$ipad_udid"
boot_device "$iphone_udid"

remote_auth_env=()
if [[ -n "$remote_auth_token" ]]; then
  remote_auth_env=("$(remote_auth_token_env_key)=$remote_auth_token" "SPACES_E2E_REMOTE_AUTH_TOKEN=$remote_auth_token")
fi

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
  SPACESD_EXECUTABLE="$terminal_service" \
  SPACES_MOBILE_BRIDGE_HOST="$bridge_bind_host" \
  SPACES_MOBILE_BRIDGE_PORT="$bridge_port" \
  SPACES_GHOSTTYKIT_XCFRAMEWORK="$ghostty_xcframework" \
  SPACES_GHOSTTY_RESOURCES_DIR="$ghostty_resources" \
  SPACES_MOBILE_TERMINAL_TRACE="$demo_trace" \
  SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$performance_log_path" \
  "${remote_auth_env[@]}" \
  "$spaces_app" >"$app_log" 2>&1 &
app_pid=$!
wait_for_pid "$app_pid" "SpacesApp"

local_session_id="$(open_workspace_terminal_session "$local_project_dir" "local")"
session_id="$local_session_id"
show_session_on_mac "$local_session_id"
wait_for_session_owner "$local_session_id"

remote_session_id="$(open_workspace_terminal_session "$remote_project_dir" "remote")"
secondary_session_id="$remote_session_id"
show_session_on_mac "$remote_session_id"
wait_for_session_owner "$remote_session_id"

start_mobile_bridge
wait_for_bridge_port
terminal_service_pid="$(discover_terminal_service_pid || true)"
if [[ -z "$terminal_service_pid" ]]; then
  echo "Failed to discover the spacesd process." >&2
  exit 1
fi
bridge_pid="$terminal_service_pid"
{
  echo "bind_host=$bridge_bind_host"
  echo "client_host=$bridge_host"
  echo "pairing_link=$pairing_link"
  echo "bridge_pid=$bridge_pid"
  echo "terminal_service_pid=$terminal_service_pid"
} >>"$bridge_log"

ipad_installation_id="$(generate_installation_id)"
iphone_installation_id="$(generate_installation_id)"
pairing_json="$temp_root/pairing.json"
ipad_pairing_link="$pairing_link"
ipad_token="$(pair_device "$ipad_pairing_link" "$ipad_installation_id" "$ipad_name")"
open_mobile_pairing_window
iphone_pairing_link="$pairing_link"
iphone_token="$(pair_device "$iphone_pairing_link" "$iphone_installation_id" "$iphone_name")"
write_pairing_json "$pairing_json" "$ipad_installation_id" "$ipad_token" "$iphone_installation_id" "$iphone_token"

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
printf -v demo_env_prefix 'HOME=%q XDG_CONFIG_HOME=%q SPACES_DB_PATH=%q SPACES_RUNTIME_DIR=%q' "$demo_home" "$ghostty_demo_xdg_config_home" "$spaces_db_path" "$spaces_runtime_dir"
echo "Manual demo env: $demo_env_prefix"
echo "Helper shell: source $manual_shell_path"
printf 'List sessions: %s %q terminal list\n' "$demo_env_prefix" "$spaces_cli"
printf 'Local Mac retakeover: %s %q terminal show %q\n' "$demo_env_prefix" "$spaces_cli" "$local_session_id"
printf 'Remote Mac retakeover: %s %q terminal show %q\n' "$demo_env_prefix" "$spaces_cli" "$remote_session_id"
printf 'Remote session tail: %s %q terminal tail %q\n' "$demo_env_prefix" "$spaces_cli" "$remote_session_id"
printf 'Local workspace terminal reopen: %s %q open-workspace-terminal --workspace-dir %q\n' "$demo_env_prefix" "$spacese2e" "$local_project_dir"
printf 'Remote workspace terminal reopen: %s %q open-workspace-terminal --workspace-dir %q\n' "$demo_env_prefix" "$spacese2e" "$remote_project_dir"
echo "Helper commands after sourcing:"
echo "  spaces_demo_list"
echo "  spaces_demo_tail"
echo "  spaces_demo_tail_secondary"
echo "  spaces_demo_sendline 'pwd'"
echo "  spaces_demo_sendline_secondary 'pwd'"
echo "  spaces_demo_mac_takeover"
echo "  spaces_demo_remote_mac_takeover"
echo "  spaces_demo_reopen"
echo "  spaces_demo_reopen_remote"
echo "  spaces_demo_tail_mac_log"
echo "  spaces_demo_tail_bridge_log"
echo "  spaces_demo_mobile_status"
echo "  spaces_demo_tail_ipad_stderr"

while true; do
  if ! ps -p "$app_pid" >/dev/null 2>&1; then
    if continue_after_app_recovery_if_needed; then
      sleep 1
      continue
    fi
    echo "SpacesApp exited. Cleaning up demo." >&2
    exit 0
  fi
  if [[ -n "$bridge_pid" && "$bridge_pid" != "$app_pid" ]] && ! ps -p "$bridge_pid" >/dev/null 2>&1; then
    echo "spacesd exited. Cleaning up demo." >&2
    exit 0
  fi
  sleep 1
done
