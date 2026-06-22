#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$app_root/../.." && pwd)"
source "$repo_root/scripts/spaces-e2e-env.sh"

spaces_e2e_load_env "$repo_root"

remote_host="${SPACES_E2E_REMOTE_SSH_HOST:-}"
remote_user="${SPACES_E2E_REMOTE_SSH_USER:-}"
remote_port="${SPACES_E2E_REMOTE_SSH_PORT:-}"
remote_daemon_port="${SPACES_E2E_REMOTE_DAEMON_PORT:-7443}"
remote_workspace_root="${SPACES_E2E_REMOTE_WORKSPACE_ROOT:-~/.spaces/e2e-workspaces}"
remote_git_root="${SPACES_E2E_REMOTE_GIT_ROOT:-~/.spaces/e2e-git}"
remote_install_root="${SPACES_E2E_REMOTE_INSTALL_ROOT:-~/.spaces/remote-artifact-e2e}"
remote_device_root="${SPACES_E2E_REMOTE_DEVICE_ROOT:-~/.spaces/remote-device-e2e}"
remote_legacy_install_root="~/.spaces/e2e-tools"

if [[ -z "$remote_host" ]]; then
  echo "SPACES_E2E_REMOTE_SSH_HOST is required." >&2
  exit 1
fi

ssh_destination="$remote_host"
if [[ -n "$remote_user" ]]; then
  ssh_destination="$remote_user@$remote_host"
fi

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
if [[ -n "$remote_port" ]]; then
  ssh_args+=(-p "$remote_port")
fi

cleanup_local_ssh_forwards() {
  local pids
  pids="$(
    python3 - "$ssh_destination" "$remote_port" <<'PY'
import os
import subprocess
import sys

destination = sys.argv[1]
ssh_port = sys.argv[2]
own_pid = os.getpid()

try:
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
except subprocess.SubprocessError:
    raise SystemExit(0)

for raw_line in output.splitlines():
    line = raw_line.strip()
    if not line:
        continue
    pid_text, _, command = line.partition(" ")
    try:
        pid = int(pid_text)
    except ValueError:
        continue
    if pid == own_pid:
        continue
    if "ssh" not in command:
        continue
    if destination not in command:
        continue
    if "-N" not in command or "-L" not in command:
        continue
    if "127.0.0.1:" not in command or ":127.0.0.1:" not in command:
        continue
    if ssh_port and f"-p {ssh_port}" not in command and f"-p{ssh_port}" not in command:
        continue
    print(pid)
PY
  )"
  [[ -n "$pids" ]] || return 0
  echo "==> Stopping local SSH forwards for $ssh_destination: $pids"
  kill $pids >/dev/null 2>&1 || true
  sleep 0.5
  kill -9 $pids >/dev/null 2>&1 || true
}

cleanup_local_ssh_forwards

echo "==> Cleaning remote E2E host $ssh_destination"
ssh "${ssh_args[@]}" "$ssh_destination" \
  "SPACES_E2E_REMOTE_DAEMON_PORT='$remote_daemon_port' \
   SPACES_E2E_REMOTE_WORKSPACE_ROOT='$remote_workspace_root' \
   SPACES_E2E_REMOTE_GIT_ROOT='$remote_git_root' \
   SPACES_E2E_REMOTE_INSTALL_ROOT='$remote_install_root' \
   SPACES_E2E_REMOTE_DEVICE_ROOT='$remote_device_root' \
   SPACES_E2E_REMOTE_LEGACY_INSTALL_ROOT='$remote_legacy_install_root' \
   bash -s" <<'REMOTE_CLEANUP'
set -euo pipefail

expand_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

daemon_port="${SPACES_E2E_REMOTE_DAEMON_PORT:?}"
workspace_root="$(expand_path "${SPACES_E2E_REMOTE_WORKSPACE_ROOT:?}")"
git_root="$(expand_path "${SPACES_E2E_REMOTE_GIT_ROOT:?}")"
install_root="$(expand_path "${SPACES_E2E_REMOTE_INSTALL_ROOT:?}")"
device_root="$(expand_path "${SPACES_E2E_REMOTE_DEVICE_ROOT:?}")"
legacy_install_root="$(expand_path "${SPACES_E2E_REMOTE_LEGACY_INSTALL_ROOT:?}")"
spaces_root="$(expand_path "${HOME}/.spaces")"

mapfile -t e2e_roots < <(
  python3 - "$spaces_root" "$workspace_root" "$git_root" "$install_root" "$device_root" "$legacy_install_root" <<'PY'
import sys
from pathlib import Path

spaces_root = Path(sys.argv[1]).resolve()
protected = {
    spaces_root,
    spaces_root / "bin",
    spaces_root / "daemon",
    spaces_root / "runtime",
    spaces_root / "workspaces",
}

for raw in sys.argv[2:]:
    if not raw:
        continue
    path = Path(raw).resolve()
    if path in protected:
        print(f"skipping protected Spaces path: {path}", file=sys.stderr)
        continue
    if "e2e" not in path.name.lower():
        print(f"skipping non-E2E cleanup root: {path}", file=sys.stderr)
        continue
    print(path)
PY
)

python3 - "${e2e_roots[@]}" <<'PY'
import os
import signal
import sys
import time
from pathlib import Path

roots = [str(Path(arg).resolve()) for arg in sys.argv[1:] if arg]
own_pid = os.getpid()
own_uid = os.getuid()
matches = set()

for proc_dir in Path("/proc").iterdir():
    if not proc_dir.name.isdigit():
        continue
    pid = int(proc_dir.name)
    if pid == own_pid:
        continue
    try:
        if proc_dir.stat().st_uid != own_uid:
            continue
        parts = []
        for name in ("cmdline", "environ"):
            try:
                raw = (proc_dir / name).read_bytes().replace(b"\0", b" ")
                parts.append(raw.decode("utf-8", "replace"))
            except OSError:
                pass
        try:
            parts.append(str((proc_dir / "cwd").resolve()))
        except OSError:
            pass
        haystack = "\n".join(parts)
    except OSError:
        continue
    if any(root and root in haystack for root in roots):
        matches.add(pid)

if matches:
    print("terminating remote E2E pids:", " ".join(str(pid) for pid in sorted(matches)))
for pid in sorted(matches):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
deadline = time.time() + 5
while time.time() < deadline:
    live = []
    for pid in matches:
        try:
            os.kill(pid, 0)
            live.append(pid)
        except ProcessLookupError:
            pass
    if not live:
        break
    time.sleep(0.1)
for pid in sorted(matches):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
PY

if command -v lsof >/dev/null 2>&1 && [[ "$daemon_port" =~ ^[0-9]+$ ]]; then
  pids="$(lsof -tiTCP:"$daemon_port" -sTCP:LISTEN 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    for pid in $pids; do
      command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      should_kill=0
      for root in "${e2e_roots[@]}"; do
        if [[ -n "$root" && "$command_line" == *"$root"* ]]; then
          should_kill=1
          break
        fi
      done
      if [[ "$should_kill" == "1" ]]; then
        kill "$pid" >/dev/null 2>&1 || true
      else
        echo "leaving non-E2E listener on remote daemon port $daemon_port: pid=$pid command=$command_line" >&2
      fi
    done
    sleep 0.5
    for pid in $pids; do
      command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      should_kill=0
      for root in "${e2e_roots[@]}"; do
        if [[ -n "$root" && "$command_line" == *"$root"* ]]; then
          should_kill=1
          break
        fi
      done
      [[ "$should_kill" == "1" ]] && kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true
    done
  fi
fi

for link in "${HOME}/bin/spacesd" "${HOME}/bin/spaces"; do
  if [ -L "$link" ]; then
    target="$(readlink "$link")"
    case "$target" in
      "$install_root"/*|"$legacy_install_root"/*) rm -f "$link" ;;
    esac
  fi
done

for root in "${e2e_roots[@]}"; do
  rm -rf "$root"
  echo "removed e2e_root=$root"
done

echo "preserved spaces_root=$spaces_root"
REMOTE_CLEANUP

echo "==> Remote E2E cleanup complete"
