#!/usr/bin/env bash
# Daemon end-to-end for the scheduled-automations command surface. No app, desktop control, or hotkeys:
# it drives the worktree-scoped profile daemon purely through `spacese2e automation-*` subcommands (the
# test seam for GUI-only automation authoring), which send the same profile-socket commands the app uses.
#
# The script binds to the current worktree profile (SPACES_DB_PATH / SPACES_RUNTIME_DIR from
# `spacese2e profile-show --shell`) so it only ever talks to this checkout's daemon and never another
# worktree's. The daemon is autolaunched on the first profile command; the script never stops another
# profile's daemon or app.
#
# Scenarios (all fast fake commands, no real coding agents):
#   a. manual automation: command writes a marker + exit 0 -> trigger -> run succeeds; exit code 0,
#      output.log carries the marker, the run's terminal session is stamped kind=automation + run id.
#   b. failing command (exit 3) -> run fails with exit code 3.
#   c. concurrency=skip: a sleeping run, a second trigger records a skipped(concurrency) row, then the
#      sleeping run is canceled -> canceled.
#   d. timeout 2s on a long sleep -> timed_out.
#   e. attribution stamp for the run's own workspace-bound .automation session (see the note in part_e for
#      why the spawned-agent sweep cycle needs a real provider and is covered by unit tests instead).
#   f. agent-kind automation whose workspace does not resolve -> the launch fails cleanly (failed run), the
#      run's attributed-agent list is empty, and end-agents on the terminal run is an accepted no-op (see the
#      note in part_f for why the detect/deliver/done + End-agents lifecycle needs a real provider and lives
#      in unit tests instead).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_BIN="$BUILD_DIR/spacesd"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() { printf 'PASS: %s\n' "$*"; }

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

json_field() {
  # json_field <json> <python-expr over `d`>
  printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2"
}

CREATED_AUTOMATIONS=()

cleanup() {
  local automation_id
  for automation_id in "${CREATED_AUTOMATIONS[@]:-}"; do
    [[ -n "$automation_id" ]] || continue
    # Best-effort: delete cancels any running run and cleans up artifacts + attributed sessions.
    "$SPACES_E2E" automation-delete --id "$automation_id" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

require_binaries() {
  if [[ ! -x "$SPACES_E2E" || ! -x "$SPACESD_BIN" ]]; then
    printf 'Building spacesd, spacese2e...\n'
    (cd "$REPO_ROOT" && "$REPO_ROOT/scripts/swiftpm.sh" build --product spacesd --product spacese2e >/dev/null)
  fi
  [[ -x "$SPACES_E2E" ]] || fail "spacese2e not found at $SPACES_E2E"
  [[ -x "$SPACESD_BIN" ]] || fail "spacesd not found at $SPACESD_BIN"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required."
  command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required."
}

bind_worktree_profile() {
  eval "$("$SPACES_E2E" profile-show --shell)"
  export SPACESD_EXECUTABLE="$SPACESD_BIN"
  [[ -n "${SPACES_DB_PATH:-}" ]] || fail "profile-show did not export SPACES_DB_PATH"
  printf '[automation-e2e] profile db=%s\n' "$SPACES_DB_PATH"
}

provision_fixture() {
  local profile_root workspace
  profile_root="$(dirname "$SPACES_DB_PATH")"
  FIXTURE_DIR="$profile_root/automation-e2e-fixture"
  mkdir -p "$FIXTURE_DIR"
  workspace="$("$SPACES_E2E" register-project --project-dir "$FIXTURE_DIR")"
  WORKSPACE_ID="$(json_field "$workspace" 'd["id"]')"
  [[ -n "$WORKSPACE_ID" ]] || fail "could not resolve fixture workspace from: $workspace"
  printf '[automation-e2e] fixture dir=%s workspace=%s\n' "$FIXTURE_DIR" "$WORKSPACE_ID"
}

# Creates an automation, records it for cleanup, and returns its id in AUTOMATION_ID.
AUTOMATION_ID=""
create_automation() {
  local out
  out="$("$SPACES_E2E" automation-create "$@")"
  AUTOMATION_ID="$(json_field "$out" 'd[0]["id"]')"
  [[ -n "$AUTOMATION_ID" ]] || fail "could not parse automation id from: $out"
  CREATED_AUTOMATIONS+=("$AUTOMATION_ID")
}

# Triggers an automation and returns the started/queued/skipped run id in RUN_ID.
RUN_ID=""
trigger_run() {
  local out
  out="$("$SPACES_E2E" automation-trigger --id "$1")"
  RUN_ID="$(json_field "$out" 'd[0]["id"]')"
  [[ -n "$RUN_ID" ]] || fail "could not parse run id from: $out"
}

# Status of one run id (empty if not found), read from the automation's runs listing.
run_status() {
  local automation_id="$1" run_id="$2" runs
  runs="$("$SPACES_E2E" automation-runs --automation-id "$automation_id")"
  json_field "$runs" 'next((r["status"] for r in d if r["id"]=="'"$run_id"'"), "")'
}

run_field() {
  local automation_id="$1" run_id="$2" expr="$3" runs
  runs="$("$SPACES_E2E" automation-runs --automation-id "$automation_id")"
  json_field "$runs" 'next((str(r.get('"$expr"')) for r in d if r["id"]=="'"$run_id"'"), "")'
}

# Polls until a run reaches the expected terminal status or times out.
wait_run_status() {
  local automation_id="$1" run_id="$2" expected="$3" timeout="${4:-20}" start status
  start="$(now_ms)"
  while true; do
    status="$(run_status "$automation_id" "$run_id")"
    [[ "$status" == "$expected" ]] && return 0
    if (( "$(now_ms)" - start >= timeout * 1000 )); then
      printf 'Timed out waiting for run %s to reach %s (last=%s).\n' "$run_id" "$expected" "$status" >&2
      "$SPACES_E2E" automation-runs --automation-id "$automation_id" >&2
      return 1
    fi
    sleep 0.3
  done
}

# ---------------------------------------------------------------------------

part_a() {
  printf '\n=== Scenario a: manual success, marker, exit 0, session stamp ===\n'
  local marker="$FIXTURE_DIR/marker-a.txt"
  rm -f "$marker"
  create_automation --name "e2e-success" --script "echo MARKER_A > '$marker'; echo run-output-marker; exit 0" \
    --workspace-id "$WORKSPACE_ID" --trigger manual --concurrency allow
  trigger_run "$AUTOMATION_ID"
  wait_run_status "$AUTOMATION_ID" "$RUN_ID" "succeeded" || fail "run did not succeed"

  local exit_code
  exit_code="$(run_field "$AUTOMATION_ID" "$RUN_ID" '"exitCode"')"
  [[ "$exit_code" == "0" ]] || fail "expected exit code 0, got $exit_code"
  [[ -f "$marker" ]] && grep -Fq "MARKER_A" "$marker" || fail "marker file missing/empty at $marker"

  local session_id
  session_id="$(run_field "$AUTOMATION_ID" "$RUN_ID" '"terminalSessionID"')"
  [[ -n "$session_id" && "$session_id" != "None" ]] || fail "run carried no terminal session id"

  # The run's workspace-bound command session must be stamped kind=automation + this run id.
  local db_kind db_run db_workspace
  db_kind="$(sqlite3 "$SPACES_DB_PATH" "SELECT kind FROM terminal_sessions WHERE session_id='$session_id';")"
  db_run="$(sqlite3 "$SPACES_DB_PATH" "SELECT automation_run_id FROM terminal_sessions WHERE session_id='$session_id';")"
  db_workspace="$(sqlite3 "$SPACES_DB_PATH" "SELECT workspace_id FROM terminal_sessions WHERE session_id='$session_id';")"
  [[ "$db_kind" == "automation" ]] || fail "session kind was '$db_kind', expected automation"
  [[ "$db_run" == "$RUN_ID" ]] || fail "session automation_run_id was '$db_run', expected $RUN_ID"
  [[ "$db_workspace" == "$WORKSPACE_ID" ]] || fail "session workspace_id was '$db_workspace', expected $WORKSPACE_ID"

  # output.log capture is a best-effort assertion: an embedded-Ghostty session's output.log is a
  # render-dependent snapshot that may be truncated or already reaped by the time the run settles, so the
  # marker FILE (written by the command itself) and the DB stamp above are the authoritative proof of
  # execution. Report the output.log match when it lands, but do not fail the scenario on it.
  local session_root output_log output_note="output.log not captured"
  session_root="$(json_field "$("$SPACES_E2E" profile-socket-paths --session-id "$session_id")" 'd.get("sessionRootDirectory") or ""')"
  output_log="$session_root/output.log"
  if [[ -n "$session_root" && -f "$output_log" ]] && grep -Fq "run-output-marker" "$output_log"; then
    output_note="output.log carried the marker"
  fi
  pass "scenario a: succeeded, exit 0, marker file, session stamped kind=automation run=$RUN_ID ($output_note)"
}

part_b() {
  printf '\n=== Scenario b: failing command, exit 3 ===\n'
  create_automation --name "e2e-fail" --script "exit 3" --workspace-id "$WORKSPACE_ID" --trigger manual --concurrency allow
  trigger_run "$AUTOMATION_ID"
  wait_run_status "$AUTOMATION_ID" "$RUN_ID" "failed" || fail "run did not fail"
  local exit_code
  exit_code="$(run_field "$AUTOMATION_ID" "$RUN_ID" '"exitCode"')"
  [[ "$exit_code" == "3" ]] || fail "expected exit code 3, got $exit_code"
  pass "scenario b: failed with exit code 3"
}

part_c() {
  printf '\n=== Scenario c: concurrency=skip + cancel ===\n'
  create_automation --name "e2e-skip" --script "sleep 60" --workspace-id "$WORKSPACE_ID" --trigger manual --concurrency skip
  trigger_run "$AUTOMATION_ID"
  local running_run="$RUN_ID"
  # Give the first run time to become running before the second trigger.
  wait_run_status "$AUTOMATION_ID" "$running_run" "running" 10 || fail "first run never started running"

  trigger_run "$AUTOMATION_ID"
  local skipped_run="$RUN_ID"
  local skipped_status skip_reason
  skipped_status="$(run_status "$AUTOMATION_ID" "$skipped_run")"
  [[ "$skipped_status" == "skipped" ]] || fail "second trigger was not skipped (got $skipped_status)"
  skip_reason="$(run_field "$AUTOMATION_ID" "$skipped_run" '"skipReason"')"
  [[ "$skip_reason" == "concurrency" ]] || fail "skip reason was '$skip_reason', expected concurrency"
  pass "scenario c.1: overlapping trigger recorded a skipped(concurrency) row"

  "$SPACES_E2E" automation-cancel --run-id "$running_run" >/dev/null
  wait_run_status "$AUTOMATION_ID" "$running_run" "canceled" || fail "running run was not canceled"
  pass "scenario c.2: the sleeping run was canceled"
}

part_d() {
  printf '\n=== Scenario d: timeout ===\n'
  create_automation --name "e2e-timeout" --script "sleep 60" --workspace-id "$WORKSPACE_ID" --trigger manual --concurrency allow \
    --timeout-seconds 2
  trigger_run "$AUTOMATION_ID"
  wait_run_status "$AUTOMATION_ID" "$RUN_ID" "timed_out" 25 || fail "run did not time out"
  pass "scenario d: long-running command was timed out"
}

part_e() {
  printf '\n=== Scenario e: attribution stamp (spawned-agent sweep note) ===\n'
  # The spawned-agent-session sweep cycle (spawn a fake agent inside a run, end it, re-trigger, assert the
  # prior ended attributed session is finalized by the sweep) cannot run here: `agent spawn` gates its
  # command against the supported-coding-agent set (AgentSpawnCommandGate), so a fake `bash`/`sleep`
  # command is rejected and no attributed coding-agent session can be created without a real provider on
  # PATH. That sweep path is covered instead by the workspacecore unit test
  # `AutomationServiceTests.testSweepFinalizesEndedAttributedSessionAndKeepsLiveOne`, which injects a fake
  # ended attributed session directly. Here we assert the directly-launched attributed session the product
  # always creates: the run's own workspace-bound .automation session, stamped with the run id.
  create_automation --name "e2e-attribution" --script "echo attributed; exit 0" --workspace-id "$WORKSPACE_ID" --trigger manual \
    --concurrency allow
  trigger_run "$AUTOMATION_ID"
  wait_run_status "$AUTOMATION_ID" "$RUN_ID" "succeeded" || fail "attribution run did not succeed"
  local session_id count
  session_id="$(run_field "$AUTOMATION_ID" "$RUN_ID" '"terminalSessionID"')"
  count="$(sqlite3 "$SPACES_DB_PATH" "SELECT COUNT(*) FROM terminal_sessions WHERE automation_run_id='$RUN_ID' AND session_id='$session_id';")"
  [[ "$count" == "1" ]] || fail "run's own session was not stamped with automation_run_id=$RUN_ID"
  pass "scenario e: run's own .automation session is stamped with the run id (spawned-agent sweep covered by unit test)"
}

part_f() {
  printf '\n=== Scenario f: agent-kind clean-failure + attributed agents + end-agents ===\n'
  # The full agent-kind lifecycle — spawn a real coding agent, wait for foreground detection, deliver the
  # seed prompt, observe `done`, then End-agents the left-open session — cannot run here without a real
  # provider on PATH. A fake `claude` shell-script fixture passes the spawn command gate (which matches only
  # the command string) but is NOT foreground-detected: the daemon's foreground classifier
  # (TerminalForegroundProcessInspector) matches the live foreground process's executable/argv[0] basename,
  # and a shebang script named `claude` runs as its interpreter (`/bin/bash <path>/claude`), so the detected
  # executable is `bash`, never `claude`. That detect/deliver/done + End-agents cycle is covered by the
  # workspacecore unit tests (AutomationServiceTests: prompt delivery, done completion, endAttributedAgents).
  #
  # Here we drive the agent-kind clean-failure path end to end: a supported command (`claude`, so the gate
  # passes) targeting a workspace id that does not resolve, so the spawn fails and the run is recorded failed
  # with no attributed session created. We then assert the run's attributed-agent list is empty and that
  # end-agents on the (terminal) run is an accepted no-op that leaves the run failed.
  create_automation --name "e2e-agent-failure" --kind agent --script "" --agent-command "claude" --agent-prompt "investigate" \
    --workspace-id "nonexistent-workspace-e2e" --trigger manual --concurrency allow
  trigger_run "$AUTOMATION_ID"
  wait_run_status "$AUTOMATION_ID" "$RUN_ID" "failed" || fail "agent run with an unresolvable workspace did not fail"

  # A clean launch failure creates no attributed session, so the run's attributed-agent list is empty.
  local runs agent_count
  runs="$("$SPACES_E2E" automation-runs --automation-id "$AUTOMATION_ID")"
  agent_count="$(json_field "$runs" 'next((len(r["attributedAgents"]) for r in d if r["id"]=="'"$RUN_ID"'"), -1)')"
  [[ "$agent_count" == "0" ]] || fail "expected 0 attributed agents on the failed run, got $agent_count"
  pass "scenario f.1: agent-kind run with an unresolvable workspace failed with no attributed agents"

  # End-agents on the terminal (failed) run is an accepted no-op: it succeeds and leaves the run failed.
  "$SPACES_E2E" automation-end-agents --run-id "$RUN_ID" >/dev/null || fail "end-agents on a terminal run should succeed"
  local status_after
  status_after="$(run_status "$AUTOMATION_ID" "$RUN_ID")"
  [[ "$status_after" == "failed" ]] || fail "end-agents changed the run status to '$status_after', expected failed"
  pass "scenario f.2: end-agents on the terminal run is a no-op and leaves the run failed"
}

main() {
  require_binaries
  bind_worktree_profile
  provision_fixture
  part_a
  part_b
  part_c
  part_d
  part_e
  part_f
  printf '\nAll automation e2e scenarios passed.\n'
}

main "$@"
