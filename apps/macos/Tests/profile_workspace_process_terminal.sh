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

WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/spaces-workspace-profile.XXXXXX")}"
DB_PATH="${SPACES_DB_PATH:-$WORK_ROOT/spaces.db}"
RUNTIME_DIR="${SPACES_RUNTIME_DIR:-$WORK_ROOT/runtime}"
APP_LOG="$WORK_ROOT/spaces-app.log"
SUMMARY_PATH="$WORK_ROOT/summary.txt"
METRICS_PATH="$WORK_ROOT/metrics.json"
PROJECT_DIR="$WORK_ROOT/repo"
WORKSPACE_INFO_JSON="$WORK_ROOT/workspace.json"
FOCUS_LOG="$WORK_ROOT/focus-process.log"
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

log_pattern_count() {
  local pattern="$1"
  grep -Ec "$pattern" "$APP_LOG" || true
}

wait_for_log_pattern_count_greater_than() {
  local pattern="$1"
  local baseline="$2"
  local timeout="${3:-30}"
  local start
  start="$(date +%s)"
  while true; do
    local count
    count="$(log_pattern_count "$pattern")"
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

write_workspace_dump() {
  local workspace_dir="$1"
  local output_path="$2"
  env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" dump-workspace --workspace-dir "$workspace_dir" >"$output_path"
}

process_field() {
  local dump_path="$1"
  local process_name="$2"
  local field_name="$3"
  python3 - "$dump_path" "$process_name" "$field_name" <<'PY'
import json, sys
path, process_name, field_name = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
for process in payload["runningProcesses"]:
    if process["name"] == process_name:
        value = process.get(field_name)
        print("" if value is None else value)
        break
else:
    raise SystemExit(f"missing process {process_name}")
PY
}

wait_for_process_session_id() {
  local workspace_dir="$1"
  local process_name="$2"
  local dump_path="$3"
  local timeout="${4:-30}"
  local start
  start="$(date +%s)"
  while true; do
    write_workspace_dump "$workspace_dir" "$dump_path"
    if [[ -n "$(process_field "$dump_path" "$process_name" terminalTrackingID)" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "Timed out waiting for process session ID: $process_name" >&2
      return 1
    fi
    sleep 0.5
  done
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
  printf '# Workspace Profile\n' > README.md
  git add README.md
  git commit -q -m init
)

env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" seed-fixture \
  --project-dir "$PROJECT_DIR" \
  --docs-url 'http://localhost:$SPACES_APP_PORT/docs/' \
  --admin-url 'http://localhost:$SPACES_APP_PORT/admin/' > /dev/null
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" lookup-workspace --project-dir "$PROJECT_DIR" >"$WORKSPACE_INFO_JSON"
WORKSPACE_DIR="$(json_get "$WORKSPACE_INFO_JSON" "dir")"
WORKSPACE_ID="$(json_get "$WORKSPACE_INFO_JSON" "id")"

SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" spaces_profile_stop_running_app "$SPACES_CLI"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_APP" >"$APP_LOG" 2>&1 &
APP_PID="$!"
sleep 3

start_started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_CLI" workspace start --workspace "$WORKSPACE_ID" >/dev/null
wait_for_process_session_id "$WORKSPACE_DIR" backend "$WORK_ROOT/after-start.json" 30
START_MS="$(ms_since "$start_started_at")"

BACKEND_SESSION_ID="$(process_field "$WORK_ROOT/after-start.json" backend terminalTrackingID)"

close_started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" "$SPACES_E2E_CLI" close-workspace-process-window --workspace-dir "$WORKSPACE_DIR" --process-name backend >/dev/null
CLOSE_MS="$(ms_since "$close_started_at")"

focus_started_at="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
# The window-focus IPC this scenario drives resolves through `openOrFocusTerminalTarget`, which reports
# `terminal_pane_focus` for the session and never `terminal_window_summon` — that metric belongs to the
# owner-mode open IPC (`spaces terminal show`), which nothing here posts. Waiting on the summon could
# therefore never be satisfied, so the focus wall time is bounded by this pane-focus report instead.
focus_pattern="spaces: perf metric=terminal_pane_focus target=session=${BACKEND_SESSION_ID} success=1"
focus_baseline="$(log_pattern_count "$focus_pattern")"
env SPACES_DB_PATH="$DB_PATH" SPACES_RUNTIME_DIR="$RUNTIME_DIR" DEBUG=1 "$SPACES_E2E_CLI" focus-workspace-process --workspace-dir "$WORKSPACE_DIR" --process-name backend >/dev/null 2>"$FOCUS_LOG"
wait_for_log_pattern_count_greater_than "$focus_pattern" "$focus_baseline" 30
write_workspace_dump "$WORKSPACE_DIR" "$WORK_ROOT/after-focus.json"
FOCUS_MS="$(ms_since "$focus_started_at")"
REOPENED_SESSION_ID="$(process_field "$WORK_ROOT/after-focus.json" backend terminalTrackingID)"

python3 - "$APP_LOG" "$FOCUS_LOG" "$START_MS" "$CLOSE_MS" "$FOCUS_MS" "$BACKEND_SESSION_ID" "$REOPENED_SESSION_ID" "$METRICS_PATH" >"$SUMMARY_PATH" <<'PY'
import json, re, sys

app_log_path, focus_log_path, start_ms, close_ms, focus_ms, original_session, reopened_session, metrics_path = sys.argv[1:9]
pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) workspace=(?P<workspace>\S+) target=(?P<target>\S+) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
terminal_pattern = re.compile(r"spaces: perf metric=(?P<metric>\S+) target=(?P<target>.*?) success=(?P<success>[01]) elapsed_ms=(?P<elapsed>\d+)(?: (?P<detail>.*))?$")
samples = []
with open(app_log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        match = terminal_pattern.match(line)
        if not match or match.group("success") != "1":
            continue
        samples.append({
            "metric": match.group("metric"),
            "target": match.group("target"),
            "elapsed": int(match.group("elapsed")),
            "detail": match.group("detail") or "",
        })

with open(focus_log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        match = pattern.match(line)
        if not match or match.group("success") != "1":
            continue
        samples.append({
            "metric": match.group("metric"),
            "target": match.group("target"),
            "elapsed": int(match.group("elapsed")),
            "detail": match.group("detail") or "",
        })

shell_samples = [
    ("workspace_start_wall", int(start_ms), "workspace-profile"),
    ("workspace_process_close_wall", int(close_ms), "backend"),
    ("workspace_process_focus_wall", int(focus_ms), "backend"),
]

combined = [(name, elapsed, target, "shell") for name, elapsed, target in shell_samples]
combined.extend((sample["metric"], sample["elapsed"], sample["target"], sample["detail"]) for sample in samples)
combined.sort(key=lambda item: item[1], reverse=True)
focus_route = None
focus_ipc_route = None
focus_ipc_elapsed = None
for sample in samples:
    if sample["metric"] != "process_focus":
        if sample["metric"] == "terminal_window_focus_ipc" and focus_ipc_route is None:
            detail = sample["detail"] or ""
            route_match = re.search(r"route=([a-z_]+)", detail)
            if route_match:
                focus_ipc_route = route_match.group(1)
            focus_ipc_elapsed = sample["elapsed"]
        continue
    detail = sample["detail"] or ""
    route_match = re.search(r"route=([a-z_]+)", detail)
    if route_match:
        focus_route = route_match.group(1)
        break

with open(metrics_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "backend_session_stable": original_session == reopened_session,
            "backend_session_before_close": original_session,
            "backend_session_after_focus": reopened_session,
            "workspace_process_focus_route": focus_route,
            "terminal_window_focus_ipc_route": focus_ipc_route,
            "terminal_window_focus_ipc_elapsed_ms": focus_ipc_elapsed,
            "slowest_samples": [
                {
                    "metric": name,
                    "elapsed_ms": elapsed,
                    "target": target,
                    "detail": detail,
                }
                for name, elapsed, target, detail in combined[:20]
            ],
        },
        handle,
        indent=2,
        sort_keys=True,
    )

print("Workspace process terminal profile")
print()
print(f"backend session stable across close/reopen: {'yes' if original_session == reopened_session else 'no'}")
print(f"backend session before close: {original_session}")
print(f"backend session after focus:  {reopened_session}")
if focus_route:
    print(f"workspace process focus route: {focus_route}")
if focus_ipc_route:
    print(f"terminal window focus ipc route: {focus_ipc_route} ({focus_ipc_elapsed}ms)")
else:
    print("terminal window focus ipc route: missing")
print()
print("Slowest samples:")
for name, elapsed, target, detail in combined[:10]:
    suffix = f" ({detail})" if detail and detail != "shell" else (" (wall)" if detail == "shell" else "")
    print(f"- {name}: {elapsed}ms target={target}{suffix}")
PY

cat "$SUMMARY_PATH"
echo
echo "Artifacts:"
echo "  app log:      $APP_LOG"
echo "  focus log:    $FOCUS_LOG"
echo "  summary:      $SUMMARY_PATH"
echo "  metrics:      $METRICS_PATH"
echo "  workspace dir: $WORKSPACE_DIR"
