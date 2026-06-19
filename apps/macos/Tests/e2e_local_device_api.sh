#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$ROOT_DIR/scripts/spaces-e2e-env.sh"
spaces_e2e_load_env "$ROOT_DIR"
source "$ROOT_DIR/scripts/spaces-profile-helpers.sh"

SPACES_E2E_BIN="${SPACES_E2E:-$ROOT_DIR/apps/macos/.build/debug/spacese2e}"
TERMINAL_SERVICE_BIN="${SPACESD_EXECUTABLE:-$ROOT_DIR/apps/macos/.build/debug/spacesd}"
TMP_ROOT="${TMPDIR:-/tmp}/spaces-local-device-e2e.$$"
TMP_HOME="$TMP_ROOT/home"
TMP_RUNTIME_DIR="$TMP_ROOT/runtime"
TMP_DB="$TMP_ROOT/spaces.db"
RESULT_JSON="${SPACES_E2E_LOCAL_DEVICE_RESULT_JSON:-$TMP_ROOT/result.json}"
RUN_ID="${SPACES_E2E_LOCAL_DEVICE_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"

SERVICE_PID=""
DEVICE_API_PORT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  HOME="$TMP_HOME" \
    SPACES_DB_PATH="$TMP_DB" \
    SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
    SPACESD_EXECUTABLE="$TERMINAL_SERVICE_BIN" \
    spaces_profile_stop_terminal_service "$SPACES_E2E_BIN" 5 || true
  if [[ -n "$SERVICE_PID" ]]; then
    kill "$SERVICE_PID" >/dev/null 2>&1 || true
    wait "$SERVICE_PID" >/dev/null 2>&1 || true
  fi
  if [[ $exit_code -eq 0 ]]; then
    rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
  else
    printf 'Preserved local Device API E2E temp root: %s\n' "$TMP_ROOT" >&2
  fi
}
trap cleanup EXIT

require_local_config() {
  [[ -x "$SPACES_E2E_BIN" ]] || fail "spacese2e not found at $SPACES_E2E_BIN."
  [[ -x "$TERMINAL_SERVICE_BIN" ]] || fail "spacesd not found at $TERMINAL_SERVICE_BIN."
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for local paired-device E2E."
}

allocate_local_port() {
  python3 <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

start_local_daemon() {
  mkdir -p "$TMP_HOME" "$TMP_RUNTIME_DIR"
  DEVICE_API_PORT="$(allocate_local_port)"
  HOME="$TMP_HOME" \
    SPACES_DB_PATH="$TMP_DB" \
    SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
    SPACES_DEVICE_API_PORT="$DEVICE_API_PORT" \
    "$TERMINAL_SERVICE_BIN" >"$TMP_ROOT/spacesd.log" 2>&1 &
  SERVICE_PID=$!

  local deadline
  deadline=$((SECONDS + 15))
  while [[ $SECONDS -lt $deadline ]]; do
    if HOME="$TMP_HOME" \
      SPACES_DB_PATH="$TMP_DB" \
      SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
      SPACESD_EXECUTABLE="$TERMINAL_SERVICE_BIN" \
      SPACES_DEVICE_API_HOST="0.0.0.0" \
      SPACES_DEVICE_API_PORT="$DEVICE_API_PORT" \
      "$SPACES_E2E_BIN" mobile-status >"$TMP_ROOT/mobile-status.json" 2>"$TMP_ROOT/mobile-status.log"; then
      return 0
    fi
    if ! kill -0 "$SERVICE_PID" >/dev/null 2>&1; then
      cat "$TMP_ROOT/spacesd.log" >&2 || true
      cat "$TMP_ROOT/mobile-status.log" >&2 || true
      fail "local spacesd exited before opening its control socket."
    fi
    sleep 0.1
  done
  cat "$TMP_ROOT/spacesd.log" >&2 || true
  cat "$TMP_ROOT/mobile-status.log" >&2 || true
  fail "timed out waiting for local spacesd Device API status."
}

open_pairing_window() {
  HOME="$TMP_HOME" \
    SPACES_DB_PATH="$TMP_DB" \
    SPACES_RUNTIME_DIR="$TMP_RUNTIME_DIR" \
    SPACESD_EXECUTABLE="$TERMINAL_SERVICE_BIN" \
    SPACES_DEVICE_API_HOST="0.0.0.0" \
    SPACES_DEVICE_API_PORT="$DEVICE_API_PORT" \
    "$SPACES_E2E_BIN" open-device-pairing-window --timeout-seconds 10 >"$TMP_ROOT/pairing-window.json"
}

pair_local_device() {
  python3 - "$TMP_ROOT/pairing-window.json" "$TMP_ROOT/pair-request.json" <<'PY'
import json
import sys

window_path, request_path = sys.argv[1:3]
window = json.load(open(window_path))
payload = {
    "command": {"pair": {"pairingCode": window["pairingCode"], "pairingNonce": window["pairingNonce"]}},
    "clientApp": {
        "installationID": "LOCAL-DEVICE-E2E",
        "bundleID": "dev.usespaces.spacesmobile",
        "platform": "ios",
        "deviceName": "Local Device E2E",
        "appVersion": "1.0",
    },
}
open(request_path, "w").write(json.dumps(payload, separators=(",", ":")))
PY
  local host port transport_key request_json response
  host="127.0.0.1"
  port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$TMP_ROOT/pairing-window.json")"
  transport_key="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["transportKey"])' "$TMP_ROOT/pairing-window.json")"
  request_json="$(cat "$TMP_ROOT/pair-request.json")"
  response="$("$SPACES_E2E_BIN" mobile-request --host "$host" --port "$port" --transport-key "$transport_key" --request-json "$request_json")"
  printf '%s' "$response" >"$TMP_ROOT/pair-response.json"
}

create_local_fixture_project() {
  local project_root="$TMP_ROOT/device-api-project-$RUN_ID"
  rm -rf "$project_root"
  mkdir -p "$project_root"
  printf 'local device api sentinel\n' >"$project_root/README.txt"
  cat >"$project_root/spaces.yaml" <<'YAML'
version: 1
processes:
  - name: parity-process
    command: >-
      python3 -c "import time; print('device-api-process-ready', flush=True); time.sleep(120)"
    on_exit: none
agent_launchers:
  - name: parity-agent
    command: >-
      python3 -c "import time; print('device-api-agent-ready', flush=True); time.sleep(120)"
YAML
  git -C "$project_root" init >/dev/null
  git -C "$project_root" config user.email "spaces-e2e@example.invalid"
  git -C "$project_root" config user.name "Spaces E2E"
  git -C "$project_root" add README.txt spaces.yaml
  git -C "$project_root" commit -m "Initial device API parity fixture" >/dev/null
  printf '%s\n' "$project_root"
}

local_device_parity() {
  local host port transport_key auth_token project_dir
  host="127.0.0.1"
  port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$TMP_ROOT/pairing-window.json")"
  transport_key="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["transportKey"])' "$TMP_ROOT/pairing-window.json")"
  auth_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["issuedAuthToken"]["authToken"])' "$TMP_ROOT/pair-response.json")"
  project_dir="$(create_local_fixture_project)"

  "$ROOT_DIR/apps/macos/Tests/device_api_parity.py" \
    --spacese2e "$SPACES_E2E_BIN" \
    --host "$host" \
    --port "$port" \
    --transport-key "$transport_key" \
    --auth-token "$auth_token" \
    --project-dir "$project_dir" \
    --label "local-device" \
    --client-installation-id "LOCAL-DEVICE-E2E" \
    --client-device-name "Local Device E2E" \
    --result-json "$RESULT_JSON" >"$TMP_ROOT/local-device-api-parity.stdout" 2>"$TMP_ROOT/local-device-api-parity.log" \
    || fail "Local Device API parity flow failed. See $TMP_ROOT/local-device-api-parity.log"
  cat "$RESULT_JSON"
}

main() {
  require_local_config
  mkdir -p "$TMP_ROOT"
  printf '[local-device] starting local daemon\n'
  start_local_daemon
  printf '[local-device] pairing through local daemon control socket\n'
  open_pairing_window
  pair_local_device
  printf '[local-device] creating project, workspace, terminal, process, and coding agent\n'
  local_device_parity
}

main "$@"
