#!/usr/bin/env bash
# Remote agent send/tail E2E: pairs the CLI with the configured remote daemon over SSH, creates a
# terminal session on the remote host, then drives it purely from this machine with
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
TMP_ROOT="${TMPDIR:-/tmp}/spaces-remote-terminal-send-e2e.$$"
MARKER="hello-remote-e2e-$$"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
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

[[ -x "$SPACES_BIN" ]] || fail "spaces CLI not built at $SPACES_BIN (run apps/macos/scripts/swiftpm.sh build)"

mkdir -p "$TMP_ROOT"
# Isolated client identity so this pairing never mixes with the operator's real client database.
export SPACES_CLIENT_DB_PATH="$TMP_ROOT/spaces-client.db"
export SPACES_CLIENT_SECRET_DIR="$TMP_ROOT/client-secrets"

DEVICE_ID=""
REMOTE_SESSION_ID=""

cleanup() {
  if [[ -n "$REMOTE_SESSION_ID" ]]; then
    remote_ssh "~/.spaces/bin/spaces terminal send $REMOTE_SESSION_ID 'exit' --newline" >/dev/null 2>&1 || true
  fi
  if [[ -n "$DEVICE_ID" ]]; then
    "$SPACES_BIN" device remove "$DEVICE_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

echo "== pairing with $(remote_destination) over SSH =="
PAIR_ARGS=(device pair --ssh "$(remote_destination)")
if [[ -n "$REMOTE_SSH_PORT" ]]; then
  PAIR_ARGS+=(--ssh-port "$REMOTE_SSH_PORT")
fi
PAIR_OUTPUT="$("$SPACES_BIN" "${PAIR_ARGS[@]}")"
echo "$PAIR_OUTPUT"
DEVICE_ID="$(printf '%s' "$PAIR_OUTPUT" | sed -nE 's/.*id=([^\t]+).*/\1/p' | head -n 1)"
[[ -n "$DEVICE_ID" ]] || fail "device pair did not print a device id"

echo "== creating a remote terminal session =="
REMOTE_SESSION_LINE="$(remote_ssh "~/.spaces/bin/spaces terminal command --command 'bash -i'")"
echo "$REMOTE_SESSION_LINE"
REMOTE_SESSION_ID="$(printf '%s' "$REMOTE_SESSION_LINE" | sed -nE 's/^Started terminal session ([^\t]+).*/\1/p' | head -n 1)"
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

echo "PASS: remote terminal send/tail round trip through device $DEVICE_ID"
