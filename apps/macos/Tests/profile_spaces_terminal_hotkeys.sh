#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
source "$SCRIPT_DIR/terminal_harness_lock.sh"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
MX_E2E_BIN="$BUILD_DIR/spacese2e"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

ITERATIONS="${ITERATIONS:-5}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-hotkeys.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
APP_LOG="$WORK_ROOT/spaces-app.log"
PROJECT_DIR="$WORK_ROOT/repo"
WORKSPACE_INFO_JSON="$WORK_ROOT/workspace.json"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
SHOW_TOGGLE_WALL_SAMPLES="$WORK_ROOT/show-toggle-wall-samples.txt"
HIDE_TOGGLE_WALL_SAMPLES="$WORK_ROOT/hide-toggle-wall-samples.txt"
PROCESS_FOCUS_LOG="$WORK_ROOT/process-focus.log"
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

frontmost_app() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  return name of first process whose frontmost is true
end tell
APPLESCRIPT
}

activate_spaces_pid() {
  local pid="$1"
  osascript - "$pid" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      set frontmost of proc to true
      try
        if (count of windows of proc) > 0 then
          perform action "AXRaise" of window 1 of proc
        end if
      end try
      return
    end repeat
  end tell
end run
APPLESCRIPT
}

wait_for_spaces_frontmost_ready() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    activate_spaces_pid "$APP_PID"
    if [[ "$(frontmost_app 2>/dev/null || true)" == "SpacesApp" ]] && osascript <<'APPLESCRIPT' 2>/dev/null | grep -Eiq '^(1|true)$'; then
tell application "System Events"
  if exists process "SpacesApp" then
    tell process "SpacesApp"
      return (count of windows) > 0
    end tell
  end if
end tell
return false
APPLESCRIPT
      return 0
    fi
    sleep 0.2
  done
  echo "Timed out waiting for Spaces to become frontmost" >&2
  exit 1
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

send_spaces_toggle_hotkey() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  key code 24 using {command down, option down}
end tell
APPLESCRIPT
}

wait_for_app_log_pattern() {
  local pattern="$1"
  local timeout="${2:-30}"
  local start
  start="$(date +%s)"
  while true; do
    if grep -Eq "$pattern" "$APP_LOG"; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for app log pattern: $pattern" >&2
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
require_binary "$MX_E2E_BIN"

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
  printf '# Spaces Terminal Hotkey Profile\n' > README.md
  git add README.md
  git commit -q -m init
)

env SPACES_DB_PATH="$DB_PATH" "$MX_E2E_BIN" seed-fixture \
  --project-dir "$PROJECT_DIR" \
  --workspace-title "spaces-terminal-hotkey-profile" \
  --docs-url 'http://localhost:$APP_PORT/docs/' \
  --admin-url 'http://localhost:$APP_PORT/admin/' >/dev/null
env SPACES_DB_PATH="$DB_PATH" "$MX_E2E_BIN" lookup-workspace --project-dir "$PROJECT_DIR" --title "spaces-terminal-hotkey-profile" >"$WORKSPACE_INFO_JSON"

WORKSPACE_DIR="$(json_get "$WORKSPACE_INFO_JSON" "dir")"
WORKSPACE_ID="$(json_get "$WORKSPACE_INFO_JSON" "id")"

pkill -x SpacesApp >/dev/null 2>&1 || true
pkill -f "$SPACES_APP" >/dev/null 2>&1 || true
env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3
wait_for_spaces_frontmost_ready

env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$SPACES_CLI" start "$WORKSPACE_DIR" >/dev/null
wait_for_app_log_pattern "spaces: perf metric=process_focus .*target=frontend .*success=1|spaces: perf metric=terminal_window_summon .*mode=owner" 30 || true
env SPACES_DB_PATH="$DB_PATH" DEBUG=1 "$MX_E2E_BIN" focus-workspace-process --workspace-dir "$WORKSPACE_DIR" --process-name frontend >/dev/null 2>"$PROCESS_FOCUS_LOG"
wait_for_spaces_frontmost_ready

for iteration in $(seq 1 "$ITERATIONS"); do
  toggle_show_pattern="spaces: perf metric=toggle_window target=action=show .*app_active_before=1 .*success=1 elapsed_ms="
  toggle_hide_pattern="spaces: perf metric=toggle_window target=action=hide .*app_active_before=1 .*success=1 elapsed_ms="
  lookup_pattern="spaces: perf metric=toggle_window_terminal_workspace_lookup target=session=.* success=[01] elapsed_ms="
  refresh_pattern="spaces: perf metric=toggle_window_selection_refresh target=workspace=.* success=1 elapsed_ms="
  return_pattern="spaces: perf metric=toggle_window_return_terminal_focus target=session=.* success=1 elapsed_ms="
  toggle_show_baseline="$(grep -Ec "$toggle_show_pattern" "$APP_LOG" || true)"
  toggle_hide_baseline="$(grep -Ec "$toggle_hide_pattern" "$APP_LOG" || true)"
  lookup_baseline="$(grep -Ec "$lookup_pattern" "$APP_LOG" || true)"
  refresh_baseline="$(grep -Ec "$refresh_pattern" "$APP_LOG" || true)"
  return_baseline="$(grep -Ec "$return_pattern" "$APP_LOG" || true)"

  started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  send_spaces_toggle_hotkey
  wait_for_log_pattern_count_greater_than "$toggle_show_pattern" "$toggle_show_baseline" 30
  wait_for_log_pattern_count_greater_than "$lookup_pattern" "$lookup_baseline" 30
  wait_for_log_pattern_count_greater_than "$refresh_pattern" "$refresh_baseline" 30
  wait_for_spaces_frontmost_ready
  printf 'iteration=%s terminal_to_main_toggle_wall_ms=%s\n' "$iteration" "$(ms_since "$started_at")" >>"$SHOW_TOGGLE_WALL_SAMPLES"

  hide_started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  send_spaces_toggle_hotkey
  wait_for_log_pattern_count_greater_than "$toggle_hide_pattern" "$toggle_hide_baseline" 30
  wait_for_log_pattern_count_greater_than "$return_pattern" "$return_baseline" 30
  printf 'iteration=%s main_to_terminal_toggle_wall_ms=%s\n' "$iteration" "$(ms_since "$hide_started_at")" >>"$HIDE_TOGGLE_WALL_SAMPLES"
done

python3 - "$APP_LOG" "$ITERATIONS" "$SHOW_TOGGLE_WALL_SAMPLES" "$HIDE_TOGGLE_WALL_SAMPLES" "$METRICS_PATH" <<'PY' >"$SUMMARY_PATH"
import json, math, re, statistics, sys

log_path, iterations, show_wall_samples_path, hide_wall_samples_path, metrics_path = sys.argv[1:6]
iterations = int(iterations)
pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
metrics = {
    "toggle_window_show": [],
    "toggle_window_hide": [],
    "toggle_window_reveal_target": [],
    "toggle_window_focused_window_workspace_lookup": [],
    "toggle_window_terminal_workspace_lookup": [],
    "toggle_window_selection_refresh": [],
    "toggle_window_return_terminal_focus": [],
}

with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        match = pattern.match(line)
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        if metric == "toggle_window" and "action=show" in match.group("target") and "app_active_before=1" in match.group("target"):
            metrics["toggle_window_show"].append(int(match.group("elapsed")))
        elif metric == "toggle_window" and "action=hide" in match.group("target") and "app_active_before=1" in match.group("target"):
            metrics["toggle_window_hide"].append(int(match.group("elapsed")))
        elif metric in metrics:
            metrics[metric].append(int(match.group("elapsed")))

show_wall_samples = []
with open(show_wall_samples_path, "r", encoding="utf-8") as handle:
    for line in handle:
        if "terminal_to_main_toggle_wall_ms=" not in line:
            continue
        show_wall_samples.append(int(line.strip().split("terminal_to_main_toggle_wall_ms=", 1)[1]))

hide_wall_samples = []
with open(hide_wall_samples_path, "r", encoding="utf-8") as handle:
    for line in handle:
        if "main_to_terminal_toggle_wall_ms=" not in line:
            continue
        hide_wall_samples.append(int(line.strip().split("main_to_terminal_toggle_wall_ms=", 1)[1]))

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
    ("terminal_to_main_toggle_wall", show_wall_samples),
    ("main_to_terminal_toggle_wall", hide_wall_samples),
    ("toggle_window_show", metrics["toggle_window_show"]),
    ("toggle_window_hide", metrics["toggle_window_hide"]),
    ("toggle_window_reveal_target", metrics["toggle_window_reveal_target"]),
    ("toggle_window_focused_window_workspace_lookup", metrics["toggle_window_focused_window_workspace_lookup"]),
    ("toggle_window_terminal_workspace_lookup", metrics["toggle_window_terminal_workspace_lookup"]),
    ("toggle_window_selection_refresh", metrics["toggle_window_selection_refresh"]),
    ("toggle_window_return_terminal_focus", metrics["toggle_window_return_terminal_focus"]),
]

payload = {"iterations": iterations, "metrics": {}}
print(f"Profiled Spaces terminal hotkeys over {iterations} iteration(s)")
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
