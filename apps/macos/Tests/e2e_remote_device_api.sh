#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$ROOT_DIR/scripts/spaces-e2e-env.sh"
spaces_e2e_require_remote_host_env "$ROOT_DIR"

SPACES_E2E_BIN="${SPACES_E2E:-$ROOT_DIR/apps/macos/.build/debug/spacese2e}"
REMOTE_HOST="${SPACES_E2E_REMOTE_SSH_HOST:-}"
REMOTE_USER="${SPACES_E2E_REMOTE_SSH_USER:-}"
REMOTE_SSH_PORT="${SPACES_E2E_REMOTE_SSH_PORT:-}"
REMOTE_DAEMON_HOST="${SPACES_E2E_REMOTE_DAEMON_HOST:-$REMOTE_HOST}"
REMOTE_WORKSPACE_ROOT="${SPACES_E2E_REMOTE_WORKSPACE_ROOT:-~/.spaces/e2e-workspaces}"
# This lane runs its own isolated remote daemon as a development profile, so it never touches the
# remote account's installed profile. The profile name fixes the root, the unit instance, and the
# CLI the lane drives it with; the daemon assigns its own Device API port, read back after install.
REMOTE_E2E_PROFILE_NAME="remote-device-e2e"
REMOTE_E2E_ROOT="~/.spaces-dev/profiles/spaces/$REMOTE_E2E_PROFILE_NAME"
REMOTE_E2E_CLI="$REMOTE_E2E_ROOT/daemon/current/bin/spaces"
REMOTE_DAEMON_PORT=""
REMOTE_PERFORMANCE_LOG="${SPACES_E2E_REMOTE_PERFORMANCE_LOG:-$REMOTE_E2E_ROOT/mobile-terminal-performance.jsonl}"
TMP_ROOT="${TMPDIR:-/tmp}/spaces-remote-device-e2e.$$"
RESULT_JSON="${SPACES_E2E_REMOTE_DEVICE_RESULT_JSON:-$TMP_ROOT/result.json}"
TERMINAL_LATENCY_JSON="${SPACES_E2E_REMOTE_DEVICE_TERMINAL_LATENCY_JSON:-$TMP_ROOT/terminal-latency-summary.json}"
TERMINAL_LATENCY_SAMPLES="${SPACES_E2E_REMOTE_DEVICE_TERMINAL_LATENCY_SAMPLES:-${SPACES_E2E_DEVICE_TERMINAL_LATENCY_SAMPLES:-3}}"
RUN_ID="${SPACES_E2E_REMOTE_DEVICE_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"

PAIRING_CODE=""
PAIRING_NONCE=""
CERTIFICATE_FINGERPRINT=""
AUTH_TOKEN=""
MAC_AUTH_TOKEN=""
REMOTE_HTTP_PID=""
LOCAL_FORWARD_PID=""
REMOTE_MAC_CLIENT_INSTALLATION_ID="${SPACES_E2E_REMOTE_MAC_CLIENT_INSTALLATION_ID:-MACOS-REMOTE-DEVICE-E2E}"
REMOTE_MAC_CLIENT_DEVICE_NAME="${SPACES_E2E_REMOTE_MAC_CLIENT_DEVICE_NAME:-Remote Device macOS E2E}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
}

remote_destination() {
  if [[ -n "$REMOTE_USER" ]]; then
    printf '%s@%s' "$REMOTE_USER" "$REMOTE_HOST"
  else
    printf '%s' "$REMOTE_HOST"
  fi
}

ssh_args() {
  printf '%s\n' -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes
  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    printf '%s\n' -p "$REMOTE_SSH_PORT"
  fi
}

remote_ssh() {
  local -a args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(ssh_args)
  ssh "${args[@]}" "$(remote_destination)" "$@"
}

remote_expand_path() {
  local quoted
  quoted="$(shell_quote "$1")"
  remote_ssh "python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' $quoted"
}

cleanup() {
  local exit_code=$?
  if [[ -n "$LOCAL_FORWARD_PID" ]]; then
    kill "$LOCAL_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$LOCAL_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$REMOTE_HTTP_PID" ]]; then
    remote_ssh "kill $(shell_quote "$REMOTE_HTTP_PID") >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
  if [[ $exit_code -eq 0 ]]; then
    rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
  else
    printf 'Preserved remote Device API E2E temp root: %s\n' "$TMP_ROOT" >&2
  fi
}
trap cleanup EXIT

require_remote_config() {
  [[ -n "$REMOTE_HOST" ]] || fail "SPACES_E2E_REMOTE_SSH_HOST is required for remote paired-device E2E."
  [[ -n "$REMOTE_DAEMON_HOST" ]] || fail "SPACES_E2E_REMOTE_DAEMON_HOST or SPACES_E2E_REMOTE_SSH_HOST is required."
  [[ -x "$SPACES_E2E_BIN" ]] || fail "spacese2e not found at $SPACES_E2E_BIN."
  command -v ssh >/dev/null 2>&1 || fail "ssh is required for remote paired-device E2E."
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for remote paired-device E2E."
}

prepare_remote_daemon() {
  local artifact_assignments artifact_url archive_path install_root performance_log_path
  local quoted_archive quoted_install quoted_performance_log quoted_profile_name
  # Cleanup stops and disables this profile's unit and removes its root, so the daemon is always
  # installed and started fresh here -- there is no running daemon left to reuse. The install root
  # is pointed at this lane's own profile root (where the archive is extracted) so cleanup's default
  # does not delete the uploaded artifact the deploy helper caches on the remote host.
  SPACES_E2E_REMOTE_WORKSPACE_ROOT="$REMOTE_WORKSPACE_ROOT" \
    SPACES_E2E_REMOTE_INSTALL_ROOT="$REMOTE_E2E_ROOT" \
    "$ROOT_DIR/apps/macos/scripts/cleanup_linux_spacesd_e2e.sh" >/dev/null
  artifact_assignments="$("$ROOT_DIR/apps/macos/scripts/deploy_linux_spacesd_e2e.sh" --profile "$REMOTE_E2E_PROFILE_NAME")"
  eval "$artifact_assignments"
  artifact_url="${artifact_url:-}"
  [[ "$artifact_url" == file://* ]] || fail "Remote artifact URL must be file://, got: $artifact_url"
  archive_path="${artifact_url#file://}"
  install_root="$(remote_expand_path "$REMOTE_E2E_ROOT/install")"
  performance_log_path="$(remote_expand_path "$REMOTE_PERFORMANCE_LOG")"
  quoted_archive="$(shell_quote "$archive_path")"
  quoted_install="$(shell_quote "$install_root")"
  quoted_performance_log="$(shell_quote "$performance_log_path")"
  quoted_profile_name="$(shell_quote "$REMOTE_E2E_PROFILE_NAME")"
  remote_ssh "rm -rf $quoted_install && mkdir -p $quoted_install && tar -xzf $quoted_archive -C $quoted_install --strip-components=1 && $quoted_install/install.sh --profile $quoted_profile_name --performance-log $quoted_performance_log" >/dev/null
}

# The Device API port the daemon assigned itself for this profile and persisted at first start. The
# lane never picks a port, so every client address it builds comes from here.
resolve_remote_daemon_port() {
  local settings_path
  settings_path="$(remote_expand_path "$REMOTE_E2E_ROOT/runtime/terminal/device-api.json")"
  REMOTE_DAEMON_PORT="$(remote_ssh "python3 - $(shell_quote "$settings_path")" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    print(json.load(handle)["port"])
PY
  )"
  [[ "$REMOTE_DAEMON_PORT" =~ ^[0-9]+$ ]] || fail "remote profile $REMOTE_E2E_PROFILE_NAME reported no numeric Device API port."
}

wait_for_remote_daemon_from_mac() {
  python3 - "$REMOTE_DAEMON_HOST" "$REMOTE_DAEMON_PORT" <<'PY'
import socket
import sys
import time

host = sys.argv[1]
port = int(sys.argv[2])

def wait_until_reachable(label):
    deadline = time.time() + 60
    last_error = None
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return
        except OSError as exc:
            last_error = exc
            time.sleep(0.5)
    raise SystemExit(f"remote daemon {host}:{port} did not stay reachable after SSH setup exited during {label}: {last_error}")

wait_until_reachable("initial check")
time.sleep(5)
wait_until_reachable("follow-up check")
PY
}

# The profile's own CLI, which resolves this profile from its own path -- so no profile environment
# is passed, and the installed profile's CLI is never involved.
remote_spaces_pair_json() {
  remote_ssh "$REMOTE_E2E_CLI device pair --json"
}

wait_for_remote_daemon() {
  local quoted_port
  quoted_port="$(shell_quote "$REMOTE_DAEMON_PORT")"
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
raise SystemExit(f"remote daemon port {port} did not open: {last_error}")
PY
}

open_remote_pairing_window() {
  local pair_output parsed
  pair_output="$(remote_spaces_pair_json)"
  parsed="$(
    python3 - "$pair_output" <<'PY'
import json
import shlex
import sys
payload = json.loads(sys.argv[1])
for key in ("pairingCode", "pairingNonce", "certificateFingerprint"):
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"remote pairing JSON missing {key}")
if not isinstance(payload.get("protocolVersion"), int):
    raise SystemExit("remote pairing JSON missing protocolVersion")
print(f"PAIRING_CODE={shlex.quote(payload['pairingCode'])}")
print(f"PAIRING_NONCE={shlex.quote(payload['pairingNonce'])}")
print(f"CERTIFICATE_FINGERPRINT={shlex.quote(payload['certificateFingerprint'])}")
print(f"PROTOCOL_VERSION={payload['protocolVersion']}")
PY
  )"
  eval "$parsed"
  [[ -n "$PAIRING_CODE" ]] || fail "remote pairing JSON missing pairingCode"
  [[ -n "$PAIRING_NONCE" ]] || fail "remote pairing JSON missing pairingNonce"
  [[ -n "$CERTIFICATE_FINGERPRINT" ]] || fail "remote pairing JSON missing certificateFingerprint"
  [[ -n "$PROTOCOL_VERSION" ]] || fail "remote pairing JSON missing protocolVersion"
}

device_request() {
  local request_json="$1"
  local request_file response_file
  request_file="$TMP_ROOT/request.json"
  response_file="$TMP_ROOT/response.json"
  mkdir -p "$TMP_ROOT"
  printf '%s' "$request_json" >"$request_file"
  "$SPACES_E2E_BIN" mobile-request \
    --host "$REMOTE_DAEMON_HOST" \
    --port "$REMOTE_DAEMON_PORT" \
    --certificate-fingerprint="$CERTIFICATE_FINGERPRINT" \
    --request-json "$request_json" >"$response_file"
  python3 - "$response_file" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1]))
if not payload.get("ok"):
    raise SystemExit(payload.get("message") or payload)
print(json.dumps(payload, sort_keys=True))
PY
}

pair_remote_client() {
  local installation_id="$1"
  local bundle_id="$2"
  local platform="$3"
  local device_name="$4"
  local app_version="$5"
  local response request_json
  request_json="$(
    python3 - "$PAIRING_CODE" "$PAIRING_NONCE" "$installation_id" "$bundle_id" "$platform" "$device_name" "$app_version" "$PROTOCOL_VERSION" <<'PY'
import json
import sys
code, nonce, installation_id, bundle_id, platform, device_name, app_version, protocol_version = sys.argv[1:9]
print(json.dumps({
    "command": {"pair": {"pairingCode": code, "pairingNonce": nonce, "clientProtocolVersion": int(protocol_version)}},
    "clientApp": {
        "installationID": installation_id,
        "bundleID": bundle_id,
        "platform": platform,
        "deviceName": device_name,
        "appVersion": app_version,
    },
}, separators=(",", ":")))
PY
  )"
  response="$(device_request "$request_json")"
  python3 - "$response" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
token = (((payload.get("result") or {}).get("issuedAuthToken") or {}).get("authToken"))
if not token:
    raise SystemExit("pair response did not include issuedAuthToken")
print(token)
PY
}

pair_remote_devices() {
  open_remote_pairing_window
  AUTH_TOKEN="$(
    pair_remote_client \
      "REMOTE-DEVICE-E2E" \
      "dev.usespaces.spacesmobile" \
      "ios" \
      "Remote Device E2E" \
      "1.0"
  )"
  open_remote_pairing_window
  MAC_AUTH_TOKEN="$(
    pair_remote_client \
      "$REMOTE_MAC_CLIENT_INSTALLATION_ID" \
      "dev.usespaces.spaces" \
      "macos" \
      "$REMOTE_MAC_CLIENT_DEVICE_NAME" \
      "1.0"
  )"
}

create_remote_fixture_project() {
  local project_root
  project_root="$(remote_expand_path "$REMOTE_WORKSPACE_ROOT/device-api-project-$RUN_ID")"
  remote_ssh "python3 - $(shell_quote "$project_root")" <<'PY'
import pathlib
import shutil
import subprocess
import sys

project_root = pathlib.Path(sys.argv[1])
shutil.rmtree(project_root, ignore_errors=True)
project_root.mkdir(parents=True, exist_ok=True)
(project_root / "README.txt").write_text("remote device api sentinel\n")
(project_root / "spaces.yaml").write_text(
    """version: 1
services:
  - web
processes:
  - name: remote-web-server
    command: >-
      python3 -c "import http.server, os; ReuseServer = type('ReuseServer', (http.server.ThreadingHTTPServer,), {'allow_reuse_address': True, 'allow_reuse_port': True}); http.server.test(HandlerClass=http.server.SimpleHTTPRequestHandler, ServerClass=ReuseServer, port=int(os.environ['SPACES_WEB_PORT']), bind='127.0.0.1')"
    on_exit: none
  - name: parity-process
    command: >-
      python3 -c "import time; print('device-api-process-ready', flush=True); time.sleep(120)"
    on_exit: none
browser_sessions:
  - name: remote-web
    url: $SPACES_WEB_URL/README.txt
agent_launchers:
  - name: parity-agent
    command: >-
      python3 -c "import time; print('device-api-agent-ready', flush=True); time.sleep(120)"
"""
)
def git(*args):
    subprocess.run(["git", "-C", str(project_root), *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

git("init", "-b", "main")
git("config", "user.email", "spaces-e2e@example.invalid")
git("config", "user.name", "Spaces E2E")
git("add", "README.txt", "spaces.yaml")
git("commit", "-m", "Initial device API parity fixture")
PY
  printf '%s\n' "$project_root"
}

json_file_field() {
  local payload_file="$1"
  local path="$2"
  python3 - "$payload_file" "$path" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    if part:
        value = value[part]
print("" if value is None else value)
PY
}

remote_device_parity() {
  local project_dir parity_json parity_stdout parity_log project_id default_workspace_id workspace_id session_id remote_web_service_port remote_web_service_url remote_web_browser_url
  project_dir="$(create_remote_fixture_project)"
  parity_json="$TMP_ROOT/remote-device-api-parity.json"
  parity_stdout="$TMP_ROOT/remote-device-api-parity.stdout"
  parity_log="$TMP_ROOT/remote-device-api-parity.log"
  "$ROOT_DIR/apps/macos/Tests/device_api_parity.py" \
    --spacese2e "$SPACES_E2E_BIN" \
    --host "$REMOTE_DAEMON_HOST" \
    --port "$REMOTE_DAEMON_PORT" \
    --certificate-fingerprint="$CERTIFICATE_FINGERPRINT" \
    --auth-token "$AUTH_TOKEN" \
    --project-dir "$project_dir" \
    --label "remote-device" \
    --client-installation-id "REMOTE-DEVICE-E2E" \
    --client-device-name "Remote Device E2E" \
    --result-json "$parity_json" \
    --terminal-latency-json "$TERMINAL_LATENCY_JSON" \
    --terminal-latency-samples "$TERMINAL_LATENCY_SAMPLES" >"$parity_stdout" 2>"$parity_log" \
    || fail "Remote Device API parity flow failed. See $parity_log"
  project_id="$(json_file_field "$parity_json" "projectID")"
  default_workspace_id="$(json_file_field "$parity_json" "defaultWorkspaceID")"
  workspace_id="$(json_file_field "$parity_json" "workspaceID")"
  session_id="$(json_file_field "$parity_json" "terminalSessionID")"
  remote_web_service_port="$(json_file_field "$parity_json" "remoteWebServicePort")"
  remote_web_service_url="$(json_file_field "$parity_json" "remoteWebServiceURL")"
  remote_web_browser_url="$(json_file_field "$parity_json" "remoteWebBrowserURL")"
  verify_remote_ssh_forward "$project_dir"
  verify_service_tunnel "$workspace_id"
  write_result_json "$project_dir" "$project_id" "$default_workspace_id" "$workspace_id" "$session_id" "$remote_web_service_port" "$remote_web_service_url" "$remote_web_browser_url"
}

allocate_local_port() {
  python3 <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

verify_remote_ssh_forward() {
  local project_dir="$1"
  local remote_port local_port destination
  remote_port=32187
  local_port="$(allocate_local_port)"
  destination="$(remote_destination)"
  remote_ssh "python3 - $(shell_quote "$project_dir") $remote_port /tmp/spaces-remote-device-http.log" >"$TMP_ROOT/remote-http.pid" <<'PY'
import subprocess
import sys

project_dir, port, log_path = sys.argv[1:4]
log = open(log_path, "ab", buffering=0)
process = subprocess.Popen(
    ["python3", "-m", "http.server", port, "--bind", "127.0.0.1"],
    cwd=project_dir,
    stdin=subprocess.DEVNULL,
    stdout=log,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    close_fds=True,
)
print(process.pid)
PY
  REMOTE_HTTP_PID="$(cat "$TMP_ROOT/remote-http.pid")"
  local -a args=(-N -L "127.0.0.1:$local_port:127.0.0.1:$remote_port" -o BatchMode=yes -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=yes)
  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    args+=(-p "$REMOTE_SSH_PORT")
  fi
  ssh "${args[@]}" "$destination" &
  LOCAL_FORWARD_PID=$!
  python3 - "$local_port" <<'PY'
import sys
import time
import urllib.request

port = int(sys.argv[1])
deadline = time.time() + 20
last_error = None
while time.time() < deadline:
    try:
        body = urllib.request.urlopen(f"http://127.0.0.1:{port}/README.txt", timeout=2).read().decode()
        if "remote device api sentinel" in body:
            raise SystemExit(0)
        last_error = f"unexpected body: {body!r}"
    except Exception as exc:
        last_error = exc
    time.sleep(0.5)
raise SystemExit(f"SSH-forwarded HTTP check failed: {last_error}")
PY
}

tunnel_device_request() {
  local command="$1"
  local payload_json="$2"
  local request_json
  request_json="$(
    python3 - "$AUTH_TOKEN" "$command" "$payload_json" <<'PY'
import json
import sys
auth_token, command, payload_json = sys.argv[1:4]
print(json.dumps({
    "authToken": auth_token,
    "clientApp": {
        "installationID": "REMOTE-DEVICE-E2E",
        "bundleID": "dev.usespaces.spacesmobile",
        "platform": "ios",
        "deviceName": "Remote Device E2E",
        "appVersion": "1.0",
    },
    "command": {command: json.loads(payload_json)},
}, separators=(",", ":")))
PY
  )"
  device_request "$request_json"
}

verify_service_tunnel() {
  local workspace_id="$1"
  local tunnel_output negative_output overview_json stop_payload
  printf '[remote-device] verifying service tunnel\n'
  # The parity flow leaves the workspace's web-server process stopped, and the daemon's port reserver
  # keeps the assigned port bound while no service runs — so the only way anything can listen on the
  # service port is the daemon's own run path. Run the configured process, then reach it through the
  # tunnel; the poll below absorbs process startup (transient serviceNotRunning).
  tunnel_device_request runWorkspaceProcess \
    "{\"workspaceID\": \"$workspace_id\", \"processKey\": \"remote-web-server\", \"processTemplateID\": null}" >/dev/null \
    || fail "runWorkspaceProcess for remote-web-server failed"
  tunnel_output=""
  for _ in $(seq 1 30); do
    if tunnel_output="$(
      "$SPACES_E2E_BIN" service-tunnel \
        --host "$REMOTE_DAEMON_HOST" \
        --port "$REMOTE_DAEMON_PORT" \
        --certificate-fingerprint="$CERTIFICATE_FINGERPRINT" \
        --auth-token "$AUTH_TOKEN" \
        --client-installation-id "REMOTE-DEVICE-E2E" \
        --workspace-id "$workspace_id" \
        --service-name web \
        --http-get /README.txt 2>&1
    )" && [[ "$tunnel_output" == *"remote device api sentinel"* ]]; then
      break
    fi
    sleep 1
  done
  [[ "$tunnel_output" == *"HTTP/1."* ]] || fail "Service tunnel response missing HTTP status line: $tunnel_output"
  [[ "$tunnel_output" == *"remote device api sentinel"* ]] || fail "Service tunnel response missing fixture sentinel: $tunnel_output"
  if negative_output="$(
    "$SPACES_E2E_BIN" service-tunnel \
      --host "$REMOTE_DAEMON_HOST" \
      --port "$REMOTE_DAEMON_PORT" \
      --certificate-fingerprint="$CERTIFICATE_FINGERPRINT" \
      --auth-token "$AUTH_TOKEN" \
      --client-installation-id "REMOTE-DEVICE-E2E" \
      --workspace-id "$workspace_id" \
      --service-name no-such-service \
      --http-get /README.txt 2>&1
  )"; then
    fail "Service tunnel to missing service unexpectedly succeeded: $negative_output"
  fi
  [[ "$negative_output" == *"notFound"* ]] || fail "Service tunnel missing-service failure did not report notFound: $negative_output"
  # Leave the workspace as the parity flow left it: stop the process the tunnel check started.
  overview_json="$(tunnel_device_request overview "{}")" || fail "overview fetch after tunnel check failed"
  stop_payload="$(
    python3 - "$overview_json" "$workspace_id" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
workspace_id = sys.argv[2]
for workspace in ((payload.get("result") or {}).get("overview") or {}).get("workspaces") or []:
    if workspace.get("id") != workspace_id:
        continue
    for row in workspace.get("processRows") or []:
        if row.get("name") == "remote-web-server":
            print(json.dumps({
                "workspaceID": workspace_id,
                "processID": row.get("processID"),
                "processKey": "remote-web-server",
                "processTemplateID": row.get("templateID"),
            }, separators=(",", ":")))
            raise SystemExit(0)
raise SystemExit("remote-web-server process row not found in overview")
PY
  )" || fail "could not locate remote-web-server process row to stop"
  tunnel_device_request stopWorkspaceProcess "$stop_payload" >/dev/null || fail "stopWorkspaceProcess for remote-web-server failed"
}

write_result_json() {
  local project_dir="$1"
  local project_id="$2"
  local default_workspace_id="$3"
  local workspace_id="$4"
  local session_id="$5"
  local remote_web_service_port="$6"
  local remote_web_service_url="$7"
  local remote_web_browser_url="$8"
  local device_id
  device_id="$(
    python3 - "$CERTIFICATE_FINGERPRINT" "$REMOTE_DAEMON_HOST" "$REMOTE_DAEMON_PORT" <<'PY'
import re
import sys
fingerprint, host, port = sys.argv[1:4]
source = f"{fingerprint}|{host}|{port}".lower()
slug = re.sub(r"[^a-z0-9]+", "-", source).strip("-")
print("device-" + slug[:48])
PY
  )"
  mkdir -p "$(dirname "$RESULT_JSON")"
  python3 - "$RESULT_JSON" "$REMOTE_DAEMON_HOST" "$REMOTE_DAEMON_PORT" "$project_dir" "$project_id" "$default_workspace_id" "$workspace_id" "$session_id" "$device_id" "$AUTH_TOKEN" "$CERTIFICATE_FINGERPRINT" "$REMOTE_MAC_CLIENT_INSTALLATION_ID" "$MAC_AUTH_TOKEN" "$(remote_expand_path "$REMOTE_PERFORMANCE_LOG")" "$remote_web_service_port" "$remote_web_service_url" "$remote_web_browser_url" <<'PY'
import json
import sys
(
    path,
    host,
    port,
    project_dir,
    project_id,
    default_workspace_id,
    workspace_id,
    session_id,
    device_id,
    auth_token,
    certificate_fingerprint,
    mac_client_installation_id,
    mac_auth_token,
    remote_performance_log_path,
    remote_web_service_port,
    remote_web_service_url,
    remote_web_browser_url,
) = sys.argv[1:]
payload = {
    "deviceID": device_id,
    "name": "Remote Device",
    "remoteDaemonHost": host,
    "remoteDaemonPort": int(port),
    "authToken": auth_token,
    "certificateFingerprint": certificate_fingerprint,
    "macClientInstallationID": mac_client_installation_id,
    "macAuthToken": mac_auth_token,
    "remotePerformanceLogPath": remote_performance_log_path,
    "projectDir": project_dir,
    "projectID": project_id,
    "defaultWorkspaceID": default_workspace_id,
    "workspaceID": workspace_id,
    "terminalSessionID": session_id,
    "remoteWebServicePort": int(remote_web_service_port),
    "remoteWebServiceURL": remote_web_service_url,
    "remoteWebBrowserURL": remote_web_browser_url,
}
with open(path, "w") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
print(json.dumps(payload, indent=2, sort_keys=True))
PY
}

main() {
  require_remote_config
  mkdir -p "$TMP_ROOT"
  printf '[remote-device] validating SSH target %s\n' "$(remote_destination)"
  remote_ssh "printf 'ssh-ok\n'" >/dev/null
  printf '[remote-device] deploying Linux spacesd artifact into remote profile %s\n' "$REMOTE_E2E_PROFILE_NAME"
  prepare_remote_daemon
  resolve_remote_daemon_port
  printf '[remote-device] verifying remote daemon survives SSH setup disconnect on %s:%s\n' "$REMOTE_DAEMON_HOST" "$REMOTE_DAEMON_PORT"
  wait_for_remote_daemon_from_mac
  printf '[remote-device] waiting for remote daemon on %s:%s\n' "$REMOTE_DAEMON_HOST" "$REMOTE_DAEMON_PORT"
  wait_for_remote_daemon
  printf '[remote-device] pairing mobile and macOS clients through structured remote CLI metadata\n'
  pair_remote_devices
  printf '[remote-device] creating project, workspace, terminal, SSH forward, and service tunnel\n'
  remote_device_parity
}

main "$@"
