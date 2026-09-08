#!/usr/bin/env bash
set -euo pipefail

# On-demand, fully automated iOS performance baseline lane. Drives the iOS app in a simulator
# through XCUITest, talking to a live Spaces daemon (this worktree's local dev daemon, or its
# remote Linux dev profile with --remote) through a Mac-side shaping proxy
# (ios_baseline_shaper.py). Nine scenarios run under three shaped network profiles. Never part of
# scripts/verify.sh or CI: it measures, it does not gate.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/spaces-e2e-env.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/e2e_fixture_repos.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/ios-simulator-lifecycle.sh"

BUNDLE_ID="dev.usespaces.spacesmobile"
SPACES_E2E_BIN="$ROOT_DIR/apps/macos/.build/debug/spacese2e"
SPACES_BIN="$ROOT_DIR/apps/macos/.build/debug/spaces"
SHAPER_SCRIPT="$SCRIPT_DIR/ios_baseline_shaper.py"
FIXTURE_SCRIPT="$SCRIPT_DIR/terminal_stress_fixture.py"
REPORT_SCRIPT="$SCRIPT_DIR/ios_device_baseline_report.py"
BASELINE_CONFIG_HANDOFF_PATH="/tmp/spaces-mobile-baseline-config.json"
IOS_PROJECT="$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj"
IOS_DERIVED_DATA="$ROOT_DIR/apps/macos/.build/ios-derived-data"
FIXTURE_TEMPLATE_DIR="$ROOT_DIR/apps/macos/Tests/fixtures/e2e_demo"

ALL_PROFILES=(good constrained poor)
ALL_SCENARIOS=(
  cold-open back-and-forth keyboard streaming scrollback background-terminal background-list reconnect idle
)

scenario_test_method() {
  # `fail` calls exit, which inside a command-substitution subshell would only end the subshell,
  # so this returns non-zero instead and leaves failing loudly to the caller (outside the
  # substitution). Unreachable in practice: SELECTED_SCENARIOS is validated against ALL_SCENARIOS
  # before main() ever calls this, and every ALL_SCENARIOS member is mapped below.
  case "$1" in
    cold-open) printf 'testColdOpen' ;;
    back-and-forth) printf 'testBackAndForth' ;;
    keyboard) printf 'testKeyboard' ;;
    streaming) printf 'testStreaming' ;;
    scrollback) printf 'testScrollback' ;;
    background-terminal) printf 'testBackgroundForegroundTerminal' ;;
    background-list) printf 'testBackgroundForegroundList' ;;
    reconnect) printf 'testReconnect' ;;
    idle) printf 'testIdle' ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'USAGE'
Usage: e2e_mobile_baseline.sh [--remote] [--profile NAME]... [--scenario NAME]... [--idle-seconds N]

  --remote            Target this worktree's remote Linux dev profile instead of the local dev
                       daemon. Deploy it first with scripts/dev-build-and-launch.sh (without
                       --local); this script does not deploy the daemon itself.
  --profile NAME       Limit the run to one network profile (good, constrained, poor). Repeatable.
  --scenario NAME       Limit the run to one scenario. Repeatable.
  --idle-seconds N     Hold duration for the idle scenario (default 120).
USAGE
}

REMOTE=0
IDLE_SECONDS=120
SELECTED_PROFILES=()
SELECTED_SCENARIOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE=1
      shift
      ;;
    --profile)
      [[ $# -ge 2 ]] || { echo "--profile requires a value" >&2; exit 1; }
      SELECTED_PROFILES+=("$2")
      shift 2
      ;;
    --scenario)
      [[ $# -ge 2 ]] || { echo "--scenario requires a value" >&2; exit 1; }
      SELECTED_SCENARIOS+=("$2")
      shift 2
      ;;
    --idle-seconds)
      [[ $# -ge 2 ]] || { echo "--idle-seconds requires a value" >&2; exit 1; }
      IDLE_SECONDS="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ "$IDLE_SECONDS" =~ ^[0-9]+$ ]] || { echo "--idle-seconds must be a positive integer" >&2; exit 1; }

if [[ ${#SELECTED_PROFILES[@]} -eq 0 ]]; then
  SELECTED_PROFILES=("${ALL_PROFILES[@]}")
fi
if [[ ${#SELECTED_SCENARIOS[@]} -eq 0 ]]; then
  SELECTED_SCENARIOS=("${ALL_SCENARIOS[@]}")
fi
for requested in "${SELECTED_PROFILES[@]}"; do
  [[ " ${ALL_PROFILES[*]} " == *" $requested "* ]] || { echo "Unknown profile: $requested" >&2; exit 1; }
done
for requested in "${SELECTED_SCENARIOS[@]}"; do
  [[ " ${ALL_SCENARIOS[*]} " == *" $requested "* ]] || { echo "Unknown scenario: $requested" >&2; exit 1; }
done

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[ios-baseline] %s\n' "$*" >&2
}

RUN_ROOT="$HOME/.spaces-dev/ios-baseline/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_ROOT"
DEVICE_PERF_LOG="$RUN_ROOT/device-perf.jsonl"
SHAPER_LOG="$RUN_ROOT/shaper.jsonl"
SESSIONS_JSON="$RUN_ROOT/sessions.json"
RUNNER_LOG="$RUN_ROOT/runner.log"
DEVICE_API_HELPER="$RUN_ROOT/lane_device_api.py"
touch "$DEVICE_PERF_LOG"
printf '{}' >"$SESSIONS_JSON"
# Mirror everything this run prints to runner.log as well as the caller's terminal.
exec > >(tee -a "$RUNNER_LOG") 2>&1

# Late-bound globals: pre-declared empty so `set -u` never trips on a guard check before the
# value they hold is resolved (pairing, fixture lookup, simulator selection, shaper ports).
DAEMON_HOST=""
DAEMON_PORT=""
CERTIFICATE_FINGERPRINT=""
PAIRING_CODE=""
PAIRING_NONCE=""
PROTOCOL_VERSION=""
AUTH_TOKEN=""
INSTALLATION_ID=""
WORKSPACE_ID=""
MOBILE_UDID=""
MOBILE_NAME=""
SHAPER_LISTEN_PORT=""
SHAPER_CONTROL_PORT=""
SHAPER_PID=""
CURRENT_SESSION_ID=""
SCENARIO_FAILURES=()

# A session left running by an interrupted scenario is the only daemon-side state this trap ever
# touches; it never stops or restarts the daemon itself.
cleanup() {
  local exit_code=$?
  if [[ -n "$CURRENT_SESSION_ID" && -n "$WORKSPACE_ID" && -n "$DAEMON_HOST" ]]; then
    local stop_payload
    stop_payload="$(build_workspace_terminal_payload "$WORKSPACE_ID" "$CURRENT_SESSION_ID")"
    python3 "$DEVICE_API_HELPER" stopWorkspaceTerminal --payload-json "$stop_payload" \
      --host "$DAEMON_HOST" --port "$DAEMON_PORT" --certificate-fingerprint "$CERTIFICATE_FINGERPRINT" \
      --spacese2e "$SPACES_E2E_BIN" --auth-token "$AUTH_TOKEN" --installation-id "$INSTALLATION_ID" \
      >/dev/null 2>&1 || true
  fi
  stop_shaper
  rm -f "$BASELINE_CONFIG_HANDOFF_PATH"
  restore_simulator_hardware_keyboard
  exit "$exit_code"
}
trap cleanup EXIT

# The keyboard scenario needs the software keyboard to come back when the terminal's accessory toggle
# un-suppresses it. With Simulator's "Connect Hardware Keyboard" on (the default), the first show works
# but every later toggle leaves the keyboard hidden, so the setting is turned off for the run and put
# back afterwards. Simulator reads it at boot, so the lane's device is shut down first when it is
# already up; Simulator.app itself is only quit when no other device is booted, since another run may
# own one.
SIMULATOR_DEFAULTS_DOMAIN="com.apple.iphonesimulator"
SIMULATOR_HARDWARE_KEYBOARD_KEY="ConnectHardwareKeyboard"
SAVED_HARDWARE_KEYBOARD_VALUE=""
SAVED_HARDWARE_KEYBOARD_PRESENT=0
disconnect_simulator_hardware_keyboard() {
  if SAVED_HARDWARE_KEYBOARD_VALUE="$(defaults read "$SIMULATOR_DEFAULTS_DOMAIN" "$SIMULATOR_HARDWARE_KEYBOARD_KEY" 2>/dev/null)"; then
    SAVED_HARDWARE_KEYBOARD_PRESENT=1
  fi
  defaults write "$SIMULATOR_DEFAULTS_DOMAIN" "$SIMULATOR_HARDWARE_KEYBOARD_KEY" -bool false
  if [[ "$(spaces_ios_simulator_state "$MOBILE_UDID")" == "Booted" ]]; then
    log "shutting down simulator $MOBILE_UDID so the keyboard setting applies at boot"
    xcrun simctl shutdown "$MOBILE_UDID" >/dev/null 2>&1 || true
  fi
  if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
    osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1 || true
    sleep 2
  fi
}
restore_simulator_hardware_keyboard() {
  if [[ "$SAVED_HARDWARE_KEYBOARD_PRESENT" -eq 1 ]]; then
    defaults write "$SIMULATOR_DEFAULTS_DOMAIN" "$SIMULATOR_HARDWARE_KEYBOARD_KEY" -bool "$([[ "$SAVED_HARDWARE_KEYBOARD_VALUE" == "1" ]] && echo true || echo false)"
  else
    defaults delete "$SIMULATOR_DEFAULTS_DOMAIN" "$SIMULATOR_HARDWARE_KEYBOARD_KEY" >/dev/null 2>&1 || true
  fi
}

write_device_api_helper() {
  cat >"$DEVICE_API_HELPER" <<'PY'
#!/usr/bin/env python3
"""Device API request helper for the iOS performance baseline lane runner.

Builds the typed request shape every Device API E2E lane uses (see
apps/macos/Tests/device_api_parity.py): {"authToken", "clientApp", "command": {name: payload}}.
`pair` is the one unauthenticated command, so authToken is added only when --auth-token is given.
"""
import argparse
import json
import subprocess
import sys


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("command")
    parser.add_argument("--payload-json", default="{}")
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--certificate-fingerprint", required=True)
    parser.add_argument("--spacese2e", required=True)
    parser.add_argument("--auth-token", default="")
    parser.add_argument("--installation-id", default="IOS-BASELINE-LANE")
    parser.add_argument("--device-name", default="iOS Baseline Lane")
    parser.add_argument("--out")
    parser.add_argument("--require-ok", action="store_true")
    parser.add_argument("--print-field")
    return parser.parse_args()


def main():
    args = parse_args()
    payload = json.loads(args.payload_json)
    request = {
        "clientApp": {
            "installationID": args.installation_id,
            "bundleID": "dev.usespaces.spacesmobile",
            "platform": "ios",
            "deviceName": args.device_name,
            "appVersion": "1.0",
        },
        "command": {args.command: payload},
    }
    if args.auth_token:
        request["authToken"] = args.auth_token

    completed = subprocess.run(
        [
            args.spacese2e,
            "mobile-request",
            "--host",
            args.host,
            "--port",
            str(args.port),
            f"--certificate-fingerprint={args.certificate_fingerprint}",
            "--request-json",
            json.dumps(request, separators=(",", ":")),
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if completed.returncode != 0:
        sys.stderr.write(completed.stderr)
        raise SystemExit(f"{args.command} request failed with exit status {completed.returncode}")

    response_text = completed.stdout
    try:
        response = json.loads(response_text)
    except json.JSONDecodeError as error:
        raise SystemExit(f"{args.command} returned invalid JSON: {error}\n{response_text}") from error

    if args.out:
        with open(args.out, "w") as handle:
            handle.write(response_text)

    if args.require_ok and response.get("ok") is not True:
        raise SystemExit(f"{args.command} failed: {json.dumps(response, indent=2, sort_keys=True)}")

    if args.print_field:
        value = response
        for part in args.print_field.split("."):
            if not isinstance(value, dict) or part not in value:
                raise SystemExit(
                    f"{args.command} response missing field {args.print_field}: "
                    f"{json.dumps(response, indent=2, sort_keys=True)}"
                )
            value = value[part]
        print(value if isinstance(value, str) else json.dumps(value))
    elif not args.out:
        print(response_text)


if __name__ == "__main__":
    main()
PY
}

build_workspace_terminal_payload() {
  python3 -c "import json,sys; print(json.dumps({'workspaceID': sys.argv[1], 'sessionID': sys.argv[2]}, separators=(',', ':')))" \
    "$1" "$2"
}

require_preconditions() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required."
  command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required."
  [[ -f "$SHAPER_SCRIPT" ]] || fail "missing $SHAPER_SCRIPT"
  [[ -f "$FIXTURE_SCRIPT" ]] || fail "missing $FIXTURE_SCRIPT"
  [[ -f "$REPORT_SCRIPT" ]] || fail "missing $REPORT_SCRIPT"
  if [[ ! -x "$SPACES_E2E_BIN" || ! -x "$SPACES_BIN" ]]; then
    log "building spaces and spacese2e..."
    (cd "$ROOT_DIR" && swift build --package-path apps/macos --product spacese2e --product spaces) \
      || fail "failed to build spaces and spacese2e"
  fi
}

free_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

choose_simulator() {
  local selection
  selection="$(python3 - <<'PY'
import json
import re
import subprocess

payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
best = None
for runtime_id, devices in payload.get("devices", {}).items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime_id)
    if not match:
        continue
    runtime_version = (int(match.group(1)), int(match.group(2)))
    for device in devices:
        name = device.get("name", "")
        if not name.startswith("iPhone") or not device.get("isAvailable", True):
            continue
        number_match = re.search(r"(\d+)", name)
        number = int(number_match.group(1)) if number_match else 0
        # Sort key: newest runtime first, then the largest model number in the name, then the
        # name itself (so "iPhone 17 Pro Max" ranks above "iPhone 17 Pro" for the same runtime).
        key = (runtime_version, number, name)
        if best is None or key > best[0]:
            best = (key, device["udid"], name)
if best is None:
    raise SystemExit("No available iPhone simulator found.")
print(f"{best[1]}\t{best[2]}")
PY
)" || fail "failed to select an iPhone simulator"
  MOBILE_UDID="${selection%%$'\t'*}"
  MOBILE_NAME="${selection#*$'\t'}"
  log "selected simulator: $MOBILE_NAME ($MOBILE_UDID)"
}

parse_pairing_link() {
  python3 - "$1" <<'PY'
import json
import sys
from urllib.parse import parse_qs, urlparse

window = json.load(open(sys.argv[1]))
query = parse_qs(urlparse(window["pairingLink"]).query)
code = window.get("pairingCode") or query["code"][0]
nonce = window.get("pairingNonce") or query["nonce"][0]
protocol_version = query["pv"][0]
print(code, nonce, protocol_version)
PY
}

open_local_pairing_window() {
  local window_json="$RUN_ROOT/pairing-window.json"
  "$SPACES_E2E_BIN" open-device-pairing-window --timeout-seconds 10 >"$window_json" \
    || fail "failed to open a local device pairing window; is this worktree's dev daemon reachable? (spacese2e profile-show)"
  DAEMON_HOST="127.0.0.1"
  DAEMON_PORT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['port'])" "$window_json")"
  CERTIFICATE_FINGERPRINT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['certificateFingerprint'])" "$window_json")"
  read -r PAIRING_CODE PAIRING_NONCE PROTOCOL_VERSION < <(parse_pairing_link "$window_json")
}

open_remote_pairing_window() {
  spaces_e2e_require_remote_host_env "$ROOT_DIR"
  local ssh_args=(--ssh-host "$SPACES_E2E_REMOTE_SSH_HOST")
  [[ -n "${SPACES_E2E_REMOTE_SSH_USER:-}" ]] && ssh_args+=(--ssh-user "$SPACES_E2E_REMOTE_SSH_USER")
  [[ -n "${SPACES_E2E_REMOTE_SSH_PORT:-}" ]] && ssh_args+=(--ssh-port "$SPACES_E2E_REMOTE_SSH_PORT")
  local window_json="$RUN_ROOT/pairing-window.json"
  local window_err="$RUN_ROOT/pairing-window.err"
  if ! "$SPACES_E2E_BIN" open-remote-device-pairing-window "${ssh_args[@]}" >"$window_json" 2>"$window_err"; then
    cat "$window_err" >&2 || true
    fail "failed to open a remote device pairing window; deploy this worktree's remote dev profile first with scripts/dev-build-and-launch.sh (without --local), then rerun with --remote"
  fi
  DAEMON_HOST="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['host'])" "$window_json")"
  DAEMON_PORT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['port'])" "$window_json")"
  CERTIFICATE_FINGERPRINT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['certificateFingerprint'])" "$window_json")"
  read -r PAIRING_CODE PAIRING_NONCE PROTOCOL_VERSION < <(parse_pairing_link "$window_json")
}

pair_client() {
  INSTALLATION_ID="$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")"
  local payload
  payload="$(python3 - "$PAIRING_CODE" "$PAIRING_NONCE" "$PROTOCOL_VERSION" <<'PY'
import json
import sys

code, nonce, protocol_version = sys.argv[1:4]
print(json.dumps({"pairingCode": code, "pairingNonce": nonce, "clientProtocolVersion": int(protocol_version)}, separators=(",", ":")))
PY
)"
  local out="$RUN_ROOT/pair-response.json"
  local auth_token_file="$RUN_ROOT/.auth-token.txt"
  python3 "$DEVICE_API_HELPER" pair --payload-json "$payload" \
    --host "$DAEMON_HOST" --port "$DAEMON_PORT" --certificate-fingerprint "$CERTIFICATE_FINGERPRINT" \
    --spacese2e "$SPACES_E2E_BIN" --installation-id "$INSTALLATION_ID" --device-name "iOS Baseline Lane" \
    --out "$out" --require-ok --print-field result.issuedAuthToken.authToken >"$auth_token_file" \
    || fail "failed to pair a mobile client with the daemon"
  AUTH_TOKEN="$(cat "$auth_token_file")"
}

fetch_overview() {
  local out="$RUN_ROOT/overview.json"
  python3 "$DEVICE_API_HELPER" overview --host "$DAEMON_HOST" --port "$DAEMON_PORT" \
    --certificate-fingerprint "$CERTIFICATE_FINGERPRINT" --spacese2e "$SPACES_E2E_BIN" \
    --auth-token "$AUTH_TOKEN" --installation-id "$INSTALLATION_ID" --out "$out" --require-ok >/dev/null \
    || fail "failed to fetch the daemon overview"
}

# Prints the default workspace id of a project literally named "ios-baseline", or an empty line
# when no such project exists yet. Reused by both the local and remote fixture resolvers so a
# rerun of this lane finds and reuses the same project instead of creating a new one every time.
find_fixture_workspace_id() {
  python3 - "$RUN_ROOT/overview.json" <<'PY'
import json
import sys

overview = json.load(open(sys.argv[1]))["result"]["overview"]
project = next((p for p in overview["projects"] if p["name"] == "ios-baseline"), None)
if project is None:
    print("")
else:
    workspace = next((w for w in overview["workspaces"] if w["projectID"] == project["id"]), None)
    print(workspace["id"] if workspace else "")
PY
}

resolve_local_fixture_workspace() {
  fetch_overview
  local workspace_id
  workspace_id="$(find_fixture_workspace_id)"
  if [[ -n "$workspace_id" ]]; then
    WORKSPACE_ID="$workspace_id"
    return
  fi

  log "seeding local ios-baseline fixture project..."
  local profile_root fixture_dir seed_out
  profile_root="$("$SPACES_E2E_BIN" profile-show --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["profileRoot"])')"
  fixture_dir="$profile_root/fixtures/ios-baseline"
  mkdir -p "$fixture_dir"
  spaces_e2e_create_harbor_fixture_repo "$FIXTURE_TEMPLATE_DIR" "$fixture_dir"
  seed_out="$("$SPACES_E2E_BIN" seed-fixture --project-dir "$fixture_dir" --template harbor \
    --docs-url 'http://localhost:4173/docs/' --admin-url 'http://localhost:4173/admin/')"
  WORKSPACE_ID="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['defaultWorkspace']['id'])" "$seed_out")"
}

remote_shell_quote() {
  python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$1"
}

remote_ssh() {
  local -a args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
  [[ -n "${SPACES_E2E_REMOTE_SSH_PORT:-}" ]] && args+=(-p "$SPACES_E2E_REMOTE_SSH_PORT")
  local destination="$SPACES_E2E_REMOTE_SSH_HOST"
  [[ -n "${SPACES_E2E_REMOTE_SSH_USER:-}" ]] && destination="$SPACES_E2E_REMOTE_SSH_USER@$SPACES_E2E_REMOTE_SSH_HOST"
  ssh "${args[@]}" "$destination" "$@"
}

resolve_remote_fixture_workspace() {
  fetch_overview
  local workspace_id
  workspace_id="$(find_fixture_workspace_id)"
  if [[ -n "$workspace_id" ]]; then
    WORKSPACE_ID="$workspace_id"
    return
  fi

  log "creating remote ios-baseline fixture project..."
  local workspace_root="${SPACES_E2E_REMOTE_WORKSPACE_ROOT:-~/.spaces/e2e-workspaces}"
  local project_root
  project_root="$(remote_ssh "python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' $(remote_shell_quote "$workspace_root/ios-baseline")")"
  remote_ssh "python3 - $(remote_shell_quote "$project_root")" <<'PY'
import pathlib
import subprocess
import sys

project_root = pathlib.Path(sys.argv[1])
project_root.mkdir(parents=True, exist_ok=True)
readme = project_root / "README.txt"
if not readme.exists():
    readme.write_text("ios baseline lane fixture\n")


def git(*args):
    subprocess.run(["git", "-C", str(project_root), *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


if not (project_root / ".git").exists():
    git("init", "-b", "main")
    git("config", "user.email", "spaces-e2e@example.invalid")
    git("config", "user.name", "Spaces E2E")
    git("add", "README.txt")
    git("commit", "-m", "Initial iOS baseline lane fixture")
PY

  local payload out workspace_id_file
  payload="$(python3 -c "import json,sys; print(json.dumps({'projectDir': sys.argv[1], 'gitURL': None}, separators=(',', ':')))" "$project_root")"
  out="$RUN_ROOT/create-project.json"
  workspace_id_file="$RUN_ROOT/.workspace-id.txt"
  python3 "$DEVICE_API_HELPER" createProject --payload-json "$payload" \
    --host "$DAEMON_HOST" --port "$DAEMON_PORT" --certificate-fingerprint "$CERTIFICATE_FINGERPRINT" \
    --spacese2e "$SPACES_E2E_BIN" --auth-token "$AUTH_TOKEN" --installation-id "$INSTALLATION_ID" \
    --out "$out" --require-ok --print-field result.mutation.workspaceID >"$workspace_id_file" \
    || fail "failed to create the remote ios-baseline fixture project"
  WORKSPACE_ID="$(cat "$workspace_id_file")"
}

build_ios() {
  mkdir -p "$IOS_DERIVED_DATA"
  log "building SpacesMobile and UI tests for testing..."
  xcodebuild \
    -project "$IOS_PROJECT" \
    -scheme SpacesMobile \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$MOBILE_UDID" \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    build-for-testing >"$RUN_ROOT/ios-build-for-testing.log" 2>&1 \
    || fail "failed to build SpacesMobile for testing; see $RUN_ROOT/ios-build-for-testing.log"
}

start_shaper() {
  local profile="$1"
  local ready_log="$RUN_ROOT/shaper-startup-$profile.log"
  python3 "$SHAPER_SCRIPT" \
    --listen-port "$SHAPER_LISTEN_PORT" \
    --upstream-host "$DAEMON_HOST" \
    --upstream-port "$DAEMON_PORT" \
    --profile "$profile" \
    --control-port "$SHAPER_CONTROL_PORT" \
    --log "$SHAPER_LOG" >"$ready_log" 2>&1 &
  SHAPER_PID=$!

  local deadline=$((SECONDS + 15))
  while [[ $SECONDS -lt $deadline ]]; do
    if grep -q '^listening port=' "$ready_log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$SHAPER_PID" 2>/dev/null; then
      cat "$ready_log" >&2 || true
      fail "shaper process for profile $profile exited before it was ready"
    fi
    sleep 0.1
  done
  fail "timed out waiting for shaper readiness (profile $profile)"
}

stop_shaper() {
  if [[ -n "$SHAPER_PID" ]]; then
    kill "$SHAPER_PID" >/dev/null 2>&1 || true
    wait "$SHAPER_PID" >/dev/null 2>&1 || true
    SHAPER_PID=""
  fi
}

# Prints the full startWorkspaceCommandSession payload: the fixture is base64-encoded at run time
# (so this lane always ships whatever terminal_stress_fixture.py currently contains) and delivered
# as a single self-decoding python3 -c invocation, matching the shared-contract recipe exactly.
build_start_session_payload() {
  local workspace_id="$1" scenario="$2"
  python3 - "$FIXTURE_SCRIPT" "$scenario" "$workspace_id" <<'PY'
import base64
import json
import sys

fixture_path, scenario, workspace_id = sys.argv[1:4]
with open(fixture_path, "rb") as handle:
    encoded = base64.b64encode(handle.read()).decode("ascii")

argv_items = ["fixture", "--mode", "agent_screen"]
if scenario == "scrollback":
    argv_items += ["--history-lines", "3000"]
elif scenario == "streaming":
    argv_items += ["--burst-on-stdin", "--burst-lines", "400", "--sleep-ms", "10"]
argv_literal = "[" + ",".join("'%s'" % item for item in argv_items) + "]"
command = "python3 -c \"import base64,sys;sys.argv=%s;exec(base64.b64decode('%s'))\"" % (argv_literal, encoded)
print(json.dumps({"workspaceID": workspace_id, "command": command}, separators=(",", ":")))
PY
}

record_session() {
  local profile="$1" scenario="$2" session_id="$3" workspace_id="$4"
  python3 - "$SESSIONS_JSON" "$profile" "$scenario" "$session_id" "$workspace_id" "$([[ "$REMOTE" -eq 1 ]] && echo remote || echo local)" "$DAEMON_HOST" <<'PY'
import json
import sys

sessions_path, profile, scenario, session_id, workspace_id, target_kind, target_host = sys.argv[1:8]
try:
    with open(sessions_path) as handle:
        sessions = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    sessions = {}
sessions["target"] = {"kind": target_kind, "host": target_host}
scenarios = [entry for entry in sessions.get("scenarios", []) if (entry.get("profile"), entry.get("scenario")) != (profile, scenario)]
scenarios.append({"profile": profile, "scenario": scenario, "sessionID": session_id, "workspaceID": workspace_id})
sessions["scenarios"] = scenarios
with open(sessions_path, "w") as handle:
    json.dump(sessions, handle, indent=2, sort_keys=True)
PY
}

write_scenario_config() {
  local profile="$1" scenario="$2" session_id="$3" out="$4"
  python3 - "$out" "$profile" "$scenario" "$session_id" "$DEVICE_PERF_LOG" "$INSTALLATION_ID" "$AUTH_TOKEN" \
    "$CERTIFICATE_FINGERPRINT" "$SHAPER_LISTEN_PORT" "$SHAPER_CONTROL_PORT" "$IDLE_SECONDS" <<'PY'
import json
import sys

(out_path, profile, scenario, session_id, perf_log_path, installation_id, auth_token,
 certificate_fingerprint, shaper_listen_port, shaper_control_port, idle_seconds) = sys.argv[1:12]

# The seeded device is the shaping proxy's own loopback endpoint, never the real daemon address:
# that is what forces every byte the app sends or receives through the shaped link. Combined with
# SPACES_MOBILE_TEST_FIXED_HOSTS=1 (set by the UI test launch environment) this is the only
# candidate endpoint the app's connection resolver ever considers.
device_seed = {
    "activeDeviceID": "ios-baseline-lane",
    "devices": [
        {
            "id": "ios-baseline-lane",
            "name": "iOS Baseline Lane",
            "host": "127.0.0.1",
            "port": int(shaper_listen_port),
            "authToken": auth_token,
            "certificateFingerprint": certificate_fingerprint,
        }
    ],
}
config = {
    "profile": profile,
    "scenario": scenario,
    "sessionID": session_id,
    "perfLogPath": perf_log_path,
    "deviceSeedJSON": json.dumps(device_seed, separators=(",", ":")),
    "installationID": installation_id,
    "shaperControlPort": int(shaper_control_port),
    "idleSeconds": int(idle_seconds),
    "reopenCount": 5,
    "keyboardCycles": 5,
    "flickCount": 8,
    "backgroundCycles": 3,
}
with open(out_path, "w") as handle:
    json.dump(config, handle, indent=2, sort_keys=True)
PY
}

append_marker() {
  local marker="$1" profile="$2" scenario="$3" extra="${4:-}"
  [[ -z "$extra" ]] && extra="{}"
  python3 - "$DEVICE_PERF_LOG" "$marker" "$profile" "$scenario" "$extra" <<'PY'
import datetime
import json
import sys
import time

log_path, marker, profile, scenario, extra_json = sys.argv[1:6]
attributes = {"profile": profile, "scenario": scenario, "marker": marker}
attributes.update(json.loads(extra_json))
now = datetime.datetime.now(datetime.timezone.utc)
emitted_at = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
line = {
    "sessionID": "lane",
    "source": "lane-runner",
    "name": "lane_marker",
    "emittedAt": emitted_at,
    "emittedUptimeNanoseconds": time.monotonic_ns(),
    "attributes": attributes,
}
with open(log_path, "a") as handle:
    handle.write(json.dumps(line, separators=(",", ":")) + "\n")
PY
}

# Polls device-perf.jsonl for a lane_marker or app-emitted line whose attributes match marker/
# profile/scenario (and, when given, one extra key/value pair -- used for burst_wait_end's
# "burst" number). Only the streaming scenario needs this: every other scenario just waits on
# xcodebuild's own exit.
wait_for_marker() {
  local marker="$1" profile="$2" scenario="$3" timeout="$4" extra_key="${5:-}" extra_value="${6:-}"
  python3 - "$DEVICE_PERF_LOG" "$marker" "$profile" "$scenario" "$timeout" "$extra_key" "$extra_value" <<'PY'
import json
import sys
import time

log_path, marker, profile, scenario, timeout_text, extra_key, extra_value = sys.argv[1:8]
deadline = time.monotonic() + float(timeout_text)
while time.monotonic() < deadline:
    try:
        with open(log_path) as handle:
            lines = handle.readlines()
    except FileNotFoundError:
        lines = []
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        attributes = payload.get("attributes") or {}
        if attributes.get("marker") != marker or attributes.get("profile") != profile or attributes.get("scenario") != scenario:
            continue
        if extra_key and str(attributes.get(extra_key)) != extra_value:
            continue
        sys.exit(0)
    time.sleep(0.2)
sys.exit(1)
PY
}

run_ui_test() {
  local test_method="$1" log_path="$2"
  if xcodebuild \
      -project "$IOS_PROJECT" \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$MOBILE_UDID" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      -only-testing:"SpacesMobileUITests/SpacesMobileBaselineUITests/$test_method" \
      test-without-building >"$log_path" 2>&1; then
    return 0
  fi
  log "UI test failed: $test_method (see $log_path)"
  return 1
}

send_terminal_input_newline() {
  local session_id="$1"
  local payload
  payload="$(python3 -c "import json,sys; print(json.dumps({'sessionID': sys.argv[1], 'text': '\n', 'appendNewline': False}, separators=(',', ':')))" "$session_id")"
  python3 "$DEVICE_API_HELPER" sendTerminalInput --payload-json "$payload" \
    --host "$DAEMON_HOST" --port "$DAEMON_PORT" --certificate-fingerprint "$CERTIFICATE_FINGERPRINT" \
    --spacese2e "$SPACES_E2E_BIN" --auth-token "$AUTH_TOKEN" --installation-id "$INSTALLATION_ID" --require-ok >/dev/null
}

# The streaming scenario needs the runner to inject bursts mid-test, so xcodebuild runs in the
# background while this function watches device-perf.jsonl for the test's own markers and drives
# the fixture's stdin through sendTerminalInput -- a direct PTY write with no ownership handshake,
# so it never contends with the app's own live owner-mode attachment to the same session.
run_streaming_scenario() {
  local profile="$1" scenario="$2" test_method="$3" session_id="$4" log_path="$5"
  xcodebuild \
      -project "$IOS_PROJECT" \
      -scheme SpacesMobile \
      -destination "platform=iOS Simulator,id=$MOBILE_UDID" \
      -derivedDataPath "$IOS_DERIVED_DATA" \
      -only-testing:"SpacesMobileUITests/SpacesMobileBaselineUITests/$test_method" \
      test-without-building >"$log_path" 2>&1 &
  local xcodebuild_pid=$!

  local ok=1
  if wait_for_marker "streaming_ready" "$profile" "$scenario" 120; then
    local burst
    for burst in 1 2; do
      send_terminal_input_newline "$session_id" || log "warning: sendTerminalInput failed for burst $burst"
      # Attribute values are strings throughout this event contract (matching
      # SpacesDeviceTerminalPerformanceEvent.attributes / BaselineLaneMarkers on the app side).
      append_marker "burst_sent" "$profile" "$scenario" "{\"burst\":\"$burst\"}"
      if ! wait_for_marker "burst_wait_end" "$profile" "$scenario" 60 burst "$burst"; then
        log "timed out waiting for burst_wait_end (burst $burst)"
        ok=0
        break
      fi
      sleep 5
    done
  else
    log "timed out waiting for streaming_ready"
    ok=0
  fi

  if ! wait "$xcodebuild_pid"; then
    ok=0
  fi
  [[ $ok -eq 1 ]]
}

run_scenario() {
  local profile="$1" scenario="$2"
  local test_method
  test_method="$(scenario_test_method "$scenario")" || fail "no UI test method mapped for scenario '$scenario'"

  local payload response_out session_id_file
  payload="$(build_start_session_payload "$WORKSPACE_ID" "$scenario")"
  response_out="$RUN_ROOT/start-session-$profile-$scenario.json"
  session_id_file="$RUN_ROOT/.session-id-$profile-$scenario.txt"
  if ! python3 "$DEVICE_API_HELPER" startWorkspaceCommandSession --payload-json "$payload" \
      --host "$DAEMON_HOST" --port "$DAEMON_PORT" --certificate-fingerprint "$CERTIFICATE_FINGERPRINT" \
      --spacese2e "$SPACES_E2E_BIN" --auth-token "$AUTH_TOKEN" --installation-id "$INSTALLATION_ID" \
      --out "$response_out" --require-ok --print-field result.mutation.sessionID >"$session_id_file"; then
    log "failed to start session for $profile/$scenario (see $response_out)"
    SCENARIO_FAILURES+=("$profile/$scenario")
    return
  fi
  local session_id
  session_id="$(cat "$session_id_file")"
  CURRENT_SESSION_ID="$session_id"
  record_session "$profile" "$scenario" "$session_id" "$WORKSPACE_ID"

  local config_path="$RUN_ROOT/config-$profile-$scenario.json"
  write_scenario_config "$profile" "$scenario" "$session_id" "$config_path"
  # xcodebuild does not forward this shell's environment to the XCUITest runner process, so the test
  # reads the fixed default path `BaselineLaneConfiguration.defaultConfigPath` instead (the same handoff
  # `e2e_mobile.sh` uses for its own UI test config). The run root keeps the per-scenario copy.
  cp "$config_path" "$BASELINE_CONFIG_HANDOFF_PATH"

  append_marker "runner_scenario_start" "$profile" "$scenario"

  local xcodebuild_log="$RUN_ROOT/xcodebuild-$profile-$scenario.log"
  local status="ok"
  if [[ "$scenario" == "streaming" ]]; then
    run_streaming_scenario "$profile" "$scenario" "$test_method" "$session_id" "$xcodebuild_log" || status="failed"
  else
    run_ui_test "$test_method" "$xcodebuild_log" || status="failed"
  fi

  append_marker "runner_scenario_finish" "$profile" "$scenario" "{\"status\":\"$status\"}"

  local stop_payload
  stop_payload="$(build_workspace_terminal_payload "$WORKSPACE_ID" "$session_id")"
  python3 "$DEVICE_API_HELPER" stopWorkspaceTerminal --payload-json "$stop_payload" \
    --host "$DAEMON_HOST" --port "$DAEMON_PORT" --certificate-fingerprint "$CERTIFICATE_FINGERPRINT" \
    --spacese2e "$SPACES_E2E_BIN" --auth-token "$AUTH_TOKEN" --installation-id "$INSTALLATION_ID" \
    --out "$RUN_ROOT/stop-session-$profile-$scenario.json" >/dev/null \
    || log "warning: failed to stop session $session_id"
  CURRENT_SESSION_ID=""

  if [[ "$status" != "ok" ]]; then
    SCENARIO_FAILURES+=("$profile/$scenario")
  fi
}

main() {
  write_device_api_helper
  require_preconditions
  choose_simulator
  disconnect_simulator_hardware_keyboard
  spaces_ios_simulator_boot_if_needed "$MOBILE_UDID" || fail "failed to boot simulator $MOBILE_UDID"
  open -a Simulator >/dev/null 2>&1 || true

  if [[ "$REMOTE" -eq 1 ]]; then
    open_remote_pairing_window
  else
    open_local_pairing_window
  fi
  pair_client

  if [[ "$REMOTE" -eq 1 ]]; then
    resolve_remote_fixture_workspace
  else
    resolve_local_fixture_workspace
  fi

  build_ios

  SHAPER_LISTEN_PORT="$(free_port)"
  SHAPER_CONTROL_PORT="$(free_port)"

  local profile scenario
  for profile in "${SELECTED_PROFILES[@]}"; do
    log "starting shaper for profile $profile..."
    start_shaper "$profile"
    for scenario in "${SELECTED_SCENARIOS[@]}"; do
      log "running $profile/$scenario"
      run_scenario "$profile" "$scenario"
    done
    stop_shaper
  done

  xcrun simctl terminate "$MOBILE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

  log "writing report..."
  python3 "$REPORT_SCRIPT" --run-root "$RUN_ROOT" || log "warning: report generation failed"
  local report_path="$RUN_ROOT/report.md"
  if [[ -f "$report_path" ]]; then
    printf '\nReport: %s\n\n' "$report_path"
    cat "$report_path"
  fi

  printf 'Run root: %s\n' "$RUN_ROOT"
  if [[ ${#SCENARIO_FAILURES[@]} -gt 0 ]]; then
    log "failed scenarios: ${SCENARIO_FAILURES[*]}"
    return 1
  fi
  return 0
}

main
