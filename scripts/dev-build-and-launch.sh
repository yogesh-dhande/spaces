#!/usr/bin/env bash
set -euo pipefail

LOCAL_ONLY=0
for argument in "$@"; do
  case "$argument" in
    --local) LOCAL_ONLY=1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--local]"
      echo "  --local  Skip the remote Linux spacesd deploy configured via .env."
      exit 0
      ;;
    *)
      echo "Unknown argument: $argument (usage: $(basename "$0") [--local])" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
APP="$repo_root/apps/macos/.build/debug/SpacesApp"
CLI="$repo_root/apps/macos/.build/debug/spaces"
LOG_FILE="/tmp/Spaces.log"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
POST_LAUNCH_MONITOR_SECONDS="${SPACES_POST_LAUNCH_MONITOR_SECONDS:-45}"
source "$repo_root/scripts/spaces-profile-helpers.sh"

primary_worktree_dir() {
  local common_git_dir
  common_git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$(basename "$common_git_dir")" == ".git" ]] || return 1
  cd "$common_git_dir/.." && pwd
}

configure_ghostty_cache() {
  if [[ -n "${SPACES_GHOSTTY_CACHE_DIR:-}" ]]; then
    return
  fi

  local project_dir
  if project_dir="$(primary_worktree_dir)"; then
    export SPACES_PROJECT_DIR="${SPACES_PROJECT_DIR:-$project_dir}"
    export SPACES_GHOSTTY_CACHE_DIR="$project_dir/apps/macos/.local/ghostty-cache"
  fi
}

remote_shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

remote_expand_path() {
  local raw_path="$1"
  local quoted_path
  quoted_path="$(remote_shell_quote "$raw_path")"
  ssh "${ssh_args[@]}" "$ssh_destination" "python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' $quoted_path"
}

configured_remote_device_root_override() (
  set -euo pipefail
  source "$repo_root/scripts/spaces-e2e-env.sh"
  spaces_e2e_load_env "$repo_root"
  printf '%s\n' "${SPACES_E2E_REMOTE_DEVICE_ROOT:-}"
)

print_failure_diagnostics() {
  echo "Spaces exited; last log lines:"
  tail -n 80 "$LOG_FILE" || true
  if [ -d "$CRASH_DIR" ]; then
    latest_crash="$(ls -1t "$CRASH_DIR"/SpacesApp-*.ips "$CRASH_DIR"/SpacesApp-*.crash "$CRASH_DIR"/Spaces-*.ips "$CRASH_DIR"/Spaces-*.crash 2>/dev/null | head -n 1 || true)"
    if [ -n "$latest_crash" ]; then
      echo
      echo "Most recent crash report: $latest_crash"
      tail -n 120 "$latest_crash" || true
    fi
  fi
  echo
  echo "Recent unified logs:"
  /usr/bin/log show --style compact --last 2m --predicate 'process == "SpacesApp" OR process == "Spaces"' | tail -n 120 || true
}

launch_app_detached() {
  python3 - "$APP" "$LOG_FILE" "$SPACES_DB_PATH" "$SPACES_RUNTIME_DIR" <<'PY'
import os
import subprocess
import sys

app_path, log_path, db_path, runtime_dir = sys.argv[1:]
log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
try:
    env = os.environ.copy()
    env.pop("SPACES_DEVICE_API_DISABLED", None)
    env["SPACES_DB_PATH"] = db_path
    env["SPACES_RUNTIME_DIR"] = runtime_dir
    env["SPACES_DEVICE_API_PORT"] = "0"
    process = subprocess.Popen(
        [app_path],
        stdin=subprocess.DEVNULL,
        stdout=log_fd,
        stderr=log_fd,
        env=env,
        close_fds=True,
        start_new_session=True,
    )
finally:
    os.close(log_fd)
print(process.pid)
PY
}

deploy_remote_linux_spacesd_if_configured() (
  set -euo pipefail
  source "$repo_root/scripts/spaces-e2e-env.sh"
  spaces_e2e_load_env "$repo_root"

  local remote_host="${SPACES_E2E_REMOTE_SSH_HOST:-}"
  [[ -n "$remote_host" ]] || return 0

  local remote_user="${SPACES_E2E_REMOTE_SSH_USER:-}"
  local remote_port="${SPACES_E2E_REMOTE_SSH_PORT:-}"
  local remote_daemon_port="${SPACES_E2E_REMOTE_DAEMON_PORT:-47847}"
  [[ "$remote_daemon_port" =~ ^[0-9]+$ ]] || {
    echo "SPACES_E2E_REMOTE_DAEMON_PORT must be numeric, got: $remote_daemon_port" >&2
    exit 1
  }

  local ssh_destination="$remote_host"
  if [[ -n "$remote_user" ]]; then
    ssh_destination="$remote_user@$remote_host"
  fi

  local -a ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
  if [[ -n "$remote_port" ]]; then
    ssh_args+=(-p "$remote_port")
  fi

  echo "Preparing remote Linux spacesd from current checkout at $ssh_destination..."
  local artifact_assignments artifact_url archive_path install_root quoted_archive quoted_install
  local remote_profile_name remote_profile_root remote_db_path remote_runtime_dir quoted_remote_db_path quoted_remote_runtime_dir
  artifact_assignments="$("$repo_root/apps/macos/scripts/deploy_linux_spacesd_e2e.sh")"
  eval "$artifact_assignments"
  artifact_url="${artifact_url:-}"
  [[ "$artifact_url" == file://* ]] || {
    echo "Remote Linux artifact URL must be file://, got: $artifact_url" >&2
    exit 1
  }

  archive_path="${artifact_url#file://}"
  install_root="$(dirname "$archive_path")/dev-launch-install"
  quoted_archive="$(remote_shell_quote "$archive_path")"
  quoted_install="$(remote_shell_quote "$install_root")"
  remote_profile_name="$(basename "$(dirname "${SPACES_DB_PATH:?}")")"
  remote_profile_root="${SPACES_E2E_REMOTE_DEVICE_ROOT:-~/.spaces-dev/profiles/spaces/$remote_profile_name}"
  remote_db_path="$(remote_expand_path "$remote_profile_root/spaces.db")"
  remote_runtime_dir="$(remote_expand_path "$remote_profile_root/runtime")"
  quoted_remote_db_path="$(remote_shell_quote "$remote_db_path")"
  quoted_remote_runtime_dir="$(remote_shell_quote "$remote_runtime_dir")"
  ssh "${ssh_args[@]}" "$ssh_destination" \
    "rm -rf $quoted_install && mkdir -p $quoted_install && tar -xzf $quoted_archive -C $quoted_install --strip-components=1 && SPACES_DB_PATH=$quoted_remote_db_path SPACES_RUNTIME_DIR=$quoted_remote_runtime_dir SPACES_DEVICE_API_HOST=0.0.0.0 SPACES_DEVICE_API_PORT=$remote_daemon_port $quoted_install/install.sh" >/dev/null

  ssh "${ssh_args[@]}" "$ssh_destination" "python3 - $(remote_shell_quote "$remote_daemon_port")" <<'PY'
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
raise SystemExit(f"remote spacesd Device API port {port} did not open: {last_error}")
PY
  echo "Remote Linux spacesd is running the current checkout artifact on $ssh_destination."
  echo "Using remote profile database: $remote_db_path"
  echo "Using remote runtime root: $remote_runtime_dir"
)

configure_ghostty_cache
"$repo_root/apps/macos/scripts/setup_ghostty.sh"
"$repo_root/scripts/swiftpm.sh" build

# Ad-hoc signed SwiftPM debug builds get a fresh cdhash on every rebuild, and the cdhash is the
# app's TCC identity — so the macOS Automation grant for Chrome is lost each build. Re-signing with a
# stable identity keeps that identity constant so the grant survives rebuilds. Opt in by setting
# SPACES_DEV_CODESIGN_IDENTITY in the gitignored .env (e.g. an "Apple Development: …" identity).
# The .env is read in a subshell so its e2e host variables never leak into the launched app.
dev_codesign_identity="$(
  set -euo pipefail
  source "$repo_root/scripts/spaces-e2e-env.sh"
  spaces_e2e_load_env "$repo_root"
  printf '%s' "${SPACES_DEV_CODESIGN_IDENTITY:-}"
)"
if [[ -n "$dev_codesign_identity" ]]; then
  codesign --force --preserve-metadata=entitlements --sign "$dev_codesign_identity" "$APP"
fi

spaces_profile_eval_shell_env "$CLI"
if [[ -n "${SPACES_DEV_DB_PATH:-}" ]]; then
  export SPACES_DB_PATH="$SPACES_DEV_DB_PATH"
  if [[ -z "${SPACES_RUNTIME_DIR:-}" ]]; then
    export SPACES_RUNTIME_DIR="$(dirname "$SPACES_DB_PATH")/runtime"
  fi
fi
if [[ "$LOCAL_ONLY" == "0" && -z "${SPACES_E2E_REMOTE_DEVICE_ROOT:-}" ]]; then
  remote_device_root_override="$(configured_remote_device_root_override)"
  if [[ -n "$remote_device_root_override" ]]; then
    export SPACES_E2E_REMOTE_DEVICE_ROOT="$remote_device_root_override"
  fi
fi
if [[ "$LOCAL_ONLY" == "0" ]]; then
  deploy_remote_linux_spacesd_if_configured
fi
spaces_profile_stop_running_app "$CLI"
spaces_profile_stop_terminal_service_if_idle "$CLI"

# Relaunch detached and keep logs so launch failures are visible.
mkdir -p "$(dirname "$SPACES_DB_PATH")"
app_pid="$(launch_app_detached)"

# Bring app to front when possible.
for _ in $(seq 1 12); do
  if kill -0 "$app_pid" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "Spaces exited immediately."
  print_failure_diagnostics
  exit 1
fi

osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is $app_pid to true" >/dev/null 2>&1 || true

echo "Spaces relaunched (pid $app_pid)"
echo "Using profile database: $SPACES_DB_PATH"
echo "Using runtime root: $SPACES_RUNTIME_DIR"

if [ "$POST_LAUNCH_MONITOR_SECONDS" -gt 0 ]; then
  echo "Monitoring launch stability for ${POST_LAUNCH_MONITOR_SECONDS}s..."
  for _ in $(seq 1 "$POST_LAUNCH_MONITOR_SECONDS"); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      echo "Spaces exited during post-launch monitoring window."
      print_failure_diagnostics
      exit 1
    fi
    sleep 1
  done
  echo "Spaces stayed running for ${POST_LAUNCH_MONITOR_SECONDS}s after launch."
fi
