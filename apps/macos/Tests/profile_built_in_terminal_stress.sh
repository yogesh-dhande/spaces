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

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-stress.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
CLI_LOG="$WORK_ROOT/spaces-cli.log"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
APP_PID=""

LINE_LINES="${LINE_LINES:-20000}"
REPAINT_FRAMES="${REPAINT_FRAMES:-250}"
REPAINT_ROWS="${REPAINT_ROWS:-20}"
MIXED_FRAMES="${MIXED_FRAMES:-180}"
MIXED_ROWS="${MIXED_ROWS:-18}"
CODEX_CHURN_HISTORY_LINES="${CODEX_CHURN_HISTORY_LINES:-3200}"
CODEX_CHURN_FRAMES="${CODEX_CHURN_FRAMES:-140}"
CODEX_CHURN_ROWS="${CODEX_CHURN_ROWS:-7}"
CODEX_CHURN_WIDTH="${CODEX_CHURN_WIDTH:-72}"
CODEX_CHURN_SLEEP_MS="${CODEX_CHURN_SLEEP_MS:-8}"
TAIL_SAMPLES="${TAIL_SAMPLES:-5}"
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

ms_now() {
  python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
}

run_tail_samples() {
  local session_id="$1"
  local scenario="$2"
  local output_path="$3"
  local cli_log_path="$4"
  local session_output_log="$5"
  : >"$output_path"
  : >"$cli_log_path"
  for sample_index in $(seq 1 "$TAIL_SAMPLES"); do
    local started_at finished_at elapsed_ms output_log_bytes tail_output tail_output_bytes
    started_at="$(ms_now)"
    tail_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_CLI" terminal tail "$session_id" --lines 80 2>>"$cli_log_path")"
    finished_at="$(ms_now)"
    elapsed_ms=$((finished_at - started_at))
    tail_output_bytes="$(printf '%s' "$tail_output" | wc -c | tr -d ' ')"
    output_log_bytes="$(wc -c <"$session_output_log" | tr -d ' ')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$scenario" "$sample_index" "$elapsed_ms" "$tail_output_bytes" "$output_log_bytes" >>"$output_path"
    sleep 0.2
  done
}

run_scenario() {
  local scenario="$1"
  local command="$2"
  local expected_lines="$3"
  local expected_frame="$4"
  local tail_timings_path="$WORK_ROOT/${scenario}-tail.tsv"
  local final_tail_path="$WORK_ROOT/${scenario}-tail-final.txt"
  local cli_metrics_path="$WORK_ROOT/${scenario}-cli.log"
  local command_output session_id session_dir output_log

  command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command --backend ghostty-embedded --command "$command" --title "stress-${scenario}")"
  session_id="$(extract_session_id "$command_output")"
  [[ -n "$session_id" ]] || { echo "Failed to parse session ID for scenario $scenario" >&2; exit 1; }

  wait_for_log_pattern "spaces: perf metric=terminal_window_summon target=session=${session_id} success=1 .*mode=owner|spaces: perf metric=terminal_window_attach_owner_surface target=session=${session_id} success=1 .*mode=owner"
  session_dir="$RUNTIME_DIR/terminal/sessions/$session_id"
  output_log="$session_dir/output.log"

  run_tail_samples "$session_id" "$scenario" "$tail_timings_path" "$cli_metrics_path" "$output_log"

  local done_pattern="FIXTURE_DONE mode=${scenario} emitted=${expected_lines}"
  wait_for_file_pattern "$output_log" "$done_pattern" 120
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 \
    "$SPACES_CLI" terminal tail "$session_id" --lines 120 >"$final_tail_path" 2>>"$cli_metrics_path"

  python3 - "$scenario" "$output_log" "$expected_lines" "$expected_frame" "$tail_timings_path" "$cli_metrics_path" "$APP_LOG" "$session_id" "$final_tail_path" >"$WORK_ROOT/${scenario}-summary.json" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

scenario = sys.argv[1]
output_log = Path(sys.argv[2])
expected_lines = int(sys.argv[3])
expected_frame = int(sys.argv[4])
tail_timings_path = Path(sys.argv[5])
cli_metrics_path = Path(sys.argv[6])
app_log_path = Path(sys.argv[7])
session_id = sys.argv[8]
final_tail_path = Path(sys.argv[9])
text = output_log.read_text(encoding="utf-8", errors="replace")
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
        _, sample_index, elapsed_ms, tail_output_bytes, output_log_bytes = row.split("\t")
        tail_rows.append(
            {
                "sample_index": int(sample_index),
                "tail_ms": int(elapsed_ms),
                "tail_output_bytes": int(tail_output_bytes),
                "output_log_bytes": int(output_log_bytes),
            }
        )

final_tail_text = final_tail_path.read_text(encoding="utf-8", errors="replace") if final_tail_path.exists() else ""
final_tail_sequences = [int(match.group(1)) for match in seq_pattern.finditer(final_tail_text)]
final_tail_frames = [int(match.group(1)) for match in frame_pattern.finditer(final_tail_text)]

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
    "output_bytes": output_log.stat().st_size,
    "sequence_count": len(seqs),
    "sequence_first": seqs[0] if seqs else None,
    "sequence_last": seqs[-1] if seqs else None,
    "sequence_complete": bool(seqs) and seqs == list(range(1, len(seqs) + 1)),
    "expected_lines": expected_lines,
    "lines_match_expected": len(seqs) == expected_lines,
    "frame_last": frames[-1] if frames else None,
    "frame_match_expected": (frames[-1] if frames else None) == expected_frame if expected_frame else True,
    "tail_final_contains_fixture_done": f"FIXTURE_DONE mode={scenario} emitted={expected_lines}" in final_tail_text,
    "tail_final_contains_footer": "TAIL frame=" in final_tail_text,
    "tail_final_sequence_last": final_tail_sequences[-1] if final_tail_sequences else None,
    "tail_final_frame_last": final_tail_frames[-1] if final_tail_frames else None,
    "tail_final_frame_match_expected": (final_tail_frames[-1] if final_tail_frames else None) == expected_frame if expected_frame else True,
}
if tail_rows:
    elapsed = [row["tail_ms"] for row in tail_rows]
    output_log_sizes = [row["output_log_bytes"] for row in tail_rows]
    tail_output_sizes = [row["tail_output_bytes"] for row in tail_rows]
    summary["tail_samples"] = len(tail_rows)
    summary["tail_min_ms"] = min(elapsed)
    summary["tail_median_ms"] = round(statistics.median(elapsed), 1)
    summary["tail_avg_ms"] = round(statistics.mean(elapsed), 1)
    summary["tail_p95_ms"] = sorted(elapsed)[max(math.ceil(len(elapsed) * 0.95) - 1, 0)]
    summary["tail_max_ms"] = max(elapsed)
    summary["tail_output_bytes_max"] = max(tail_output_sizes)
    summary["tail_observations"] = tail_rows
    summary["output_growth"] = {
        "first_bytes": output_log_sizes[0],
        "last_bytes": output_log_sizes[-1],
        "delta_bytes": output_log_sizes[-1] - output_log_sizes[0],
        "monotonic": all(current >= previous for previous, current in zip(output_log_sizes, output_log_sizes[1:])),
        "max_sample_bytes": max(output_log_sizes),
    }
if cli_metrics:
    summary["cli_metrics"] = {metric: summarize(values) for metric, values in sorted(cli_metrics.items()) if values}
if app_metrics:
    summary["app_metrics"] = {metric: summarize(values) for metric, values in sorted(app_metrics.items()) if values}
if mode_counts:
    summary["tail_modes"] = mode_counts
errors = []
if not summary["sequence_complete"]:
    errors.append(f"{scenario}: sequence markers were not contiguous")
if not summary["lines_match_expected"]:
    errors.append(f"{scenario}: expected {expected_lines} sequence lines but found {len(seqs)}")
if not summary["frame_match_expected"]:
    errors.append(f"{scenario}: expected final frame {expected_frame} but found {summary['frame_last']}")
if not summary["tail_final_contains_fixture_done"]:
    errors.append(f"{scenario}: final tail output did not include FIXTURE_DONE")
if not summary["tail_final_frame_match_expected"]:
    errors.append(f"{scenario}: final tail output did not include frame {expected_frame}")
if scenario == "codex_churn":
    output_growth = summary.get("output_growth") or {}
    if output_growth.get("delta_bytes", 0) <= 0:
        errors.append("codex_churn: output log did not grow during tail sampling")
    if not output_growth.get("monotonic", False):
        errors.append("codex_churn: sampled output growth regressed between tail observations")
    if not summary["tail_final_contains_footer"]:
        errors.append("codex_churn: final tail output did not retain the rewritten footer rows")
if errors:
    raise SystemExit("\n".join(errors))
print(json.dumps(summary))
PY
}

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
[[ -x "$FIXTURE_SCRIPT" ]] || chmod +x "$FIXTURE_SCRIPT"

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT"

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

run_scenario "lines" "python3 '$FIXTURE_SCRIPT' --mode lines --lines $LINE_LINES --width 80 --flush-every 50" "$LINE_LINES" 0
run_scenario "repaint" "python3 '$FIXTURE_SCRIPT' --mode repaint --frames $REPAINT_FRAMES --rows $REPAINT_ROWS --width 72" "$((REPAINT_FRAMES * REPAINT_ROWS))" "$REPAINT_FRAMES"
run_scenario "mixed" "python3 '$FIXTURE_SCRIPT' --mode mixed --frames $MIXED_FRAMES --rows $MIXED_ROWS --width 72" "$((MIXED_FRAMES * MIXED_ROWS))" "$MIXED_FRAMES"
run_scenario "codex_churn" "python3 '$FIXTURE_SCRIPT' --mode codex_churn --lines $CODEX_CHURN_HISTORY_LINES --frames $CODEX_CHURN_FRAMES --rows $CODEX_CHURN_ROWS --width $CODEX_CHURN_WIDTH --sleep-ms $CODEX_CHURN_SLEEP_MS --flush-every 40" "$((CODEX_CHURN_HISTORY_LINES + CODEX_CHURN_FRAMES * CODEX_CHURN_ROWS))" "$CODEX_CHURN_FRAMES"

python3 - "$WORK_ROOT" "$APP_LOG" "$SUMMARY_PATH" "$METRICS_PATH" <<'PY'
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
    "scenarios": scenario_summaries,
    "metrics": {metric: summarize(values) for metric, values in sorted(metrics.items()) if values},
}

lines = ["Built-in terminal stress profile", ""]
for scenario in scenario_summaries:
    lines.append(
        f"{scenario['scenario']}: output={scenario['output_bytes']}B seq={scenario['sequence_count']} "
        f"complete={1 if scenario['sequence_complete'] else 0} expected={1 if scenario['lines_match_expected'] else 0} "
        f"tail_min={scenario.get('tail_min_ms', 0)}ms tail_median={scenario.get('tail_median_ms', 0)}ms "
        f"tail_avg={scenario.get('tail_avg_ms', 0)}ms tail_p95={scenario.get('tail_p95_ms', 0)}ms tail_max={scenario.get('tail_max_ms', 0)}ms "
        f"frame_ok={1 if scenario.get('frame_match_expected', True) else 0} "
        f"tail_final={1 if scenario.get('tail_final_contains_fixture_done') else 0} "
        f"footer={1 if scenario.get('tail_final_contains_footer') else 0} "
        f"growth={scenario.get('output_growth', {}).get('delta_bytes', 0)}B"
    )
    if "tail_modes" in scenario:
        modes = ",".join(f"{mode}:{count}" for mode, count in sorted(scenario["tail_modes"].items()))
        lines.append(f"  tail_modes: {modes}")
    if "output_growth" in scenario:
        growth = scenario["output_growth"]
        lines.append(
            f"  output_growth: first={growth['first_bytes']}B last={growth['last_bytes']}B delta={growth['delta_bytes']}B monotonic={1 if growth['monotonic'] else 0}"
        )
    cli_metrics = scenario.get("cli_metrics", {})
    app_metrics = scenario.get("app_metrics", {})
    for metric in ("terminal_tail_read", "terminal_tail_command"):
        if metric in cli_metrics:
            summary = cli_metrics[metric]
            lines.append(
                f"  {metric}: count={summary['count']} min={summary['min_ms']}ms median={summary['median_ms']}ms "
                f"avg={summary['avg_ms']}ms p95={summary['p95_ms']}ms max={summary['max_ms']}ms"
            )
    for metric in ("terminal_output_write", "terminal_surface_refresh"):
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

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
metrics_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
print("\nArtifacts:")
print(f"  app log:  {app_log}")
print(f"  summary:  {summary_path}")
print(f"  metrics:  {metrics_path}")
PY
