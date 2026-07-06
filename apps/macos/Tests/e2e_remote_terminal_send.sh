#!/usr/bin/env bash
# Remote agent send/tail E2E: installs the isolated remote E2E daemon, pairs this machine's CLI
# with it by redeeming a pairing link (`spaces device pair --link`), creates a terminal session on
# the remote host, then drives it purely from this machine with
# `spaces terminal list/send/tail --device` — the orchestrator agent-to-agent path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$ROOT_DIR/scripts/spaces-e2e-env.sh"
spaces_e2e_require_remote_host_env "$ROOT_DIR"

SPACES_BIN="${SPACES_CLI:-$ROOT_DIR/apps/macos/.build/debug/spaces}"
REMOTE_HOST="${SPACES_E2E_REMOTE_SSH_HOST:-}"
REMOTE_USER="${SPACES_E2E_REMOTE_SSH_USER:-}"
REMOTE_SSH_PORT="${SPACES_E2E_REMOTE_SSH_PORT:-}"
REMOTE_DAEMON_HOST="${SPACES_E2E_REMOTE_DAEMON_HOST:-$REMOTE_HOST}"
REMOTE_DAEMON_PORT="${SPACES_E2E_REMOTE_DAEMON_PORT:-47847}"
REMOTE_E2E_ROOT="${SPACES_E2E_REMOTE_DEVICE_ROOT:-~/.spaces/remote-device-e2e}"
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

mkdir -p "$TMP_ROOT"
# Isolated client identity so this pairing never mixes with the operator's real client database.
export SPACES_CLIENT_DB_PATH="$TMP_ROOT/spaces-client.db"
export SPACES_CLIENT_SECRET_DIR="$TMP_ROOT/client-secrets"

DEVICE_ID=""
REMOTE_SESSION_ID=""
REMOTE_INSTALL=""
REMOTE_ENV_PREFIX=""

cleanup() {
  if [[ -n "$REMOTE_SESSION_ID" && -n "$REMOTE_ENV_PREFIX" ]]; then
    remote_ssh "$REMOTE_ENV_PREFIX $REMOTE_INSTALL/bin/spaces terminal send $REMOTE_SESSION_ID exit --newline" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

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

echo "== opening a pairing window on the remote E2E daemon =="
PAIR_JSON="$(remote_ssh "$REMOTE_ENV_PREFIX $REMOTE_INSTALL/bin/spaces device pair --json")"
PAIR_LINK="$(SPACES_E2E_PAIR_JSON="$PAIR_JSON" python3 - "$REMOTE_DAEMON_HOST" "$REMOTE_DAEMON_PORT" <<'PY'
import json
import os
import sys
import urllib.parse

payload = json.loads(os.environ["SPACES_E2E_PAIR_JSON"])
# The daemon advertises its own interface address, which may not be reachable from this machine;
# rebuild the v3 link against the configured daemon host/port from .env, carrying the
# daemon-advertised wire-protocol (pv) and app version (av) so the pairing-time compatibility gate passes.
query = urllib.parse.urlencode({
    "v": "3",
    "host": sys.argv[1],
    "port": sys.argv[2],
    "nonce": payload["pairingNonce"],
    "code": payload["pairingCode"],
    "fp": payload["certificateFingerprint"],
    "name": payload["name"],
    "pv": payload["protocolVersion"],
    "av": payload["appVersion"],
})
print(f"spaces://pair?{query}")
PY
)"

echo "== pairing this client with the remote E2E daemon =="
PAIR_OUTPUT="$("$SPACES_BIN" device pair --link "$PAIR_LINK")"
echo "$PAIR_OUTPUT"
DEVICE_ID="$(printf '%s' "$PAIR_OUTPUT" | tr '\t' '\n' | sed -n 's/^id=//p' | head -n 1)"
[[ -n "$DEVICE_ID" ]] || fail "device pair did not print a device id"
"$SPACES_BIN" device list

echo "== creating a remote terminal session =="
REMOTE_SESSION_LINE="$(remote_ssh "$REMOTE_ENV_PREFIX $REMOTE_INSTALL/bin/spaces terminal command --command 'bash -i'")"
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
