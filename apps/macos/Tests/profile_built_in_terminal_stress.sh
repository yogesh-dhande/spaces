#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"
FIXTURE_SCRIPT="$SCRIPT_DIR/terminal_stress_fixture.py"
TERMINAL_BACKEND="${TERMINAL_BACKEND:-script-pty}"
SUPPORTS_VIEWER_STRESS=1
if [[ "$TERMINAL_BACKEND" == "ghostty-embedded" ]]; then
  SUPPORTS_VIEWER_STRESS=0
fi

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-stress.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
APP_LOG="$WORK_ROOT/spaces-app.log"
CLI_LOG="$WORK_ROOT/spaces-cli.log"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
APP_PID=""
RESOURCE_SAMPLER_PID=""

LINE_LINES="${LINE_LINES:-20000}"
REPAINT_FRAMES="${REPAINT_FRAMES:-250}"
REPAINT_ROWS="${REPAINT_ROWS:-20}"
REPAINT_SLEEP_MS="${REPAINT_SLEEP_MS:-0}"
MIXED_FRAMES="${MIXED_FRAMES:-180}"
MIXED_ROWS="${MIXED_ROWS:-18}"
MIXED_SLEEP_MS="${MIXED_SLEEP_MS:-0}"
TAIL_SAMPLES="${TAIL_SAMPLES:-5}"
VIEWER_REPAINT_FRAMES="${VIEWER_REPAINT_FRAMES:-600}"
VIEWER_REPAINT_ROWS="${VIEWER_REPAINT_ROWS:-24}"
VIEWER_REPAINT_SLEEP_MS="${VIEWER_REPAINT_SLEEP_MS:-2}"
SCROLLBACK_REPAINT_FRAMES="${SCROLLBACK_REPAINT_FRAMES:-180}"
SCROLLBACK_REPAINT_ROWS="${SCROLLBACK_REPAINT_ROWS:-18}"
SCROLLBACK_HISTORY_ROWS="${SCROLLBACK_HISTORY_ROWS:-18}"
SCROLLBACK_REPAINT_SLEEP_MS="${SCROLLBACK_REPAINT_SLEEP_MS:-2}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
SESSION_ROOT_OVERRIDE="${SESSION_ROOT_OVERRIDE:-}"
RESOURCE_SAMPLES_PATH="$WORK_ROOT/app-resource.csv"
SCENARIOS="${SCENARIOS:-lines repaint mixed repaint_viewer scrollback_repaint}"

cleanup() {
  if [[ -n "$RESOURCE_SAMPLER_PID" ]] && kill -0 "$RESOURCE_SAMPLER_PID" >/dev/null 2>&1; then
    kill "$RESOURCE_SAMPLER_PID" >/dev/null 2>&1 || true
    wait "$RESOURCE_SAMPLER_PID" >/dev/null 2>&1 || true
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
    if grep -Eq "$pattern" "$APP_LOG"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for log pattern: $pattern" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_owner_ready() {
  local session_id="$1"
  if [[ "$TERMINAL_BACKEND" == "ghostty-embedded" ]]; then
    wait_for_log_pattern "spaces: perf metric=(terminal_surface_create|terminal_owner_focus_sync) .*target=session=${session_id} .*success=1" 30
  else
    wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=owner" 30
  fi
}

wait_for_file_pattern() {
  local path="$1"
  local pattern="$2"
  local timeout="${3:-30}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ -f "$path" ]] && grep -Eq "$pattern" "$path"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for file pattern: $pattern in $path" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_tail_pattern() {
  local session_id="$1"
  local pattern="$2"
  local lines="${3:-4000}"
  local timeout="${4:-30}"
  local start tail_output
  start="$(date +%s)"
  while true; do
    tail_output="$(env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal tail "$session_id" --lines "$lines" 2>>"$CLI_LOG" || true)"
    if printf '%s\n' "$tail_output" | grep -Eq "$pattern"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for tail pattern: $pattern for $session_id" >&2
      return 1
    fi
    sleep 0.2
  done
}

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

ms_now() {
  python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
}

start_resource_sampler() {
  local pid="$1"
  local output_path="$2"
  (
    while kill -0 "$pid" >/dev/null 2>&1; do
      local ts_ms
      ts_ms="$(ms_now)"
      ps -o rss=,%cpu= -p "$pid" | awk -v ts="$ts_ms" 'NF==2 { print ts "," $1 "," $2 }' >>"$output_path" || true
      sleep "$SAMPLE_INTERVAL_SECONDS"
    done
  ) >/dev/null 2>&1 &
  echo "$!"
}

resolve_session_dir() {
  local session_id="$1"
  local timeout="${2:-30}"
  local start candidate
  local -a candidates=()
  if [[ -n "$SESSION_ROOT_OVERRIDE" ]]; then
    candidates+=("$SESSION_ROOT_OVERRIDE/$session_id")
  fi
  candidates+=("$HOME/.spaces/terminal/sessions/$session_id")
  candidates+=("$(dirname "$DB_PATH")/terminal/sessions/$session_id")
  start="$(date +%s)"
  while true; do
    for candidate in "${candidates[@]}"; do
      if [[ -d "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out resolving session directory for $session_id" >&2
      return 1
    fi
    sleep 0.2
  done
}

run_tail_samples() {
  local session_id="$1"
  local scenario="$2"
  local output_path="$3"
  local cli_log_path="$4"
  : >"$output_path"
  : >"$cli_log_path"
  for _ in $(seq 1 "$TAIL_SAMPLES"); do
    local started_at finished_at elapsed_ms tail_output
    started_at="$(ms_now)"
    tail_output="$(env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal tail "$session_id" --lines 80 2>>"$cli_log_path")"
    finished_at="$(ms_now)"
    elapsed_ms=$((finished_at - started_at))
    printf '%s\t%s\t%s\n' "$scenario" "$elapsed_ms" "$(printf '%s' "$tail_output" | wc -c | tr -d ' ')" >>"$output_path"
    sleep 0.2
  done
}

capture_terminal_tail() {
  local session_id="$1"
  local lines="$2"
  local output_path="$3"
  env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal tail "$session_id" --lines "$lines" >"$output_path"
}

run_scenario() {
  local scenario="$1"
  local command="$2"
  local expected_lines="$3"
  local expected_frame="$4"
  local tail_timings_path="$WORK_ROOT/${scenario}-tail.tsv"
  local cli_metrics_path="$WORK_ROOT/${scenario}-cli.log"
  local command_output session_id session_dir output_log tail_capture_path

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=launch"
  command_output="$(env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal command --backend "$TERMINAL_BACKEND" --command "$command" --title "stress-${scenario}")"
  session_id="$(extract_session_id "$command_output")"
  [[ -n "$session_id" ]] || { echo "Failed to parse session ID for scenario $scenario" >&2; exit 1; }

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=wait_ready session=$session_id"
  wait_for_owner_ready "$session_id"
  session_dir="$(resolve_session_dir "$session_id" 60)"
  output_log="$session_dir/output.log"
  tail_capture_path="$WORK_ROOT/${scenario}-tail.txt"

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=tail_samples session=$session_id"
  run_tail_samples "$session_id" "$scenario" "$tail_timings_path" "$cli_metrics_path"

  local done_pattern="FIXTURE_DONE mode=${scenario} emitted=${expected_lines}"
  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=wait_done session=$session_id"
  wait_for_tail_pattern "$session_id" "$done_pattern" "$((expected_lines + 200))" 120
  capture_terminal_tail "$session_id" "$((expected_lines + 200))" "$tail_capture_path"

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=summarize session=$session_id"
  python3 - "$scenario" "$tail_capture_path" "$expected_lines" "$expected_frame" "$tail_timings_path" "$cli_metrics_path" "$APP_LOG" "$session_id" >"$WORK_ROOT/${scenario}-summary.json" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

scenario = sys.argv[1]
tail_capture = Path(sys.argv[2])
expected_lines = int(sys.argv[3])
expected_frame = int(sys.argv[4])
tail_timings_path = Path(sys.argv[5])
cli_metrics_path = Path(sys.argv[6])
app_log_path = Path(sys.argv[7])
session_id = sys.argv[8]
text = tail_capture.read_text(encoding="utf-8", errors="replace")
seq_pattern = re.compile(r"SEQ (\d{8})")
frame_pattern = re.compile(r"FRAME (\d{6})")
perf_pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
mode_pattern = re.compile(r"mode=(?P<mode>\S+)")
seqs = [int(match.group(1)) for match in seq_pattern.finditer(text)]
frames = [int(match.group(1)) for match in frame_pattern.finditer(text)]
tail_rows = []
if tail_timings_path.exists():
    for row in tail_timings_path.read_text(encoding="utf-8").splitlines():
        if not row:
            continue
        _, elapsed_ms, output_bytes = row.split("\t")
        tail_rows.append((int(elapsed_ms), int(output_bytes)))

cli_metrics = {}
app_metrics = {}
mode_counts = {}
if cli_metrics_path.exists():
    for raw_line in cli_metrics_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = perf_pattern.match(raw_line.strip())
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        elapsed_ms = int(match.group("elapsed"))
        cli_metrics.setdefault(metric, []).append(elapsed_ms)
        detail = match.group("detail") or ""
        if metric == "terminal_tail_read":
            mode_match = mode_pattern.search(detail)
            if mode_match:
                mode = mode_match.group("mode")
                mode_counts[mode] = mode_counts.get(mode, 0) + 1
if app_log_path.exists():
    for raw_line in app_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = perf_pattern.match(raw_line.strip())
        if not match or match.group("success") != "1":
            continue
        target = match.group("target")
        if f"session={session_id}" not in target:
            continue
        metric = match.group("metric")
        elapsed_ms = int(match.group("elapsed"))
        app_metrics.setdefault(metric, []).append(elapsed_ms)

def summarize(values):
    values = sorted(values)
    return {
        "count": len(values),
        "min_ms": min(values),
        "median_ms": round(statistics.median(values), 1),
        "avg_ms": round(statistics.mean(values), 1),
        "p95_ms": values[max(math.ceil(len(values) * 0.95) - 1, 0)],
        "max_ms": max(values),
    }

summary = {
    "scenario": scenario,
    "output_bytes": tail_capture.stat().st_size,
    "sequence_count": len(seqs),
    "sequence_first": seqs[0] if seqs else None,
    "sequence_last": seqs[-1] if seqs else None,
    "sequence_complete": bool(seqs) and seqs == list(range(1, len(seqs) + 1)),
    "expected_lines": expected_lines,
    "lines_match_expected": len(seqs) == expected_lines,
    "frame_last": frames[-1] if frames else None,
    "frame_match_expected": (frames[-1] if frames else None) == expected_frame if expected_frame else True,
}
if tail_rows:
    elapsed = [row[0] for row in tail_rows]
    summary["tail_samples"] = len(tail_rows)
    summary["tail_min_ms"] = min(elapsed)
    summary["tail_median_ms"] = round(statistics.median(elapsed), 1)
    summary["tail_avg_ms"] = round(statistics.mean(elapsed), 1)
    summary["tail_p95_ms"] = sorted(elapsed)[max(math.ceil(len(elapsed) * 0.95) - 1, 0)]
    summary["tail_max_ms"] = max(elapsed)
    summary["tail_output_bytes_max"] = max(row[1] for row in tail_rows)
if cli_metrics:
    summary["cli_metrics"] = {metric: summarize(values) for metric, values in sorted(cli_metrics.items()) if values}
if app_metrics:
    summary["app_metrics"] = {metric: summarize(values) for metric, values in sorted(app_metrics.items()) if values}
if mode_counts:
    summary["tail_modes"] = mode_counts
print(json.dumps(summary))
PY
}

run_viewer_repaint_scenario() {
  local scenario="repaint_viewer"
  local tail_timings_path="$WORK_ROOT/${scenario}-tail.tsv"
  local cli_metrics_path="$WORK_ROOT/${scenario}-cli.log"
  local command="python3 '$FIXTURE_SCRIPT' --mode repaint --frames $VIEWER_REPAINT_FRAMES --rows $VIEWER_REPAINT_ROWS --width 72 --sleep-ms $VIEWER_REPAINT_SLEEP_MS"
  local command_output session_id session_dir output_log tail_capture_path

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=launch"
  command_output="$(env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal command --backend "$TERMINAL_BACKEND" --command "$command" --title "stress-${scenario}")"
  session_id="$(extract_session_id "$command_output")"
  [[ -n "$session_id" ]] || { echo "Failed to parse session ID for scenario $scenario" >&2; exit 1; }

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=wait_ready session=$session_id"
  wait_for_owner_ready "$session_id"
  session_dir="$(resolve_session_dir "$session_id" 60)"
  output_log="$session_dir/output.log"
  tail_capture_path="$WORK_ROOT/${scenario}-tail.txt"

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=open_viewer session=$session_id"
  env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal show "$session_id" --viewer >/dev/null
  wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=viewer"

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=tail_samples session=$session_id"
  run_tail_samples "$session_id" "$scenario" "$tail_timings_path" "$cli_metrics_path"

  local done_pattern="FIXTURE_DONE mode=repaint emitted=$((VIEWER_REPAINT_FRAMES * VIEWER_REPAINT_ROWS))"
  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=wait_done session=$session_id"
  wait_for_tail_pattern "$session_id" "$done_pattern" "$(((VIEWER_REPAINT_FRAMES * VIEWER_REPAINT_ROWS) + 200))" 180
  capture_terminal_tail "$session_id" "$(((VIEWER_REPAINT_FRAMES * VIEWER_REPAINT_ROWS) + 200))" "$tail_capture_path"
  wait_for_log_pattern "spaces: perf metric=terminal_viewer_output_present .*target=session=${session_id} .*success=1" 30

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=summarize session=$session_id"
  python3 - "$scenario" "$tail_capture_path" "$((VIEWER_REPAINT_FRAMES * VIEWER_REPAINT_ROWS))" "$VIEWER_REPAINT_FRAMES" "$tail_timings_path" "$cli_metrics_path" "$APP_LOG" "$session_id" >"$WORK_ROOT/${scenario}-summary.json" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

scenario = sys.argv[1]
tail_capture = Path(sys.argv[2])
expected_lines = int(sys.argv[3])
expected_frame = int(sys.argv[4])
tail_timings_path = Path(sys.argv[5])
cli_metrics_path = Path(sys.argv[6])
app_log_path = Path(sys.argv[7])
session_id = sys.argv[8]
text = tail_capture.read_text(encoding="utf-8", errors="replace")
seq_pattern = re.compile(r"SEQ (\d{8})")
frame_pattern = re.compile(r"FRAME (\d{6})")
perf_pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
mode_pattern = re.compile(r"mode=(?P<mode>\S+)")
seqs = [int(match.group(1)) for match in seq_pattern.finditer(text)]
frames = [int(match.group(1)) for match in frame_pattern.finditer(text)]
tail_rows = []
if tail_timings_path.exists():
    for row in tail_timings_path.read_text(encoding="utf-8").splitlines():
        if not row:
            continue
        _, elapsed_ms, output_bytes = row.split("\t")
        tail_rows.append((int(elapsed_ms), int(output_bytes)))

cli_metrics = {}
app_metrics = {}
mode_counts = {}
if cli_metrics_path.exists():
    for raw_line in cli_metrics_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = perf_pattern.match(raw_line.strip())
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        elapsed_ms = int(match.group("elapsed"))
        cli_metrics.setdefault(metric, []).append(elapsed_ms)
        detail = match.group("detail") or ""
        if metric == "terminal_tail_read":
            mode_match = mode_pattern.search(detail)
            if mode_match:
                mode = mode_match.group("mode")
                mode_counts[mode] = mode_counts.get(mode, 0) + 1
if app_log_path.exists():
    for raw_line in app_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = perf_pattern.match(raw_line.strip())
        if not match or match.group("success") != "1":
            continue
        target = match.group("target")
        if f"session={session_id}" not in target:
            continue
        metric = match.group("metric")
        elapsed_ms = int(match.group("elapsed"))
        app_metrics.setdefault(metric, []).append(elapsed_ms)

def summarize(values):
    values = sorted(values)
    return {
        "count": len(values),
        "min_ms": min(values),
        "median_ms": round(statistics.median(values), 1),
        "avg_ms": round(statistics.mean(values), 1),
        "p95_ms": values[max(math.ceil(len(values) * 0.95) - 1, 0)],
        "max_ms": max(values),
    }

summary = {
    "scenario": scenario,
    "output_bytes": tail_capture.stat().st_size,
    "sequence_count": len(seqs),
    "sequence_first": seqs[0] if seqs else None,
    "sequence_last": seqs[-1] if seqs else None,
    "sequence_complete": bool(seqs) and seqs == list(range(1, len(seqs) + 1)),
    "expected_lines": expected_lines,
    "lines_match_expected": len(seqs) == expected_lines,
    "frame_last": frames[-1] if frames else None,
    "frame_match_expected": (frames[-1] if frames else None) == expected_frame if expected_frame else True,
}
if tail_rows:
    elapsed = [row[0] for row in tail_rows]
    summary["tail_samples"] = len(tail_rows)
    summary["tail_min_ms"] = min(elapsed)
    summary["tail_median_ms"] = round(statistics.median(elapsed), 1)
    summary["tail_avg_ms"] = round(statistics.mean(elapsed), 1)
    summary["tail_p95_ms"] = sorted(elapsed)[max(math.ceil(len(elapsed) * 0.95) - 1, 0)]
    summary["tail_max_ms"] = max(elapsed)
    summary["tail_output_bytes_max"] = max(row[1] for row in tail_rows)
if cli_metrics:
    summary["cli_metrics"] = {metric: summarize(values) for metric, values in sorted(cli_metrics.items()) if values}
if app_metrics:
    summary["app_metrics"] = {metric: summarize(values) for metric, values in sorted(app_metrics.items()) if values}
if mode_counts:
    summary["tail_modes"] = mode_counts
print(json.dumps(summary))
PY
}

run_viewer_scrollback_repaint_scenario() {
  local scenario="scrollback_repaint"
  local tail_timings_path="$WORK_ROOT/${scenario}-tail.tsv"
  local cli_metrics_path="$WORK_ROOT/${scenario}-cli.log"
  local expected_lines=$((SCROLLBACK_REPAINT_FRAMES * (SCROLLBACK_HISTORY_ROWS + SCROLLBACK_REPAINT_ROWS)))
  local command="python3 '$FIXTURE_SCRIPT' --mode scrollback_repaint --frames $SCROLLBACK_REPAINT_FRAMES --rows $SCROLLBACK_REPAINT_ROWS --history-rows $SCROLLBACK_HISTORY_ROWS --width 72 --sleep-ms $SCROLLBACK_REPAINT_SLEEP_MS"
  local command_output session_id session_dir tail_capture_path

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=launch"
  command_output="$(env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal command --backend "$TERMINAL_BACKEND" --command "$command" --title "stress-${scenario}")"
  session_id="$(extract_session_id "$command_output")"
  [[ -n "$session_id" ]] || { echo "Failed to parse session ID for scenario $scenario" >&2; exit 1; }

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=wait_ready session=$session_id"
  wait_for_owner_ready "$session_id"
  session_dir="$(resolve_session_dir "$session_id" 60)"
  tail_capture_path="$WORK_ROOT/${scenario}-tail.txt"

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=open_viewer session=$session_id"
  env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" terminal show "$session_id" --viewer >/dev/null
  wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=viewer"

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=tail_samples session=$session_id"
  run_tail_samples "$session_id" "$scenario" "$tail_timings_path" "$cli_metrics_path"

  local done_pattern="FIXTURE_DONE mode=scrollback_repaint emitted=${expected_lines}"
  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=wait_done session=$session_id"
  wait_for_tail_pattern "$session_id" "$done_pattern" "$((expected_lines + 200))" 180
  capture_terminal_tail "$session_id" "$((expected_lines + 200))" "$tail_capture_path"
  wait_for_log_pattern "spaces: perf metric=terminal_viewer_output_present .*target=session=${session_id} .*success=1" 30

  echo "phase backend=$TERMINAL_BACKEND scenario=$scenario action=summarize session=$session_id"
  python3 - "$scenario" "$tail_capture_path" "$expected_lines" "$SCROLLBACK_REPAINT_FRAMES" "$tail_timings_path" "$cli_metrics_path" "$APP_LOG" "$session_id" >"$WORK_ROOT/${scenario}-summary.json" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

scenario = sys.argv[1]
tail_capture = Path(sys.argv[2])
expected_lines = int(sys.argv[3])
expected_frame = int(sys.argv[4])
tail_timings_path = Path(sys.argv[5])
cli_metrics_path = Path(sys.argv[6])
app_log_path = Path(sys.argv[7])
session_id = sys.argv[8]
text = tail_capture.read_text(encoding="utf-8", errors="replace")
seq_pattern = re.compile(r"(?:SEQ|HISTORY) (\d{8})")
frame_pattern = re.compile(r"FRAME (\d{6})")
perf_pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
mode_pattern = re.compile(r"mode=(?P<mode>\S+)")
seqs = [int(match.group(1)) for match in seq_pattern.finditer(text)]
frames = [int(match.group(1)) for match in frame_pattern.finditer(text)]
tail_rows = []
if tail_timings_path.exists():
    for row in tail_timings_path.read_text(encoding="utf-8").splitlines():
        if not row:
            continue
        _, elapsed_ms, output_bytes = row.split("\t")
        tail_rows.append((int(elapsed_ms), int(output_bytes)))

cli_metrics = {}
app_metrics = {}
mode_counts = {}
if cli_metrics_path.exists():
    for raw_line in cli_metrics_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = perf_pattern.match(raw_line.strip())
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        elapsed_ms = int(match.group("elapsed"))
        cli_metrics.setdefault(metric, []).append(elapsed_ms)
        detail = match.group("detail") or ""
        if metric == "terminal_tail_read":
            mode_match = mode_pattern.search(detail)
            if mode_match:
                mode = mode_match.group("mode")
                mode_counts[mode] = mode_counts.get(mode, 0) + 1
if app_log_path.exists():
    for raw_line in app_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = perf_pattern.match(raw_line.strip())
        if not match or match.group("success") != "1":
            continue
        target = match.group("target")
        if f"session={session_id}" not in target:
            continue
        metric = match.group("metric")
        elapsed_ms = int(match.group("elapsed"))
        app_metrics.setdefault(metric, []).append(elapsed_ms)

def summarize(values):
    values = sorted(values)
    return {
        "count": len(values),
        "min_ms": min(values),
        "median_ms": round(statistics.median(values), 1),
        "avg_ms": round(statistics.mean(values), 1),
        "p95_ms": values[max(math.ceil(len(values) * 0.95) - 1, 0)],
        "max_ms": max(values),
    }

summary = {
    "scenario": scenario,
    "output_bytes": tail_capture.stat().st_size,
    "sequence_count": len(seqs),
    "sequence_first": seqs[0] if seqs else None,
    "sequence_last": seqs[-1] if seqs else None,
    "sequence_complete": bool(seqs) and seqs == list(range(1, len(seqs) + 1)),
    "expected_lines": expected_lines,
    "lines_match_expected": len(seqs) == expected_lines,
    "frame_last": frames[-1] if frames else None,
    "frame_match_expected": (frames[-1] if frames else None) == expected_frame if expected_frame else True,
}
if tail_rows:
    elapsed = [row[0] for row in tail_rows]
    summary["tail_samples"] = len(tail_rows)
    summary["tail_min_ms"] = min(elapsed)
    summary["tail_median_ms"] = round(statistics.median(elapsed), 1)
    summary["tail_avg_ms"] = round(statistics.mean(elapsed), 1)
    summary["tail_p95_ms"] = sorted(elapsed)[max(math.ceil(len(elapsed) * 0.95) - 1, 0)]
    summary["tail_max_ms"] = max(elapsed)
    summary["tail_output_bytes_max"] = max(row[1] for row in tail_rows)
if cli_metrics:
    summary["cli_metrics"] = {metric: summarize(values) for metric, values in sorted(cli_metrics.items()) if values}
if app_metrics:
    summary["app_metrics"] = {metric: summarize(values) for metric, values in sorted(app_metrics.items()) if values}
if mode_counts:
    summary["tail_modes"] = mode_counts
print(json.dumps(summary))
PY
}

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
[[ -x "$FIXTURE_SCRIPT" ]] || chmod +x "$FIXTURE_SCRIPT"

scenario_enabled() {
  local name="$1"
  [[ " $SCENARIOS " == *" $name "* ]]
}

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"
: >"$RESOURCE_SAMPLES_PATH"

cd "$REPO_ROOT"
"$SETUP_GHOSTTYKIT"

echo "phase backend=$TERMINAL_BACKEND action=prelaunch_kill"
pkill -x SpacesApp >/dev/null 2>&1 || true
pkill -f "$SPACES_APP" >/dev/null 2>&1 || true
echo "phase backend=$TERMINAL_BACKEND action=launch_app"
env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3
echo "phase backend=$TERMINAL_BACKEND action=start_sampler pid=$APP_PID"
RESOURCE_SAMPLER_PID="$(start_resource_sampler "$APP_PID" "$RESOURCE_SAMPLES_PATH")"
echo "phase backend=$TERMINAL_BACKEND action=start_scenarios"

if scenario_enabled "lines"; then
  run_scenario "lines" "python3 '$FIXTURE_SCRIPT' --mode lines --lines $LINE_LINES --width 80 --flush-every 50" "$LINE_LINES" 0
fi
if scenario_enabled "repaint"; then
  run_scenario "repaint" "python3 '$FIXTURE_SCRIPT' --mode repaint --frames $REPAINT_FRAMES --rows $REPAINT_ROWS --width 72 --sleep-ms $REPAINT_SLEEP_MS" "$((REPAINT_FRAMES * REPAINT_ROWS))" "$REPAINT_FRAMES"
fi
if scenario_enabled "mixed"; then
  run_scenario "mixed" "python3 '$FIXTURE_SCRIPT' --mode mixed --frames $MIXED_FRAMES --rows $MIXED_ROWS --width 72 --sleep-ms $MIXED_SLEEP_MS" "$((MIXED_FRAMES * MIXED_ROWS))" "$MIXED_FRAMES"
fi
if [[ "$SUPPORTS_VIEWER_STRESS" == "1" ]] && scenario_enabled "repaint_viewer"; then
  run_viewer_repaint_scenario
fi
if [[ "$SUPPORTS_VIEWER_STRESS" == "1" ]] && scenario_enabled "scrollback_repaint"; then
  run_viewer_scrollback_repaint_scenario
fi

python3 - "$WORK_ROOT" "$APP_LOG" "$SUMMARY_PATH" "$METRICS_PATH" "$TERMINAL_BACKEND" "$RESOURCE_SAMPLES_PATH" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

work_root = Path(sys.argv[1])
app_log = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
metrics_path = Path(sys.argv[4])
backend = sys.argv[5]
resource_samples_path = Path(sys.argv[6])

scenario_summaries = []
for path in sorted(work_root.glob("*-summary.json")):
    scenario_summaries.append(json.loads(path.read_text(encoding="utf-8")))

pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
metrics = {}
for raw_line in app_log.read_text(encoding="utf-8", errors="replace").splitlines():
    match = pattern.match(raw_line.strip())
    if not match or match.group("success") != "1":
        continue
    metric = match.group("metric")
    metrics.setdefault(metric, []).append(int(match.group("elapsed")))

def summarize(values):
    values = sorted(values)
    return {
        "count": len(values),
        "min_ms": min(values),
        "avg_ms": round(statistics.mean(values), 1),
        "p95_ms": values[max(math.ceil(len(values) * 0.95) - 1, 0)],
        "max_ms": max(values),
    }

payload = {
    "backend": backend,
    "scenarios": scenario_summaries,
    "metrics": {metric: summarize(values) for metric, values in sorted(metrics.items()) if values},
}

resource_rows = []
if resource_samples_path.exists():
    for row in resource_samples_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not row:
            continue
        ts_ms, rss_kb, cpu_pct = row.split(",", 2)
        resource_rows.append((int(ts_ms), int(rss_kb), float(cpu_pct)))
if resource_rows:
    payload["resource"] = {
        "samples": len(resource_rows),
        "rss_kb_avg": round(statistics.mean(row[1] for row in resource_rows), 1),
        "rss_kb_max": max(row[1] for row in resource_rows),
        "cpu_pct_avg": round(statistics.mean(row[2] for row in resource_rows), 1),
        "cpu_pct_max": max(row[2] for row in resource_rows),
    }

lines = [f"Built-in terminal stress profile [backend={backend}]", ""]
for scenario in scenario_summaries:
    lines.append(
        f"{scenario['scenario']}: output={scenario['output_bytes']}B seq={scenario['sequence_count']} "
        f"complete={1 if scenario['sequence_complete'] else 0} expected={1 if scenario['lines_match_expected'] else 0} "
        f"tail_min={scenario.get('tail_min_ms', 0)}ms tail_median={scenario.get('tail_median_ms', 0)}ms "
        f"tail_avg={scenario.get('tail_avg_ms', 0)}ms tail_p95={scenario.get('tail_p95_ms', 0)}ms tail_max={scenario.get('tail_max_ms', 0)}ms "
        f"frame_ok={1 if scenario.get('frame_match_expected', True) else 0}"
    )
    if "tail_modes" in scenario:
        modes = ",".join(f"{mode}:{count}" for mode, count in sorted(scenario["tail_modes"].items()))
        lines.append(f"  tail_modes: {modes}")
    cli_metrics = scenario.get("cli_metrics", {})
    app_metrics = scenario.get("app_metrics", {})
    for metric in ("terminal_tail_read", "terminal_tail_command"):
        if metric in cli_metrics:
            summary = cli_metrics[metric]
            lines.append(
                f"  {metric}: count={summary['count']} min={summary['min_ms']}ms median={summary['median_ms']}ms "
                f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms"
            )
    for metric in (
        "terminal_viewer_output_present",
        "terminal_viewer_refresh_wait_to_render",
        "terminal_viewer_refresh_render_output",
        "terminal_viewer_refresh_text_assign",
        "terminal_viewer_refresh_layout",
        "terminal_viewer_refresh_viewport_restore",
    ):
        if metric in app_metrics:
            summary = app_metrics[metric]
            lines.append(
                f"  {metric}: count={summary['count']} min={summary['min_ms']}ms median={summary['median_ms']}ms "
                f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms"
            )
for metric, summary in payload["metrics"].items():
    lines.append(
        f"{metric}: count={summary['count']} min={summary['min_ms']}ms avg={summary['avg_ms']}ms "
        f"p95={summary['p95_ms']}ms max={summary['max_ms']}ms"
    )
if "resource" in payload:
    resource = payload["resource"]
    lines.append(
        f"resource: rss_avg={resource['rss_kb_avg']}KB rss_max={resource['rss_kb_max']}KB "
        f"cpu_avg={resource['cpu_pct_avg']} cpu_max={resource['cpu_pct_max']} samples={resource['samples']}"
    )

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
metrics_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
print("\nArtifacts:")
print(f"  app log:  {app_log}")
print(f"  summary:  {summary_path}")
print(f"  metrics:  {metrics_path}")
PY
