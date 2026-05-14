#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
STRESS_SCRIPT="$SCRIPT_DIR/profile_built_in_terminal_stress.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-renderer-compare.XXXXXX")}"
GHOSTTY_ROOT="$WORK_ROOT/ghostty-embedded"
CANVAS_ROOT="$WORK_ROOT/script-pty"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"

REPAINT_FRAMES="${REPAINT_FRAMES:-600}"
REPAINT_ROWS="${REPAINT_ROWS:-24}"
REPAINT_SLEEP_MS="${REPAINT_SLEEP_MS:-2}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"

run_backend() {
  local backend="$1"
  local backend_root="$2"
  local scenarios="$3"
  mkdir -p "$backend_root"
  env \
    TERMINAL_BACKEND="$backend" \
    WORK_ROOT="$backend_root" \
    SCENARIOS="$scenarios" \
    REPAINT_FRAMES="$REPAINT_FRAMES" \
    REPAINT_ROWS="$REPAINT_ROWS" \
    VIEWER_REPAINT_FRAMES="$REPAINT_FRAMES" \
    VIEWER_REPAINT_ROWS="$REPAINT_ROWS" \
    VIEWER_REPAINT_SLEEP_MS="$REPAINT_SLEEP_MS" \
    SAMPLE_INTERVAL_SECONDS="$SAMPLE_INTERVAL_SECONDS" \
    "$STRESS_SCRIPT" >/dev/null
}

cd "$REPO_ROOT"
run_backend "ghostty-embedded" "$GHOSTTY_ROOT" "repaint"
run_backend "script-pty" "$CANVAS_ROOT" "repaint_viewer"

python3 - "$GHOSTTY_ROOT" "$CANVAS_ROOT" "$SUMMARY_PATH" "$METRICS_PATH" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

ghostty_root = Path(sys.argv[1])
canvas_root = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
metrics_path = Path(sys.argv[4])

perf_pattern = re.compile(
    r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$"
)
ts_pattern = re.compile(r"\bts_ms=(\d+)\b")


def summarize(values):
    values = sorted(values)
    return {
        "count": len(values),
        "min_ms": min(values),
        "avg_ms": round(statistics.mean(values), 1),
        "median_ms": round(statistics.median(values), 1),
        "p95_ms": values[max(math.ceil(len(values) * 0.95) - 1, 0)],
        "p99_ms": values[max(math.ceil(len(values) * 0.99) - 1, 0)],
        "max_ms": max(values),
    }


def load_backend(root: Path, metric_name: str, scenario_name: str):
    app_log = root / "spaces-app.log"
    metrics_json = root / "metrics.json"
    payload = json.loads(metrics_json.read_text(encoding="utf-8"))
    scenario = next(item for item in payload["scenarios"] if item["scenario"] == scenario_name)

    render_elapsed = []
    render_timestamps = []
    for raw_line in app_log.read_text(encoding="utf-8", errors="replace").splitlines():
        match = perf_pattern.match(raw_line.strip())
        if not match or match.group("success") != "1":
            continue
        if match.group("metric") != metric_name:
            continue
        render_elapsed.append(int(match.group("elapsed")))
        detail = match.group("detail") or ""
        ts_match = ts_pattern.search(detail)
        if ts_match:
            render_timestamps.append(int(ts_match.group(1)))

    intervals = [
        render_timestamps[index] - render_timestamps[index - 1]
        for index in range(1, len(render_timestamps))
        if render_timestamps[index] >= render_timestamps[index - 1]
    ]

    result = {
        "metric": metric_name,
        "scenario": scenario_name,
        "render_latency_ms": summarize(render_elapsed) if render_elapsed else None,
        "frame_interval_ms": summarize(intervals) if intervals else None,
        "frame_jank_over_32ms": sum(1 for value in intervals if value > 32),
        "frame_jank_over_50ms": sum(1 for value in intervals if value > 50),
        "resource": payload.get("resource"),
        "stress_scenario": scenario,
        "aggregate_metrics": payload.get("metrics", {}),
    }
    return result


ghostty = load_backend(ghostty_root, "terminal_surface_refresh", "repaint")
canvas = load_backend(canvas_root, "terminal_viewer_output_present", "repaint_viewer")
canvas_stage_metrics = canvas["stress_scenario"].get("app_metrics", {})

comparison = {
    "ghostty_embedded": ghostty,
    "script_pty_canvas": canvas,
}
metrics_path.write_text(json.dumps(comparison, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def fmt(summary):
    if not summary:
        return "n/a"
    return (
        f"count={summary['count']} min={summary['min_ms']}ms avg={summary['avg_ms']}ms "
        f"median={summary['median_ms']}ms p95={summary['p95_ms']}ms p99={summary['p99_ms']}ms max={summary['max_ms']}ms"
    )


def fmt_resource(summary):
    if not summary:
        return "n/a"
    return (
        f"rss_avg={summary['rss_kb_avg']}KB rss_max={summary['rss_kb_max']}KB "
        f"cpu_avg={summary['cpu_pct_avg']} cpu_max={summary['cpu_pct_max']} samples={summary['samples']}"
    )


def scenario_line(label, data):
    scenario = data["stress_scenario"]
    return (
        f"{label}: output={scenario['output_bytes']}B tail_avg={scenario.get('tail_avg_ms', 0)}ms "
        f"tail_p95={scenario.get('tail_p95_ms', 0)}ms tail_max={scenario.get('tail_max_ms', 0)}ms "
        f"complete={1 if scenario['sequence_complete'] else 0} expected={1 if scenario['lines_match_expected'] else 0}"
    )


lines = [
    "Renderer compare: repaint smoothness",
    "",
    "ghostty-embedded:",
    f"  scenario: {scenario_line('repaint', ghostty)}",
    f"  render metric terminal_surface_refresh: {fmt(ghostty['render_latency_ms'])}",
    f"  frame interval: {fmt(ghostty['frame_interval_ms'])}",
    f"  jank: >32ms={ghostty['frame_jank_over_32ms']} >50ms={ghostty['frame_jank_over_50ms']}",
    f"  resources: {fmt_resource(ghostty['resource'])}",
    "",
    "script-pty canvas:",
    f"  scenario: {scenario_line('repaint_viewer', canvas)}",
    f"  render metric terminal_viewer_output_present: {fmt(canvas['render_latency_ms'])}",
    f"  frame interval: {fmt(canvas['frame_interval_ms'])}",
    f"  jank: >32ms={canvas['frame_jank_over_32ms']} >50ms={canvas['frame_jank_over_50ms']}",
    f"  stage render_output: {fmt(canvas_stage_metrics.get('terminal_viewer_refresh_render_output'))}",
    f"  stage text_assign: {fmt(canvas_stage_metrics.get('terminal_viewer_refresh_text_assign'))}",
    f"  stage layout: {fmt(canvas_stage_metrics.get('terminal_viewer_refresh_layout'))}",
    f"  stage viewport_restore: {fmt(canvas_stage_metrics.get('terminal_viewer_refresh_viewport_restore'))}",
    f"  resources: {fmt_resource(canvas['resource'])}",
    "",
    f"artifacts: ghostty={ghostty_root} canvas={canvas_root} metrics={metrics_path}",
]

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
PY
