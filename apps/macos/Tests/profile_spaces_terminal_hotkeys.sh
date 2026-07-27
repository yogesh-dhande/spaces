#!/bin/bash
# Profiles and guards the Spaces window hotkey (cmd-opt-=) against a running workspace.
#
# The workspace is started through the CLI, which summons the Spaces window with the workspace's
# processes running as terminal panes, and the workspace's `frontend` process pane is focused. From
# that state the hotkey drives a two-phase cycle that the scenario repeats and times:
#
#   dismiss — the Spaces window is visible and key, so the hotkey orders it out and hides the app
#   summon  — Spaces is in the background, so the hotkey reveals the window and refreshes the selection
#
# Each phase asserts the toggle's own perf metric including the window/app state it observed before
# acting, so an iteration only passes if the window really alternated; the summon phase additionally
# asserts the reveal and the deferred selection refresh that complete that path. The summon leaves
# the window key and the app active again, which is the dismiss phase's precondition, so the cycle
# sustains itself across iterations without the harness re-fronting the app.
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
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-terminal-hotkeys.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
PROJECT_DIR="$WORK_ROOT/repo"
WORKSPACE_INFO_JSON="$WORK_ROOT/workspace.json"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
DISMISS_WALL_SAMPLES="$WORK_ROOT/dismiss-toggle-wall-samples.txt"
SUMMON_WALL_SAMPLES="$WORK_ROOT/summon-toggle-wall-samples.txt"
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
require_binary "$SPACES_E2E_CLI"
require_binary "$SPACESD_EXECUTABLE"
export SPACESD_EXECUTABLE

mkdir -p "$(dirname "$DB_PATH")"
touch "$APP_LOG"

cd "$REPO_ROOT"
acquire_terminal_harness_lock
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
  printf '# Spaces Terminal Hotkey Profile\n' > README.md
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
wait_for_app_log_pattern "spaces: perf metric=process_focus .*target=frontend .*success=1|spaces: perf metric=terminal_window_summon .*mode=owner" 30 || true
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$WORKSPACE_DIR" --process-name frontend >/dev/null 2>"$PROCESS_FOCUS_LOG"
# The focus lands asynchronously over IPC; its own metric is the signal that the frontend pane is
# focused and the Spaces window is key, which is the dismiss phase's precondition. Waiting on the
# metric rather than re-fronting the app keeps the harness from raising a window the app did not
# choose, which would change which phase the first hotkey takes.
wait_for_app_log_pattern "spaces: perf metric=process_focus target=frontend success=1" 30

# Every wait below is baseline-relative: the baselines are recomputed at the top of each iteration
# and each wait requires the count to grow, so a line left by an earlier iteration cannot satisfy a
# later one. The `*_before=` fields pin the state the toggle observed, so a phase that fires in the
# wrong window state does not match.
for iteration in $(seq 1 "$ITERATIONS"); do
  # The dismiss asserts all three state fields: they restate the branch's own precondition (the app
  # was active with the window up), so they are stable. The summon asserts only `app_active_before=0`
  # — that Spaces really was in the background when the hotkey arrived. Its `app_hidden_before` and
  # `main_visible_before` are deliberately left unasserted because AppKit settles the hide
  # asynchronously: the window can be ordered back in and made key again while the app is still
  # hidden, so those two fields legitimately read either way depending on when the hotkey lands.
  toggle_dismiss_pattern="spaces: perf metric=toggle_window target=action=hide app_active_before=1 app_hidden_before=0 main_visible_before=1 .*success=1 elapsed_ms="
  toggle_summon_pattern="spaces: perf metric=toggle_window target=action=show app_active_before=0 .*success=1 elapsed_ms="
  reveal_pattern="spaces: perf metric=toggle_window_reveal_target target=main success=1 elapsed_ms="
  refresh_pattern="spaces: perf metric=toggle_window_selection_refresh target=workspace=.* success=1 elapsed_ms="
  toggle_dismiss_baseline="$(grep -Ec "$toggle_dismiss_pattern" "$APP_LOG" || true)"
  toggle_summon_baseline="$(grep -Ec "$toggle_summon_pattern" "$APP_LOG" || true)"
  reveal_baseline="$(grep -Ec "$reveal_pattern" "$APP_LOG" || true)"
  refresh_baseline="$(grep -Ec "$refresh_pattern" "$APP_LOG" || true)"

  dismiss_started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  send_spaces_toggle_hotkey
  wait_for_log_pattern_count_greater_than "$toggle_dismiss_pattern" "$toggle_dismiss_baseline" 30
  printf 'iteration=%s dismiss_toggle_wall_ms=%s\n' "$iteration" "$(ms_since "$dismiss_started_at")" >>"$DISMISS_WALL_SAMPLES"

  summon_started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  send_spaces_toggle_hotkey
  wait_for_log_pattern_count_greater_than "$toggle_summon_pattern" "$toggle_summon_baseline" 30
  wait_for_log_pattern_count_greater_than "$reveal_pattern" "$reveal_baseline" 30
  # The selection refresh is scheduled as a cancellable deferred task at the end of the summon path,
  # so its metric also proves the summon ran to completion and was not superseded. It lands after the
  # window has become key and the app active again, so waiting for it settles the next iteration's
  # dismiss precondition.
  wait_for_log_pattern_count_greater_than "$refresh_pattern" "$refresh_baseline" 30
  printf 'iteration=%s summon_toggle_wall_ms=%s\n' "$iteration" "$(ms_since "$summon_started_at")" >>"$SUMMON_WALL_SAMPLES"
done

python3 - "$APP_LOG" "$ITERATIONS" "$DISMISS_WALL_SAMPLES" "$SUMMON_WALL_SAMPLES" "$METRICS_PATH" <<'PY' >"$SUMMARY_PATH"
import json, math, re, statistics, sys

log_path, iterations, dismiss_wall_samples_path, summon_wall_samples_path, metrics_path = sys.argv[1:6]
iterations = int(iterations)
pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
metrics = {
    "toggle_window_summon": [],
    "toggle_window_dismiss": [],
    "toggle_window_reveal_target": [],
    "toggle_window_selection_refresh": [],
}

with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        # `search`, not `match`: perf lines carry a `HH:MM:SS.mmm ` prefix, which anchoring at
        # `spaces:` would reject, leaving every metric row empty.
        match = pattern.search(line)
        if not match or match.group("success") != "1":
            continue
        metric = match.group("metric")
        if metric == "toggle_window" and "action=show" in match.group("target") and "app_active_before=0" in match.group("target"):
            metrics["toggle_window_summon"].append(int(match.group("elapsed")))
        elif metric == "toggle_window" and "action=hide" in match.group("target") and "app_active_before=1" in match.group("target"):
            metrics["toggle_window_dismiss"].append(int(match.group("elapsed")))
        elif metric in metrics:
            metrics[metric].append(int(match.group("elapsed")))

dismiss_wall_samples = []
with open(dismiss_wall_samples_path, "r", encoding="utf-8") as handle:
    for line in handle:
        if "dismiss_toggle_wall_ms=" not in line:
            continue
        dismiss_wall_samples.append(int(line.strip().split("dismiss_toggle_wall_ms=", 1)[1]))

summon_wall_samples = []
with open(summon_wall_samples_path, "r", encoding="utf-8") as handle:
    for line in handle:
        if "summon_toggle_wall_ms=" not in line:
            continue
        summon_wall_samples.append(int(line.strip().split("summon_toggle_wall_ms=", 1)[1]))

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
    ("dismiss_toggle_wall", dismiss_wall_samples),
    ("summon_toggle_wall", summon_wall_samples),
    ("toggle_window_dismiss", metrics["toggle_window_dismiss"]),
    ("toggle_window_summon", metrics["toggle_window_summon"]),
    ("toggle_window_reveal_target", metrics["toggle_window_reveal_target"]),
    ("toggle_window_selection_refresh", metrics["toggle_window_selection_refresh"]),
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
