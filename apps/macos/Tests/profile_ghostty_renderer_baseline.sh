#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"
FIXTURE_SCRIPT="$SCRIPT_DIR/terminal_stress_fixture.py"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-ghostty-baseline.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
APP_LOG="$WORK_ROOT/spaces-app.log"
SAMPLES_PATH="$WORK_ROOT/app-resource.csv"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"

START_DELAY_SECONDS="${START_DELAY_SECONDS:-0}"
REPAINT_FRAMES="${REPAINT_FRAMES:-180}"
REPAINT_ROWS="${REPAINT_ROWS:-18}"
REPAINT_WIDTH="${REPAINT_WIDTH:-72}"
REPAINT_SLEEP_MS="${REPAINT_SLEEP_MS:-25}"
POST_FIXTURE_BUFFER_SECONDS="${POST_FIXTURE_BUFFER_SECONDS:-6}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
TITLE="${TITLE:-ghostty-render-baseline}"
FIRST_OUTPUT_TIMEOUT_SECONDS="${FIRST_OUTPUT_TIMEOUT_SECONDS:-70}"

APP_PID=""
SAMPLER_PID=""
SESSION_ID=""

cleanup() {
  if [[ -n "$SESSION_ID" ]] && [[ -x "$SPACES_E2E" ]]; then
    "$SPACES_E2E" close-terminal-session-window --session-id "$SESSION_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SAMPLER_PID" ]] && kill -0 "$SAMPLER_PID" >/dev/null 2>&1; then
    kill "$SAMPLER_PID" >/dev/null 2>&1 || true
    wait "$SAMPLER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

wait_for_log_pattern() {
  local pattern="$1"
  local timeout="${2:-30}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -f "$APP_LOG" ]] && grep -Eq "$pattern" "$APP_LOG"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for log pattern: $pattern" >&2
      return 1
    fi
    sleep 0.2
  done
}

start_resource_sampler() {
  local pid="$1"
  local output_path="$2"
  (
    while kill -0 "$pid" >/dev/null 2>&1; do
      local ts_ms
      ts_ms="$(python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
)"
      ps -o rss=,%cpu= -p "$pid" | awk -v ts="$ts_ms" 'NF==2 { print ts "," $1 "," $2 }' >>"$output_path" || true
      sleep "$SAMPLE_INTERVAL_SECONDS"
    done
  ) >/dev/null 2>&1 &
  echo "$!"
}

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
require_binary "$SPACES_E2E"
[[ -x "$FIXTURE_SCRIPT" ]] || chmod +x "$FIXTURE_SCRIPT"

mkdir -p "$(dirname "$DB_PATH")"
: >"$APP_LOG"
: >"$SAMPLES_PATH"

cd "$REPO_ROOT"
"$SETUP_GHOSTTYKIT" >/dev/null

pkill -x SpacesApp >/dev/null 2>&1 || true
pkill -f "$SPACES_APP" >/dev/null 2>&1 || true

echo "Using work root: $WORK_ROOT"
echo "Using DB path:  $DB_PATH"

env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3
SAMPLER_PID="$(start_resource_sampler "$APP_PID" "$SAMPLES_PATH")"

COMMAND="sleep $START_DELAY_SECONDS; python3 '$FIXTURE_SCRIPT' --mode repaint --frames $REPAINT_FRAMES --rows $REPAINT_ROWS --width $REPAINT_WIDTH --sleep-ms $REPAINT_SLEEP_MS"
COMMAND_OUTPUT="$(env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal command --backend ghostty-embedded --command "$COMMAND" --title "$TITLE")"
SESSION_ID="$(extract_session_id "$COMMAND_OUTPUT")"
[[ -n "$SESSION_ID" ]] || { echo "Failed to parse session ID from: $COMMAND_OUTPUT" >&2; exit 1; }

wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${SESSION_ID} .*mode=owner" 30
wait_for_log_pattern "spaces: perf metric=terminal_surface_create .*target=session=${SESSION_ID} .*success=1" 30

wait_for_log_pattern "spaces: perf metric=terminal_first_output .*target=session=${SESSION_ID} .*success=1" "$FIRST_OUTPUT_TIMEOUT_SECONDS"
POST_OUTPUT_WAIT_SECONDS=$((((REPAINT_FRAMES * REPAINT_SLEEP_MS) / 1000) + POST_FIXTURE_BUFFER_SECONDS + 2))
sleep "$POST_OUTPUT_WAIT_SECONDS"

"$SPACES_E2E" close-terminal-session-window --session-id "$SESSION_ID" >/dev/null 2>&1 || true
sleep 1

kill "$APP_PID" >/dev/null 2>&1 || true
wait "$APP_PID" >/dev/null 2>&1 || true
APP_PID=""
kill "$SAMPLER_PID" >/dev/null 2>&1 || true
wait "$SAMPLER_PID" >/dev/null 2>&1 || true
SAMPLER_PID=""

python3 - "$WORK_ROOT" "$APP_LOG" "$SAMPLES_PATH" "$SESSION_ID" "$METRICS_PATH" "$SUMMARY_PATH" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

work_root = Path(sys.argv[1])
app_log_path = Path(sys.argv[2])
samples_path = Path(sys.argv[3])
session_id = sys.argv[4]
metrics_path = Path(sys.argv[5])
summary_path = Path(sys.argv[6])

perf_pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
ts_pattern = re.compile(r"\bts_ms=(\d+)\b")

metrics: dict[str, list[int]] = {}
for raw_line in app_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
    match = perf_pattern.match(raw_line.strip())
    if not match or match.group("success") != "1":
        continue
    target = match.group("target")
    if f"session={session_id}" not in target:
        continue
    metric = match.group("metric")
    elapsed = int(match.group("elapsed"))
    metrics.setdefault(metric, []).append(elapsed)

performed_timestamps = []
requested_timestamps = []
first_output_timestamp = None
for raw_line in app_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
    match = perf_pattern.match(raw_line.strip())
    if not match or match.group("success") != "1":
        continue
    target = match.group("target")
    if f"session={session_id}" not in target:
        continue
    metric = match.group("metric")
    if metric not in {"terminal_surface_refresh", "terminal_surface_refresh_request"}:
        continue
    detail = match.group("detail") or ""
    ts_match = ts_pattern.search(detail)
    if not ts_match:
        continue
    timestamp = int(ts_match.group(1))
    if metric == "terminal_first_output":
        first_output_timestamp = timestamp
    elif metric == "terminal_surface_refresh":
        performed_timestamps.append(timestamp)
    else:
        requested_timestamps.append(timestamp)

if first_output_timestamp is not None:
    requested_timestamps = [value for value in requested_timestamps if value >= first_output_timestamp]
    performed_timestamps = [value for value in performed_timestamps if value >= first_output_timestamp]

request_intervals = [
    requested_timestamps[index] - requested_timestamps[index - 1]
    for index in range(1, len(requested_timestamps))
    if requested_timestamps[index] >= requested_timestamps[index - 1]
]
performed_intervals = [
    performed_timestamps[index] - performed_timestamps[index - 1]
    for index in range(1, len(performed_timestamps))
    if performed_timestamps[index] >= performed_timestamps[index - 1]
]

def summarize(values):
    values = sorted(values)
    if not values:
        return None
    return {
        "count": len(values),
        "min_ms": min(values),
        "avg_ms": round(statistics.mean(values), 1),
        "median_ms": round(statistics.median(values), 1),
        "p95_ms": values[max(math.ceil(len(values) * 0.95) - 1, 0)],
        "p99_ms": values[max(math.ceil(len(values) * 0.99) - 1, 0)],
        "max_ms": max(values),
    }

resource_rows = []
if samples_path.exists():
    for row in samples_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not row:
            continue
        ts_ms, rss_kb, cpu_pct = row.split(",", 2)
        resource_rows.append((int(ts_ms), int(rss_kb), float(cpu_pct)))

payload = {
    "session_id": session_id,
    "first_output_timestamp_ms": first_output_timestamp,
    "surface_refresh_request": summarize(metrics.get("terminal_surface_refresh_request", [])),
    "surface_refresh": summarize(metrics.get("terminal_surface_refresh", [])),
    "request_interval": summarize(request_intervals),
    "request_jank_over_32ms": sum(1 for value in request_intervals if value > 32),
    "request_jank_over_50ms": sum(1 for value in request_intervals if value > 50),
    "frame_interval": summarize(performed_intervals),
    "jank_over_32ms": sum(1 for value in performed_intervals if value > 32),
    "jank_over_50ms": sum(1 for value in performed_intervals if value > 50),
    "resource": {
        "samples": len(resource_rows),
        "rss_kb_avg": round(statistics.mean(row[1] for row in resource_rows), 1) if resource_rows else None,
        "rss_kb_max": max((row[1] for row in resource_rows), default=None),
        "cpu_pct_avg": round(statistics.mean(row[2] for row in resource_rows), 1) if resource_rows else None,
        "cpu_pct_max": max((row[2] for row in resource_rows), default=None),
    },
    "metrics": {name: summarize(values) for name, values in sorted(metrics.items())},
}

lines = [
    "Ghostty renderer baseline",
    "",
    f"session_id: {session_id}",
]
for metric_name in ("terminal_surface_refresh_request", "terminal_surface_refresh"):
    summary = payload["metrics"].get(metric_name)
    if not summary:
        lines.append(f"{metric_name}: no samples")
        continue
    lines.append(
        f"{metric_name}: count={summary['count']} min={summary['min_ms']}ms avg={summary['avg_ms']}ms "
        f"median={summary['median_ms']}ms p95={summary['p95_ms']}ms p99={summary['p99_ms']}ms max={summary['max_ms']}ms"
    )
if payload["request_interval"]:
    interval = payload["request_interval"]
    lines.append(
        f"request_interval: count={interval['count']} min={interval['min_ms']}ms avg={interval['avg_ms']}ms "
        f"median={interval['median_ms']}ms p95={interval['p95_ms']}ms p99={interval['p99_ms']}ms max={interval['max_ms']}ms"
    )
    lines.append(f"request_jank: >32ms={payload['request_jank_over_32ms']} >50ms={payload['request_jank_over_50ms']}")
else:
    lines.append("request_interval: unavailable")
    lines.append("request_jank: unavailable")
if payload["frame_interval"]:
    interval = payload["frame_interval"]
    lines.append(
        f"frame_interval: count={interval['count']} min={interval['min_ms']}ms avg={interval['avg_ms']}ms "
        f"median={interval['median_ms']}ms p95={interval['p95_ms']}ms p99={interval['p99_ms']}ms max={interval['max_ms']}ms"
    )
    lines.append(f"jank: >32ms={payload['jank_over_32ms']} >50ms={payload['jank_over_50ms']}")
else:
    lines.append("frame_interval: unavailable")
    lines.append("jank: unavailable")
resource = payload["resource"]
lines.append(
    f"resource: rss_avg={resource['rss_kb_avg']}KB rss_max={resource['rss_kb_max']}KB "
    f"cpu_avg={resource['cpu_pct_avg']} cpu_max={resource['cpu_pct_max']} samples={resource['samples']}"
)
if not payload["frame_interval"]:
    lines.append(
        "note: performed Ghostty refresh samples are still sparse in this run; use refresh-request cadence as the current repaint target."
    )

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
metrics_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
print("Artifacts:")
print(f"  app log:  {app_log_path}")
print(f"  samples:  {samples_path}")
print(f"  summary:  {summary_path}")
print(f"  metrics:  {metrics_path}")
PY
