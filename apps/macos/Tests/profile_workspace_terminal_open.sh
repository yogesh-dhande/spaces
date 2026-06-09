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
SPACES_E2E_CLI="$BUILD_DIR/spacese2e"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

ITERATIONS="${ITERATIONS:-3}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-workspace-terminal-open.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
WORKSPACE_INFO_JSON="$WORK_ROOT/workspace.json"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
PROJECT_DIR="$WORK_ROOT/repo"
WORKSPACE_DIR=""
APP_PID=""

stop_profile_workspace() {
  if [[ -z "$WORKSPACE_DIR" || ! -e "$DB_PATH" ]]; then
    return
  fi

  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" stop-workspace --workspace-dir "$WORKSPACE_DIR" >/dev/null 2>&1 || true
}

cleanup() {
  stop_profile_workspace
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  release_terminal_harness_lock
}
trap cleanup EXIT

require_binary() {
  local path="$1"
  [[ -x "$path" ]] || { echo "Missing binary: $path" >&2; exit 1; }
}

wait_for_log_pattern_count_greater_than() {
  local pattern="$1"
  local baseline="$2"
  local timeout="${3:-30}"
  local start
  start="$(date +%s)"
  while true; do
    local count
    count="$(grep -Ec "$pattern" "$APP_LOG" || true)"
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

json_get() {
  local file="$1"
  local expression="$2"
  python3 - "$file" "$expression" <<'PY'
import json, sys
path, expression = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as handle:
    value = json.load(handle)
for part in expression.split("."):
    if part.isdigit():
        value = value[int(part)]
    else:
        value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is None:
    print("")
else:
    print(value)
PY
}

ms_since() {
  python3 - "$1" <<'PY'
import sys, time
started = float(sys.argv[1])
print(max(int((time.time() - started) * 1000), 0))
PY
}

require_binary "$SPACES_APP"
require_binary "$SPACES_CLI"
require_binary "$SPACES_E2E_CLI"

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
"$SETUP_GHOSTTYKIT"

rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
(
  cd "$PROJECT_DIR"
  git init -q -b main
  git config user.email "spaces-profile@example.com"
  git config user.name "spaces-profile"
  printf '# Workspace Terminal Open Profile\n' > README.md
  git add README.md
  git commit -q -m init
)

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" seed-fixture \
  --project-dir "$PROJECT_DIR" \
  --workspace-title "workspace-terminal-open-profile" \
  --docs-url 'http://localhost:$APP_PORT/docs/' \
  --admin-url 'http://localhost:$APP_PORT/admin/' >/dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" lookup-workspace --project-dir "$PROJECT_DIR" --title "workspace-terminal-open-profile" >"$WORKSPACE_INFO_JSON"

WORKSPACE_DIR="$(json_get "$WORKSPACE_INFO_JSON" "dir")"
WORKSPACE_ID="$(json_get "$WORKSPACE_INFO_JSON" "id")"

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

for iteration in $(seq 1 "$ITERATIONS"); do
  ui_pattern="spaces: perf metric=workspace_terminal_open_ui target=workspace=${WORKSPACE_ID} success=1"
  wait_pattern="spaces: perf metric=terminal_session_wait_ready target=session=.* success=1"
  summon_pattern="spaces: perf metric=terminal_window_summon target=session=.* success=1 .*mode=owner"
  ui_baseline="$(grep -Ec "$ui_pattern" "$APP_LOG" || true)"
  wait_baseline="$(grep -Ec "$wait_pattern" "$APP_LOG" || true)"
  summon_baseline="$(grep -Ec "$summon_pattern" "$APP_LOG" || true)"

  started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" open-workspace-terminal --workspace-dir "$WORKSPACE_DIR" >/dev/null
  wait_for_log_pattern_count_greater_than "$ui_pattern" "$ui_baseline" 30
  wait_for_log_pattern_count_greater_than "$wait_pattern" "$wait_baseline" 30
  wait_for_log_pattern_count_greater_than "$summon_pattern" "$summon_baseline" 30
  wall_ms="$(ms_since "$started_at")"
  printf 'iteration=%s workspace_terminal_open_wall_ms=%s\n' "$iteration" "$wall_ms" >>"$WORK_ROOT/open-wall-samples.txt"
done

python3 - "$APP_LOG" "$ITERATIONS" "$WORK_ROOT/open-wall-samples.txt" "$METRICS_PATH" <<'PY' >"$SUMMARY_PATH"
import json, math, re, statistics, sys

log_path, iterations, wall_samples_path, metrics_path = sys.argv[1:5]
iterations = int(iterations)
terminal_pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
metrics = {
    "workspace_terminal_open_ui": [],
    "terminal_session_wait_ready": [],
    "terminal_window_summon": [],
}
for path_metric in metrics:
    pass

with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        match = terminal_pattern.match(line)
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        if metric in metrics:
            metrics[metric].append(int(match.group("elapsed")))

wall_samples = []
with open(wall_samples_path, "r", encoding="utf-8") as handle:
    for line in handle:
        if "workspace_terminal_open_wall_ms=" not in line:
            continue
        wall_samples.append(int(line.strip().split("workspace_terminal_open_wall_ms=", 1)[1]))

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

ordered = [
    ("workspace_terminal_open_wall", wall_samples),
    ("workspace_terminal_open_ui", metrics["workspace_terminal_open_ui"]),
    ("terminal_session_wait_ready", metrics["terminal_session_wait_ready"]),
    ("terminal_window_summon", metrics["terminal_window_summon"]),
]

payload = {"iterations": iterations, "metrics": {}}
print(f"Profiled workspace terminal open over {iterations} iteration(s)")
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

with open(metrics_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
PY

cat "$SUMMARY_PATH"
echo
echo "Artifacts:"
echo "  app log:  $APP_LOG"
echo "  summary:  $SUMMARY_PATH"
echo "  metrics:  $METRICS_PATH"
