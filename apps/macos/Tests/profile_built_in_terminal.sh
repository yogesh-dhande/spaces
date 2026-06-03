#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

ITERATIONS="${ITERATIONS:-3}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-profile.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
PERF_LOG="$RUNTIME_DIR/perf.log"
APP_LOG="$WORK_ROOT/spaces-app.log"
SESSION_SUMMARY="$WORK_ROOT/summary.txt"
SESSION_METRICS_JSON="$WORK_ROOT/metrics.json"
COMMAND_WALL_SAMPLES="$WORK_ROOT/command-wall.tsv"
VIEWER_SHOW_WALL_SAMPLES="$WORK_ROOT/viewer-show-wall.tsv"
VIEWER_UPDATE_WALL_SAMPLES="$WORK_ROOT/viewer-update-wall.tsv"
APP_PID=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_log_pattern_count_greater_than() {
  local log_path="$1"
  local pattern="$2"
  local baseline="$3"
  local timeout="${4:-30}"
  local start
  start="$(date +%s)"
  while true; do
    local count
    count="$(grep -Ec "$pattern" "$log_path" 2>/dev/null || true)"
    if (( count > baseline )); then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for log count increase: $pattern (baseline $baseline)" >&2
      return 1
    fi
    sleep 0.2
  done
}

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

ms_since() {
  python3 - "$1" <<'PY'
import sys, time
started = float(sys.argv[1])
print(max(int((time.time() - started) * 1000), 0))
PY
}

active_attachment_client_id() {
  local session_id="$1"
  local mode="$2"
  local attachments_path
  attachments_path="$RUNTIME_DIR/terminal/sessions/$session_id/attachments.json"
  python3 - "$attachments_path" "$mode" <<'PY'
import json, sys
path = sys.argv[1]
mode = sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    attachments = json.load(handle)
for attachment in attachments:
    if attachment.get("mode") == mode and attachment.get("detachedAt") is None:
        print(attachment["clientID"])
        break
else:
    raise SystemExit(f"no active {mode} attachment found")
PY
}

attach_remote_viewer_client() {
  local session_id="$1"
  local socket_path="$RUNTIME_DIR/terminal/sessions/$session_id/control.sock"
  python3 - "$socket_path" <<'PY'
import json
import socket
import sys
import uuid
from datetime import datetime, timezone

socket_path = sys.argv[1]
client_id = str(uuid.uuid4()).upper()
request = {
    "command": "attach",
    "client": {
        "id": client_id,
        "kind": "remoteViewer",
        "identity": {
            "label": "Terminal Profile Viewer",
            "deviceName": "Terminal Profile Viewer",
            "networkAddress": "127.0.0.1",
        },
        "connectedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    },
    "attachmentMode": "viewer",
}

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5)
client.connect(socket_path)
client.sendall(json.dumps(request).encode("utf-8"))
client.shutdown(socket.SHUT_WR)
response = json.loads(client.recv(65536).decode("utf-8"))
client.close()
if not response.get("ok"):
    raise SystemExit(response.get("message") or response)
print(client_id)
PY
}

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

mkdir -p "$(dirname "$DB_PATH")" "$RUNTIME_DIR"
touch "$APP_LOG" "$PERF_LOG"
: >"$COMMAND_WALL_SAMPLES"
: >"$VIEWER_SHOW_WALL_SAMPLES"
: >"$VIEWER_UPDATE_WALL_SAMPLES"

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT"

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"

echo "Using work root: $WORK_ROOT"
echo "Using DB path:  $DB_PATH"
echo "Using runtime:  $RUNTIME_DIR"

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

for iteration in $(seq 1 "$ITERATIONS"); do
  title="terminal-profile-$iteration"
  command_started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  command_output="$(
    env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 \
      "$SPACES_CLI" terminal command --backend ghostty-embedded --command cat --title "$title"
  )"
  command_wall_ms="$(ms_since "$command_started_at")"
  session_id="$(extract_session_id "$command_output")"
  [[ -n "$session_id" ]] || { echo "Failed to parse session ID from: $command_output" >&2; exit 1; }
  printf '%s\t%s\n' "$session_id" "$command_wall_ms" >>"$COMMAND_WALL_SAMPLES"

  wait_for_log_pattern_count_greater_than \
    "$PERF_LOG" \
    "spaces: perf metric=terminal_window_summon target=session=${session_id} success=1 .*mode=owner" \
    0 \
    30

  payload="profile-ping-$iteration"
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 \
    "$SPACES_CLI" terminal send "$session_id" "$payload" --newline >/dev/null
  wait_for_log_pattern_count_greater_than \
    "$PERF_LOG" \
    "spaces: perf metric=terminal_control_send target=session=${session_id} success=1" \
    0 \
    30

  tail_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal tail "$session_id" --lines 10)"
  printf '%s\n' "$tail_output" | grep -q "$payload"

  viewer_show_started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  viewer_client_id="$(attach_remote_viewer_client "$session_id")"
  viewer_show_wall_ms="$(ms_since "$viewer_show_started_at")"
  printf '%s\t%s\n' "$session_id" "$viewer_show_wall_ms" >>"$VIEWER_SHOW_WALL_SAMPLES"
  [[ "$(active_attachment_client_id "$session_id" viewer)" == "$viewer_client_id" ]] || {
    echo "Attached remote viewer did not become the active viewer attachment" >&2
    exit 1
  }
  owner_client_id="$(active_attachment_client_id "$session_id" owner)"

  viewer_takeover_baseline="$(
    grep -Ec \
      "spaces: perf metric=terminal_control_takeover target=session=${session_id} client=${viewer_client_id} success=1" \
      "$PERF_LOG" || true
  )"
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal takeover "$session_id" "$viewer_client_id" >/dev/null
  wait_for_log_pattern_count_greater_than \
    "$PERF_LOG" \
    "spaces: perf metric=terminal_control_takeover target=session=${session_id} client=${viewer_client_id} success=1" \
    "$viewer_takeover_baseline" \
    30

  owner_takeover_baseline="$(
    grep -Ec \
      "spaces: perf metric=terminal_control_takeover target=session=${session_id} client=${owner_client_id} success=1" \
      "$PERF_LOG" || true
  )"
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal takeover "$session_id" "$owner_client_id" >/dev/null
  wait_for_log_pattern_count_greater_than \
    "$PERF_LOG" \
    "spaces: perf metric=terminal_control_takeover target=session=${session_id} client=${owner_client_id} success=1" \
    "$owner_takeover_baseline" \
    30
done

python3 - "$PERF_LOG" "$ITERATIONS" "$COMMAND_WALL_SAMPLES" "$VIEWER_SHOW_WALL_SAMPLES" "$VIEWER_UPDATE_WALL_SAMPLES" "$SESSION_METRICS_JSON" <<'PY' >"$SESSION_SUMMARY"
import json, math, re, statistics, sys
from collections import defaultdict

perf_log_path, iterations, command_wall_path, viewer_show_wall_path, viewer_update_wall_path, json_path = sys.argv[1:7]
iterations = int(iterations)
pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
detail_pattern = re.compile(r"(?P<key>[A-Za-z0-9_:-]+)=(?P<value>\S+)")

def parse_detail(detail: str) -> dict[str, str]:
    return {match.group("key"): match.group("value") for match in detail_pattern.finditer(detail)}

def summarize(values):
    avg = round(statistics.mean(values), 1)
    sorted_values = sorted(values)
    p95_index = max(math.ceil(len(values) * 0.95) - 1, 0)
    p95 = sorted_values[p95_index]
    return {
        "count": len(values),
        "min_ms": min(values),
        "avg_ms": avg,
        "p95_ms": p95,
        "max_ms": max(values),
    }

def load_wall_samples(path):
    values = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            _, elapsed = line.split("\t", 1)
            values.append(int(elapsed))
    return values

command_wall_samples = load_wall_samples(command_wall_path)
viewer_show_wall_samples = load_wall_samples(viewer_show_wall_path)
viewer_update_wall_samples = load_wall_samples(viewer_update_wall_path)

service_ensure_by_launch = defaultdict(list)
snapshot_refresh_by_renderer = defaultdict(list)
viewer_output_by_renderer = defaultdict(list)
remote_state_publish_by_reason = defaultdict(list)
remote_state_receive_by_reason = defaultdict(list)
service_create_samples = []
window_summon_by_mode = defaultdict(list)
show_records_by_mode = defaultdict(list)
show_stage_by_mode_and_name = defaultdict(list)

pending_show_stages_by_session = defaultdict(list)
completed_shows_by_session = defaultdict(list)

with open(perf_log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        match = pattern.match(line)
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        target = match.group("target")
        elapsed = int(match.group("elapsed"))
        detail = match.group("detail") or ""
        detail_map = parse_detail(detail)

        session_id = None
        for token in target.split():
            if token.startswith("session="):
                session_id = token.split("=", 1)[1]
                break

        if metric == "terminal_service_ensure_running":
            service_ensure_by_launch[detail_map.get("launched", "unknown")].append(elapsed)
        elif metric == "terminal_service_create_session":
            service_create_samples.append(elapsed)
        elif metric == "terminal_snapshot_stream_refresh":
            snapshot_refresh_by_renderer[detail_map.get("renderer", "unknown")].append(elapsed)
        elif metric == "terminal_viewer_output_present":
            viewer_output_by_renderer[detail_map.get("renderer", "unknown")].append(elapsed)
        elif metric == "terminal_remote_state_publish":
            remote_state_publish_by_reason[detail_map.get("reason", "unknown")].append(elapsed)
        elif metric == "terminal_remote_state_receive":
            remote_state_receive_by_reason[detail_map.get("reason", "unknown")].append(elapsed)
        elif metric == "terminal_window_show_stage" and session_id:
            pending_show_stages_by_session[session_id].append((detail_map.get("stage", "unknown"), elapsed))
        elif metric == "terminal_window_show" and session_id:
            completed_shows_by_session[session_id].append({
                "mode": None,
                "elapsed": elapsed,
                "stages": pending_show_stages_by_session[session_id],
            })
            pending_show_stages_by_session[session_id] = []
        elif metric == "terminal_window_summon" and session_id:
            mode = detail_map.get("mode", "unknown")
            window_summon_by_mode[mode].append(elapsed)
            for show in reversed(completed_shows_by_session[session_id]):
                if show["mode"] is None:
                    show["mode"] = mode
                    show_records_by_mode[mode].append(show["elapsed"])
                    for stage_name, stage_elapsed in show["stages"]:
                        show_stage_by_mode_and_name[(mode, stage_name)].append(stage_elapsed)
                    break

ordered = [
    ("terminal_command_wall", command_wall_samples),
    ("terminal_service_create_session", service_create_samples),
    ("owner_window_summon", window_summon_by_mode.get("owner", [])),
    ("owner_window_show", show_records_by_mode.get("owner", [])),
    ("viewer_show_wall", viewer_show_wall_samples),
    ("viewer_window_summon", window_summon_by_mode.get("viewer", [])),
    ("viewer_window_show", show_records_by_mode.get("viewer", [])),
    ("viewer_snapshot_update_wall", viewer_update_wall_samples),
]

payload = {"iterations": iterations, "metrics": {}}
print(f"Profiled daemon-backed built-in terminal over {iterations} iteration(s)")
print()
for name, values in ordered:
    if not values:
        print(f"{name}: no successful samples recorded")
        continue
    summary = summarize(values)
    payload["metrics"][name] = summary
    print(
        f"{name}: count={summary['count']} min={summary['min_ms']}ms avg={summary['avg_ms']}ms "
        f"p95={summary['p95_ms']}ms max={summary['max_ms']}ms")

if service_ensure_by_launch:
    print()
    for launched in sorted(service_ensure_by_launch):
        values = service_ensure_by_launch[launched]
        summary = summarize(values)
        payload["metrics"][f"terminal_service_ensure_running:launched={launched}"] = summary
        print(
            f"terminal_service_ensure_running launched={launched}: count={summary['count']} min={summary['min_ms']}ms "
            f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms")

if show_stage_by_mode_and_name:
    print()
    for mode, stage_name in sorted(show_stage_by_mode_and_name):
        values = show_stage_by_mode_and_name[(mode, stage_name)]
        summary = summarize(values)
        payload["metrics"][f"{mode}_show_stage:{stage_name}"] = summary
        print(
            f"{mode}_show_stage {stage_name}: count={summary['count']} min={summary['min_ms']}ms "
            f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms")

if snapshot_refresh_by_renderer:
    print()
    for renderer in sorted(snapshot_refresh_by_renderer):
        values = snapshot_refresh_by_renderer[renderer]
        summary = summarize(values)
        payload["metrics"][f"terminal_snapshot_stream_refresh:{renderer}"] = summary
        print(
            f"terminal_snapshot_stream_refresh renderer={renderer}: count={summary['count']} min={summary['min_ms']}ms "
            f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms")

if viewer_output_by_renderer:
    print()
    for renderer in sorted(viewer_output_by_renderer):
        values = viewer_output_by_renderer[renderer]
        summary = summarize(values)
        payload["metrics"][f"terminal_viewer_output_present:{renderer}"] = summary
        print(
            f"terminal_viewer_output_present renderer={renderer}: count={summary['count']} min={summary['min_ms']}ms "
            f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms")

if remote_state_publish_by_reason:
    print()
    for reason in sorted(remote_state_publish_by_reason):
        values = remote_state_publish_by_reason[reason]
        summary = summarize(values)
        payload["metrics"][f"terminal_remote_state_publish:{reason}"] = summary
        print(
            f"terminal_remote_state_publish reason={reason}: count={summary['count']} min={summary['min_ms']}ms "
            f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms")

if remote_state_receive_by_reason:
    print()
    for reason in sorted(remote_state_receive_by_reason):
        values = remote_state_receive_by_reason[reason]
        summary = summarize(values)
        payload["metrics"][f"terminal_remote_state_receive:{reason}"] = summary
        print(
            f"terminal_remote_state_receive reason={reason}: count={summary['count']} min={summary['min_ms']}ms "
            f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms")

with open(json_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY

cat "$SESSION_SUMMARY"
echo
echo "Artifacts:"
echo "  app log:    $APP_LOG"
echo "  perf log:   $PERF_LOG"
echo "  summary:    $SESSION_SUMMARY"
echo "  metrics:    $SESSION_METRICS_JSON"
