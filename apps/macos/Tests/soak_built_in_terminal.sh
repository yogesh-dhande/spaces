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

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-soak.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
APP_LOG="$WORK_ROOT/spaces-app.log"
SAMPLES_PATH="$WORK_ROOT/samples.tsv"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
APP_PID=""

DURATION_SECONDS="${DURATION_SECONDS:-300}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-5}"
FRAMES_PER_SECOND="${FRAMES_PER_SECOND:-8}"
ROWS="${ROWS:-20}"
APP_PID=""

cleanup() {
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

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"
require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
[[ -x "$FIXTURE_SCRIPT" ]] || chmod +x "$FIXTURE_SCRIPT"

cd "$REPO_ROOT"
"$SETUP_GHOSTTYKIT"

pkill -x SpacesApp >/dev/null 2>&1 || true
pkill -f "$SPACES_APP" >/dev/null 2>&1 || true
env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

frames=$((DURATION_SECONDS * FRAMES_PER_SECOND))
sleep_ms=$((1000 / FRAMES_PER_SECOND))
command_output="$(env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal command --backend ghostty-embedded --command "python3 '$FIXTURE_SCRIPT' --mode mixed --frames $frames --rows $ROWS --width 72 --sleep-ms $sleep_ms" --title soak-mixed)"
session_id="$(extract_session_id "$command_output")"
[[ -n "$session_id" ]] || { echo "Failed to parse soak session ID" >&2; exit 1; }
wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=owner"

session_dir="$(dirname "$DB_PATH")/terminal/sessions/$session_id"
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
  tail_started="$(python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
)"
  tail_output="$(env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal tail "$session_id" --lines 120)"
  tail_finished="$(python3 - <<'PY'
import time
print(time.time_ns() // 1_000_000)
PY
)"
  tail_ms=$((tail_finished - tail_started))
  output_bytes="$(wc -c <"$output_log" | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$elapsed" "${rss_kb:-0}" "${cpu_percent:-0}" "$tail_ms" "$output_bytes" >>"$SAMPLES_PATH"
  sleep "$SAMPLE_INTERVAL_SECONDS"
done

wait_for_file_pattern "$output_log" "FIXTURE_DONE mode=mixed emitted=$((frames * ROWS))" 120

python3 - "$SAMPLES_PATH" "$output_log" "$frames" "$ROWS" "$SUMMARY_PATH" "$METRICS_PATH" <<'PY'
import json
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
payload = {
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
    "expected_lines": frames * rows,
    "lines_match_expected": len(seqs) == frames * rows,
}
summary = [
    "Built-in terminal soak profile",
    "",
    f"duration={payload['duration_seconds']}s samples={payload['sample_count']}",
    f"rss_max={payload['rss_kb_max']}KB cpu_avg={payload['cpu_percent_avg']} tail_avg={payload['tail_ms_avg']}ms tail_max={payload['tail_ms_max']}ms",
    f"output={payload['output_bytes_final']}B seq={payload['sequence_count']} complete={1 if payload['sequence_complete'] else 0} expected={1 if payload['lines_match_expected'] else 0} frame_ok={1 if payload['frame_match_expected'] else 0}",
]
summary_path.write_text("\n".join(summary) + "\n", encoding="utf-8")
metrics_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
print("\nArtifacts:")
print(f"  samples:  {samples_path}")
print(f"  summary:  {summary_path}")
print(f"  metrics:  {metrics_path}")
PY
