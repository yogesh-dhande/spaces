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
SPACESD_EXECUTABLE="$BUILD_DIR/spacesd"
SETUP_GHOSTTYKIT="$APP_ROOT/scripts/setup_ghosttykit.sh"

ITERATIONS="${ITERATIONS:-5}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-palette.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
PROJECT_DIR="$WORK_ROOT/repo"
WORKSPACE_INFO_JSON="$WORK_ROOT/workspace.json"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
TOGGLE_WALL_SAMPLES="$WORK_ROOT/toggle-wall-samples.txt"
PROCESS_FOCUS_LOG="$WORK_ROOT/process-focus.log"
APP_PID=""

cleanup() {
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

send_spaces_command_palette_hotkey() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  key code 27 using {command down, option down}
end tell
APPLESCRIPT
}

select_command_palette_item_by_query() {
  local query="$1"
  osascript - "$query" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    keystroke (item 1 of argv)
    key code 36
  end tell
end run
APPLESCRIPT
}

focused_terminal_title() {
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" \
    "$SPACES_E2E_CLI" surface-snapshot --spaces-pid "$APP_PID" 2>/dev/null \
    | python3 -c 'import json, sys; print((json.load(sys.stdin).get("spaces") or {}).get("frontTerminalPaneTitle") or "")' 2>/dev/null \
    || true
}

wait_for_focused_terminal_title() {
  local expected_title="$1"
  local deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    if [[ "$(focused_terminal_title)" == "$expected_title" ]]; then
      return 0
    fi
    sleep 0.2
  done
  echo "Timed out waiting for focused terminal '$expected_title'; found '$(focused_terminal_title)'" >&2
  return 1
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
require_binary "$SPACESD_EXECUTABLE"
export SPACESD_EXECUTABLE

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"

cd "$REPO_ROOT"
if [[ "${SPACES_E2E_SKIP_GHOSTTYKIT_SETUP:-0}" != "1" ]]; then
  "$SETUP_GHOSTTYKIT"
fi

rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
(
  cd "$PROJECT_DIR"
  git init -q -b main
  git config user.email "spaces-profile@example.com"
  git config user.name "spaces-profile"
  printf '# Spaces Terminal Palette Profile\n' > README.md
  git add README.md
  git commit -q -m init
)

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" seed-fixture \
  --project-dir "$PROJECT_DIR" \
  --docs-url 'http://localhost:$SPACES_APP_PORT/docs/' \
  --admin-url 'http://localhost:$SPACES_APP_PORT/admin/' >/dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" lookup-workspace --project-dir "$PROJECT_DIR" >"$WORKSPACE_INFO_JSON"

WORKSPACE_DIR="$(json_get "$WORKSPACE_INFO_JSON" "dir")"
WORKSPACE_ID="$(json_get "$WORKSPACE_INFO_JSON" "id")"

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"
SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_wait_for_desktop_control "$SPACES_CLI"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3
wait_for_spaces_frontmost_ready

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_CLI" workspace start --workspace "$WORKSPACE_ID" >/dev/null
wait_for_log_pattern_count_greater_than "spaces: perf metric=process_focus .*target=frontend .*success=1|spaces: perf metric=terminal_window_summon .*mode=owner" 0 30 || true
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$WORKSPACE_DIR" --process-name frontend >/dev/null 2>"$PROCESS_FOCUS_LOG"
wait_for_spaces_frontmost_ready

# Selecting a palette row is navigation, not cancellation. In particular, the
# terminal focused before the palette opened must not reclaim focus after the
# selected terminal makes the palette resign key.
palette_rows_pattern="spaces: hotkey_debug rebuild_palette_rows_done rows=[1-9][0-9]*"
palette_rows_baseline="$(grep -Ec "$palette_rows_pattern" "$APP_LOG" || true)"
send_spaces_command_palette_hotkey
wait_for_log_pattern_count_greater_than "$palette_rows_pattern" "$palette_rows_baseline" 30
select_command_palette_item_by_query "backend"
wait_for_focused_terminal_title "backend"
sleep 0.5
[[ "$(focused_terminal_title)" == "backend" ]] || {
  echo "Command palette selection returned focus to '$(focused_terminal_title)' instead of keeping backend focused" >&2
  exit 1
}
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$WORKSPACE_DIR" --process-name frontend >/dev/null 2>>"$PROCESS_FOCUS_LOG"
wait_for_spaces_frontmost_ready

for iteration in $(seq 1 "$ITERATIONS"); do
  toggle_pattern="spaces: perf metric=toggle_palette target=action=show .*app_active_before=1 .*success=1 elapsed_ms="
  terminal_lookup_pattern="spaces: perf metric=toggle_palette_terminal_workspace_lookup target=session=.* success=[01] elapsed_ms="
  toggle_baseline="$(grep -Ec "$toggle_pattern" "$APP_LOG" || true)"
  terminal_lookup_baseline="$(grep -Ec "$terminal_lookup_pattern" "$APP_LOG" || true)"

  started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  send_spaces_command_palette_hotkey
  wait_for_log_pattern_count_greater_than "$toggle_pattern" "$toggle_baseline" 30
  wait_for_log_pattern_count_greater_than "$terminal_lookup_pattern" "$terminal_lookup_baseline" 5 || true
  wait_for_spaces_frontmost_ready
  printf 'iteration=%s terminal_to_palette_toggle_wall_ms=%s\n' "$iteration" "$(ms_since "$started_at")" >>"$TOGGLE_WALL_SAMPLES"

  send_spaces_command_palette_hotkey
  sleep 0.3
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$WORKSPACE_DIR" --process-name frontend >/dev/null 2>>"$PROCESS_FOCUS_LOG"
  wait_for_spaces_frontmost_ready
done

python3 - "$APP_LOG" "$ITERATIONS" "$TOGGLE_WALL_SAMPLES" "$METRICS_PATH" <<'PY' >"$SUMMARY_PATH"
import json, statistics, re, sys

log_path, iterations, wall_samples_path, metrics_path = sys.argv[1:5]
iterations = int(iterations)
pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
metrics = {
    "toggle_palette": [],
    "toggle_palette_terminal_workspace_lookup": [],
    "toggle_palette_focused_window_workspace_lookup": [],
    "toggle_palette_context_workspace": [],
    "toggle_palette_reveal_target": [],
    "toggle_palette_apply_filter": [],
}

with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        match = pattern.match(line)
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        if metric == "toggle_palette" and "action=show" in match.group("target") and "app_active_before=1" in match.group("target"):
            metrics["toggle_palette"].append(int(match.group("elapsed")))
        elif metric in metrics:
            metrics[metric].append(int(match.group("elapsed")))

wall_samples = []
with open(wall_samples_path, "r", encoding="utf-8") as handle:
    for line in handle:
        wall_samples.append(int(line.strip().rsplit("=", 1)[1]))

def summarize(values):
    if not values:
        return {"count": 0}
    ordered = sorted(values)
    p95_index = min(len(ordered) - 1, max(0, round(len(ordered) * 0.95) - 1))
    return {
        "count": len(values),
        "min_ms": ordered[0],
        "avg_ms": round(statistics.fmean(values), 1),
        "p95_ms": ordered[p95_index],
        "max_ms": ordered[-1],
    }

summary = {"iterations": iterations, "terminal_to_palette_toggle_wall": summarize(wall_samples)}
for name, values in metrics.items():
    summary[name] = summarize(values)

with open(metrics_path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)

print(f"Workspace root: {log_path.rsplit('/', 1)[0]}")
for key in [
    "terminal_to_palette_toggle_wall",
    "toggle_palette",
    "toggle_palette_terminal_workspace_lookup",
    "toggle_palette_focused_window_workspace_lookup",
    "toggle_palette_context_workspace",
    "toggle_palette_reveal_target",
    "toggle_palette_apply_filter",
]:
    stats = summary[key]
    if stats["count"] == 0:
        print(f"{key}: no samples")
    else:
        print(
            f"{key}: count={stats['count']} min={stats['min_ms']}ms avg={stats['avg_ms']}ms "
            f"p95={stats['p95_ms']}ms max={stats['max_ms']}ms")
PY

cat "$SUMMARY_PATH"
echo "Detailed metrics: $METRICS_PATH"
