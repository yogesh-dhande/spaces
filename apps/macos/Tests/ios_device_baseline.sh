#!/usr/bin/env bash
set -euo pipefail

# Repeatable, on-demand, measure-only performance baseline for the iOS app on the user's
# physical iPhone. This script drives the manual parts (install, fixture, daemon-side load) and
# prompts the user through each scenario by hand; the user performs the described step on the
# phone and presses Enter, and this script stamps the boundaries. Scope is MEASURE EVERYTHING,
# FIX NOTHING: no assertion in this script ever fails the run over a slow number, it only
# refuses to proceed when a precondition (device reachability, pairing, install) is not met.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$REPO_ROOT/scripts/spaces-e2e-env.sh"

SPACES_CLI="${SPACES_CLI:-$APP_ROOT/.build/debug/spaces}"
SPACES_E2E="${SPACES_E2E:-$APP_ROOT/.build/debug/spacese2e}"
DEVICE_UDID=""
# BUNDLE_ID is derived after .env is loaded (spaces_e2e_require_env, below), since
# scripts/install-ios-device.sh honors SPACES_IOS_BUNDLE_ID from that same .env and this script
# must target whatever bundle id the install actually used.
BUNDLE_ID=""

# Canonical scenario order. Scenario selection always runs in this order regardless of the order
# --scenario was passed in, so a run's device-perf.jsonl and runner-events.jsonl always tell the
# same story: fresh app state first, then progressively more disruptive network conditions.
SCENARIOS=(
  cold-open
  back-and-forth
  keyboard-toggle
  streaming
  background-foreground-terminal
  background-foreground-list
  wifi-handoff
  cellular-open
  battery-30min
)
SELECTED_SCENARIOS=()

RUN_ROOT=""
RUNNER_EVENTS=""
SESSION_ID=""
SESSION_IDS_BEFORE_OPEN=""
WORKSPACE_DIR=""
WORKSPACE_ID=""
# Session ids for every ad hoc terminal this run had the user open (cold-open and
# cellular-open each open one; resolve_open_session_id appends here, no duplicates). Nothing
# in the runner otherwise ends these shells, so left alone they accumulate across repeated runs.
CREATED_SESSION_IDS=()

print_usage() {
  cat <<EOF
Usage: apps/macos/Tests/ios_device_baseline.sh [options]

Options:
  --list             List available scenarios.
  --scenario NAME    Run only one scenario. May be passed multiple times.
  --help             Show this help text.

Requires SPACES_IOS_DEVICE_UDID in $REPO_ROOT/.env.
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

scenario_exists() {
  local requested="$1" scenario
  for scenario in "${SCENARIOS[@]}"; do
    [[ "$scenario" == "$requested" ]] && return 0
  done
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)
        printf '%s\n' "${SCENARIOS[@]}"
        exit 0
        ;;
      --scenario)
        [[ $# -ge 2 ]] || fail "missing value for --scenario"
        scenario_exists "$2" || fail "unknown scenario: $2"
        SELECTED_SCENARIOS+=("$2")
        shift 2
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

# Prints a line every prompt shares, so a bare `grep '>>>'` over the transcript reconstructs the
# whole run: every instruction the user was given and every wait point.
say() { printf '>>> %s\n' "$1"; }

# Prints an instruction and blocks for Enter. Used at the start and the end of every scenario
# step, per the scenario descriptions below.
wait_for_enter() {
  say "$1"
  read -r -p ">>> Press Enter to continue... " _ || true
}

iso8601_now_ms() {
  python3 - <<'PY'
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
print(now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z")
PY
}

# Appends one stamp to runner-events.jsonl and echoes it, so the terminal transcript alone is
# enough to reconstruct the run's timeline. `kind` is scenario_begin, scenario_end, step, or
# note; `scenario` and `detail` may be empty.
stamp() {
  local kind="$1" scenario="${2:-}" detail="${3:-}"
  local t line
  t="$(iso8601_now_ms)"
  line="$(python3 - "$t" "$kind" "$scenario" "$detail" <<'PY'
import json
import sys

t, kind, scenario, detail = sys.argv[1:5]
print(json.dumps({"t": t, "kind": kind, "scenario": scenario or None, "detail": detail or None}))
PY
)"
  printf '%s\n' "$line" >>"$RUNNER_EVENTS"
  say "$line"
}

json_field() {
  local file="$1" expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)
for part in expr.split("."):
    value = value[part]
print("" if value is None else value)
PY
}

# Reads the `connectionProperties.tunnelState` field devicectl reports for one device, writing
# its full `device info details` JSON to `out_path`. Prints "unknown" (never raises) when the
# devicectl call itself fails, since a disconnected/unreachable device is exactly the case this
# feeds into a precondition check for.
device_tunnel_state() {
  local out_path="$1"
  xcrun devicectl device info details --device "$DEVICE_UDID" --json-output "$out_path" -q >/dev/null 2>&1 || true
  python3 - "$out_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
    print(data["result"]["connectionProperties"]["tunnelState"])
except Exception:
    print("unknown")
PY
}

check_device_tunnel_connected() {
  local out_path="$1"
  local state
  state="$(device_tunnel_state "$out_path")"
  if [[ "$state" != "connected" ]]; then
    fail "Device tunnel is not connected (tunnelState=$state). Unlock the iPhone and keep it on the same Wi-Fi network as this Mac, then rerun."
  fi
}

check_daemon_reachable() {
  local out_path="$1"
  if ! "$SPACES_E2E" mobile-status >"$out_path" 2>&1; then
    fail "Could not reach this worktree's dev daemon Device API:
$(cat "$out_path")
Start this worktree's Spaces app or daemon (apps/macos/.build/debug/SpacesApp, or scripts/dev-build-and-launch.sh) and rerun."
  fi
}

# The Device API control channel this daemon exposes (spacese2e mobile-status) reports only its
# endpoint, not which mobile clients have paired with it, so this script cannot tell on its own
# whether this iPhone is already paired. It prints a fresh pairing window unconditionally and
# waits for the user to confirm, rather than guessing and rather than redeeming the link itself.
print_pairing_instructions() {
  local out_path="$1"
  "$SPACES_E2E" open-device-pairing-window >"$out_path" 2>&1 || fail "Failed to open a Device API pairing window:
$(cat "$out_path")"
  local link code
  link="$(json_field "$out_path" pairingLink)"
  code="$(json_field "$out_path" pairingCode)"
  say "Device API pairing window (only needed if SpacesMobile on this iPhone is not already paired with this dev daemon):"
  say "  Link: $link"
  say "  Code: $code"
  say "  Scan the QR code from the Mac app's Devices panel, or open the link on the phone."
  wait_for_enter "Press Enter once SpacesMobile on this iPhone is paired with this dev daemon (or was already paired)."
}

relaunch_app_cold() {
  stamp step "" "relaunching $BUNDLE_ID cold via devicectl --terminate-existing"
  xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing \
    --environment-variables '{"SPACES_MOBILE_PAYWALL_BYPASS": "1"}' "$BUNDLE_ID" \
    >>"$RUN_ROOT/devicectl.log" 2>&1 || fail "devicectl relaunch failed; see $RUN_ROOT/devicectl.log"
}

# Snapshots the terminal session ids currently listed under WORKSPACE_DIR into
# SESSION_IDS_BEFORE_OPEN. Call this right before prompting the user to open a fresh ad hoc
# terminal, so resolve_open_session_id can tell that new terminal apart from the seeded
# workspace's own service sessions (frontend/backend), which run in the same directory.
snapshot_session_ids() {
  SESSION_IDS_BEFORE_OPEN="$("$SPACES_CLI" terminal list 2>/dev/null | awk -F'\t' -v dir="$WORKSPACE_DIR" '
    {
      cwd = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^cwd=/) cwd = substr($i, 5)
      if (cwd == dir) print $1
    }
  ')"
}

# Finds the ad hoc terminal session the phone just opened in the fixture workspace: the row under
# WORKSPACE_DIR whose id is not in SESSION_IDS_BEFORE_OPEN (set by snapshot_session_ids before the
# prompt). A plain last-row-under-this-directory match would also catch the seeded workspace's own
# service sessions (frontend/backend), which run in the same directory as the ad hoc terminal the
# phone opens, and could point terminal-targeted CLI actions like `terminal send` at the wrong
# terminal. Fails with instructions when the snapshot diff finds anything but exactly one new id.
resolve_open_session_id() {
  local rows new_ids count
  rows="$("$SPACES_CLI" terminal list 2>/dev/null || true)"
  new_ids="$(printf '%s\n' "$rows" | awk -F'\t' -v dir="$WORKSPACE_DIR" -v before="$SESSION_IDS_BEFORE_OPEN" '
    BEGIN {
      n = split(before, seen, "\n")
      for (i = 1; i <= n; i++) if (seen[i] != "") already[seen[i]] = 1
    }
    {
      cwd = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^cwd=/) cwd = substr($i, 5)
      if (cwd == dir && !($1 in already)) print $1
    }
  ')"
  count="$(printf '%s\n' "$new_ids" | grep -c . || true)"
  if [[ "$count" -ne 1 ]]; then
    fail "Expected exactly one newly opened terminal session under $WORKSPACE_DIR, found $count:
$new_ids
Open exactly one fresh ad hoc terminal in the 'baseline-harbor' workspace and try again."
  fi
  SESSION_ID="$new_ids"
  if ! _array_contains "$SESSION_ID" "${CREATED_SESSION_IDS[@]:-}"; then
    CREATED_SESSION_IDS+=("$SESSION_ID")
  fi
  stamp step "" "resolved open session id: $SESSION_ID"
}

_array_contains() {
  local needle="$1" candidate
  shift
  for candidate in "${@:-}"; do
    [[ -n "$candidate" && "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

# Ends every ad hoc terminal this run had the user open (tracked in CREATED_SESSION_IDS by
# resolve_open_session_id). `spaces terminal` has no command that closes a session, but an ad
# hoc terminal is a bare interactive shell, so sending it `exit` ends the shell the same way the
# user closing it by hand would. Registered on the script's EXIT trap so it runs once, last.
cleanup_created_sessions() {
  local session
  for session in "${CREATED_SESSION_IDS[@]:-}"; do
    [[ -n "$session" ]] || continue
    "$SPACES_CLI" terminal send text "$session" "exit" --submit >/dev/null 2>&1 || true
    if [[ -n "$RUNNER_EVENTS" && -f "$RUNNER_EVENTS" ]]; then
      stamp step "" "closed session $session"
    fi
  done
}

# Ensures SESSION_ID names the ad hoc terminal open in the fixture workspace, for scenarios that
# may run standalone (selected on their own via --scenario, without an earlier scenario already
# setting it). Returns immediately when SESSION_ID is already set; otherwise prompts the user to
# open a fresh terminal and resolves it the same way cold-open does.
ensure_open_session() {
  [[ -n "$SESSION_ID" ]] && return 0
  snapshot_session_ids
  wait_for_enter "Open a fresh ad hoc terminal in the 'baseline-harbor' workspace (workspace control bar -> Terminal), then press Enter."
  resolve_open_session_id
}

scenario_cold_open() {
  wait_for_enter "cold-open: the app is about to relaunch cold with the paywall bypass."
  stamp scenario_begin cold-open "about to relaunch cold"
  relaunch_app_cold
  snapshot_session_ids
  wait_for_enter "cold-open: wait for the workspace list to finish loading, then open the 'baseline-harbor' workspace and tap Terminal to open a fresh ad hoc terminal. Press Enter once it is open and showing a shell prompt."
  stamp scenario_end cold-open ""
  resolve_open_session_id
}

scenario_back_and_forth() {
  ensure_open_session
  wait_for_enter "back-and-forth: the 'baseline-harbor' terminal should already be open. You are about to press back and reopen it 5 times."
  stamp scenario_begin back-and-forth ""
  wait_for_enter "back-and-forth: press back to the workspace list, then reopen the same terminal. Repeat for a total of 5 back/reopen cycles, then press Enter."
  stamp scenario_end back-and-forth ""
}

scenario_keyboard_toggle() {
  ensure_open_session
  wait_for_enter "keyboard-toggle: with the terminal open, you are about to show the keyboard, type, and dismiss it 5 times."
  stamp scenario_begin keyboard-toggle ""
  wait_for_enter "keyboard-toggle: show the keyboard, type 'echo hi' and press Return, then dismiss the keyboard. Repeat for a total of 5 times, then press Enter."
  stamp scenario_end keyboard-toggle ""
}

scenario_streaming() {
  ensure_open_session
  wait_for_enter "streaming: with the terminal open, just watch the screen. The runner sends two bursts of output next."
  stamp scenario_begin streaming ""
  stamp step streaming "sending burst 1: seq 1 2000"
  "$SPACES_CLI" terminal send text "$SESSION_ID" "seq 1 2000" --submit \
    || fail "terminal send failed for burst 1; is session $SESSION_ID still open?"
  stamp step streaming "sent burst 1"
  sleep 2
  local burst2
  read -r -d '' burst2 <<'CMD' || true
for i in $(seq 1 200); do printf '\e[3%dm%s\e[0m ' $((i%7+1)) "$(head -c 60 /dev/zero | tr '\0' x)"; done; echo
CMD
  stamp step streaming "sending burst 2: wide colorful output"
  "$SPACES_CLI" terminal send text "$SESSION_ID" "$burst2" --submit \
    || fail "terminal send failed for burst 2; is session $SESSION_ID still open?"
  stamp step streaming "sent burst 2"
  wait_for_enter "streaming: once the output has finished scrolling, press Enter."
  stamp scenario_end streaming ""
}

scenario_background_foreground_terminal() {
  ensure_open_session
  wait_for_enter "background-foreground-terminal: with the terminal open, you are about to background the app (press Home) and return, 3 times, about 10s away each time."
  stamp scenario_begin background-foreground-terminal ""
  wait_for_enter "background-foreground-terminal: press Home, wait about 10 seconds, then reopen Spaces. Repeat for a total of 3 times, then press Enter."
  stamp scenario_end background-foreground-terminal ""
}

scenario_background_foreground_list() {
  wait_for_enter "background-foreground-list: you are about to press back to the workspace list, then background and return 3 times."
  stamp scenario_begin background-foreground-list ""
  wait_for_enter "background-foreground-list: press back to the workspace list, then press Home, wait about 10 seconds, and reopen Spaces. Repeat for a total of 3 times, then press Enter."
  stamp scenario_end background-foreground-list ""
}

scenario_wifi_handoff() {
  ensure_open_session
  wait_for_enter "wifi-handoff: reopen the 'baseline-harbor' terminal if it is not on screen (the list scenario leaves the phone on the list). With the terminal open, you are about to turn Wi-Fi OFF on the phone (leave cellular and Tailscale on)."
  stamp scenario_begin wifi-handoff ""
  wait_for_enter "wifi-handoff: turn Wi-Fi OFF on the phone now (leave cellular and Tailscale on), then press Enter."
  wait_for_enter "wifi-handoff: wait for the terminal view to show reconnecting or unreachable and then recover over cellular. Press Enter once it has recovered and is showing live output again."
  stamp step wifi-handoff "recovered over cellular"
  wait_for_enter "wifi-handoff: now turn Wi-Fi back ON and wait for it to reconnect over Wi-Fi, then press Enter."
  stamp scenario_end wifi-handoff ""
}

# The cold relaunch goes through devicectl, whose device tunnel rides the phone's Wi-Fi, so the
# relaunch happens while Wi-Fi is still on; Wi-Fi then goes off on the list screen, and the list
# refresh and the open are what run over cellular.
scenario_cellular_open() {
  wait_for_enter "cellular-open: keep Wi-Fi ON for a moment; the app is about to relaunch cold to the workspace list."
  relaunch_app_cold
  snapshot_session_ids
  wait_for_enter "cellular-open: turn Wi-Fi OFF on the phone now (cellular and Tailscale stay on). Press Enter once Wi-Fi is off, before the list has refreshed."
  # The window opens only once Wi-Fi is off: the relaunch above needs the Wi-Fi device tunnel, and its
  # launch-time list refresh runs over Wi-Fi, which is cold-open's number, not this scenario's.
  stamp scenario_begin cellular-open "Wi-Fi off, cellular and Tailscale only"
  wait_for_enter "cellular-open: pull to refresh the workspace list so it loads over cellular, then open the 'baseline-harbor' terminal. Press Enter once it is open and rendering."
  stamp step cellular-open "cold-open over cellular complete"
  resolve_open_session_id
  wait_for_enter "cellular-open (back-and-forth over cellular): press back and reopen the same terminal 5 times, then press Enter."
  stamp step cellular-open "back-and-forth over cellular complete"
  wait_for_enter "cellular-open: turn Wi-Fi back ON now and wait for the terminal to recover over Wi-Fi, then press Enter."
  stamp scenario_end cellular-open ""
}

scenario_battery_30min() {
  ensure_open_session
  wait_for_enter "battery-30min: reopen the 'baseline-harbor' terminal if it is not on screen. Confirm Wi-Fi is OFF (cellular + Tailscale only), the terminal is open, and the phone is unplugged so battery drain is measurable. This runs for 30 minutes; press Enter to start."
  stamp scenario_begin battery-30min ""
  local total_minutes=30 minute=0 interrupted=0
  trap 'interrupted=1' INT
  while (( minute < total_minutes )); do
    # Unlike the streaming scenario's sends, a single failed burst here does not abort an
    # unattended 30-minute run; it just leaves one minute with no forced render in the report.
    "$SPACES_CLI" terminal send text "$SESSION_ID" "seq 1 200" --submit >/dev/null 2>&1 || true
    minute=$((minute + 1))
    stamp step battery-30min "minute $minute/$total_minutes: sent burst"
    if (( interrupted == 1 )); then
      say "battery-30min: interrupted, ending early at $minute/$total_minutes minutes"
      break
    fi
    sleep 60 || true
    if (( interrupted == 1 )); then
      say "battery-30min: interrupted, ending early at $minute/$total_minutes minutes"
      break
    fi
  done
  trap - INT
  stamp scenario_end battery-30min ""
}

run_scenario() {
  case "$1" in
    cold-open) scenario_cold_open ;;
    back-and-forth) scenario_back_and_forth ;;
    keyboard-toggle) scenario_keyboard_toggle ;;
    streaming) scenario_streaming ;;
    background-foreground-terminal) scenario_background_foreground_terminal ;;
    background-foreground-list) scenario_background_foreground_list ;;
    wifi-handoff) scenario_wifi_handoff ;;
    cellular-open) scenario_cellular_open ;;
    battery-30min) scenario_battery_30min ;;
    *) fail "no runner for scenario: $1" ;;
  esac
}

parse_args "$@"
if [[ ${#SELECTED_SCENARIOS[@]} -eq 0 ]]; then
  SELECTED_SCENARIOS=("${SCENARIOS[@]}")
fi

# Informational flags (--list, --help) exit inside parse_args above, before anything below here
# runs, so they work on a checkout with no .env: everything that needs the device's env lives
# after this point instead.
spaces_e2e_require_env "$REPO_ROOT"
DEVICE_UDID="${SPACES_IOS_DEVICE_UDID:-}"
BUNDLE_ID="${SPACES_IOS_BUNDLE_ID:-dev.usespaces.spacesmobile}"
[[ -n "$DEVICE_UDID" ]] || fail "SPACES_IOS_DEVICE_UDID is required in $REPO_ROOT/.env."
[[ -x "$SPACES_CLI" ]] || fail "spaces CLI not found at $SPACES_CLI"
[[ -x "$SPACES_E2E" ]] || fail "spacese2e not found at $SPACES_E2E"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required."

# Preconditions, before anything on disk is created for this run.
precondition_tunnel_json="$(mktemp "${TMPDIR:-/tmp}/spaces-ios-baseline-tunnel.XXXXXX.json")"
check_device_tunnel_connected "$precondition_tunnel_json"
precondition_status_json="$(mktemp "${TMPDIR:-/tmp}/spaces-ios-baseline-status.XXXXXX.json")"
check_daemon_reachable "$precondition_status_json"

RUN_ROOT="$HOME/.spaces-dev/ios-baseline/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_ROOT"
RUNNER_EVENTS="$RUN_ROOT/runner-events.jsonl"
touch "$RUNNER_EVENTS"
# Registered once RUN_ROOT (and RUNNER_EVENTS) exist, so cleanup_created_sessions can stamp into
# it. The normal end-of-run path below pulls the device log, then renders the report, then falls
# off the end of the script; the EXIT trap fires only then, so the log pull still sees the open
# sessions' final events and closing them is the very last thing the run does.
trap cleanup_created_sessions EXIT
cp "$precondition_tunnel_json" "$RUN_ROOT/device-info-initial.json"
cp "$precondition_status_json" "$RUN_ROOT/mobile-status.json"
say "Run root: $RUN_ROOT"
stamp note "" "run root created"

read -r -p ">>> Network profile notes (carrier, Wi-Fi network name, or blank): " network_notes || true

git_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
# Two runs of one HEAD can still measure different code when a patch is uncommitted, so the
# provenance also carries the working tree's diff identity: the diff itself is kept in the run
# root, and its digest names the exact source state for a before/after comparison. Untracked
# (not ignored) files are part of that state, since a new source file builds through a tracked
# project-file change, so each one is appended as a diff against nothing.
# Captured here, immediately before the install invocation, rather than after the scenarios run:
# the scenarios span up to 30 minutes, and a tree that changes during that window would otherwise
# have its git state misattributed to the build that was actually installed and measured.
{
  git -C "$REPO_ROOT" diff HEAD
  git -C "$REPO_ROOT" ls-files --others --exclude-standard -z | while IFS= read -r -d '' untracked; do
    git -C "$REPO_ROOT" diff --no-index -- /dev/null "$untracked" || true
  done
} >"$RUN_ROOT/worktree.diff" 2>/dev/null || true
git_diff_sha="$(shasum -a 256 "$RUN_ROOT/worktree.diff" | awk '{ print $1 }')"
git_dirty="$([[ -s "$RUN_ROOT/worktree.diff" ]] && echo true || echo false)"

say "Installing the debug build on the device (scripts/install-ios-device.sh)..."
stamp step "" "installing device build"
# The baseline needs a Debug build: DevicePerformanceLog's configureLoggerAtLaunch only runs under
# `#if DEBUG`, so a Release build never writes Documents/perf/device-perf.jsonl and the run would
# fail only at the final pull. The installer sources .env itself, so a value set there cannot be
# overridden from this environment; it has to be absent or Debug.
case "${SPACES_IOS_CONFIGURATION:-Debug}" in
  Debug) ;;
  *) fail "SPACES_IOS_CONFIGURATION is set to '${SPACES_IOS_CONFIGURATION}' in .env; the baseline needs a Debug build (unset it or set it to Debug)." ;;
esac
"$REPO_ROOT/scripts/install-ios-device.sh" 2>&1 | tee "$RUN_ROOT/install.log" \
  || fail "scripts/install-ios-device.sh failed; see $RUN_ROOT/install.log"
stamp step "" "install complete"

# The installer's own launch carries no paywall bypass, and the pairing link handler lives behind
# the subscription gate, so the app is relaunched with the bypass before the phone is asked to pair.
say "Relaunching the app with the paywall bypass before pairing..."
relaunch_app_cold

# After the install, not before: a pairing window is one-time and expires, and the install takes
# minutes, so a window opened first would be dead by the time the phone could scan it.
print_pairing_instructions "$RUN_ROOT/pairing-window.json"

# Fixture: register a project so the phone has a workspace and terminal to open.
# seed-fixture reuses an already-registered project at the same directory (verified: rerunning
# it against the same --project-dir returns the same project/workspace with exit 0), so this is
# just called unconditionally rather than pre-checking `spaces workspace list` for a name match.
profile_root="$("$SPACES_E2E" profile-show | awk -F'\t' '$1 == "profile-root" { print $2 }')"
[[ -n "$profile_root" ]] || fail "Could not resolve this worktree's profile root."
fixtures_dir="$profile_root/fixtures"
mkdir -p "$fixtures_dir"
seed_json="$RUN_ROOT/seed-fixture.json"
"$SPACES_E2E" seed-fixture --project-dir "$fixtures_dir/baseline-harbor" --template harbor \
  --docs-url http://localhost:4173/docs --admin-url http://localhost:4173/admin \
  >"$seed_json" 2>"$RUN_ROOT/seed-fixture.stderr.log" \
  || fail "seed-fixture failed; see $seed_json and $RUN_ROOT/seed-fixture.stderr.log"
WORKSPACE_ID="$(json_field "$seed_json" defaultWorkspace.id)"
WORKSPACE_DIR="$(json_field "$seed_json" defaultWorkspace.dir)"
[[ -n "$WORKSPACE_ID" && -n "$WORKSPACE_DIR" ]] || fail "seed-fixture did not return a default workspace; see $seed_json"
stamp step "" "fixture workspace $WORKSPACE_ID at $WORKSPACE_DIR"

"$SPACES_CLI" workspace start --workspace "$WORKSPACE_ID" >"$RUN_ROOT/workspace-start.log" 2>&1 \
  || fail "workspace start failed; see $RUN_ROOT/workspace-start.log"
stamp step "" "workspace started"

for scenario in "${SCENARIOS[@]}"; do
  for selected in "${SELECTED_SCENARIOS[@]}"; do
    if [[ "$scenario" == "$selected" ]]; then
      say "Scenario: $scenario"
      run_scenario "$scenario"
      break
    fi
  done
done

say "All scenarios complete. Turn Wi-Fi back ON now so the Xcode device tunnel reconnects."
tunnel_deadline=$((SECONDS + 120))
final_state="unknown"
while [[ $SECONDS -lt $tunnel_deadline ]]; do
  final_state="$(device_tunnel_state "$RUN_ROOT/device-info-final.json")"
  [[ "$final_state" == "connected" ]] && break
  sleep 5
done
[[ "$final_state" == "connected" ]] || fail "Timed out waiting for the device tunnel to reconnect (tunnelState=$final_state)."

say "Pulling device-perf.jsonl off the device..."
xcrun devicectl device copy from --device "$DEVICE_UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source "Documents/perf/device-perf.jsonl" --destination "$RUN_ROOT/device-perf.jsonl" \
  >"$RUN_ROOT/devicectl-copy.log" 2>&1 || fail "Failed to copy device-perf.jsonl from the device; see $RUN_ROOT/devicectl-copy.log"
xcrun devicectl device copy from --device "$DEVICE_UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source "Documents/perf/device-perf.jsonl.1" --destination "$RUN_ROOT/device-perf.jsonl.1" \
  >"$RUN_ROOT/devicectl-copy-rotated.log" 2>&1 || true

device_model="$(json_field "$RUN_ROOT/device-info-initial.json" result.hardwareProperties.marketingName 2>/dev/null || echo unknown)"
# git_sha, git_dirty, and git_diff_sha are captured earlier, immediately before the
# install-ios-device.sh invocation, so they name the source state that was actually installed
# and measured rather than whatever the tree looks like after the scenarios finish.
python3 - "$RUN_ROOT" "$REPO_ROOT" "$git_sha" "$device_model" "$profile_root" "$network_notes" "$RUN_ROOT/mobile-status.json" "$git_dirty" "$git_diff_sha" <<'PY'
import json
import sys

run_root, worktree, git_sha, device_model, profile_root, network_notes, status_path, git_dirty, git_diff_sha = sys.argv[1:10]
with open(status_path, encoding="utf-8") as handle:
    status = json.load(handle)
payload = {
    "worktree": worktree,
    "gitSHA": git_sha,
    "gitDirty": git_dirty == "true",
    "worktreeDiffSHA256": git_diff_sha,
    "deviceModel": device_model,
    "profileRoot": profile_root,
    "networkProfileNotes": network_notes,
    "daemonEndpoint": {"host": status.get("host"), "port": status.get("port")},
}
with open(f"{run_root}/run.json", "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

say "Rendering report..."
python3 "$SCRIPT_DIR/ios_device_baseline_report.py" --run-root "$RUN_ROOT" | tee "$RUN_ROOT/report.md"

say "Run root: $RUN_ROOT"
