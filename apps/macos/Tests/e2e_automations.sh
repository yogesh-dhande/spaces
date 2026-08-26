#!/usr/bin/env bash
# Daemon end-to-end for the scheduled-automations command surface. No app, desktop control, or hotkeys:
# it drives the worktree-scoped profile daemon purely through `spacese2e automation-*` subcommands (the
# test seam for GUI-only automation authoring), which send the same profile-socket commands the app uses.
#
# The script binds to the current worktree profile by construction: spacese2e resolves its own
# profile from where it sits in the checkout, so every subcommand already talks to this checkout's
# daemon and never another worktree's. The database path the sqlite assertions need is read from
# `spacese2e profile-show` output (never exported — a binding is refused inside a live profile root).
# The daemon is autolaunched on the first profile command; the script never stops another profile's
# daemon or app.
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
#   f. an agent-kind automation whose workspace does not resolve is refused at creation, and end-agents on a
#      terminal run is an accepted no-op that leaves its status untouched.
#   g. REAL PROVIDER (`claude` on PATH, skipped with a clear line otherwise): an agent-kind automation drives
#      Claude Code with a multi-line seed prompt and asserts the whole prompt reached the agent, was
#      submitted exactly once, and was answered. This is the ground truth for seed-prompt delivery — the
#      thing no fake can vouch for, since the failure it guards (issue #556) is the real TUI enabling
#      bracketed paste before its composer accepts input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_BIN="$BUILD_DIR/spacesd"
SPACES_CLI="$BUILD_DIR/spaces"

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
  # The agent fixture directory is left in place: it lives under the ignored build directory, it is
  # registered as a Spaces project, and removing it would leave the daemon rescanning a directory that no
  # longer exists on every discovery pass.
}
trap cleanup EXIT

require_binaries() {
  if [[ ! -x "$SPACES_E2E" || ! -x "$SPACESD_BIN" || ! -x "$SPACES_CLI" ]]; then
    printf 'Building spacesd, spacese2e, spaces...\n'
    (cd "$REPO_ROOT" && "$REPO_ROOT/scripts/swiftpm.sh" build --product spacesd --product spacese2e --product spaces >/dev/null)
  fi
  [[ -x "$SPACES_E2E" ]] || fail "spacese2e not found at $SPACES_E2E"
  [[ -x "$SPACESD_BIN" ]] || fail "spacesd not found at $SPACESD_BIN"
  [[ -x "$SPACES_CLI" ]] || fail "spaces not found at $SPACES_CLI"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required."
  command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required."
}

bind_worktree_profile() {
  PROFILE_DB_PATH="$("$SPACES_E2E" profile-show | awk -F'\t' '$1 == "database-path" { print $2 }')"
  export SPACESD_EXECUTABLE="$SPACESD_BIN"
  [[ -n "$PROFILE_DB_PATH" ]] || fail "profile-show did not report database-path"
  printf '[automation-e2e] profile db=%s\n' "$PROFILE_DB_PATH"
}

provision_fixture() {
  local profile_root workspace
  profile_root="$(dirname "$PROFILE_DB_PATH")"
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
  db_kind="$(sqlite3 "$PROFILE_DB_PATH" "SELECT kind FROM terminal_sessions WHERE session_id='$session_id';")"
  db_run="$(sqlite3 "$PROFILE_DB_PATH" "SELECT automation_run_id FROM terminal_sessions WHERE session_id='$session_id';")"
  db_workspace="$(sqlite3 "$PROFILE_DB_PATH" "SELECT workspace_id FROM terminal_sessions WHERE session_id='$session_id';")"
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
  count="$(sqlite3 "$PROFILE_DB_PATH" "SELECT COUNT(*) FROM terminal_sessions WHERE automation_run_id='$RUN_ID' AND session_id='$session_id';")"
  [[ "$count" == "1" ]] || fail "run's own session was not stamped with automation_run_id=$RUN_ID"
  pass "scenario e: run's own .automation session is stamped with the run id (spawned-agent sweep covered by unit test)"
}

part_f() {
  printf '\n=== Scenario f: agent-kind workspace validation + end-agents on a terminal run ===\n'
  # An automation is bound to a workspace at creation time and the daemon refuses one whose workspace does
  # not resolve, so an agent-kind run can never start against a missing workspace. Deleting a workspace
  # takes its automations with it (an app-managed cascade), which is why there is no "run against a
  # vanished workspace" state to drive here. The rest of the agent-kind lifecycle — spawn a real coding
  # agent, wait for foreground detection, deliver the seed prompt, observe `done` — is scenario g, which
  # needs a real provider; the failure branches around it (spawn failure, deadline miss, session end before
  # delivery) are covered by the workspacecore unit tests (AutomationServiceTests).
  local create_output=""
  if create_output="$("$SPACES_E2E" automation-create --name "e2e-agent-bad-workspace" --kind agent --script "" --agent-command "claude" \
    --agent-prompt "investigate" --workspace-id "nonexistent-workspace-e2e" --trigger manual --concurrency allow 2>&1)"; then
    fail "creating an agent automation for an unresolvable workspace should be refused, got: $create_output"
  fi
  printf '%s' "$create_output" | grep -Fq "Workspace not found" || fail "the refusal did not name the missing workspace: $create_output"
  pass "scenario f.1: an automation whose workspace does not resolve is refused at creation"

  # End-agents on a terminal run is an accepted no-op: it succeeds and leaves the run's status untouched.
  create_automation --name "e2e-end-agents-noop" --script "exit 4" --workspace-id "$WORKSPACE_ID" --trigger manual --concurrency allow
  trigger_run "$AUTOMATION_ID"
  wait_run_status "$AUTOMATION_ID" "$RUN_ID" "failed" || fail "the run did not fail"
  "$SPACES_E2E" automation-end-agents --run-id "$RUN_ID" >/dev/null || fail "end-agents on a terminal run should succeed"
  local status_after
  status_after="$(run_status "$AUTOMATION_ID" "$RUN_ID")"
  [[ "$status_after" == "failed" ]] || fail "end-agents changed the run status to '$status_after', expected failed"
  pass "scenario f.2: end-agents on a terminal run is a no-op and leaves the run failed"
}

# ---------------------------------------------------------------------------

# Fixture directory for the real-provider scenario. It lives inside the checkout (under the ignored build
# directory) because Claude Code asks for folder trust in a project whose tree the user has not accepted,
# and a directory inside the checkout inherits the checkout's trust; a directory under the profile root, or
# one made into a git repo of its own, is a project Claude has never seen and stops at that dialog.
AGENT_FIXTURE_DIR=""

provision_agent_fixture() {
  AGENT_FIXTURE_DIR="$APP_ROOT/.build/automation-agent-e2e-fixture"
  mkdir -p "$AGENT_FIXTURE_DIR"
  local workspace
  workspace="$("$SPACES_E2E" register-project --project-dir "$AGENT_FIXTURE_DIR")"
  AGENT_WORKSPACE_ID="$(json_field "$workspace" 'd["id"]')"
  [[ -n "$AGENT_WORKSPACE_ID" ]] || fail "could not resolve the agent fixture workspace from: $workspace"
  printf '[automation-e2e] agent fixture dir=%s workspace=%s\n' "$AGENT_FIXTURE_DIR" "$AGENT_WORKSPACE_ID"
}

# A session's rendered screen and scrollback, which is what `spaces terminal tail` reconstructs by
# replaying its transcript through a terminal. The raw output log is a stream of repaints where the same
# text appears once per redraw, so only the rendered form can answer "how many times did this happen".
run_session_screen() {
  "$SPACES_CLI" terminal tail "$1" --lines 400 2>/dev/null || true
}

part_g() {
  printf '\n=== Scenario g: real coding agent (claude) seed-prompt delivery ===\n'
  if ! command -v claude >/dev/null 2>&1; then
    printf 'SKIP: scenario g needs the `claude` CLI on PATH; it is the real-provider ground truth for seed-prompt delivery.\n'
    return 0
  fi
  provision_agent_fixture

  # Multi-line on purpose: the prompt goes to the agent as one paste, and Claude Code collapses a
  # multi-line paste to a "[Pasted text]" placeholder in the composer — so NONE of these lines is on
  # screen until the prompt is actually submitted and rendered as a message. The reply is a word to copy
  # rather than anything to reason about, so a wrong answer means delivery failed, not that the model
  # slipped. Submitting once therefore puts the reply token on screen exactly twice: the message and the
  # answer.
  local marker="ZZPROMPT-E2E" answer="ZZREPLY-OK"
  local prompt="$marker-L1 This is an automation seed prompt delivered by Spaces.
$marker-L2 Do not read or write any files and do not run any commands.
$marker-L3 Reply with exactly $answer and nothing else."

  create_automation --name "e2e-agent-claude" --kind agent --script "" --agent-command "claude --model haiku" \
    --agent-prompt "$prompt" --workspace-id "$AGENT_WORKSPACE_ID" --trigger manual --concurrency allow
  trigger_run "$AUTOMATION_ID"
  local run_id="$RUN_ID" session_id=""
  local start deadline_seconds=240
  start="$(now_ms)"
  while [[ -z "$session_id" ]]; do
    session_id="$(run_field "$AUTOMATION_ID" "$run_id" '"terminalSessionID"')"
    [[ "$session_id" == "None" ]] && session_id=""
    (( "$(now_ms)" - start < 30000 )) || fail "the agent run never recorded a terminal session"
    [[ -n "$session_id" ]] || sleep 0.3
  done
  printf '[automation-e2e] agent session=%s\n' "$session_id"

  # Poll for the agent's answer. A folder-trust dialog means this machine has never accepted the checkout in
  # Claude Code; that is an environment gap, not a delivery failure, so it skips rather than fails.
  local screen="" delivered_at=""
  start="$(now_ms)"
  while true; do
    screen="$(run_session_screen "$session_id")"
    if printf '%s' "$screen" | grep -Fq "trust this folder"; then
      printf 'SKIP: claude asked for folder trust in %s; accept it once (run `claude` there) and re-run scenario g.\n' "$AGENT_FIXTURE_DIR"
      return 0
    fi
    # Two occurrences: the submitted message plus the agent's reply. One is only the message.
    (( "$(printf '%s' "$screen" | grep -o "$answer" | wc -l)" >= 2 )) && break
    if (( "$(now_ms)" - start >= deadline_seconds * 1000 )); then
      printf '%s\n' "$screen" | tail -40 >&2
      fail "the agent never answered the seed prompt within ${deadline_seconds}s (delivery did not reach it)"
    fi
    sleep 1
  done
  pass "scenario g.1: the agent answered the seed prompt"

  # Delivery is recorded from the terminal's own reaction, which the run observes on its next ticks — the
  # agent can start answering before the ladder has seen enough to record it.
  start="$(now_ms)"
  while true; do
    delivered_at="$(sqlite3 "$PROFILE_DB_PATH" "SELECT COALESCE(prompt_delivered_at, '') FROM automation_runs WHERE id='$run_id';")"
    [[ -n "$delivered_at" ]] && break
    (( "$(now_ms)" - start < 30000 )) || fail "the run answered its prompt but never recorded a delivery timestamp"
    sleep 0.5
  done
  pass "scenario g.2: the run recorded the prompt as delivered"

  # The whole prompt reached the agent: a multi-line paste shows as a placeholder in the composer, so its
  # lines are on screen only because the agent submitted and rendered the message.
  local line
  for line in "$marker-L1" "$marker-L2" "$marker-L3"; do
    printf '%s' "$screen" | grep -Fq "$line" || fail "the agent's transcript is missing prompt line '$line' — the prompt arrived truncated"
  done
  pass "scenario g.3: every line of the multi-line prompt reached the agent"

  # Submitted exactly once. A re-sent prompt is a second user message the agent answers again, so the
  # delivery ladder duplicating work shows up as a second answer on the rendered screen. The wait covers the
  # ladder's own retry budget (a few one-second ticks) so a late duplicate is not missed.
  sleep 12
  screen="$(run_session_screen "$session_id")"
  local answers submissions
  answers="$(printf '%s' "$screen" | grep -o "$answer" | wc -l | tr -d ' ')"
  submissions="$(printf '%s' "$screen" | grep -o "$marker-L1" | wc -l | tr -d ' ')"
  [[ "$submissions" == "1" ]] || fail "the prompt appears $submissions times in the agent's transcript, expected exactly 1 (a re-send duplicated the work)"
  [[ "$answers" == "2" ]] || fail "the reply token appears $answers times, expected 2 (one submitted message and one answer)"
  pass "scenario g.4: the prompt was submitted exactly once"
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
  part_g
  printf '\nAll automation e2e scenarios passed.\n'
}

main "$@"
