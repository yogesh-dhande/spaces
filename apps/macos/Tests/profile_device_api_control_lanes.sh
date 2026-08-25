#!/usr/bin/env bash
# Device API control-lane bench: N bursty agent-shaped producers streaming while a client resyncs each of
# them and types into a separate session, so the typed round trip is charged for whatever cross-session
# serialization the daemon still has. Reports p50/p95/max for the typed control round trip, for the
# `.overview` poll that generates the inline shared-queue load, and for the DEBUG-gated control-lane queue
# wait read out of the profile's perf.log. Publishes nothing unless the load held for the whole window.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/terminal_harness_lock.sh"
spaces_cli="${SPACES_CLI:-$repo_root/apps/macos/.build/debug/spaces}"
spacese2e="${SPACES_E2E:-$repo_root/apps/macos/.build/debug/spacese2e}"
terminal_service="${SPACESD_EXECUTABLE:-$repo_root/apps/macos/.build/debug/spacesd}"
fixture_script="$script_dir/terminal_stress_fixture.py"

for binary in "$spaces_cli" "$spacese2e" "$terminal_service"; do
  [[ -x "$binary" ]] || { echo "Missing executable: $binary" >&2; exit 1; }
done

producers="${PRODUCERS:-5}"
samples="${SAMPLES:-60}"
# Frames at 25/s (--sleep-ms 40) over 36 rows of ~128 bytes is roughly 115 KB/s per producer, flushed once
# per frame so the traffic arrives in bursts. The frame count is the producer's own deadline: it stops on
# its own even if this script is killed before its trap runs.
producer_frames="${PRODUCER_FRAMES:-3000}"
run_seed="$$"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/spaces-control-lane-bench.XXXXXX")"
export HOME="$temp_root/home"
export SPACES_DB_PATH="$temp_root/spaces.db"
export SPACES_RUNTIME_DIR="$temp_root/runtime"
export SPACESD_EXECUTABLE="$terminal_service"
mkdir -p "$HOME" "$SPACES_RUNTIME_DIR"
service_log="$temp_root/spacesd.log"
summary_path="${SUMMARY_PATH:-$temp_root/control-lane-summary.json}"
# Cleared before any work, so "no summary published" is literally true for every run that ends without
# publishing one and a reader can never mistake a previous run's artifact for this run's result. It has to
# happen here rather than in the driver: the wrapper can fail before the driver ever starts (a daemon that
# will not come up, a session that will not create), and those runs must clear the file too.
rm -f "$summary_path"

cleanup() {
  stop_terminal_service_for_runtime_dir "$SPACES_RUNTIME_DIR" 5 >/dev/null 2>&1 || true
  # The producers are children of the daemon, not of this shell, so the process-group kill above cannot
  # reach them; sweep by this run's fixture seed, which no other run shares.
  pkill -P $$ >/dev/null 2>&1 || true
  pkill -f "terminal_stress_fixture.py .*--seed $run_seed" >/dev/null 2>&1 || true
  rm -rf "$temp_root"
}
trap cleanup EXIT

device_api_port="$(python3 -c 'import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])')"
export SPACES_DEVICE_API_PORT="$device_api_port"

# DEBUG=1 is what arms TerminalPerformance, and it is read once at launch; perf.log lands in the profile's
# runtime directory.
DEBUG=1 "$terminal_service" >"$service_log" 2>&1 &
service_pid=$!
deadline=$((SECONDS + 20))
until "$spacese2e" mobile-status >/dev/null 2>&1; do
  [[ $SECONDS -lt $deadline ]] || { cat "$service_log" >&2; echo "Timed out waiting for spacesd." >&2; exit 1; }
  kill -0 "$service_pid" 2>/dev/null || { cat "$service_log" >&2; echo "spacesd exited during startup." >&2; exit 1; }
  sleep 0.1
done

fixture_project_dir="$temp_root/fixture-project"
mkdir -p "$fixture_project_dir"
workspace_id="$("$spacese2e" register-project --project-dir "$fixture_project_dir" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

create_session() {
  local title="$1" command="$2" output
  output="$("$spaces_cli" terminal create --workspace "$workspace_id" --command "$command" --title "$title")"
  awk '/Started terminal session/ { print $4 }' <<<"$output"
}

# A command substitution swallows the exit status of what runs inside it, so a `terminal create` that
# failed would yield an empty id here and the driver would then derive the expected load from a shorter
# list — reporting a full-load run that never had one. Each id is checked as it is captured instead.
producer_ids=()
for index in $(seq 1 "$producers"); do
  producer_id="$(create_session "producer-$index" \
    "python3 '$fixture_script' --mode mixed --frames $producer_frames --rows 36 --width 88 --sleep-ms 40 --seed $run_seed")"
  [[ -n "$producer_id" ]] || { echo "Failed to create producer session $index of $producers." >&2; exit 1; }
  producer_ids+=("$producer_id")
done
typing_session_id="$(create_session "typing" 'cat')"
[[ -n "$typing_session_id" ]] || { echo "Failed to create the typing session." >&2; exit 1; }

"$spacese2e" open-device-pairing-window --timeout-seconds 30 >"$temp_root/pairing-window.json"

PRODUCER_SESSION_IDS="$(IFS=,; echo "${producer_ids[*]}")" \
TYPING_SESSION_ID="$typing_session_id" \
PAIRING_WINDOW_JSON="$temp_root/pairing-window.json" \
DEVICE_API_PORT="$device_api_port" \
SPACES_E2E="$spacese2e" \
PERF_LOG="$SPACES_RUNTIME_DIR/perf.log" \
PRODUCER_FIXTURE_PATTERN="terminal_stress_fixture.py .*--seed $run_seed" \
SAMPLES="$samples" \
SUMMARY_PATH="$summary_path" \
python3 "$script_dir/profile_device_api_control_lanes.py"
