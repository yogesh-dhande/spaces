#!/usr/bin/env bash
#
# record_ios_demo_recording.sh — deterministic, idempotent recorder for the iOS
# Demo Mode bundled recording (apps/ios/Resources/DemoRecording/).
#
# It stands up a fully isolated, throwaway Spaces daemon profile, seeds the three
# hand-authored Lighthouse fixtures (harbor-web / lantern-api / atlas-docs), drives
# them into three contrasting states through the real Device API (the same path a
# paired iOS client uses), then captures the real daemon overview plus real Ghostty
# full-frame terminal payloads at iOS-native grids via `spacese2e record-mobile-demo`.
#
# Contrasting states produced:
#   - harbor-web  : launched (frontend + backend running, healthy) + coding agent
#                   "Fix checkout 500" waiting on input.
#   - lantern-api : launched, then its backend process stopped (exited → Alerts).
#   - atlas-docs  : seeded but idle (an untouched workspace).
#
# The output is deterministic: daemon session IDs become stable slugs, the temp
# profile path is rewritten to a fixed placeholder, browser sessions / assigned
# ports / workspace environment are stripped, and every timestamp is rebased to a
# signed second-offset from a reference date. Re-running produces semantically
# identical output (same slugs, same renderText). See `spacese2e record-mobile-demo`.
#
# Everything runs against a temp HOME + temp SPACES_DB_PATH + temp SPACES_RUNTIME_DIR,
# so ~/.spaces and other worktrees' running instances are never touched.
#
# Grid derivation (documented; not measured at runtime to keep the harness free of
# the iOS app/simulator). The iOS viewer (GhosttyRemoteTerminalView) reports a grid
# of floor((width - 16) / cellW) x floor((height - 12) / cellH), where the 16/12 are
# the 8pt/6pt content insets and the cell metrics come from
# UIFont.monospacedSystemFont(ofSize: 11):
#     cellW = ceil("W".size.width) = ceil(6.7998) = 7 pt
#     cellH = ceil(font.lineHeight) = ceil(13.127) = 14 pt   (measured on iOS 26 sim)
# For a read-only demo terminal there is no keyboard/accessory occlusion, so the
# render bounds fill the terminal surface below the ~36pt custom header and inside the
# device safe area:
#   iPhone 17 Pro portrait  402 x 874 pt, safe insets top 59 / bottom 34:
#     cols = floor((402 - 16) / 7)              = 55
#     rows = floor(((874-59-36-34) - 12) / 14)  = 52   -> 55x52
#   iPad 11" portrait       834 x 1194 pt, safe insets top 24 / bottom 20:
#     cols = floor((834 - 16) / 7)              = 116
#     rows = floor(((1194-24-36-20) - 12) / 14) = 78   -> 116x78
# The Demo backend picks the nearest-grid recording at attach and acks the client's
# exact requested size, so a few cells of drift is tolerated exactly as today.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
source "$repo_root/apps/macos/Tests/e2e_fixture_repos.sh"

spacese2e="${SPACES_E2E:-$repo_root/apps/macos/.build/debug/spacese2e}"
spaces_cli="${SPACES_CLI:-$repo_root/apps/macos/.build/debug/spaces}"
spacesd="${SPACESD_EXECUTABLE:-$repo_root/apps/macos/.build/debug/spacesd}"
ghostty_xcframework="${SPACES_GHOSTTYKIT_XCFRAMEWORK:-$repo_root/apps/macos/.local/ghosttykit/GhosttyKit.xcframework}"
ghostty_resources="${SPACES_GHOSTTY_RESOURCES_DIR:-$repo_root/apps/macos/.local/ghosttykit/Resources/ghostty}"
fixture_template_dir="$repo_root/apps/macos/Tests/fixtures/e2e_demo"

output_dir="${1:-$repo_root/apps/ios/Resources/DemoRecording}"
# The daemon binds all interfaces (a loopback-only bind fails with EINVAL, same as
# every other Spaces harness); clients connect over loopback.
device_api_host="127.0.0.1"
device_api_bind_host="0.0.0.0"
device_api_port="${SPACES_DEMO_RECORD_PORT:-47922}"
bundle_id="dev.usespaces.spacesmobile"

# iOS-native grids (see header derivation): iPhone 17 Pro portrait, iPad 11" portrait.
grids=("55x52" "116x78")
path_placeholder="/Users/lighthouse/Projects"

temp_root=""
daemon_pid=""

log() { printf '%s\n' "$*" >&2; }

cleanup() {
  local status=$?
  stop_daemon || true
  if [[ -n "$temp_root" && -d "$temp_root" ]]; then
    rm -rf "$temp_root"
  fi
  exit "$status"
}
trap cleanup EXIT

demo_env() {
  env \
    -u NO_COLOR -u CLICOLOR -u CLICOLOR_FORCE -u CI \
    -u CODEX_CI -u CODEX_MANAGED_BY_NPM -u CODEX_MANAGED_PACKAGE_ROOT -u CODEX_THREAD_ID \
    HOME="$demo_home" \
    XDG_CONFIG_HOME="$demo_xdg" \
    SPACES_DB_PATH="$db_path" \
    SPACES_RUNTIME_DIR="$runtime_dir" \
    SPACESD_EXECUTABLE="$spacesd" \
    SPACES_DEVICE_API_HOST="$device_api_bind_host" \
    SPACES_DEVICE_API_PORT="$device_api_port" \
    SPACES_GHOSTTYKIT_XCFRAMEWORK="$ghostty_xcframework" \
    SPACES_GHOSTTY_RESOURCES_DIR="$ghostty_resources" \
    SPACES_PROJECT_DIR="$repo_root" \
    "$@"
}

require_path() {
  [[ -e "$1" ]] || { log "Missing required path ($2): $1"; exit 1; }
}

build_products() {
  log "Building spacese2e, spaces, and spacesd..."
  swift build --package-path "$repo_root/apps/macos" --product spacese2e >&2
  swift build --package-path "$repo_root/apps/macos" --product spaces >&2
  swift build --package-path "$repo_root/apps/macos" --product spacesd >&2
}

create_profile() {
  # Strip any trailing slash from TMPDIR (macOS sets it with one) so mktemp does not produce a
  # double-slash path that fails to substring-match the daemon's normalized workspace dirs.
  local tmp_base="${TMPDIR:-/tmp}"
  tmp_base="${tmp_base%/}"
  temp_root="$(mktemp -d "$tmp_base/spaces-demo-record.XXXXXX")"
  # macOS resolves /var/folders paths to /private/var/folders; the daemon canonicalizes some,
  # so both spellings must be rewritten out of the recording.
  canonical_temp_root="$(cd "$temp_root" && pwd -P)"
  demo_home="$temp_root/home"
  demo_xdg="$temp_root/xdg"
  db_path="$temp_root/spaces.db"
  runtime_dir="$temp_root/runtime"
  mkdir -p "$demo_home" "$demo_xdg" "$runtime_dir"
}

stop_device_api_port_listeners() {
  local pid command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" != *"$spacesd"* ]]; then
      log "Refusing to stop non-Spaces listener on port $device_api_port: pid=$pid command=$command"
      exit 1
    fi
    kill "$pid" >/dev/null 2>&1 || true
  done < <(lsof -tiTCP:"$device_api_port" -sTCP:LISTEN 2>/dev/null || true)
}

start_daemon() {
  log "Starting isolated spacesd daemon on Device API port $device_api_port..."
  demo_env "$spacesd" >"$temp_root/daemon.log" 2>&1 &
  daemon_pid=$!
}

stop_daemon() {
  # Stop the fixture workspaces first so the daemon runs each stop script, killing the workspace
  # processes and per-workspace router it deliberately detached from itself. Killing the daemon alone
  # would orphan those children (they outlive the daemon by design) and leak their listening ports.
  if [[ -n "$daemon_pid" ]] && ps -p "$daemon_pid" >/dev/null 2>&1 && [[ -n "$temp_root" ]]; then
    demo_env "$spacese2e" stop-fixtures --dir-prefix "$temp_root" >/dev/null 2>&1 || true
  fi
  if [[ -n "$daemon_pid" ]] && ps -p "$daemon_pid" >/dev/null 2>&1; then
    kill "$daemon_pid" >/dev/null 2>&1 || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=""
  fi
  stop_device_api_port_listeners
  # Backstop: reap any workspace process / router still bound to this run's temp profile.
  if [[ -n "$temp_root" ]]; then
    pkill -f "$temp_root" >/dev/null 2>&1 || true
  fi
}

wait_for_device_api_port() {
  python3 - "$device_api_host" "$device_api_port" <<'PY'
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
for _ in range(60):
    try:
        s = socket.create_connection((host, port), timeout=1)
        s.close()
        raise SystemExit(0)
    except OSError:
        time.sleep(0.5)
raise SystemExit("Device API port never became ready.")
PY
}

open_pairing_window() {
  local window_json
  window_json="$(demo_env "$spacese2e" open-device-pairing-window)"
  eval "$(python3 - "$window_json" <<'PY'
import json, shlex, sys
p = json.loads(sys.argv[1])
print(f"pairing_link={shlex.quote(p['pairingLink'])}")
print(f"certificate_fingerprint={shlex.quote(p['certificateFingerprint'])}")
PY
)"
}

pair_recorder() {
  installation_id="$(uuidgen)"
  auth_token="$(python3 - "$spacese2e" "$pairing_link" "$device_api_host" "$device_api_port" "$installation_id" "$bundle_id" <<'PY'
import json, subprocess, sys
from urllib.parse import parse_qs, urlparse

spacese2e, pairing_link, host, port, installation_id, bundle_id = sys.argv[1:]
query = parse_qs(urlparse(pairing_link).query)
code = query.get("code", [""])[0]
nonce = query.get("nonce", [""])[0]
pv = query.get("pv", [""])[0]
if not (code and nonce and pv):
    raise SystemExit(f"pairing link missing code/nonce/pv: {pairing_link}")
request = {
    "command": {"pair": {"pairingCode": code, "pairingNonce": nonce, "clientProtocolVersion": int(pv)}},
    "clientApp": {"installationID": installation_id, "bundleID": bundle_id, "platform": "ios",
                  "deviceName": "Spaces Demo Recorder", "appVersion": "1.0"},
}
out = subprocess.run(
    [spacese2e, "mobile-request", "--pairing-link", pairing_link, "--host", host, "--port", port,
     "--request-json", json.dumps(request)],
    capture_output=True, text=True, check=True).stdout
response = json.loads(out)
token = (((response.get("result") or {}).get("issuedAuthToken") or {}).get("authToken"))
if not response.get("ok") or not token:
    raise SystemExit(f"pair failed: {response}")
print(token)
PY
)"
}

device_request() {
  local command_json="$1"
  local request_json
  request_json="$(python3 - "$command_json" "$auth_token" "$installation_id" "$bundle_id" <<'PY'
import json, sys
command, auth_token, installation_id, bundle_id = sys.argv[1:]
print(json.dumps({
    "command": json.loads(command),
    "authToken": auth_token,
    "clientApp": {"installationID": installation_id, "bundleID": bundle_id, "platform": "ios",
                  "deviceName": "Spaces Demo Recorder", "appVersion": "1.0"},
}))
PY
)"
  demo_env "$spacese2e" mobile-request \
    --host "$device_api_host" --port "$device_api_port" \
    --certificate-fingerprint "$certificate_fingerprint" \
    --request-json "$request_json"
}

workspace_id_for() {
  demo_env "$spacese2e" lookup-workspace --project-dir "$1" | jq -r '.id'
}

seed_and_launch() {
  spaces_e2e_create_harbor_fixture_repo "$fixture_template_dir" "$temp_root/harbor-web"
  spaces_e2e_create_lantern_fixture_repo "$fixture_template_dir" "$temp_root/lantern-api"
  spaces_e2e_create_atlas_fixture_repo "$fixture_template_dir" "$temp_root/atlas-docs"

  for template in harbor:harbor-web lantern:lantern-api atlas:atlas-docs; do
    local name="${template%%:*}" dir="$temp_root/${template##*:}"
    demo_env "$spacese2e" seed-fixture \
      --project-dir "$dir" --template "$name" \
      --docs-url 'http://localhost:$SPACES_APP_PORT/docs/' \
      --admin-url 'http://localhost:$SPACES_APP_PORT/admin/' >/dev/null
  done

  local harbor_ws lantern_ws
  harbor_ws="$(workspace_id_for "$temp_root/harbor-web")"
  lantern_ws="$(workspace_id_for "$temp_root/lantern-api")"

  log "Launching harbor-web (frontend + backend) and its coding agent..."
  device_request "{\"launchWorkspace\":{\"workspaceID\":\"$harbor_ws\"}}" >/dev/null
  local agent_response agent_session
  agent_response="$(device_request "{\"runCodingAgent\":{\"workspaceID\":\"$harbor_ws\",\"agentName\":\"Fix checkout 500\"}}")"
  agent_session="$(printf '%s' "$agent_response" | jq -r '.result.mutation.sessionID // empty')"
  if [[ -z "$agent_session" ]]; then
    log "Failed to resolve the coding-agent session id from runCodingAgent response."
    exit 1
  fi
  # Drive the real agent lifecycle so the row settles into the flagship "waiting on input" state
  # (Alerts attention event). Same mechanism as e2e_macos_app.sh's mock agent: init -> working ->
  # blocked, where the daemon maps `blocked` to activityState=waiting. The scripted fixture agent
  # itself stays signal-free; the harness owns these transitions here.
  log "Signaling the coding agent to the waiting-on-input state..."
  local event
  for event in init working blocked; do
    demo_env "$spaces_cli" agent signal --workspace "$harbor_ws" --session "$agent_session" "$event" >/dev/null
  done

  log "Launching lantern-api, then crashing its backend (exited state + alert)..."
  device_request "{\"launchWorkspace\":{\"workspaceID\":\"$lantern_ws\"}}" >/dev/null
  # Let the backend print its banner and register before killing it, so its final frame has content
  # and its process row becomes `exited` (not `notStarted`) — a real exit that drives an Alerts entry.
  sleep 3
  kill_workspace_process "$lantern_ws" backend

  # Let all sessions render their steady-state output before recording.
  sleep 3
}

# Kills a workspace process's foreground child so it exits on its own (a crash), which the daemon
# records as an `exited` process row + ended terminal session — unlike a graceful stop, which reverts
# the row to `notStarted`. Resolves the child PID from the Device API overview.
kill_workspace_process() {
  local workspace_id="$1" process_name="$2" pid
  pid="$(device_request '{"overview":{}}' | jq -r --arg ws "$workspace_id" --arg name "$process_name" '
    .result.overview as $o
    | ($o.workspaces[] | select(.id == $ws) | .processRows[] | select(.name == $name) | .sessionID) as $sid
    | ($o.sessions[] | select(.id == $sid) | .childPID) // empty')"
  if [[ -n "$pid" && "$pid" != "null" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
  else
    log "Warning: could not resolve child PID for $process_name in $workspace_id."
  fi
}

record() {
  mkdir -p "$output_dir"
  local -a grid_args=()
  local grid
  for grid in "${grids[@]}"; do
    grid_args+=(--grid "$grid")
  done
  log "Recording into $output_dir ..."
  demo_env "$spacese2e" record-mobile-demo \
    --output "$output_dir" \
    "${grid_args[@]}" \
    --host "$device_api_host" --port "$device_api_port" \
    --certificate-fingerprint "$certificate_fingerprint" \
    --auth-token "$auth_token" \
    --client-installation-id "$installation_id" \
    --path-rewrite "$canonical_temp_root=$path_placeholder" \
    --path-rewrite "$temp_root=$path_placeholder" \
    --path-rewrite "$repo_root=/Users/lighthouse/spaces"
}

check_size() {
  local kib
  kib="$(du -sk "$output_dir" | awk '{print $1}')"
  log "Bundle size: ${kib} KiB"
  if (( kib > 10240 )); then
    log "Recording exceeds the 10 MB budget (${kib} KiB)."
    exit 1
  fi
}

validate() {
  log "Validating every ndjson line decodes with the production codecs and renders non-empty text..."
  local file text
  while IFS= read -r file; do
    text="$(demo_env "$spacese2e" render-update-text <"$file" | jq -r 'select(.ok == true) | .text // ""')"
    if [[ -z "${text//[$'\n\r\t ']/}" ]]; then
      log "Empty or undecodable render text in $file"
      exit 1
    fi
  done < <(find "$output_dir/grids" -name '*.ndjson' | sort)
  log "Validation passed."
}

require_path "$ghostty_xcframework" "GhosttyKit.xcframework"
require_path "$ghostty_resources" "Ghostty resources"

build_products
require_path "$spacese2e" "spacese2e"
require_path "$spaces_cli" "spaces"
require_path "$spacesd" "spacesd"
create_profile
stop_device_api_port_listeners
start_daemon
wait_for_device_api_port
open_pairing_window
pair_recorder
seed_and_launch
record
check_size
validate

log "Demo recording written to $output_dir"
find "$output_dir" -type f | sort | sed "s#^$output_dir/#  #" >&2
