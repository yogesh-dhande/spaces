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
FIXTURE_SCRIPT="$SCRIPT_DIR/terminal_stress_fixture.py"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-soak.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
SAMPLES_PATH="$WORK_ROOT/samples.tsv"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
APP_PID=""

DURATION_SECONDS="${DURATION_SECONDS:-300}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-5}"
FRAMES_PER_SECOND="${FRAMES_PER_SECOND:-8}"
ROWS="${ROWS:-20}"
SOAK_MODE="${SOAK_MODE:-repaint_viewer}"
APP_PID=""

cleanup() {
  release_terminal_harness_lock
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

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

python_ms_now() {
  python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
}

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"
require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
[[ -x "$FIXTURE_SCRIPT" ]] || chmod +x "$FIXTURE_SCRIPT"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT"

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

frames=$((DURATION_SECONDS * FRAMES_PER_SECOND))
sleep_ms=$((1000 / FRAMES_PER_SECOND))
fixture_mode="mixed"
session_title="soak-mixed"
if [[ "$SOAK_MODE" == "repaint_viewer" ]]; then
  fixture_mode="repaint"
  session_title="soak-repaint-viewer"
fi
command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command --backend ghostty-embedded --command "python3 '$FIXTURE_SCRIPT' --mode $fixture_mode --frames $frames --rows $ROWS --width 72 --sleep-ms $sleep_ms" --title "$session_title")"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse soak session ID" >&2; exit 1; }
wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=owner"
if [[ "$SOAK_MODE" == "repaint_viewer" ]]; then
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal show "$session_id" --viewer >/dev/null
  wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=viewer"
fi

session_dir="$RUNTIME_DIR/terminal/sessions/$session_id"
output_log="$session_dir/output.log"

echo -e "elapsed_s\trss_kb\tcpu_percent\ttail_ms\toutput_bytes\tviewer_present_count" >"$SAMPLES_PATH"
started_at="$(date +%s)"
while true; do
  now="$(date +%s)"
  elapsed=$((now - started_at))
  if (( elapsed >= DURATION_SECONDS )); then
    break
  fi
  read -r rss_kb cpu_percent <<<"$(ps -o rss=,%cpu= -p "$APP_PID" | awk '{print $1, $2}')"
  tail_started="$(python_ms_now)"
  tail_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal tail "$session_id" --lines 120)"
  tail_finished="$(python_ms_now)"
  tail_ms=$((tail_finished - tail_started))
  output_bytes="$(wc -c <"$output_log" | tr -d ' ')"
  viewer_present_count="$(grep -Ec "spaces: perf metric=terminal_viewer_output_present .*target=session=${session_id} .*success=1" "$APP_LOG" || true)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$elapsed" "${rss_kb:-0}" "${cpu_percent:-0}" "$tail_ms" "$output_bytes" "$viewer_present_count" >>"$SAMPLES_PATH"
  sleep "$SAMPLE_INTERVAL_SECONDS"
done

wait_for_file_pattern "$output_log" "FIXTURE_DONE mode=${fixture_mode} emitted=$((frames * ROWS))" 120

python3 - "$SAMPLES_PATH" "$output_log" "$frames" "$ROWS" "$SUMMARY_PATH" "$METRICS_PATH" "$APP_LOG" "$session_id" "$SOAK_MODE" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

samples_path = Path(sys.argv[1])
output_log = Path(sys.argv[2])
frames = int(sys.argv[3])
rows = int(sys.argv[4])
summary_path = Path(sys.argv[5])
metrics_path = Path(sys.argv[6])
app_log_path = Path(sys.argv[7])
session_id = sys.argv[8]
soak_mode = sys.argv[9]
perf_pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")

rows_out = []
for row in samples_path.read_text(encoding="utf-8").splitlines()[1:]:
    elapsed_s, rss_kb, cpu_percent, tail_ms, output_bytes, viewer_present_count = row.split("\t")
    rows_out.append(
        {
            "elapsed_s": int(elapsed_s),
            "rss_kb": int(float(rss_kb)),
            "cpu_percent": float(cpu_percent),
            "tail_ms": int(tail_ms),
            "output_bytes": int(output_bytes),
            "viewer_present_count": int(viewer_present_count),
        }
    )

text = output_log.read_text(encoding="utf-8", errors="replace")
seqs = [int(match.group(1)) for match in re.finditer(r"SEQ (\d{8})", text)]
frames_seen = [int(match.group(1)) for match in re.finditer(r"FRAME (\d{6})", text)]
app_metrics = {}
if app_log_path.exists():
    for raw_line in app_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = perf_pattern.match(raw_line.strip())
        if not match or match.group("success") != "1":
            continue
        if f"session={session_id}" not in match.group("target"):
            continue
        metric = match.group("metric")
        app_metrics.setdefault(metric, []).append(int(match.group("elapsed")))

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

def summarize_phases(values):
    if len(values) < 2:
        return {}
    phase_size = max(len(values) // 3, 1)
    early = values[:phase_size]
    late = values[-phase_size:]
    return {
        "early": summarize(early),
        "late": summarize(late),
    }

def summarize_sample_phases(rows, key):
    if len(rows) < 2:
        return {}
    phase_size = max(len(rows) // 3, 1)
    early = [row[key] for row in rows[:phase_size]]
    late = [row[key] for row in rows[-phase_size:]]
    return {
        "early": summarize(early),
        "late": summarize(late),
    }

payload = {
    "soak_mode": soak_mode,
    "duration_seconds": rows_out[-1]["elapsed_s"] if rows_out else 0,
    "sample_count": len(rows_out),
    "rss_kb_max": max((row["rss_kb"] for row in rows_out), default=0),
    "cpu_percent_avg": round(statistics.mean((row["cpu_percent"] for row in rows_out)), 1) if rows_out else 0,
    "tail_ms_avg": round(statistics.mean((row["tail_ms"] for row in rows_out)), 1) if rows_out else 0,
    "tail_ms_max": max((row["tail_ms"] for row in rows_out), default=0),
    "output_bytes_final": output_log.stat().st_size,
    "viewer_present_count_final": rows_out[-1]["viewer_present_count"] if rows_out else 0,
    "sequence_count": len(seqs),
    "sequence_complete": bool(seqs) and seqs == list(range(1, len(seqs) + 1)),
    "frame_last": frames_seen[-1] if frames_seen else None,
    "frame_match_expected": (frames_seen[-1] if frames_seen else None) == frames,
    "expected_lines": frames * rows,
    "lines_match_expected": len(seqs) == frames * rows,
}
if rows_out:
    payload["sample_phases"] = {
        "tail_ms": summarize_sample_phases(rows_out, "tail_ms"),
        "cpu_percent": summarize_sample_phases(rows_out, "cpu_percent"),
        "rss_kb": summarize_sample_phases(rows_out, "rss_kb"),
    }
if app_metrics:
    payload["app_metrics"] = {metric: summarize(values) for metric, values in sorted(app_metrics.items()) if values}
    viewer_values = app_metrics.get("terminal_viewer_output_present")
    if viewer_values:
        payload["app_metric_phases"] = {
            "terminal_viewer_output_present": summarize_phases(viewer_values)
        }
summary = [
    "Built-in terminal soak profile",
    "",
    f"mode={payload['soak_mode']} duration={payload['duration_seconds']}s samples={payload['sample_count']}",
    f"rss_max={payload['rss_kb_max']}KB cpu_avg={payload['cpu_percent_avg']} tail_avg={payload['tail_ms_avg']}ms tail_max={payload['tail_ms_max']}ms",
    f"output={payload['output_bytes_final']}B seq={payload['sequence_count']} complete={1 if payload['sequence_complete'] else 0} expected={1 if payload['lines_match_expected'] else 0} frame_ok={1 if payload['frame_match_expected'] else 0}",
]
if "app_metrics" in payload and "terminal_viewer_output_present" in payload["app_metrics"]:
    viewer = payload["app_metrics"]["terminal_viewer_output_present"]
    summary.append(
        f"viewer_present: count={viewer['count']} min={viewer['min_ms']}ms median={viewer['median_ms']}ms avg={viewer['avg_ms']}ms p95={viewer['p95_ms']}ms max={viewer['max_ms']}ms"
    )
if "app_metric_phases" in payload and "terminal_viewer_output_present" in payload["app_metric_phases"]:
    phases = payload["app_metric_phases"]["terminal_viewer_output_present"]
    if phases:
        early = phases["early"]
        late = phases["late"]
        summary.append(
            f"viewer_present_phases: early_median={early['median_ms']}ms early_p95={early['p95_ms']}ms late_median={late['median_ms']}ms late_p95={late['p95_ms']}ms"
        )
if "sample_phases" in payload and payload["sample_phases"].get("tail_ms"):
    tail_phases = payload["sample_phases"]["tail_ms"]
    early = tail_phases["early"]
    late = tail_phases["late"]
    summary.append(
        f"tail_phases: early_avg={early['avg_ms']}ms early_max={early['max_ms']}ms late_avg={late['avg_ms']}ms late_max={late['max_ms']}ms"
    )
summary_path.write_text("\n".join(summary) + "\n", encoding="utf-8")
metrics_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
print("\nArtifacts:")
print(f"  samples:  {samples_path}")
print(f"  summary:  {summary_path}")
print(f"  metrics:  {metrics_path}")
PY
