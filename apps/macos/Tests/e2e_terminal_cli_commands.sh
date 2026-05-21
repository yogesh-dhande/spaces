#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-cli.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
APP_PID=""
SERVICE_PID=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SERVICE_PID" ]] && kill -0 "$SERVICE_PID" >/dev/null 2>&1; then
    kill "$SERVICE_PID" >/dev/null 2>&1 || true
    wait "$SERVICE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_active_attachment_client_id() {
  local session_id="$1"
  local mode="$2"
  local timeout="${3:-20}"
  local start
  start="$(date +%s)"
  while true; do
    if active_attachment_client_id "$session_id" "$mode" >/dev/null 2>&1; then
      active_attachment_client_id "$session_id" "$mode"
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for active ${mode} attachment for session ${session_id}" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_tail_contains() {
  local session_id="$1"
  local needle="$2"
  local timeout="${3:-20}"
  local start
  local output=""
  start="$(date +%s)"
  while true; do
    output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal tail "$session_id" --lines 40)"
    if printf '%s\n' "$output" | grep -Fq "$needle"; then
      printf '%s\n' "$output"
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for tail output containing: $needle" >&2
      printf '%s\n' "$output" >&2
      return 1
    fi
    sleep 0.2
  done
}

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

active_attachment_client_id() {
  local session_id="$1"
  local mode="$2"
  local attachments_path
  attachments_path="$RUNTIME_DIR/terminal/sessions/$session_id/attachments.json"
  python3 - "$attachments_path" "$mode" <<'PY'
import json, sys
path = sys.argv[1]
mode = sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    attachments = json.load(handle)
for attachment in attachments:
    if attachment.get("mode") == mode and attachment.get("detachedAt") is None:
        print(attachment["clientID"])
        break
else:
    raise SystemExit(f"no active {mode} attachment found")
PY
}

attach_remote_viewer_client() {
  local session_id="$1"
  local socket_path="$RUNTIME_DIR/terminal/sessions/$session_id/control.sock"
  python3 - "$socket_path" <<'PY'
import json
import socket
import sys
import uuid
from datetime import datetime, timezone

socket_path = sys.argv[1]
client_id = str(uuid.uuid4()).upper()
request = {
    "command": "attach",
    "client": {
        "id": client_id,
        "kind": "remoteViewer",
        "identity": {
            "label": "CLI E2E Viewer",
            "deviceName": "CLI E2E Viewer",
            "networkAddress": "127.0.0.1",
        },
        "connectedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    },
    "attachmentMode": "viewer",
    "appendNewline": False,
}

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5)
client.connect(socket_path)
client.sendall(json.dumps(request).encode("utf-8"))
client.shutdown(socket.SHUT_WR)
response = json.loads(client.recv(65536).decode("utf-8"))
client.close()
if not response.get("ok"):
    raise SystemExit(response.get("message") or response)
print(client_id)
PY
}

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT" >/dev/null

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

command_payload="stty raw -echo; python3 -c 'import os,sys,select,time; data=bytearray(); deadline=time.time()+5; exec(\"while time.time() < deadline:\\n r,_,_=select.select([0],[],[],0.5)\\n if not r: continue\\n chunk=os.read(0,64)\\n data.extend(chunk)\\n if b\\\"\\\\r\\\" in data or b\\\"\\\\n\\\" in data: break\"); print(repr(bytes(data))); sys.stdout.flush(); time.sleep(2)'"
command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command --backend ghostty-embedded --command "$command_payload" --title cli-e2e)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse session ID from: $command_output" >&2; exit 1; }
state_path="$RUNTIME_DIR/terminal/sessions/$session_id/state.json"
SERVICE_PID="$(python3 - "$state_path" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["servicePID"])
PY
)"

owner_client_id="$(wait_for_active_attachment_client_id "$session_id" owner)"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal send "$session_id" "abc" >/dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal key "$session_id" up >/dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal key "$session_id" enter >/dev/null

tail_output="$(wait_for_tail_contains "$session_id" "b'abc")"
printf '%s\n' "$tail_output" | grep -Fq "b'abc"
printf '%s\n' "$tail_output" | grep -Fq "\\x1b[A"
printf '%s\n' "$tail_output" | grep -Fq "\\r'"

viewer_client_id="$(attach_remote_viewer_client "$session_id")"
[[ "$(wait_for_active_attachment_client_id "$session_id" viewer)" == "$viewer_client_id" ]] || {
  echo "Attached viewer client did not become the active viewer attachment" >&2
  exit 1
}

[[ "$viewer_client_id" != "$owner_client_id" ]] || { echo "Viewer and owner client IDs should differ" >&2; exit 1; }

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal takeover "$session_id" "$viewer_client_id" >/dev/null
[[ "$(wait_for_active_attachment_client_id "$session_id" owner)" == "$viewer_client_id" ]] || {
  echo "Viewer takeover did not become active owner" >&2
  exit 1
}

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal takeover "$session_id" "$owner_client_id" >/dev/null
[[ "$(wait_for_active_attachment_client_id "$session_id" owner)" == "$owner_client_id" ]] || {
  echo "Original owner did not regain ownership" >&2
  exit 1
}

echo "Spaces terminal CLI E2E passed for session $session_id"
