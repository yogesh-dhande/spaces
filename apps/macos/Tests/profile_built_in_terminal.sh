#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

ITERATIONS="${ITERATIONS:-3}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-profile.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
APP_LOG="$WORK_ROOT/spaces-app.log"
SESSION_SUMMARY="$WORK_ROOT/summary.txt"
SESSION_METRICS_JSON="$WORK_ROOT/metrics.json"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_log_pattern() {
  local pattern="$1"
  local timeout="${2:-20}"
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

extract_session_id() {
  local output="$1"
  printf '%s\n' "$output" | grep -Eo '[0-9A-F-]{36}' | tail -n 1
}

active_viewer_client_id() {
  local session_id="$1"
  local attachments_path
  attachments_path="$(dirname "$DB_PATH")/terminal/sessions/$session_id/attachments.json"
  python3 - "$attachments_path" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    attachments = json.load(handle)
for attachment in attachments:
    if attachment.get("mode") == "viewer" and attachment.get("detachedAt") is None:
        print(attachment["clientID"])
        break
else:
    raise SystemExit("no active viewer attachment found")
PY
}

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"

cd "$REPO_ROOT"
"$SETUP_GHOSTTYKIT"

pkill -x SpacesApp >/dev/null 2>&1 || true
pkill -f "$SPACES_APP" >/dev/null 2>&1 || true

echo "Using work root: $WORK_ROOT"
echo "Using DB path:  $DB_PATH"

env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

for iteration in $(seq 1 "$ITERATIONS"); do
  title="terminal-profile-$iteration"
  command_output="$(env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal command --backend ghostty-embedded --command cat --title "$title")"
  session_id="$(extract_session_id "$command_output")"
  [[ -n "$session_id" ]] || { echo "Failed to parse session ID from: $command_output" >&2; exit 1; }

  wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=owner"

  payload="profile-ping-$iteration"
  env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal send "$session_id" "$payload" --newline >/dev/null
  wait_for_log_pattern "spaces: perf metric=terminal_control_send .*target=session=${session_id} .*success=1"

  tail_output="$(env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal tail "$session_id" --lines 10)"
  printf '%s\n' "$tail_output" | grep -q "$payload"

  env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal show "$session_id" --viewer
  wait_for_log_pattern "spaces: perf metric=terminal_window_attach .*target=session=${session_id} .*mode=viewer"

  viewer_client_id="$(active_viewer_client_id "$session_id")"
  env SPACES_DB_PATH="$DB_PATH" "$SPACES_CLI" terminal takeover "$session_id" "$viewer_client_id" >/dev/null
  wait_for_log_pattern "spaces: perf metric=terminal_control_takeover .*target=session=${session_id} client=${viewer_client_id} .*success=1"
done

python3 - "$APP_LOG" "$ITERATIONS" "$SESSION_METRICS_JSON" >"$SESSION_SUMMARY" <<'PY'
import math, re, statistics, sys
import json

log_path = sys.argv[1]
expected_iterations = int(sys.argv[2])
json_path = sys.argv[3]
pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
samples = {}
focus_reason_samples = {}

with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        match = pattern.match(line)
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        elapsed = int(match.group("elapsed"))
        detail = match.group("detail") or ""
        samples.setdefault(metric, []).append(elapsed)
        if metric == "terminal_owner_focus_sync":
            reason = "unknown"
            for part in detail.split():
                if part.startswith("reason="):
                    reason = part.split("=", 1)[1]
                    break
            focus_reason_samples.setdefault(reason, []).append(elapsed)

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

ordered_metrics = [
    "terminal_session_start",
    "terminal_first_output",
    "terminal_surface_create",
    "terminal_window_attach",
    "terminal_window_summon",
    "terminal_owner_focus_sync",
    "terminal_control_send",
    "terminal_control_takeover",
]

metrics_payload = {}
print(f"Profiled built-in terminal over {expected_iterations} iteration(s)")
print()
for metric in ordered_metrics:
    values = samples.get(metric, [])
    if not values:
        print(f"{metric}: no successful samples recorded")
        continue
    summary = summarize(values)
    metrics_payload[metric] = summary
    print(
        f"{metric}: count={summary['count']} min={summary['min_ms']}ms avg={summary['avg_ms']}ms "
        f"p95={summary['p95_ms']}ms max={summary['max_ms']}ms")
    if metric == "terminal_owner_focus_sync" and focus_reason_samples:
        for reason in sorted(focus_reason_samples):
            reason_summary = summarize(focus_reason_samples[reason])
            metrics_payload[f"{metric}:{reason}"] = reason_summary
            print(
                f"  reason={reason}: count={reason_summary['count']} min={reason_summary['min_ms']}ms "
                f"avg={reason_summary['avg_ms']}ms p95={reason_summary['p95_ms']}ms max={reason_summary['max_ms']}ms")

with open(json_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "iterations": expected_iterations,
            "metrics": metrics_payload,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
PY

cat "$SESSION_SUMMARY"
echo
echo "Artifacts:"
echo "  app log:  $APP_LOG"
echo "  summary:  $SESSION_SUMMARY"
echo "  metrics:  $SESSION_METRICS_JSON"
