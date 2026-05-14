#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_SCRIPT="$SCRIPT_DIR/profile_built_in_terminal.sh"
STRESS_SCRIPT="$SCRIPT_DIR/profile_built_in_terminal_stress.sh"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-compare.XXXXXX")}"
ITERATIONS="${ITERATIONS:-3}"
RUN_STRESS="${RUN_STRESS:-1}"
BACKENDS="${BACKENDS:-ghostty-embedded script-pty}"

mkdir -p "$WORK_ROOT"

require_executable() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing executable: $path" >&2; exit 1; }
}

require_executable "$PROFILE_SCRIPT"
require_executable "$STRESS_SCRIPT"

run_backend() {
  local backend="$1"
  local backend_root="$WORK_ROOT/$backend"
  mkdir -p "$backend_root"

  echo "Running built-in terminal profile for backend=$backend"
  env \
    WORK_ROOT="$backend_root/profile" \
    ITERATIONS="$ITERATIONS" \
    TERMINAL_BACKEND="$backend" \
    "$PROFILE_SCRIPT" >"$backend_root/profile.stdout"

  if [[ "$RUN_STRESS" == "1" ]]; then
    echo "Running built-in terminal stress profile for backend=$backend"
    env \
      WORK_ROOT="$backend_root/stress" \
      TERMINAL_BACKEND="$backend" \
      "$STRESS_SCRIPT" >"$backend_root/stress.stdout"
  fi
}

for backend in $BACKENDS; do
  run_backend "$backend"
done

python3 - "$WORK_ROOT" "$BACKENDS" "$RUN_STRESS" <<'PY'
import json
import sys
from pathlib import Path

work_root = Path(sys.argv[1])
backends = sys.argv[2].split()
run_stress = sys.argv[3] == "1"

profile_metrics = [
    "terminal_window_attach",
    "terminal_window_summon",
    "terminal_owner_focus_sync",
    "terminal_control_send",
    "terminal_viewer_output_present",
    "terminal_control_takeover",
]
stress_metrics = [
    "terminal_window_attach",
    "terminal_window_summon",
    "terminal_viewer_output_present",
]

def load_json(path: Path):
    if not path.exists():
        raise SystemExit(f"Missing metrics file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))

def metric_cell(summary: dict, metric: str) -> str:
    metrics = summary.get("metrics", {})
    data = metrics.get(metric)
    if not data:
        return "n/a"
    return f"avg={data['avg_ms']}ms p95={data['p95_ms']}ms max={data['max_ms']}ms"

def scenario_cell(summary: dict, scenario_name: str, key: str) -> str:
    for scenario in summary.get("scenarios", []):
        if scenario.get("scenario") == scenario_name:
            value = scenario.get(key)
            if value is None:
                return "n/a"
            return f"{value}ms"
    return "n/a"

profiles = {}
stresses = {}
for backend in backends:
    profiles[backend] = load_json(work_root / backend / "profile" / "metrics.json")
    if run_stress:
        stresses[backend] = load_json(work_root / backend / "stress" / "metrics.json")

lines = ["Built-in terminal backend comparison", ""]
lines.append("Profile metrics:")
for metric in profile_metrics:
    lines.append(f"- {metric}")
    for backend in backends:
        lines.append(f"  {backend}: {metric_cell(profiles[backend], metric)}")

if run_stress:
    lines.append("")
    lines.append("Stress metrics:")
    for metric in stress_metrics:
        lines.append(f"- {metric}")
        for backend in backends:
            lines.append(f"  {backend}: {metric_cell(stresses[backend], metric)}")

    lines.append("")
    lines.append("Stress tail latency by scenario:")
    for scenario_name in ("lines", "repaint", "mixed", "repaint_viewer"):
        lines.append(f"- {scenario_name}")
        for backend in backends:
            lines.append(
                f"  {backend}: avg={scenario_cell(stresses[backend], scenario_name, 'tail_avg_ms')} "
                f"p95={scenario_cell(stresses[backend], scenario_name, 'tail_p95_ms')} "
                f"max={scenario_cell(stresses[backend], scenario_name, 'tail_max_ms')}"
            )

summary = "\n".join(lines) + "\n"
summary_path = work_root / "comparison-summary.txt"
summary_path.write_text(summary, encoding="utf-8")
print(summary, end="")
print("Artifacts:")
for backend in backends:
    print(f"  {backend} profile: {work_root / backend / 'profile' / 'metrics.json'}")
    if run_stress:
        print(f"  {backend} stress:  {work_root / backend / 'stress' / 'metrics.json'}")
print(f"  summary: {summary_path}")
PY
