#!/usr/bin/env bash
set -euo pipefail

# On-demand, fully automated client performance baseline lane. Drives the iOS app in a simulator
# through XCUITest, talking to a live Spaces daemon (this worktree's local dev daemon, or its
# remote Linux dev profile with --remote) through a Mac-side shaping proxy
# (ios_baseline_shaper.py). The mac-reconnect scenario drives this worktree's Mac app through the
# same proxy instead, so both clients' reconnect behavior is measured by one procedure into one
# report. Every scenario runs under three shaped network profiles. Never part of
# scripts/verify.sh or CI: it measures, it does not gate.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/spaces-e2e-env.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/e2e_fixture_repos.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/ios-simulator-lifecycle.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/spaces-profile-helpers.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/e2e_ui_automation.sh"

BUNDLE_ID="dev.usespaces.spacesmobile"
SPACES_E2E_BIN="$ROOT_DIR/apps/macos/.build/debug/spacese2e"
SPACES_BIN="$ROOT_DIR/apps/macos/.build/debug/spaces"
SPACES_APP_BIN="$ROOT_DIR/apps/macos/.build/debug/SpacesApp"
SPACESD_BIN="$ROOT_DIR/apps/macos/.build/debug/spacesd"
SHAPER_SCRIPT="$SCRIPT_DIR/ios_baseline_shaper.py"
FIXTURE_SCRIPT="$SCRIPT_DIR/terminal_stress_fixture.py"
REPORT_SCRIPT="$SCRIPT_DIR/ios_device_baseline_report.py"
BASELINE_CONFIG_HANDOFF_PATH="/tmp/spaces-mobile-baseline-config.json"
IOS_PROJECT="$ROOT_DIR/apps/ios/SpacesMobile.xcodeproj"
IOS_DERIVED_DATA="$ROOT_DIR/apps/macos/.build/ios-derived-data"
FIXTURE_TEMPLATE_DIR="$ROOT_DIR/apps/macos/Tests/fixtures/e2e_demo"

# The paired-device record the mac-reconnect scenario seeds into this profile's client store. The id
# is anything other than SpacesPairedDeviceRecord.localDeviceID ("local"), which is all the app reads
# to treat a device as remote. The sidebar publishes no identifier for a device row, so the section
# header text (the device name, uppercased) is how the scenario tells the seeded device's copy of a
# workspace apart from the local device's copy of the same workspace.
MAC_DEVICE_ID="mac-reconnect-lane"
MAC_DEVICE_NAME="Mac Reconnect Lane"
MAC_DEVICE_SECTION_TITLE="MAC RECONNECT LANE"
# The seeded device's sidebar rows appear only once the app has loaded that device's overview through
# the shaped link, which on the poor profile follows a first-launch setup probe of up to 25 seconds.
MAC_SIDEBAR_TIMEOUT_SECONDS=90
# Read by the accessibility automation in e2e_ui_automation.sh.
ACTION_TIMEOUT_SECONDS="${ACTION_TIMEOUT_SECONDS:-20}"
AX_PROBE_TIMEOUT_SECONDS="${AX_PROBE_TIMEOUT_SECONDS:-3}"

ALL_PROFILES=(good constrained poor)
ALL_SCENARIOS=(
  cold-open cold-open-owned back-and-forth keyboard streaming scrollback background-terminal background-list reconnect idle
  mac-reconnect
)

scenario_test_method() {
  # `fail` calls exit, which inside a command-substitution subshell would only end the subshell,
  # so this returns non-zero instead and leaves failing loudly to the caller (outside the
  # substitution). Unreachable in practice: SELECTED_SCENARIOS is validated against ALL_SCENARIOS
  # before main() ever calls this, and every ALL_SCENARIOS member is mapped below.
  case "$1" in
    cold-open) printf 'testColdOpen' ;;
    cold-open-owned) printf 'testColdOpen' ;;
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
  # A remote run's default list leaves out cold-open-owned, which no remote session can satisfy: no Mac
  # window can own one. Asking for it explicitly is still an error, so a run that names it hears why.
  if [[ "$REMOTE" -eq 1 ]]; then
    for scenario in "${ALL_SCENARIOS[@]}"; do
      [[ "$scenario" == "cold-open-owned" ]] || SELECTED_SCENARIOS+=("$scenario")
    done
  else
    SELECTED_SCENARIOS=("${ALL_SCENARIOS[@]}")
  fi
fi
for requested in "${SELECTED_PROFILES[@]}"; do
  [[ " ${ALL_PROFILES[*]} " == *" $requested "* ]] || { echo "Unknown profile: $requested" >&2; exit 1; }
done
for requested in "${SELECTED_SCENARIOS[@]}"; do
  [[ " ${ALL_SCENARIOS[*]} " == *" $requested "* ]] || { echo "Unknown scenario: $requested" >&2; exit 1; }
done
if [[ "$REMOTE" -eq 1 ]]; then
  for requested in "${SELECTED_SCENARIOS[@]}"; do
    [[ "$requested" == "cold-open-owned" ]] \
      && { echo "cold-open-owned cannot run with --remote: no Mac window can own a remote session" >&2; exit 1; }
  done
fi

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
LANE_LAUNCHED_MAC_APP_PID=""
PROFILE_ROOT=""
MAC_DEVICE_SEEDED=0
UPSTREAM_DB_PATH=""
UPSTREAM_RUNTIME_DIR=""
UPSTREAM_HOST=""
UPSTREAM_PORT=""
UPSTREAM_FINGERPRINT=""
UPSTREAM_WORKSPACE_ID=""
UPSTREAM_LANE_TOKEN=""
UPSTREAM_LANE_INSTALLATION_ID=""
# The endpoint the scenario now running started its session on, so cleanup can stop a session an
# interrupted scenario left behind on whichever daemon owns it.
SESSION_HOST=""
SESSION_PORT=""
SESSION_FINGERPRINT=""
SESSION_TOKEN=""
SESSION_INSTALLATION_ID=""
SESSION_WORKSPACE_ID=""
# The pid the accessibility automation in e2e_ui_automation.sh drives: the Mac app this lane launched.
SPACES_PID=""

# A session left running by an interrupted scenario is the only daemon-side state this trap ever
# touches; it never stops or restarts the daemon itself.
cleanup() {
  local exit_code=$?
  if [[ -n "$CURRENT_SESSION_ID" && -n "$SESSION_WORKSPACE_ID" && -n "$SESSION_HOST" ]]; then
    local stop_payload
    stop_payload="$(build_workspace_terminal_payload "$SESSION_WORKSPACE_ID" "$CURRENT_SESSION_ID")"
    python3 "$DEVICE_API_HELPER" stopWorkspaceTerminal --payload-json "$stop_payload" \
      --host "$SESSION_HOST" --port "$SESSION_PORT" --certificate-fingerprint "$SESSION_FINGERPRINT" \
      --spacese2e "$SPACES_E2E_BIN" --auth-token "$SESSION_TOKEN" --installation-id "$SESSION_INSTALLATION_ID" \
      >/dev/null 2>&1 || true
  fi
  # The app goes first: the shaping proxy's shutdown waits for its live connections to close, so a
  # still-connected client would park `stop_shaper` forever.
  quit_mac_app
  remove_mac_paired_device
  stop_shaper
  stop_mac_upstream_daemon
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
# Set once the run has actually written the setting, so a run that never touched it (no iOS scenario
# selected) restores nothing rather than deleting the developer's own value.
HARDWARE_KEYBOARD_OVERRIDDEN=0
disconnect_simulator_hardware_keyboard() {
  if SAVED_HARDWARE_KEYBOARD_VALUE="$(defaults read "$SIMULATOR_DEFAULTS_DOMAIN" "$SIMULATOR_HARDWARE_KEYBOARD_KEY" 2>/dev/null)"; then
    SAVED_HARDWARE_KEYBOARD_PRESENT=1
  fi
  HARDWARE_KEYBOARD_OVERRIDDEN=1
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
  [[ "$HARDWARE_KEYBOARD_OVERRIDDEN" -eq 1 ]] || return 0
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
    # The mac-reconnect scenario pairs the Mac app's own installation id, and a daemon authorizes a
    # request only when the client app matches the pairing it was issued under.
    parser.add_argument("--bundle-id", default="dev.usespaces.spacesmobile")
    parser.add_argument("--platform", default="ios")
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
            "bundleID": args.bundle_id,
            "platform": args.platform,
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

# True when cold-open-owned is in this run: it needs a native Mac window, and only a local run can
# supply one. Read by require_preconditions, so the SpacesApp product is staged before it runs.
owned_scenario_selected() {
  [[ "$REMOTE" -eq 0 && " ${SELECTED_SCENARIOS[*]} " == *" cold-open-owned "* ]]
}

mac_scenario_selected() {
  [[ " ${SELECTED_SCENARIOS[*]} " == *" mac-reconnect "* ]]
}

# True when anything in this run drives the iOS app, which is what the simulator, its keyboard
# setting, and the XCUITest build are for. A mac-reconnect-only run needs none of them.
ios_scenarios_selected() {
  local scenario
  for scenario in "${SELECTED_SCENARIOS[@]}"; do
    [[ "$scenario" == "mac-reconnect" ]] || return 0
  done
  return 1
}

require_preconditions() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required."
  if ios_scenarios_selected; then
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required."
  fi
  [[ -f "$SHAPER_SCRIPT" ]] || fail "missing $SHAPER_SCRIPT"
  [[ -f "$FIXTURE_SCRIPT" ]] || fail "missing $FIXTURE_SCRIPT"
  [[ -f "$REPORT_SCRIPT" ]] || fail "missing $REPORT_SCRIPT"
  if [[ ! -x "$SPACES_E2E_BIN" || ! -x "$SPACES_BIN" ]]; then
    log "building spaces and spacese2e..."
    (cd "$ROOT_DIR" && swift build --package-path apps/macos --product spacese2e --product spaces) \
      || fail "failed to build spaces and spacese2e"
  fi
  if { owned_scenario_selected || mac_scenario_selected; } && [[ ! -x "$SPACES_APP_BIN" ]]; then
    log "building SpacesApp..."
    (cd "$ROOT_DIR" && swift build --package-path apps/macos --product SpacesApp) \
      || fail "failed to build SpacesApp"
  fi
  if mac_scenario_selected && [[ ! -x "$SPACESD_BIN" ]]; then
    log "building spacesd..."
    (cd "$ROOT_DIR" && swift build --package-path apps/macos --product spacesd) || fail "failed to build spacesd"
  fi
  # mac-reconnect measures events only an app launched with the performance log path emits, so it
  # cannot borrow an app instance that is already running for this profile.
  if mac_scenario_selected; then
    local existing_pid
    existing_pid="$(spaces_profile_app_owner_pid "$SPACES_E2E_BIN")"
    [[ -z "$existing_pid" ]] \
      || fail "mac-reconnect needs to launch this profile's Mac app itself; quit the instance already running for it (pid $existing_pid)"
  fi
}

# This worktree profile's root, resolved once. The fixture project the lane seeds lives under it.
profile_root() {
  if [[ -z "$PROFILE_ROOT" ]]; then
    PROFILE_ROOT="$("$SPACES_E2E_BIN" profile-show --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["profileRoot"])')" \
      || fail "failed to resolve this worktree's profile root"
  fi
  printf '%s' "$PROFILE_ROOT"
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
  local fixture_dir seed_out
  fixture_dir="$(profile_root)/fixtures/ios-baseline"
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

# Starts the shaping proxy for one profile in front of `upstream_host:upstream_port`. The listen and
# control ports stay the same across a run, so the device record seeded against them survives every
# restart the profile loop does.
start_shaper() {
  local profile="$1" upstream_host="$2" upstream_port="$3"
  local ready_log="$RUN_ROOT/shaper-startup-$profile.log"
  python3 "$SHAPER_SCRIPT" \
    --listen-port "$SHAPER_LISTEN_PORT" \
    --upstream-host "$upstream_host" \
    --upstream-port "$upstream_port" \
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
    # The proxy closes only once its live connections are gone, and a Mac pane keeps redialing the
    # seeded device until the app itself is gone, so the wait is bounded and then escalated.
    local deadline=$((SECONDS + 10))
    while [[ $SECONDS -lt $deadline ]] && kill -0 "$SHAPER_PID" >/dev/null 2>&1; do
      sleep 0.2
    done
    kill -9 "$SHAPER_PID" >/dev/null 2>&1 || true
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

# True (exit 0) when the daemon's overview reports an active (never-detached) owner attachment on
# $2 within the overview snapshot at $1, matching the shape TerminalSessionAttachmentSnapshot puts
# on the wire (SpacesDeviceTerminalSessionSummary.attachmentSnapshot.attachments[].mode/detachedAt).
session_has_owner_attachment() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

overview_path, session_id = sys.argv[1:3]
overview = json.load(open(overview_path))["result"]["overview"]
session = next((s for s in overview["sessions"] if s["id"] == session_id), None)
if session is None:
    sys.exit(1)
attachments = (session.get("attachmentSnapshot") or {}).get("attachments") or []
has_owner = any(a.get("mode") == "owner" and a.get("detachedAt") is None for a in attachments)
sys.exit(0 if has_owner else 1)
PY
}

# Polls the daemon overview (the same command fetch_overview already uses) for an active owner
# attachment on session $1, bounded to ~20s at 0.5s intervals. `spaces terminal show` only posts an
# IPC notification to the running Mac app and returns; the window's open and its attach round trip
# to the daemon land asynchronously, so cold-open-owned waits here rather than assuming the app's
# window is already the owner by the time the UI test starts.
wait_for_owner_attachment() {
  local session_id="$1"
  local overview_out="$RUN_ROOT/overview-cold-open-owned.json"
  local deadline=$((SECONDS + 20))
  while [[ $SECONDS -lt $deadline ]]; do
    if python3 "$DEVICE_API_HELPER" overview --host "$DAEMON_HOST" --port "$DAEMON_PORT" \
        --certificate-fingerprint "$CERTIFICATE_FINGERPRINT" --spacese2e "$SPACES_E2E_BIN" \
        --auth-token "$AUTH_TOKEN" --installation-id "$INSTALLATION_ID" --out "$overview_out" --require-ok >/dev/null 2>&1 \
        && session_has_owner_attachment "$overview_out" "$session_id"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Stages this worktree's Mac app for the scenarios that need one. `spaces terminal show`
# (open_owned_session's precondition step) requires a running Mac app that holds this profile's
# app-owner lease; without one it fails outright with "No Spaces app instance is running for this
# profile". mac-reconnect needs the app for the pane it measures. A local lane run with only the
# daemon up has no such app, so this launches one and records the pid so cleanup() can quit exactly
# that instance and leave an already-running app alone. The performance log path is part of the
# launch environment because the app reads it once at process launch.
ensure_mac_app() {
  [[ -z "$LANE_LAUNCHED_MAC_APP_PID" ]] || return 0
  local existing_pid
  existing_pid="$(spaces_profile_app_owner_pid "$SPACES_E2E_BIN")"
  if [[ -n "$existing_pid" ]]; then
    log "profile app already running (pid $existing_pid)"
    return 0
  fi

  local app_log="$RUN_ROOT/mac-app.log"
  log "no Mac app owns this profile; launching $SPACES_APP_BIN"
  SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH="$DEVICE_PERF_LOG" nohup "$SPACES_APP_BIN" >"$app_log" 2>&1 &
  # Detached from job control so quitting it from `cleanup` prints no "Terminated" job notice.
  disown

  local deadline=$((SECONDS + 30))
  local owner_pid=""
  while [[ $SECONDS -lt $deadline ]]; do
    owner_pid="$(spaces_profile_app_owner_pid "$SPACES_E2E_BIN")"
    [[ -n "$owner_pid" ]] && break
    sleep 0.5
  done
  [[ -n "$owner_pid" ]] || fail "staged Mac app never took the profile owner lease; see $app_log"

  LANE_LAUNCHED_MAC_APP_PID="$owner_pid"
  SPACES_PID="$owner_pid"
  log "staged Mac app pid $owner_pid owns the profile"
}

# Quits the Mac app this lane launched, and only that one: the profile's owner lease is re-read right
# before signalling, so a pid the OS has since reused for an unrelated process is never signalled.
quit_mac_app() {
  [[ -n "$LANE_LAUNCHED_MAC_APP_PID" ]] || return 0
  local current_owner_pid
  current_owner_pid="$(spaces_profile_app_owner_pid "$SPACES_E2E_BIN" 2>/dev/null || true)"
  if [[ "$current_owner_pid" == "$LANE_LAUNCHED_MAC_APP_PID" ]]; then
    kill "$LANE_LAUNCHED_MAC_APP_PID" >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 10))
    while [[ $SECONDS -lt $deadline ]] && kill -0 "$LANE_LAUNCHED_MAC_APP_PID" >/dev/null 2>&1; do
      sleep 0.2
    done
    # This is the pid the lane launched itself and the profile still names it as the owner, so a
    # graceful quit that does not land is escalated rather than left holding the seeded link open.
    kill -9 "$LANE_LAUNCHED_MAC_APP_PID" >/dev/null 2>&1 || true
  fi
  LANE_LAUNCHED_MAC_APP_PID=""
  SPACES_PID=""
}

# The cold-open-owned scenario's precondition: opens the just-started session in a native Mac
# window before the UI test runs, so the iPhone's cold open lands on a session a localWindow owner
# already holds (GitHub issue #672's common case) rather than the ownerless session every other
# cold-open scenario measures.
open_owned_session() {
  local session_id="$1"
  ensure_mac_app
  log "cold-open-owned: opening session $session_id in a native Mac window"
  if ! "$SPACES_BIN" terminal show "$session_id" >/dev/null; then
    log "cold-open-owned: failed to open session $session_id in a native Mac window"
    return 1
  fi
  if ! wait_for_owner_attachment "$session_id"; then
    log "cold-open-owned: timed out waiting for session $session_id to report an active owner attachment"
    return 1
  fi
}

# Runs one spacese2e command against the throwaway upstream profile. `SPACES_DB_PATH` names an
# ephemeral throwaway profile and nothing else, which is exactly what this is: a profile that lives
# and dies with the run root, outside every real profile root. Its Device API binds loopback on a
# port the daemon picks, so it never collides with a real profile's port.
upstream_e2e() {
  env SPACES_DB_PATH="$UPSTREAM_DB_PATH" SPACES_RUNTIME_DIR="$UPSTREAM_RUNTIME_DIR" \
    SPACESD_EXECUTABLE="$SPACESD_BIN" SPACES_DEVICE_API_HOST="127.0.0.1" SPACES_DEVICE_API_PORT="0" \
    "$SPACES_E2E_BIN" "$@"
}

# Pairs one client with the throwaway upstream daemon and prints the token it issued. Each pairing
# gets its own window: a window is consumed by the pairing it authorizes.
pair_with_mac_upstream() {
  local installation_id="$1" bundle_id="$2" platform="$3" device_name="$4" label="$5"
  local window_json="$RUN_ROOT/upstream-pairing-window-$label.json"
  upstream_e2e open-device-pairing-window --timeout-seconds 10 >"$window_json" \
    || fail "failed to open a pairing window on the throwaway upstream daemon"
  local code nonce protocol_version
  read -r code nonce protocol_version < <(parse_pairing_link "$window_json")
  local payload
  payload="$(python3 - "$code" "$nonce" "$protocol_version" <<'PY'
import json
import sys

code, nonce, protocol_version = sys.argv[1:4]
print(json.dumps({"pairingCode": code, "pairingNonce": nonce, "clientProtocolVersion": int(protocol_version)}, separators=(",", ":")))
PY
)"
  python3 "$DEVICE_API_HELPER" pair --payload-json "$payload" \
    --host "$UPSTREAM_HOST" --port "$UPSTREAM_PORT" --certificate-fingerprint "$UPSTREAM_FINGERPRINT" \
    --spacese2e "$SPACES_E2E_BIN" --installation-id "$installation_id" --bundle-id "$bundle_id" \
    --platform "$platform" --device-name "$device_name" \
    --out "$RUN_ROOT/upstream-pair-response-$label.json" --require-ok --print-field result.issuedAuthToken.authToken \
    || fail "failed to pair $label with the throwaway upstream daemon"
}

# Brings up the daemon the mac-reconnect scenario measures against, once per run.
#
# It is a throwaway daemon on an ephemeral profile rather than this worktree's profile daemon
# because the Mac app shadows a paired device whose projects duplicate ids it already shows: the
# sidebar merges every device's projects first-wins by id (AppKitController.mergedSidebarData) with
# the local device's section always first, so a device serving the same daemon renders an empty
# section and its session can never be opened. A separate daemon has its own project and workspace
# ids, so the seeded device's rows stand on their own.
ensure_mac_upstream_daemon() {
  [[ -z "$UPSTREAM_PORT" ]] || return 0
  local upstream_root="$RUN_ROOT/upstream"
  UPSTREAM_DB_PATH="$upstream_root/spaces.db"
  UPSTREAM_RUNTIME_DIR="$upstream_root/runtime"
  local project_dir="$upstream_root/project"
  mkdir -p "$upstream_root" "$UPSTREAM_RUNTIME_DIR" "$project_dir"
  # The project is a git fixture repo, the same one the iOS scenarios use. The sidebar folds a
  # non-git project's single workspace into the project row, so only a git project gives the
  # seeded device the workspace row this scenario selects.
  spaces_e2e_create_harbor_fixture_repo "$FIXTURE_TEMPLATE_DIR" "$project_dir"

  log "starting the throwaway upstream daemon under $upstream_root"
  upstream_e2e mobile-status >"$RUN_ROOT/upstream-mobile-status.json" 2>&1 \
    || { cat "$RUN_ROOT/upstream-mobile-status.json" >&2 || true; fail "the throwaway upstream daemon did not come up"; }
  UPSTREAM_WORKSPACE_ID="$(upstream_e2e register-project --project-dir "$project_dir" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
    || fail "failed to register the throwaway upstream daemon's project"

  local window_json="$RUN_ROOT/upstream-pairing-window-lane.json"
  upstream_e2e open-device-pairing-window --timeout-seconds 10 >"$window_json" \
    || fail "failed to read the throwaway upstream daemon's Device API endpoint"
  UPSTREAM_HOST="127.0.0.1"
  UPSTREAM_PORT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['port'])" "$window_json")"
  UPSTREAM_FINGERPRINT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['certificateFingerprint'])" "$window_json")"

  UPSTREAM_LANE_INSTALLATION_ID="$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")"
  UPSTREAM_LANE_TOKEN="$(pair_with_mac_upstream "$UPSTREAM_LANE_INSTALLATION_ID" "dev.usespaces.spacesmobile" "ios" \
    "Mac Reconnect Lane Runner" "runner")"
  log "throwaway upstream daemon ready on 127.0.0.1:$UPSTREAM_PORT (workspace $UPSTREAM_WORKSPACE_ID)"
}

# Stops the throwaway daemon, and only that one: the profile the ephemeral database and runtime
# directory resolve to is asserted to be this run's throwaway profile root before anything is
# signalled, so this worktree's profile daemon is never a candidate.
stop_mac_upstream_daemon() {
  [[ -n "$UPSTREAM_RUNTIME_DIR" ]] || return 0
  local resolved_root
  resolved_root="$(
    export SPACES_DB_PATH="$UPSTREAM_DB_PATH" SPACES_RUNTIME_DIR="$UPSTREAM_RUNTIME_DIR"
    spaces_profile_field "$SPACES_E2E_BIN" profileRoot 2>/dev/null || true
  )"
  if [[ "$resolved_root" != "$RUN_ROOT/upstream" ]]; then
    log "refusing to stop a daemon on profile root $resolved_root, which is not this run's throwaway profile"
    return 0
  fi
  log "stopping the throwaway upstream daemon"
  (
    export SPACES_DB_PATH="$UPSTREAM_DB_PATH" SPACES_RUNTIME_DIR="$UPSTREAM_RUNTIME_DIR"
    spaces_profile_stop_terminal_service "$SPACES_E2E_BIN" 20
  )
  # The daemon's own service processes (the workspace proxy) outlive that shutdown, and they are
  # identifiable by the throwaway profile's runtime path, which nothing outside this run shares.
  pkill -f "$UPSTREAM_RUNTIME_DIR" >/dev/null 2>&1 || true
  UPSTREAM_RUNTIME_DIR=""
}

# Line count of the shared performance log, so a wait only considers what is appended after an action.
perf_log_line_count() {
  wc -l <"$DEVICE_PERF_LOG" | tr -d ' '
}

# Blocks until device-perf.jsonl grows a line from `source` named `name` for `session_id` whose
# attributes match every `key=value` argument, considering only lines past `since_line`. This is how
# the Mac scenario watches the app: the Mac client has no XCUITest runner in this lane, and the
# events it emits are the same ones the report reads, so the procedure and the measurement agree on
# what "the banner appeared" means.
wait_for_app_event() {
  local since_line="$1" timeout="$2" source="$3" name="$4" session_id="$5"
  shift 5
  python3 - "$DEVICE_PERF_LOG" "$since_line" "$timeout" "$source" "$name" "$session_id" "$@" <<'PY'
import json
import sys
import time

log_path, since_text, timeout_text, source, name, session_id = sys.argv[1:7]
pairs = [item.split("=", 1) for item in sys.argv[7:]]
since = int(since_text)
deadline = time.monotonic() + float(timeout_text)
while True:
    try:
        with open(log_path) as handle:
            lines = handle.readlines()[since:]
    except FileNotFoundError:
        lines = []
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            # The app appends to this file concurrently, so the tail can be a partial line.
            continue
        if event.get("source") != source or event.get("name") != name or event.get("sessionID") != session_id:
            continue
        attributes = event.get("attributes") or {}
        if all(str(attributes.get(key)) == value for key, value in pairs):
            sys.exit(0)
    if time.monotonic() >= deadline:
        sys.exit(1)
    time.sleep(0.2)
PY
}

# Line count of the shaping proxy's log, so a wait only considers what it appends after an action.
shaper_log_line_count() {
  wc -l <"$SHAPER_LOG" | tr -d ' '
}

# Blocks until the shaping proxy logs `event` past `since_line`. The Mac scenario waits on
# `conn_open` this way to learn when the pane has parked a fresh dial in the dead link, which is the
# moment the measured recovery has to start from.
wait_for_shaper_event() {
  local since_line="$1" timeout="$2" event="$3"
  python3 - "$SHAPER_LOG" "$since_line" "$timeout" "$event" <<'PY'
import json
import sys
import time

log_path, since_text, timeout_text, event = sys.argv[1:5]
since = int(since_text)
deadline = time.monotonic() + float(timeout_text)
while True:
    try:
        with open(log_path) as handle:
            lines = handle.readlines()[since:]
    except FileNotFoundError:
        lines = []
    for line in lines:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            # The proxy appends to this file concurrently, so the tail can be a partial line.
            continue
        if record.get("event") == event:
            sys.exit(0)
    if time.monotonic() >= deadline:
        sys.exit(1)
    time.sleep(0.2)
PY
}

# Sends one line to the shaping proxy's control port and checks it answered, the same control verbs
# the iOS reconnect UI test sends through ShaperControlClient.
shaper_control() {
  local command="$1"
  python3 - "$SHAPER_CONTROL_PORT" "$command" <<'PY'
import socket
import sys

port, command = int(sys.argv[1]), sys.argv[2]
with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
    sock.sendall((command + "\n").encode())
    reply = sock.recv(64).decode("utf-8", "replace").strip()
if not reply.startswith("ok"):
    raise SystemExit("shaper control did not acknowledge %r: %r" % (command, reply))
PY
}

# Records the shaping proxy as a paired device of this Mac in the app's own client store, so the app
# reaches the throwaway upstream daemon only through the shaped link.
#
# The token comes from a real pairing, minted for the installation id the Mac app presents (the same
# out-of-band pairing `seed_remote_device_for_macos` seeds a remote daemon from in e2e_macos_app.sh).
# The record is written before the app that reads it launches, so the seeded device is in the sidebar
# from the app's first sidebar load. The seeded host and port are the proxy's, never the daemon's.
seed_mac_paired_device() {
  local installation_id token
  installation_id="$("$SPACES_E2E_BIN" mac-client-installation-id)" \
    || fail "failed to read this profile's Mac client installation id"
  token="$(pair_with_mac_upstream "$installation_id" "dev.usespaces.spaces" "macos" "$MAC_DEVICE_NAME" "mac")"
  "$SPACES_E2E_BIN" seed-paired-device --device-id "$MAC_DEVICE_ID" --name "$MAC_DEVICE_NAME" \
    --host "127.0.0.1" --port "$SHAPER_LISTEN_PORT" --certificate-fingerprint "$UPSTREAM_FINGERPRINT" \
    --auth-token "$token" \
    || fail "failed to seed the shaping proxy as a paired device"
  MAC_DEVICE_SEEDED=1
  log "seeded paired device $MAC_DEVICE_ID at 127.0.0.1:$SHAPER_LISTEN_PORT"
}

remove_mac_paired_device() {
  [[ "$MAC_DEVICE_SEEDED" -eq 1 ]] || return 0
  "$SPACES_BIN" device remove "$MAC_DEVICE_ID" >/dev/null 2>&1 \
    || log "warning: failed to remove the seeded paired device $MAC_DEVICE_ID"
  MAC_DEVICE_SEEDED=0
}

# Selects one row of the seeded device's sidebar section. Every device showing a given workspace
# publishes the same row identifiers, so the section header is what picks the seeded device's copy
# out of the local device's. A first launch can offer the coding-agents setup step ahead of the
# sidebar; it is dismissed through its own control rather than by waiting it out.
select_mac_sidebar_row() {
  local identifier="$1" description="$2"
  local deadline=$((SECONDS + MAC_SIDEBAR_TIMEOUT_SECONDS))
  while [[ $SECONDS -lt $deadline ]]; do
    if ui_select_outline_row_containing_identifier_in_section "$MAC_DEVICE_SECTION_TITLE" "$identifier" >/dev/null 2>&1; then
      return 0
    fi
    if ui_identifier_exists "setup-coding-agents-skip"; then
      ui_click_identifier "setup-coding-agents-skip" >/dev/null 2>&1 || true
    fi
    sleep 0.5
  done
  fail "timed out waiting for the seeded device's $description ($identifier)"
}

# Opens the seeded device's copy of `session_id` in a Mac paired-device terminal pane and waits for
# the pane's stream to deliver a frame. That frame is also the proof the pane under test is the
# seeded device's: only a paired-device pane emits "mac-pane" events, and it carries the device id.
open_mac_paired_device_pane() {
  local session_id="$1"
  local since
  since="$(perf_log_line_count)"
  activate_spaces_pid "$SPACES_PID"
  wait_for_spaces_frontmost_ready
  ui_fill_screen_with_main_window
  select_mac_sidebar_row "sidebar-workspace-title-$UPSTREAM_WORKSPACE_ID" "workspace row"
  local terminal_row="sidebar-target-${UPSTREAM_WORKSPACE_ID}-terminal:${session_id}"
  # Selecting the row waits for the seeded device to publish it; the click is what opens its pane.
  select_mac_sidebar_row "$terminal_row" "terminal row"
  ui_click_identifier "$terminal_row" || fail "failed to open the seeded device's terminal row"
  wait_for_ui_identifier "terminal-pane-$session_id" "paired-device terminal pane"
  wait_for_app_event "$since" 120 "mac-pane" "stream_first_frame" "$session_id" \
    || fail "the Mac pane for session $session_id never reported a first frame from the seeded device"
}

# The Mac client's reconnect scenario, step for step the procedure the iOS reconnect UI test runs
# (apps/ios/UITests/SpacesMobileBaselineUITests.swift): open the session, hold the link down long
# enough for the banner to appear and stay up, then bring it back and wait for the pane to recover.
#
# Setting the pane up is a precondition, so a failure there fails the run rather than the scenario:
# it means the lane is not measuring what it claims to. A banner that never appears or never clears
# is a result about the client, so it fails only this scenario and lets the next profile run.
run_mac_reconnect_scenario() {
  local profile="$1" scenario="$2" session_id="$3"
  [[ "$MAC_DEVICE_SEEDED" -eq 1 ]] || seed_mac_paired_device
  ensure_mac_app
  local status=0
  mac_reconnect_procedure "$profile" "$scenario" "$session_id" || status=1
  # The pane keeps redialing the session this scenario is about to stop, and its events land in the
  # same log every other scenario is measured from, so the app goes away with the scenario.
  quit_mac_app
  return "$status"
}

mac_reconnect_procedure() {
  local profile="$1" scenario="$2" session_id="$3"
  open_mac_paired_device_pane "$session_id"
  sleep 3

  local since
  since="$(perf_log_line_count)"
  append_marker "link_down" "$profile" "$scenario"
  shaper_control "link down" || fail "shaper control did not answer link down"
  if ! wait_for_app_event "$since" 20 "mac-pane" "connection_stage" "$session_id" "banner=1"; then
    log "mac-reconnect: the reconnecting banner did not appear within 20s of link down"
    return 1
  fi
  append_marker "banner_seen" "$profile" "$scenario"

  # The link comes back while one of the pane's redials is in flight, because that is the case #694
  # is about: the dial the path change stranded holds the pane for its whole budget while the
  # network is already back. Waiting for the proxy to accept a dial puts every profile at the same
  # point of that budget instead of wherever a fixed hold happens to land.
  local shaper_since
  shaper_since="$(shaper_log_line_count)"
  if ! wait_for_shaper_event "$shaper_since" 40 "conn_open"; then
    log "mac-reconnect: the pane did not redial within 40s of the banner appearing"
    return 1
  fi

  since="$(perf_log_line_count)"
  append_marker "link_up" "$profile" "$scenario"
  # `link up dead` rather than `link up`: the link returns for new connections while the dial the
  # pane just parked stays black-holed. A plain `link up` closes that dial, which hands the pane an
  # instant failure it never gets in the field.
  shaper_control "link up dead" || fail "shaper control did not answer link up dead"
  # The pane is recovered when its stream is live again, which is what the marker claims. The report
  # reads the first banner-clearing connection_stage event after link up out of the same stream.
  # The budget the stranded dial sits out is the measurement, so this waits well past it.
  if ! wait_for_app_event "$since" 120 "mac-pane" "connection_stage" "$session_id" "stage=connected"; then
    log "mac-reconnect: the pane did not reconnect within 120s of link up"
    return 1
  fi
  append_marker "recovered" "$profile" "$scenario"
  sleep 3
}

run_scenario() {
  local profile="$1" scenario="$2"
  # mac-reconnect drives the Mac app directly, so it maps to no XCUITest method.
  local test_method=""
  if [[ "$scenario" != "mac-reconnect" ]]; then
    test_method="$(scenario_test_method "$scenario")" || fail "no UI test method mapped for scenario '$scenario'"
  fi

  # mac-reconnect measures a paired device, so its session lives on the throwaway upstream daemon;
  # every other scenario's lives on the daemon the run targets.
  if [[ "$scenario" == "mac-reconnect" ]]; then
    SESSION_HOST="$UPSTREAM_HOST"
    SESSION_PORT="$UPSTREAM_PORT"
    SESSION_FINGERPRINT="$UPSTREAM_FINGERPRINT"
    SESSION_TOKEN="$UPSTREAM_LANE_TOKEN"
    SESSION_INSTALLATION_ID="$UPSTREAM_LANE_INSTALLATION_ID"
    SESSION_WORKSPACE_ID="$UPSTREAM_WORKSPACE_ID"
  else
    SESSION_HOST="$DAEMON_HOST"
    SESSION_PORT="$DAEMON_PORT"
    SESSION_FINGERPRINT="$CERTIFICATE_FINGERPRINT"
    SESSION_TOKEN="$AUTH_TOKEN"
    SESSION_INSTALLATION_ID="$INSTALLATION_ID"
    SESSION_WORKSPACE_ID="$WORKSPACE_ID"
  fi

  local payload response_out session_id_file
  payload="$(build_start_session_payload "$SESSION_WORKSPACE_ID" "$scenario")"
  response_out="$RUN_ROOT/start-session-$profile-$scenario.json"
  session_id_file="$RUN_ROOT/.session-id-$profile-$scenario.txt"
  if ! python3 "$DEVICE_API_HELPER" startWorkspaceCommandSession --payload-json "$payload" \
      --host "$SESSION_HOST" --port "$SESSION_PORT" --certificate-fingerprint "$SESSION_FINGERPRINT" \
      --spacese2e "$SPACES_E2E_BIN" --auth-token "$SESSION_TOKEN" --installation-id "$SESSION_INSTALLATION_ID" \
      --out "$response_out" --require-ok --print-field result.mutation.sessionID >"$session_id_file"; then
    log "failed to start session for $profile/$scenario (see $response_out)"
    SCENARIO_FAILURES+=("$profile/$scenario")
    return
  fi
  local session_id
  session_id="$(cat "$session_id_file")"
  CURRENT_SESSION_ID="$session_id"
  record_session "$profile" "$scenario" "$session_id" "$SESSION_WORKSPACE_ID"

  if [[ -n "$test_method" ]]; then
    local config_path="$RUN_ROOT/config-$profile-$scenario.json"
    write_scenario_config "$profile" "$scenario" "$session_id" "$config_path"
    # xcodebuild does not forward this shell's environment to the XCUITest runner process, so the test
    # reads the fixed default path `BaselineLaneConfiguration.defaultConfigPath` instead (the same handoff
    # `e2e_mobile.sh` uses for its own UI test config). The run root keeps the per-scenario copy.
    cp "$config_path" "$BASELINE_CONFIG_HANDOFF_PATH"
  fi

  append_marker "runner_scenario_start" "$profile" "$scenario"

  local xcodebuild_log="$RUN_ROOT/xcodebuild-$profile-$scenario.log"
  local status="ok"
  if [[ "$scenario" == "mac-reconnect" ]]; then
    run_mac_reconnect_scenario "$profile" "$scenario" "$session_id" || status="failed"
  elif [[ "$scenario" == "cold-open-owned" ]] && ! open_owned_session "$session_id"; then
    status="failed"
  elif [[ "$scenario" == "streaming" ]]; then
    run_streaming_scenario "$profile" "$scenario" "$test_method" "$session_id" "$xcodebuild_log" || status="failed"
  else
    run_ui_test "$test_method" "$xcodebuild_log" || status="failed"
  fi

  append_marker "runner_scenario_finish" "$profile" "$scenario" "{\"status\":\"$status\"}"

  local stop_payload
  stop_payload="$(build_workspace_terminal_payload "$SESSION_WORKSPACE_ID" "$session_id")"
  python3 "$DEVICE_API_HELPER" stopWorkspaceTerminal --payload-json "$stop_payload" \
    --host "$SESSION_HOST" --port "$SESSION_PORT" --certificate-fingerprint "$SESSION_FINGERPRINT" \
    --spacese2e "$SPACES_E2E_BIN" --auth-token "$SESSION_TOKEN" --installation-id "$SESSION_INSTALLATION_ID" \
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
  if ios_scenarios_selected; then
    choose_simulator
    disconnect_simulator_hardware_keyboard
    spaces_ios_simulator_boot_if_needed "$MOBILE_UDID" || fail "failed to boot simulator $MOBILE_UDID"
    open -a Simulator >/dev/null 2>&1 || true
  fi

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

  if ios_scenarios_selected; then
    build_ios
  fi

  SHAPER_LISTEN_PORT="$(free_port)"
  SHAPER_CONTROL_PORT="$(free_port)"

  # The two clients dial different daemons, so each profile shapes one of them at a time: the iOS
  # scenarios against the run's target daemon, then mac-reconnect against its throwaway upstream.
  local profile scenario
  for profile in "${SELECTED_PROFILES[@]}"; do
    if ios_scenarios_selected; then
      log "starting shaper for profile $profile..."
      start_shaper "$profile" "$DAEMON_HOST" "$DAEMON_PORT"
      for scenario in "${SELECTED_SCENARIOS[@]}"; do
        [[ "$scenario" == "mac-reconnect" ]] && continue
        log "running $profile/$scenario"
        run_scenario "$profile" "$scenario"
      done
      stop_shaper
    fi
    if mac_scenario_selected; then
      ensure_mac_upstream_daemon
      log "starting shaper for profile $profile (Mac upstream)..."
      start_shaper "$profile" "$UPSTREAM_HOST" "$UPSTREAM_PORT"
      log "running $profile/mac-reconnect"
      run_scenario "$profile" "mac-reconnect"
      stop_shaper
    fi
  done

  if ios_scenarios_selected; then
    xcrun simctl terminate "$MOBILE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi

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
