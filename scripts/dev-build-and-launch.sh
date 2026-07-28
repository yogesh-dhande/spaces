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

# The app inherits this shell's environment and nothing profile-shaped is added to it: the repo-local
# SpacesApp resolves its own worktree profile from where it sits in the checkout. Only an explicit
# SPACES_DEV_DB_PATH throwaway profile, exported below, reaches it — as an inherited SPACES_DB_PATH.
launch_app_detached() {
  python3 - "$APP" "$LOG_FILE" <<'PY'
import os
import subprocess
import sys

app_path, log_path = sys.argv[1:]
log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
try:
    env = os.environ.copy()
    env.pop("SPACES_DEVICE_API_DISABLED", None)
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
  local remote_profile_name remote_profile_root quoted_profile_name quoted_profile_root remote_device_api_port
  # The remote development profile is named after this worktree's local profile, so one worktree owns
  # exactly one remote daemon and the app's own remote pairing derives the same profile without being
  # handed a path. The installer needs the name and nothing else: no database, runtime, host, or port
  # environment reaches it, because a profile-rooted binary resolves all of that from its own path.
  remote_profile_name="$(basename "${PROFILE_ROOT:?}")"
  # On the device the name is both a path component under ~/.spaces-dev/profiles/spaces/ and the
  # systemd instance name in spacesd@<name>.service, so the installer accepts only characters that
  # are literal in both. A branch name with a non-ASCII letter slugifies into a profile name that is
  # not, and the deploy would otherwise fail deep in the installer after a full artifact build and
  # upload. Fail here, before any remote work, naming what produced the name.
  if [[ ! "$remote_profile_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Branch '$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)' resolves to development profile '$remote_profile_name', which a Linux device cannot host." >&2
    echo "Profile names may use letters A-Z/a-z, digits, '.', '_', and '-' only. Rename the branch to deploy from this worktree, or launch with --local." >&2
    exit 1
  fi
  artifact_assignments="$("$repo_root/apps/macos/scripts/deploy_linux_spacesd_e2e.sh" --profile "$remote_profile_name")"
  eval "$artifact_assignments"
  artifact_url="${artifact_url:-}"
  [[ "$artifact_url" == file://* ]] || {
    echo "Remote Linux artifact URL must be file://, got: $artifact_url" >&2
    exit 1
  }

  archive_path="${artifact_url#file://}"
  # The staging tree sits beside the uploaded archive, which the deploy helper keyed by profile, so
  # a concurrent deploy of another profile cannot clear this one mid-install.
  install_root="$(dirname "$archive_path")/dev-launch-install"
  quoted_archive="$(remote_shell_quote "$archive_path")"
  quoted_install="$(remote_shell_quote "$install_root")"
  remote_profile_root="$(remote_expand_path "~/.spaces-dev/profiles/spaces/$remote_profile_name")"
  quoted_profile_name="$(remote_shell_quote "$remote_profile_name")"
  quoted_profile_root="$(remote_shell_quote "$remote_profile_root")"
  ssh "${ssh_args[@]}" "$ssh_destination" \
    "rm -rf $quoted_install && mkdir -p $quoted_install && tar -xzf $quoted_archive -C $quoted_install --strip-components=1 && $quoted_install/install.sh --profile $quoted_profile_name" >/dev/null

  # Readiness is the profile's own two facts: systemd holds its unit instance active, and its own CLI
  # gets an answer out of it. There is no well-known port to probe -- the daemon assigns its own.
  ssh "${ssh_args[@]}" "$ssh_destination" "bash -s $quoted_profile_name $quoted_profile_root" <<'REMOTE_WAIT'
set -euo pipefail
profile_name="$1"
profile_root="$2"
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
    if systemctl --user is-active --quiet "spacesd@$profile_name.service" \
        && "$profile_root/daemon/current/bin/spaces" terminal list >/dev/null 2>&1; then
        exit 0
    fi
    sleep 0.5
done
echo "remote spacesd for profile $profile_name did not become ready within 60s" >&2
systemctl --user status "spacesd@$profile_name.service" --no-pager >&2 || true
exit 1
REMOTE_WAIT

  remote_device_api_port="$(ssh "${ssh_args[@]}" "$ssh_destination" "python3 - $quoted_profile_root" <<'PY'
import json
import pathlib
import sys

# The daemon records the Device API port it assigned itself for this profile here at first start.
settings_path = pathlib.Path(sys.argv[1]) / "runtime" / "terminal" / "device-api.json"
print(json.loads(settings_path.read_text())["port"])
PY
  )"
  echo "Remote Linux spacesd is running the current checkout artifact on $ssh_destination."
  echo "Using remote profile root: $remote_profile_root"
  echo "Remote Device API port: $remote_device_api_port"
)

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

# SPACES_DEV_DB_PATH launches this build against a one-off throwaway profile instead of the worktree's
# own. It must name a database outside ~/.spaces and ~/.spaces-dev/profiles; profile resolution refuses
# a live profile root, which is never something this variable should be pointing at. Naming the database
# binds the whole profile, so the runtime root derives from it and is deliberately not set here too.
if [[ -n "${SPACES_DEV_DB_PATH:-}" ]]; then
  export SPACES_DB_PATH="$SPACES_DEV_DB_PATH"
fi

# The paths below are looked up from the profile the binaries themselves resolve, not exported into the
# shell: the app, CLI, and E2E helper all derive their profile from where they sit in this checkout, and
# a shell binding would only be able to point them somewhere that is not their own.
PROFILE_ROOT="$(spaces_profile_field "$CLI" profileRoot)"
PROFILE_DB_PATH="$(spaces_profile_field "$CLI" databasePath)"
PROFILE_RUNTIME_DIR="$(spaces_profile_field "$CLI" runtimeDirectory)"

if [[ "$LOCAL_ONLY" == "0" ]]; then
  deploy_remote_linux_spacesd_if_configured
fi
spaces_profile_stop_running_app "$CLI"
spaces_profile_stop_terminal_service_if_idle "$CLI"

# Relaunch detached and keep logs so launch failures are visible.
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
echo "Using profile root: $PROFILE_ROOT"
echo "Using profile database: $PROFILE_DB_PATH"
echo "Using runtime root: $PROFILE_RUNTIME_DIR"

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
