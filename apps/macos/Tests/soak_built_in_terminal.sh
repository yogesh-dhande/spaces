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
SPACES_E2E="$BUILD_DIR/spacese2e"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"
FIXTURE_SCRIPT="$SCRIPT_DIR/terminal_stress_fixture.py"

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-soak.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
SAMPLES_PATH="$WORK_ROOT/samples.tsv"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
FINAL_TAIL_PATH="$WORK_ROOT/final-tail.txt"
APP_PID=""

DURATION_SECONDS="${DURATION_SECONDS:-300}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-5}"
FRAMES_PER_SECOND="${FRAMES_PER_SECOND:-8}"
ROWS="${ROWS:-20}"
SOAK_MODE="${SOAK_MODE:-repaint}"
SOAK_HISTORY_LINES="${SOAK_HISTORY_LINES:-12000}"
APP_PID=""

cleanup() {
  release_terminal_harness_lock
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  stop_terminal_service_for_runtime_dir "$RUNTIME_DIR"
}
trap cleanup EXIT

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

# Requests the owner-mode pane open until the owner summon lands. `spaces terminal command` only creates
# the session; nothing opens its pane on its own, and `mode=owner` is emitted solely for the owner-mode
# open IPC that `spaces terminal show` posts. The request repeats once a second because the app resolves a
# just-created session through a cold overview fetch, so an early request can find nothing to open.
wait_for_owner_window_summon() {
  local session_id="$1"
  local timeout="${2:-30}"
  local pattern="spaces: perf metric=terminal_window_summon target=session=${session_id} success=1 .*mode=owner|spaces: perf metric=terminal_window_attach_owner_surface target=session=${session_id} success=1 .*mode=owner"
  local start
  local next_request_at=0
  start="$(date +%s)"
  while true; do
    if grep -Eq "$pattern" "$APP_LOG"; then
      return 0
    fi

    local now
    now="$(date +%s)"
    if (( now >= next_request_at )); then
      env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal show "$session_id" >/dev/null
      next_request_at=$((now + 1))
    fi

    if (( now - start >= timeout )); then
      echo "Timed out waiting for owner window summon for session $session_id" >&2
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
require_binary "$SPACES_E2E"
[[ -x "$FIXTURE_SCRIPT" ]] || chmod +x "$FIXTURE_SCRIPT"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
if [[ "${SPACES_E2E_SKIP_GHOSTTYKIT_SETUP:-0}" != "1" ]]; then
  "$SETUP_GHOSTTYKIT"
fi

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

# terminal command is workspace-scoped; register a fixture project and use its default workspace.
FIXTURE_PROJECT_DIR="$WORK_ROOT/terminal-fixture-project"
mkdir -p "$FIXTURE_PROJECT_DIR"
FIXTURE_WORKSPACE_JSON="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E" register-project --project-dir "$FIXTURE_PROJECT_DIR")"
FIXTURE_WORKSPACE_ID="$(printf '%s' "$FIXTURE_WORKSPACE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

frames=$((DURATION_SECONDS * FRAMES_PER_SECOND))
sleep_ms=$((1000 / FRAMES_PER_SECOND))
fixture_mode="mixed"
session_title="soak-mixed"
expected_lines=$((frames * ROWS))
fixture_args=(--mode "$fixture_mode" --frames "$frames" --rows "$ROWS" --width 72 --sleep-ms "$sleep_ms")
case "$SOAK_MODE" in
  repaint)
    fixture_mode="repaint"
    session_title="soak-repaint"
    fixture_args=(--mode "$fixture_mode" --frames "$frames" --rows "$ROWS" --width 72 --sleep-ms "$sleep_ms")
    ;;
  mixed)
    ;;
  codex|codex_churn)
    fixture_mode="codex_churn"
    session_title="soak-codex-churn"
    expected_lines=$((SOAK_HISTORY_LINES + frames * ROWS))
    fixture_args=(--mode "$fixture_mode" --lines "$SOAK_HISTORY_LINES" --frames "$frames" --rows "$ROWS" --width 72 --sleep-ms "$sleep_ms" --flush-every 40)
    ;;
  *)
    echo "Unsupported SOAK_MODE: $SOAK_MODE" >&2
    exit 1
    ;;
esac
command_output="$(env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_CLI" terminal command --workspace "$FIXTURE_WORKSPACE_ID" --command "python3 '$FIXTURE_SCRIPT' ${fixture_args[*]}" --title "$session_title")"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse soak session ID" >&2; exit 1; }
wait_for_owner_window_summon "$session_id"
session_dir="$RUNTIME_DIR/terminal/sessions/$session_id"
output_log="$session_dir/output.log"

echo -e "elapsed_s\trss_kb\tcpu_percent\ttail_ms\toutput_bytes" >"$SAMPLES_PATH"
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
  printf '%s\t%s\t%s\t%s\t%s\n' "$elapsed" "${rss_kb:-0}" "${cpu_percent:-0}" "$tail_ms" "$output_bytes" >>"$SAMPLES_PATH"
  sleep "$SAMPLE_INTERVAL_SECONDS"
done

wait_for_file_pattern "$output_log" "FIXTURE_DONE mode=${fixture_mode} emitted=${expected_lines}" 120
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 \
  "$SPACES_CLI" terminal tail "$session_id" --lines 160 >"$FINAL_TAIL_PATH"

python3 - "$SAMPLES_PATH" "$output_log" "$frames" "$ROWS" "$expected_lines" "$SUMMARY_PATH" "$METRICS_PATH" "$APP_LOG" "$session_id" "$SOAK_MODE" "$FINAL_TAIL_PATH" <<'PY'
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
expected_lines = int(sys.argv[5])
summary_path = Path(sys.argv[6])
metrics_path = Path(sys.argv[7])
app_log_path = Path(sys.argv[8])
session_id = sys.argv[9]
soak_mode = sys.argv[10]
final_tail_path = Path(sys.argv[11])
perf_pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")

rows_out = []
for row in samples_path.read_text(encoding="utf-8").splitlines()[1:]:
    elapsed_s, rss_kb, cpu_percent, tail_ms, output_bytes = row.split("\t")
    rows_out.append(
        {
            "elapsed_s": int(elapsed_s),
            "rss_kb": int(float(rss_kb)),
            "cpu_percent": float(cpu_percent),
            "tail_ms": int(tail_ms),
            "output_bytes": int(output_bytes),
        }
    )

text = output_log.read_text(encoding="utf-8", errors="replace")
seqs = [int(match.group(1)) for match in re.finditer(r"SEQ (\d{8})", text)]
frames_seen = [int(match.group(1)) for match in re.finditer(r"FRAME (\d{6})", text)]
final_tail_text = final_tail_path.read_text(encoding="utf-8", errors="replace") if final_tail_path.exists() else ""
final_tail_sequences = [int(match.group(1)) for match in re.finditer(r"SEQ (\d{8})", final_tail_text)]
final_tail_frames = [int(match.group(1)) for match in re.finditer(r"FRAME (\d{6})", final_tail_text)]
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
    "sequence_count": len(seqs),
    "sequence_complete": bool(seqs) and seqs == list(range(1, len(seqs) + 1)),
    "frame_last": frames_seen[-1] if frames_seen else None,
    "frame_match_expected": (frames_seen[-1] if frames_seen else None) == frames,
    "expected_lines": expected_lines,
    "lines_match_expected": len(seqs) == expected_lines,
    "tail_final_contains_fixture_done": f"FIXTURE_DONE mode={'codex_churn' if soak_mode in {'codex', 'codex_churn'} else soak_mode} emitted={expected_lines}" in final_tail_text,
    "tail_final_contains_footer": "TAIL frame=" in final_tail_text,
    "tail_final_sequence_last": final_tail_sequences[-1] if final_tail_sequences else None,
    "tail_final_frame_last": final_tail_frames[-1] if final_tail_frames else None,
    "tail_final_frame_match_expected": (final_tail_frames[-1] if final_tail_frames else None) == frames if frames else True,
}
if rows_out:
    payload["sample_phases"] = {
        "tail_ms": summarize_sample_phases(rows_out, "tail_ms"),
        "cpu_percent": summarize_sample_phases(rows_out, "cpu_percent"),
        "rss_kb": summarize_sample_phases(rows_out, "rss_kb"),
        "output_bytes": summarize_sample_phases(rows_out, "output_bytes"),
    }
    payload["output_growth"] = {
        "first_bytes": rows_out[0]["output_bytes"],
        "last_bytes": rows_out[-1]["output_bytes"],
        "delta_bytes": rows_out[-1]["output_bytes"] - rows_out[0]["output_bytes"],
        "monotonic": all(current["output_bytes"] >= previous["output_bytes"] for previous, current in zip(rows_out, rows_out[1:])),
    }
    if payload["sample_phases"].get("tail_ms"):
        tail_phases = payload["sample_phases"]["tail_ms"]
        payload["tail_latency_drift_ms"] = round(tail_phases["late"]["avg_ms"] - tail_phases["early"]["avg_ms"], 1)
    if payload["sample_phases"].get("rss_kb"):
        rss_phases = payload["sample_phases"]["rss_kb"]
        payload["rss_growth_kb"] = round(rss_phases["late"]["avg_ms"] - rss_phases["early"]["avg_ms"], 1)
if app_metrics:
    payload["app_metrics"] = {metric: summarize(values) for metric, values in sorted(app_metrics.items()) if values}
errors = []
if not payload["sequence_complete"]:
    errors.append(f"{soak_mode}: sequence markers were not contiguous")
if not payload["lines_match_expected"]:
    errors.append(f"{soak_mode}: expected {expected_lines} sequence lines but found {len(seqs)}")
if not payload["frame_match_expected"]:
    errors.append(f"{soak_mode}: expected final frame {frames} but found {payload['frame_last']}")
if not payload["tail_final_contains_fixture_done"]:
    errors.append(f"{soak_mode}: final tail output did not include FIXTURE_DONE")
if not payload["tail_final_frame_match_expected"]:
    errors.append(f"{soak_mode}: final tail output did not include frame {frames}")
if soak_mode in {"codex", "codex_churn"}:
    output_growth = payload.get("output_growth") or {}
    if output_growth.get("delta_bytes", 0) <= 0:
        errors.append("codex_churn soak: output bytes did not grow across samples")
    if not output_growth.get("monotonic", False):
        errors.append("codex_churn soak: output bytes regressed between samples")
    if not payload["tail_final_contains_footer"]:
        errors.append("codex_churn soak: final tail output did not retain the rewritten footer rows")
if errors:
    raise SystemExit("\n".join(errors))
summary = [
    "Built-in terminal soak profile",
    "",
    f"mode={payload['soak_mode']} duration={payload['duration_seconds']}s samples={payload['sample_count']}",
    f"rss_max={payload['rss_kb_max']}KB cpu_avg={payload['cpu_percent_avg']} tail_avg={payload['tail_ms_avg']}ms tail_max={payload['tail_ms_max']}ms",
    f"output={payload['output_bytes_final']}B seq={payload['sequence_count']} complete={1 if payload['sequence_complete'] else 0} expected={1 if payload['lines_match_expected'] else 0} frame_ok={1 if payload['frame_match_expected'] else 0} tail_final={1 if payload['tail_final_contains_fixture_done'] else 0} footer={1 if payload['tail_final_contains_footer'] else 0}",
]
if "sample_phases" in payload and payload["sample_phases"].get("tail_ms"):
    tail_phases = payload["sample_phases"]["tail_ms"]
    early = tail_phases["early"]
    late = tail_phases["late"]
    summary.append(
        f"tail_phases: early_avg={early['avg_ms']}ms early_max={early['max_ms']}ms late_avg={late['avg_ms']}ms late_max={late['max_ms']}ms"
    )
if "output_growth" in payload:
    growth = payload["output_growth"]
    summary.append(
        f"output_growth: first={growth['first_bytes']}B last={growth['last_bytes']}B delta={growth['delta_bytes']}B monotonic={1 if growth['monotonic'] else 0}"
    )
if "tail_latency_drift_ms" in payload:
    summary.append(f"tail_drift_ms={payload['tail_latency_drift_ms']}")
if "rss_growth_kb" in payload:
    summary.append(f"rss_growth_kb={payload['rss_growth_kb']}")
for metric in ("terminal_output_write", "terminal_surface_refresh"):
    if metric in payload.get("app_metrics", {}):
        metric_summary = payload["app_metrics"][metric]
        summary.append(
            f"{metric}: count={metric_summary['count']} min={metric_summary['min_ms']}ms median={metric_summary['median_ms']}ms "
            f"avg={metric_summary['avg_ms']}ms p95={metric_summary['p95_ms']}ms max={metric_summary['max_ms']}ms"
        )
summary_path.write_text("\n".join(summary) + "\n", encoding="utf-8")
metrics_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
print("\nArtifacts:")
print(f"  samples:  {samples_path}")
print(f"  summary:  {summary_path}")
print(f"  metrics:  {metrics_path}")
print(f"  final tail:{final_tail_path}")
PY
