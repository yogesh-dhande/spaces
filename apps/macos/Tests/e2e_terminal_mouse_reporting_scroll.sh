#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"

BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_EXECUTABLE="$BUILD_DIR/spacesd"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-mouse-scroll.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
export SPACES_DEVICE_API_PORT="${SPACES_DEVICE_API_PORT:-0}"
APP_LOG="$WORK_ROOT/spaces-app.log"
PROBE_SCRIPT="$WORK_ROOT/mouse-reporting-scroll.py"
PROBE_OUTPUT="$WORK_ROOT/mouse-reporting-input.bin"
APP_PID=""
session_id=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$session_id" ]] && [[ -x "$SPACES_E2E" ]]; then
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" terminate-terminal-session "$session_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  stop_terminal_service_for_runtime_dir "$RUNTIME_DIR"
}
trap cleanup EXIT

fail() {
  echo "$*" >&2
  exit 1
}

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || fail "Missing binary: $path"
}

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | sed -nE 's/^Started terminal session ([0-9A-F-]{36})([[:space:]].*)?$/\1/p' | tail -n 1
}

wait_for_tail_contains() {
  local needle="$1"
  local deadline=$((SECONDS + 30))
  local output=""
  while (( SECONDS < deadline )); do
    output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal tail "$session_id" --lines 20 2>/dev/null || true)"
    if printf '%s\n' "$output" | grep -Fq "$needle"; then
      return 0
    fi
    sleep 0.2
  done
  printf '%s\n' "$output" >&2
  fail "Timed out waiting for terminal output: $needle"
}

wait_for_probe_output() {
  # Must outlast the probe's own 30s capture deadline so a failed run still
  # flushes the partial capture for diagnosis instead of dying with no data.
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if [[ -f "$PROBE_OUTPUT" ]]; then
      return 0
    fi
    sleep 0.1
  done
  fail "Timed out waiting for the mouse-reporting process to capture terminal input."
}

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
require_binary "$SPACESD_EXECUTABLE"
require_binary "$SPACES_E2E"
export SPACESD_EXECUTABLE

mkdir -p "$(dirname "$DB_PATH")" "$RUNTIME_DIR"
touch "$APP_LOG"
python3 - "$PROBE_SCRIPT" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
    """
import os
import re
import select
import sys
import termios
import time
import tty

fd = sys.stdin.fileno()
previous = termios.tcgetattr(fd)
captured = bytearray()
deadline = time.time() + 30
try:
    tty.setraw(fd)
    os.write(sys.stdout.fileno(), b"\\x1b[?1000h\\x1b[?1006hMOUSE_SCROLL_READY\\r\\n")
    while time.time() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.25)
        if not readable:
            continue
        captured.extend(os.read(fd, 128))
        if (
            re.search(rb"\\x1b\\[<(64|65);[0-9]+;[0-9]+M", captured)
            and re.search(rb"\\x1b\\[<0;[0-9]+;[0-9]+M", captured)
            and re.search(rb"\\x1b\\[<0;[0-9]+;[0-9]+m", captured)
        ):
            break
finally:
    with open(sys.argv[1], "wb") as output:
        output.write(captured)
    termios.tcsetattr(fd, termios.TCSADRAIN, previous)
""".lstrip()
)
PY

cd "$REPO_ROOT"
acquire_terminal_harness_lock
if [[ "${SPACES_E2E_SKIP_GHOSTTYKIT_SETUP:-0}" != "1" ]]; then
  "$SETUP_GHOSTTYKIT" >/dev/null
fi
SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"

FIXTURE_PROJECT_DIR="$WORK_ROOT/terminal-fixture-project"
mkdir -p "$FIXTURE_PROJECT_DIR"
FIXTURE_WORKSPACE_JSON="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" register-project --project-dir "$FIXTURE_PROJECT_DIR")"
FIXTURE_WORKSPACE_ID="$(printf '%s' "$FIXTURE_WORKSPACE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
COMMAND_TEXT="$(
  python3 - "$PROBE_SCRIPT" "$PROBE_OUTPUT" <<'PY'
import shlex
import sys
print(f"/usr/bin/python3 {shlex.quote(sys.argv[1])} {shlex.quote(sys.argv[2])}")
PY
)"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

command_output="$(
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command \
    --workspace "$FIXTURE_WORKSPACE_ID" --command "$COMMAND_TEXT" --title "terminal-mouse-reporting-scroll"
)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || fail "Failed to parse session ID from: $command_output"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal show "$session_id" >/dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" focus-terminal-session-window --session-id "$session_id" >/dev/null
wait_for_tail_contains "MOUSE_SCROLL_READY"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
  scroll-application-window --executable-name SpacesApp --normalized-x 0.75 --normalized-y 0.5 --delta-y 120 --repetitions 2 >/dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" \
  click-application-window --executable-name SpacesApp --normalized-x 0.75 --normalized-y 0.5 >/dev/null
wait_for_probe_output

python3 - "$PROBE_OUTPUT" <<'PY'
import re
import sys
from pathlib import Path

captured = Path(sys.argv[1]).read_bytes()
match = re.search(rb"\x1b\[<(64|65);([0-9]+);([0-9]+)M", captured)
if not match:
    raise SystemExit(f"Mac scroll did not reach the mouse-reporting terminal application: {captured!r}")
column = int(match.group(2))
row = int(match.group(3))
if column < 1 or row < 1:
    raise SystemExit(f"Invalid application mouse coordinates: column={column} row={row}")
PY

python3 - "$PROBE_OUTPUT" <<'PY'
import re
import sys
from pathlib import Path

captured = Path(sys.argv[1]).read_bytes()
press = re.search(rb"\x1b\[<0;([0-9]+);([0-9]+)M", captured)
release = re.search(rb"\x1b\[<0;([0-9]+);([0-9]+)m", captured)
if not press:
    raise SystemExit(f"Mac click press did not reach the mouse-reporting terminal application: {captured!r}")
if not release:
    raise SystemExit(f"Mac click release did not reach the mouse-reporting terminal application: {captured!r}")
press_column, press_row = int(press.group(1)), int(press.group(2))
release_column, release_row = int(release.group(1)), int(release.group(2))
if press_column < 1 or press_row < 1:
    raise SystemExit(f"Invalid application click press coordinates: column={press_column} row={press_row}")
if release_column < 1 or release_row < 1:
    raise SystemExit(f"Invalid application click release coordinates: column={release_column} row={release_row}")
PY

echo "Spaces macOS mouse-reporting terminal scroll and click E2E passed for session $session_id"
