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
SPACES_E2E="$BUILD_DIR/spacese2e"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d /tmp/spcli.XXXXXX)}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/rt}"
APP_LOG="$WORK_ROOT/spaces-app.log"
APP_PID=""
SERVICE_PID=""
PROFILE_ROOT=""
no_attach_session_id=""
no_attach_service_pid=""
session_id=""

cleanup() {
  release_terminal_harness_lock
  for cleanup_session_id in "$no_attach_session_id" "$session_id"; do
    if [[ -n "$cleanup_session_id" ]] && [[ -x "$SPACES_E2E" ]]; then
      env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" terminate-terminal-session "$cleanup_session_id" >/dev/null 2>&1 || true
    fi
  done
  if [[ -n "$no_attach_service_pid" ]] && [[ "$no_attach_service_pid" != "$SERVICE_PID" ]] && kill -0 "$no_attach_service_pid" >/dev/null 2>&1; then
    kill "$no_attach_service_pid" >/dev/null 2>&1 || true
    wait "$no_attach_service_pid" >/dev/null 2>&1 || true
  fi
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

wait_for_control_socket() {
  local session_id="$1"
  local timeout="${2:-20}"
  local socket_path
  socket_path="$(control_socket_path "$session_id")"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -S "$socket_path" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for control socket: $socket_path" >&2
      return 1
    fi
    sleep 0.2
  done
}

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

resolve_profile_root() {
  local root
  root="$(
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" profile-show \
      | awk -F '\t' '$1 == "profile-root" { print $2; exit }'
  )"
  [[ -n "$root" ]] || { echo "Failed to resolve profile root from spacese2e profile-show" >&2; exit 1; }
  printf '%s\n' "$root"
}

control_socket_path() {
  local session_id="$1"
  [[ -n "$PROFILE_ROOT" ]] || { echo "Profile root was not resolved before socket lookup" >&2; return 1; }
  python3 - "$PROFILE_ROOT" "$session_id" <<'PY'
import sys

profile_root = sys.argv[1]
session_id = sys.argv[2]
hash_value = 5381
for byte in f"{profile_root}|{session_id}".encode("utf-8"):
    hash_value = (((hash_value << 5) + hash_value) + byte) & 0xFFFFFFFFFFFFFFFF
print(f"/tmp/spaces-terminal-sockets/{hash_value:016x}.sock")
PY
}

active_attachment_client_id() {
  local session_id="$1"
  local mode="$2"
  python3 - "$DB_PATH" "$RUNTIME_DIR/terminal/sessions/$session_id" "$mode" <<'PY'
import os
import sqlite3
import sys

db_path = sys.argv[1]
root_directory = os.path.normpath(sys.argv[2])
mode = sys.argv[3]
with sqlite3.connect(db_path) as db:
    row = db.execute(
        """
        SELECT client_id
        FROM terminal_attachments
        WHERE root_directory = ?
          AND mode = ?
          AND detached_at IS NULL
        ORDER BY attached_at DESC
        LIMIT 1
        """,
        (root_directory, mode),
    ).fetchone()
if row:
    print(row[0])
else:
    raise SystemExit(f"no active {mode} attachment found")
PY
}

terminal_service_pid() {
  local session_id="$1"
  python3 - "$DB_PATH" "$RUNTIME_DIR/terminal/sessions/$session_id" <<'PY'
import os
import sqlite3
import sys

db_path = sys.argv[1]
root_directory = os.path.normpath(sys.argv[2])
with sqlite3.connect(db_path) as db:
    row = db.execute(
        "SELECT service_pid FROM terminal_runtime_states WHERE root_directory = ?",
        (root_directory,),
    ).fetchone()
if row:
    print(row[0])
else:
    raise SystemExit("missing terminal runtime state")
PY
}

attach_control_client() {
  local session_id="$1"
  local attachment_mode="$2"
  local socket_path
  socket_path="$(control_socket_path "$session_id")"
  python3 - "$socket_path" "$attachment_mode" <<'PY'
import json
import socket
import sys
import uuid
from datetime import datetime, timezone

socket_path = sys.argv[1]
attachment_mode = sys.argv[2]
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
    "attachmentMode": attachment_mode,
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
PROFILE_ROOT="$(resolve_profile_root)"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT" >/dev/null

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"

no_attach_payload="python3 -c 'import time; print(\"__cli_noattach_ready__\", flush=True); time.sleep(30)'"
no_attach_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command --backend ghostty-embedded --command "$no_attach_payload" --title cli-e2e-no-attach)"
no_attach_session_id="$(extract_session_id "$no_attach_output")"
[[ -n "$no_attach_session_id" ]] || { echo "Failed to parse unattached session ID from: $no_attach_output" >&2; exit 1; }
no_attach_service_pid="$(terminal_service_pid "$no_attach_session_id")"
sleep 2
no_attach_list="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal list)"
printf '%s\n' "$no_attach_list" | grep -Fq "$no_attach_session_id" || {
  echo "Unattached CLI-created session disappeared before any app window attached." >&2
  printf '%s\n' "$no_attach_list" >&2
  exit 1
}

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

command_payload="stty raw -echo; python3 -c 'import os,sys,select,time; data=bytearray(); deadline=time.time()+5; exec(\"while time.time() < deadline:\\n r,_,_=select.select([0],[],[],0.5)\\n if not r: continue\\n chunk=os.read(0,64)\\n data.extend(chunk)\\n if b\\\"\\\\r\\\" in data or b\\\"\\\\n\\\" in data: break\"); print(repr(bytes(data))); sys.stdout.flush(); time.sleep(120)'"
command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command --backend ghostty-embedded --command "$command_payload" --title cli-e2e)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse session ID from: $command_output" >&2; exit 1; }
SERVICE_PID="$(terminal_service_pid "$session_id")"

wait_for_control_socket "$session_id"
owner_client_id="$(attach_control_client "$session_id" owner)"
[[ "$(wait_for_active_attachment_client_id "$session_id" owner)" == "$owner_client_id" ]] || {
  echo "Attached owner client did not become the active owner attachment" >&2
  exit 1
}

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal send "$session_id" "abc" >/dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal key "$session_id" up >/dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal key "$session_id" enter >/dev/null

tail_output="$(wait_for_tail_contains "$session_id" "b'abc")"
printf '%s\n' "$tail_output" | grep -Fq "b'abc"
printf '%s\n' "$tail_output" | grep -Fq "\\x1b[A"
printf '%s\n' "$tail_output" | grep -Eq "\\\\r'|\\\\n'"

wait_for_control_socket "$session_id"
viewer_client_id="$(attach_control_client "$session_id" viewer)"
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
