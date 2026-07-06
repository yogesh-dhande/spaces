#!/usr/bin/env bash
# Remote agent send/tail E2E: installs the isolated remote E2E daemon, registers a workspace-owned
# terminal session on it, pairs this machine's CLI with the daemon by redeeming a pairing link
# (`spaces device pair --link`), then drives the session purely from this machine with
# `spaces terminal list/send/tail --device` — the orchestrator agent-to-agent path.
#
# Every terminal session is workspace-owned, so the session cannot be a standalone shell: the script
# first creates a git project + default workspace on the remote daemon through the Device API
# (`spacese2e mobile-request createProject`, the only project-creation surface — the shipped `spaces`
# CLI has no project-add command), then starts the session with `spaces terminal command --workspace`
# inside that workspace. The Device-API setup pairing (mobile-request) and the CLI link pairing are
# two separate device registrations against the same daemon; send/tail is token-authorized without
# owner gating, so the CLI-paired device drives the session the setup device created.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$ROOT_DIR/scripts/spaces-e2e-env.sh"
spaces_e2e_require_remote_host_env "$ROOT_DIR"

SPACES_BIN="${SPACES_CLI:-$ROOT_DIR/apps/macos/.build/debug/spaces}"
SPACES_E2E_BIN="${SPACES_E2E:-$ROOT_DIR/apps/macos/.build/debug/spacese2e}"
REMOTE_HOST="${SPACES_E2E_REMOTE_SSH_HOST:-}"
REMOTE_USER="${SPACES_E2E_REMOTE_SSH_USER:-}"
REMOTE_SSH_PORT="${SPACES_E2E_REMOTE_SSH_PORT:-}"
REMOTE_DAEMON_HOST="${SPACES_E2E_REMOTE_DAEMON_HOST:-$REMOTE_HOST}"
REMOTE_DAEMON_PORT="${SPACES_E2E_REMOTE_DAEMON_PORT:-47847}"
REMOTE_E2E_ROOT="${SPACES_E2E_REMOTE_DEVICE_ROOT:-~/.spaces/remote-device-e2e}"
REMOTE_WORKSPACE_ROOT="${SPACES_E2E_REMOTE_WORKSPACE_ROOT:-~/.spaces/e2e-workspaces}"
RUN_ID="${SPACES_E2E_REMOTE_DEVICE_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"
TMP_ROOT="${TMPDIR:-/tmp}/spaces-remote-terminal-send-e2e.$$"
MARKER="hello-remote-e2e-$$"

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
  remote_ssh "eval printf '%s' $quoted"
}

[[ -x "$SPACES_BIN" ]] || fail "spaces CLI not built at $SPACES_BIN (run apps/macos/scripts/swiftpm.sh build)"
[[ -x "$SPACES_E2E_BIN" ]] || fail "spacese2e not built at $SPACES_E2E_BIN (run apps/macos/scripts/swiftpm.sh build)"

mkdir -p "$TMP_ROOT"
# Isolated client identity so this pairing never mixes with the operator's real client database.
export SPACES_CLIENT_DB_PATH="$TMP_ROOT/spaces-client.db"
export SPACES_CLIENT_SECRET_DIR="$TMP_ROOT/client-secrets"

DEVICE_ID=""
REMOTE_SESSION_ID=""
REMOTE_INSTALL=""
REMOTE_ENV_PREFIX=""
REMOTE_PROJECT_DIR=""
CERTIFICATE_FINGERPRINT=""

cleanup() {
  if [[ -n "$REMOTE_SESSION_ID" && -n "$REMOTE_ENV_PREFIX" ]]; then
    remote_ssh "$REMOTE_ENV_PREFIX $REMOTE_INSTALL/bin/spaces terminal send $REMOTE_SESSION_ID exit --newline" >/dev/null 2>&1 || true
  fi
  if [[ -n "$REMOTE_PROJECT_DIR" ]]; then
    remote_ssh "rm -rf $(shell_quote "$REMOTE_PROJECT_DIR")" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# Opens a fresh one-time pairing window on the remote E2E daemon and prints its code, nonce, and the
# daemon's certificate fingerprint (stable across windows — it is the daemon's TLS identity).
open_remote_pairing_window() {
  local pair_json parsed
  pair_json="$(remote_ssh "$REMOTE_ENV_PREFIX $REMOTE_INSTALL/bin/spaces device pair --json")"
  parsed="$(
    SPACES_E2E_PAIR_JSON="$pair_json" python3 <<'PY'
import json
import os
import shlex
payload = json.loads(os.environ["SPACES_E2E_PAIR_JSON"])
for key in ("pairingCode", "pairingNonce", "certificateFingerprint"):
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"remote pairing JSON missing {key}")
if not isinstance(payload.get("protocolVersion"), int):
    raise SystemExit("remote pairing JSON missing protocolVersion")
print(f"PAIRING_CODE={shlex.quote(payload['pairingCode'])}")
print(f"PAIRING_NONCE={shlex.quote(payload['pairingNonce'])}")
print(f"CERTIFICATE_FINGERPRINT={shlex.quote(payload['certificateFingerprint'])}")
print(f"PAIRING_PROTOCOL_VERSION={payload['protocolVersion']}")
print(f"PAIRING_APP_VERSION={shlex.quote(str(payload.get('appVersion') or '1.0'))}")
print(f"PAIRING_NAME={shlex.quote(str(payload.get('name') or 'remote-e2e'))}")
PY
  )"
  eval "$parsed"
  [[ -n "$PAIRING_CODE" ]] || fail "remote pairing JSON missing pairingCode"
  [[ -n "$PAIRING_NONCE" ]] || fail "remote pairing JSON missing pairingNonce"
  [[ -n "$CERTIFICATE_FINGERPRINT" ]] || fail "remote pairing JSON missing certificateFingerprint"
}

# Sends one authenticated Device API request to the remote daemon over pinned TLS and prints the
# validated (ok) JSON response.
device_request() {
  local request_json="$1" response_file
  response_file="$TMP_ROOT/response.json"
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

echo "== deploying the isolated remote E2E daemon =="
artifact_assignments="$("$ROOT_DIR/apps/macos/scripts/deploy_linux_spacesd_e2e.sh")"
eval "$artifact_assignments"
[[ "${artifact_url:-}" == file://* ]] || fail "Remote artifact URL must be file://, got: ${artifact_url:-<unset>}"
archive_path="${artifact_url#file://}"

REMOTE_INSTALL="$(remote_expand_path "$REMOTE_E2E_ROOT/install")"
remote_db_path="$(remote_expand_path "$REMOTE_E2E_ROOT/spaces.db")"
remote_runtime_dir="$(remote_expand_path "$REMOTE_E2E_ROOT/runtime")"
REMOTE_ENV_PREFIX="SPACES_DB_PATH=$(shell_quote "$remote_db_path") SPACES_RUNTIME_DIR=$(shell_quote "$remote_runtime_dir")"
remote_ssh "rm -rf $(shell_quote "$REMOTE_INSTALL") && mkdir -p $(shell_quote "$REMOTE_INSTALL") && tar -xzf $(shell_quote "$archive_path") -C $(shell_quote "$REMOTE_INSTALL") --strip-components=1 && $REMOTE_ENV_PREFIX SPACES_DEVICE_API_HOST=0.0.0.0 SPACES_DEVICE_API_PORT=$REMOTE_DAEMON_PORT $(shell_quote "$REMOTE_INSTALL/install.sh")" >/dev/null

echo "== creating a git fixture project on the remote host =="
REMOTE_PROJECT_DIR="$(remote_expand_path "$REMOTE_WORKSPACE_ROOT/remote-terminal-send-$RUN_ID")"
remote_ssh "python3 - $(shell_quote "$REMOTE_PROJECT_DIR")" <<'PY'
import pathlib
import shutil
import subprocess
import sys

project_root = pathlib.Path(sys.argv[1])
shutil.rmtree(project_root, ignore_errors=True)
project_root.mkdir(parents=True, exist_ok=True)
(project_root / "README.txt").write_text("remote terminal send/tail sentinel\n")
(project_root / "spaces.yaml").write_text("version: 1\n")

def git(*args):
    subprocess.run(["git", "-C", str(project_root), *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

git("init", "-b", "main")
git("config", "user.email", "spaces-e2e@example.invalid")
git("config", "user.name", "Spaces E2E")
git("add", "README.txt", "spaces.yaml")
git("commit", "-m", "Initial remote terminal send fixture")
PY

echo "== registering a workspace-owned project on the remote daemon (Device API setup) =="
open_remote_pairing_window
SETUP_REQUEST="$(
  python3 - "$PAIRING_CODE" "$PAIRING_NONCE" "$PAIRING_PROTOCOL_VERSION" <<'PY'
import json
import sys
code, nonce, protocol_version = sys.argv[1:4]
print(json.dumps({
    "command": {"pair": {"pairingCode": code, "pairingNonce": nonce, "clientProtocolVersion": int(protocol_version)}},
    "clientApp": {
        "installationID": "REMOTE-TERMINAL-SEND-SETUP",
        "bundleID": "dev.usespaces.spaces",
        "platform": "macos",
        "deviceName": "Remote Terminal Send Setup",
        "appVersion": "1.0",
    },
}, separators=(",", ":")))
PY
)"
SETUP_TOKEN="$(device_request "$SETUP_REQUEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["issuedAuthToken"]["authToken"])')"
[[ -n "$SETUP_TOKEN" ]] || fail "setup pairing did not issue an auth token"

CREATE_PROJECT_REQUEST="$(
  python3 - "$SETUP_TOKEN" "$REMOTE_PROJECT_DIR" <<'PY'
import json
import sys
token, project_dir = sys.argv[1:3]
print(json.dumps({
    "authToken": token,
    "clientApp": {
        "installationID": "REMOTE-TERMINAL-SEND-SETUP",
        "bundleID": "dev.usespaces.spaces",
        "platform": "macos",
        "deviceName": "Remote Terminal Send Setup",
        "appVersion": "1.0",
    },
    "command": {"createProject": {"projectDir": project_dir, "gitURL": None}},
}, separators=(",", ":")))
PY
)"
REMOTE_WORKSPACE_ID="$(device_request "$CREATE_PROJECT_REQUEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["mutation"]["workspaceID"])')"
[[ -n "$REMOTE_WORKSPACE_ID" ]] || fail "createProject did not return a default workspace id"
echo "remote workspace: $REMOTE_WORKSPACE_ID"

echo "== pairing this client's CLI with the remote E2E daemon (link redemption) =="
open_remote_pairing_window
PAIR_LINK="$(
  python3 - "$REMOTE_DAEMON_HOST" "$REMOTE_DAEMON_PORT" "$PAIRING_NONCE" "$PAIRING_CODE" "$CERTIFICATE_FINGERPRINT" "$PAIRING_NAME" "$PAIRING_PROTOCOL_VERSION" "$PAIRING_APP_VERSION" <<'PY'
import sys
import urllib.parse
host, port, nonce, code, fingerprint, name, pv, av = sys.argv[1:9]
# The daemon advertises its own interface address, which may not be reachable from this machine;
# rebuild the v3 link against the configured daemon host/port from .env, carrying the daemon
# wire-protocol (pv) and app version (av) so the pairing-time compatibility gate passes.
query = urllib.parse.urlencode({
    "v": "3", "host": host, "port": port, "nonce": nonce, "code": code,
    "fp": fingerprint, "name": name, "pv": pv, "av": av,
})
print(f"spaces://pair?{query}")
PY
)"
PAIR_OUTPUT="$("$SPACES_BIN" device pair --link "$PAIR_LINK")"
echo "$PAIR_OUTPUT"
DEVICE_ID="$(printf '%s' "$PAIR_OUTPUT" | tr '\t' '\n' | sed -n 's/^id=//p' | head -n 1)"
[[ -n "$DEVICE_ID" ]] || fail "device pair did not print a device id"
"$SPACES_BIN" device list

echo "== creating a remote terminal session in the workspace =="
REMOTE_SESSION_LINE="$(remote_ssh "$REMOTE_ENV_PREFIX $REMOTE_INSTALL/bin/spaces terminal command --workspace $(shell_quote "$REMOTE_WORKSPACE_ID") --command 'bash -i'")"
echo "$REMOTE_SESSION_LINE"
REMOTE_SESSION_ID="$(printf '%s' "$REMOTE_SESSION_LINE" | sed -n 's/^Started terminal session //p' | cut -f1 | head -n 1)"
[[ -n "$REMOTE_SESSION_ID" ]] || fail "remote terminal command did not print a session id"

echo "== listing remote sessions through the device =="
LIST_OUTPUT="$("$SPACES_BIN" terminal list --device "$DEVICE_ID")"
echo "$LIST_OUTPUT"
printf '%s\n' "$LIST_OUTPUT" | grep -q "$REMOTE_SESSION_ID" || fail "terminal list --device did not show $REMOTE_SESSION_ID"

echo "== sending input through the device =="
"$SPACES_BIN" terminal send --device "$DEVICE_ID" "$REMOTE_SESSION_ID" "echo $MARKER" --newline

echo "== tailing output through the device =="
deadline=$((SECONDS + 30))
while true; do
  TAIL_OUTPUT="$("$SPACES_BIN" terminal tail --device "$DEVICE_ID" "$REMOTE_SESSION_ID" --lines 50 || true)"
  if printf '%s\n' "$TAIL_OUTPUT" | grep -qx "$MARKER"; then
    break
  fi
  if ((SECONDS >= deadline)); then
    printf '%s\n' "$TAIL_OUTPUT"
    fail "terminal tail --device never showed '$MARKER'"
  fi
  sleep 1
done

echo "== removing the pairing =="
"$SPACES_BIN" device remove "$DEVICE_ID"

echo "PASS: remote terminal send/tail round trip through device $DEVICE_ID"
