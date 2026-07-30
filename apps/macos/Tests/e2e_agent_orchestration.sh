#!/usr/bin/env bash
# Daemon+CLI end-to-end for the `spaces agent` orchestration surface. No app, desktop control, or
# hotkeys: it drives the worktree-scoped profile daemon purely through the `spaces` CLI.
#
# Every binary the script drives lives in this checkout and resolves the worktree profile from its own
# location, so it only ever talks to this checkout's daemon and never another worktree's, with no profile
# environment set anywhere. The daemon is autolaunched on the first CLI call; the script never stops
# another profile's daemon or app.
#
# Part A (always runnable, no real coding agents): the orchestration lifecycle is driven with explicit
# `spaces agent signal` events against two ordinary shell sessions (orchestrator O and child C). Those
# flows (list/annotate/status, subscribe + notification injection, busy-subscriber queue/flush, cycle
# rejection, kill) need deterministic signal control that real agents cannot give. It then covers the two
# `agent spawn` behaviors that are deterministic without a real coding agent — failing as soon as the
# child exits, and running the command through the interactive login shell — with a fixture binary named
# after a supported agent. Detection of the real providers stays in the opt-in Part B matrix.
#
# Part B (opt-in, real coding agents; SPACES_E2E_AGENT_MATRIX=1): for each provider whose binary is on
# PATH, spawn the agent (detection-only — spawn delivers no prompt), then drive the real orchestrator
# flow itself: `terminal send text ... --submit`, poll `terminal tail` for the reply, and record the
# hook signal sequence via `agent status` polling. `--submit` is the one intended way to submit a
# prompt — it sends the text as a paste, then a separate Enter keystroke, so every supported agent TUI
# (Claude Code, Codex, OpenCode) runs the line instead of leaving it as an unsubmitted paste; no
# per-provider send sequence is needed here. A non-zero spawn (detection
# failure) or a row surviving kill is a per-provider FAIL; a missing reply is only recorded, because it
# depends on the environment (an auth-gated or trust/onboarding-dialog-blocked provider answers nothing
# until a human clears the dialog, which is exactly the state spawn no longer tries to handle). Hooks are
# not a spawn prerequisite, so no provider is skipped for hook state; only a missing binary skips. This
# section installs nothing and leaves the user's real agent configs untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
BUILD_DIR="$APP_ROOT/.build/debug"
SPACES_CLI="$BUILD_DIR/spaces"
SPACES_E2E="$BUILD_DIR/spacese2e"
SPACESD_BIN="$BUILD_DIR/spacesd"
source "$REPO_ROOT/scripts/spaces-profile-helpers.sh"

MATRIX_ENABLED="${SPACES_E2E_AGENT_MATRIX:-0}"
# Providers probed by Part B: <SupportedCodingAgentHook display> maps to the PATH executable name.
MATRIX_PROVIDERS=(claude codex opencode)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# Session ids created here so cleanup can tear them down without touching anything else on the profile.
CREATED_SESSIONS=()

cleanup() {
  local session_id
  for session_id in "${CREATED_SESSIONS[@]:-}"; do
    [[ -n "$session_id" ]] || continue
    # Kill the agent row (if any) and terminate the terminal session. Both are best-effort: a session
    # already killed by the test body must not turn cleanup into a failure.
    "$SPACES_CLI" agent kill "$session_id" >/dev/null 2>&1 || true
    "$SPACES_E2E" terminate-terminal-session "$session_id" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

require_binaries() {
  if [[ ! -x "$SPACES_CLI" || ! -x "$SPACES_E2E" || ! -x "$SPACESD_BIN" ]]; then
    printf 'Building spaces, spacesd, spacese2e...\n'
    (cd "$REPO_ROOT" && "$REPO_ROOT/scripts/swiftpm.sh" build --product spaces --product spacesd --product spacese2e >/dev/null)
  fi
  [[ -x "$SPACES_CLI" ]] || fail "spaces CLI not found at $SPACES_CLI"
  [[ -x "$SPACES_E2E" ]] || fail "spacese2e not found at $SPACES_E2E"
  [[ -x "$SPACESD_BIN" ]] || fail "spacesd not found at $SPACESD_BIN"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required."
}

resolve_worktree_profile() {
  # The binaries this script drives all live in this checkout, so each resolves the worktree profile
  # from its own location -- there is nothing to bind, and a binding this shell was started with would
  # either abort the run or point it at another profile entirely. This is the first thing main() does,
  # so everything below runs unbound. See spaces_profile_clear_inherited_binding.
  spaces_profile_clear_inherited_binding
  # The root is looked up only because the fixture directory below lives inside it; the database path is
  # how the lifecycle-event assertions read what the daemon recorded (no CLI reports the event log).
  local profile_json
  profile_json="$("$SPACES_E2E" profile-show --json)"
  PROFILE_ROOT="$(json_field "$profile_json" 'd["profileRoot"]')"
  DB_PATH="$(json_field "$profile_json" 'd["databasePath"]')"
  [[ -n "$PROFILE_ROOT" ]] || fail "profile-show did not report a profile root"
  [[ -n "$DB_PATH" ]] || fail "profile-show did not report a database path"
  # Pin the daemon binary to the debug build so autolaunch uses this checkout's spacesd.
  export SPACESD_EXECUTABLE="$SPACESD_BIN"
  printf '[agent-e2e] profile root=%s\n' "$PROFILE_ROOT"
}

extract_session_id() {
  printf '%s\n' "$1" | sed -nE 's/^Started terminal session ([0-9A-F-]{36})([[:space:]].*)?$/\1/p' | tail -n 1
}

# Opens a terminal session running `command` in the fixture workspace, records it for cleanup, and
# returns its id in the global OPENED_SESSION_ID. It sets a global rather than printing into a command
# substitution so the `CREATED_SESSIONS` append lands in the caller's shell, not a subshell.
OPENED_SESSION_ID=""
open_session() {
  local title="$1" command="$2" out session_id
  out="$("$SPACES_CLI" terminal command --workspace "$FIXTURE_WORKSPACE_ID" --command "$command" --title "$title")"
  session_id="$(extract_session_id "$out")"
  [[ -n "$session_id" ]] || fail "could not parse session id for $title from: $out"
  CREATED_SESSIONS+=("$session_id")
  OPENED_SESSION_ID="$session_id"
}

signal() {
  local session_id="$1" event="$2"
  "$SPACES_CLI" agent signal --workspace "$FIXTURE_WORKSPACE_ID" --session "$session_id" "$event" >/dev/null
}

# Number of tail lines on `session` that contain `needle`.
tail_count() {
  local session_id="$1" needle="$2"
  "$SPACES_CLI" terminal tail "$session_id" --lines 120 | grep -Fc "$needle" || true
}

# Polls for the injected notification block in the subscriber's tail. The block is multi-line — a
# `[spaces] <label> (<kind>) is <transition>` sentence line followed by two-space-indented `key: value`
# lines — so the fragments land on separate lines and are checked independently against the whole tail
# rather than chained per-line. `session: <child>` pins the child's session field and
# `link: spaces://terminal/<child>` its deep link, both of which the block always carries.
wait_for_notification() {
  local subscriber="$1" transition="$2" child="$3" timeout="${4:-15}" start tail
  start="$(now_ms)"
  while true; do
    tail="$("$SPACES_CLI" terminal tail "$subscriber" --lines 120)"
    if printf '%s\n' "$tail" | grep -Fq "[spaces]" \
      && printf '%s\n' "$tail" | grep -Fq "is $transition" \
      && printf '%s\n' "$tail" | grep -Fq "session: $child" \
      && printf '%s\n' "$tail" | grep -Fq "link: spaces://terminal/$child"; then
      return 0
    fi
    if (( "$(now_ms)" - start >= timeout * 1000 )); then
      printf 'Timed out waiting for "%s" notification for %s in %s tail:\n' "$transition" "$child" "$subscriber" >&2
      "$SPACES_CLI" terminal tail "$subscriber" --lines 120 >&2
      return 1
    fi
    sleep 0.2
  done
}

json_field() {
  # json_field <json> <python-expr over `d`>
  printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2"
}

# How many lifecycle events of one type and source the daemon recorded for an agent row. Read straight
# from the database because the event log is the daemon's own record of what it finalized and no CLI
# surfaces it; a duplicate here is what turns into a duplicate injected block for every subscriber.
agent_event_count() {
  local agent_id="$1" event_type="$2" event_source="$3"
  python3 - "$DB_PATH" "$agent_id" "$event_type" "$event_source" <<'PY'
import sqlite3
import sys

db_path, agent_id, event_type, event_source = sys.argv[1:5]
with sqlite3.connect(db_path) as db:
    row = db.execute(
        "SELECT COUNT(*) FROM agent_session_events WHERE agent_session_id = ? AND event_type = ? AND source = ?",
        (agent_id, event_type, event_source),
    ).fetchone()
print(row[0] if row else 0)
PY
}

# The pid of a session's current foreground process, as the daemon's foreground sampler recorded it —
# the process its agent classification was made from, and so exactly the process to quit to simulate a
# coding agent exiting on its own.
foreground_pid() {
  local session_id="$1"
  python3 - "$DB_PATH" "$session_id" <<'PY'
import sqlite3
import sys

db_path, session_id = sys.argv[1:3]
with sqlite3.connect(db_path) as db:
    row = db.execute("SELECT foreground_pid FROM terminal_runtime_states WHERE session_id = ?", (session_id,)).fetchone()
print(row[0] if row and row[0] else "")
PY
}

provision_fixture() {
  # Stable fixture directory under the profile root so re-runs reuse one project row instead of
  # accumulating (there is no project-removal CLI). register-project is idempotent for the same dir.
  FIXTURE_DIR="$PROFILE_ROOT/agent-orchestration-e2e-fixture"
  mkdir -p "$FIXTURE_DIR"
  local register_json
  register_json="$("$SPACES_E2E" register-project --project-dir "$FIXTURE_DIR")"
  FIXTURE_WORKSPACE_ID="$(json_field "$register_json" 'd["id"]')"
  [[ -n "$FIXTURE_WORKSPACE_ID" ]] || fail "could not resolve fixture workspace id from: $register_json"
  printf '[agent-e2e] fixture workspace=%s dir=%s\n' "$FIXTURE_WORKSPACE_ID" "$FIXTURE_DIR"

  # A stand-in coding agent for the hookless-exit step. Foreground detection classifies a process by its
  # executable and argv[0] basename, so a `codex`-named symlink to `sleep` is classified exactly as the
  # real CLI is — and, like codex and opencode, it emits no session-end hook when it quits, which is the
  # case only the daemon's foreground reconciler can finalize. Part A stays real-agent-free.
  FAKE_AGENT_BIN="$FIXTURE_DIR/bin/codex"
  mkdir -p "$FIXTURE_DIR/bin"
  ln -sf /bin/sleep "$FAKE_AGENT_BIN"
}

# ---------------------------------------------------------------------------
# Part A: signal-driven core flow
# ---------------------------------------------------------------------------

part_a() {
  printf '\n=== Part A: signal-driven orchestration flow ===\n'

  # Child C stays alive to receive signals; orchestrator O runs `cat` with echo off so an injected
  # notification appears exactly once in its tail (no tty echo doubling).
  local C O
  open_session child-C "python3 -c 'import time; time.sleep(600)'"
  C="$OPENED_SESSION_ID"
  open_session orch-O 'stty -echo; cat'
  O="$OPENED_SESSION_ID"
  printf '[agent-e2e] child C=%s orchestrator O=%s\n' "$C" "$O"
  sleep 2

  # Step 1: init creates the agent row (ready), annotate sets a note, working preserves it.
  signal "$C" init
  local list_json ready status note
  list_json="$("$SPACES_CLI" agent list --json)"
  ready="$(json_field "$list_json" '"yes" if any(r.get("terminalSessionID")=="'"$C"'" and r.get("lastSignalAt") for r in d) else "no"')"
  [[ "$ready" == "yes" ]] || fail "agent list did not show C=$C ready after init: $list_json"
  "$SPACES_CLI" agent status --session "$C" >/dev/null || fail "agent status --session C failed"
  pass "step 1a: init created a ready agent row for C"

  "$SPACES_CLI" agent annotate "investigating flaky test" --session "$C" >/dev/null
  signal "$C" working
  local status_json
  status_json="$("$SPACES_CLI" agent status --session "$C" --json)"
  note="$(json_field "$status_json" 'd.get("note") or ""')"
  status="$(json_field "$status_json" 'd.get("status") or ""')"
  [[ "$note" == "investigating flaky test" ]] || fail "note was clobbered by working signal: note=$note"
  [[ "$status" == "spinning" ]] || fail "expected status spinning after working, got: $status"
  pass "step 1b: annotate note survived a later working signal (status=$status)"

  # Step 2: O subscribes to C; C blocked (O idle) injects the notification into O's tail.
  "$SPACES_CLI" agent subscribe "$C" --subscriber "$O" >/dev/null || fail "subscribe O->C failed"
  signal "$C" blocked
  wait_for_notification "$O" blocked "$C" || fail "blocked notification never reached O"
  pass "step 2: subscribe + blocked injected the notification line into O's tail"

  # Step 3: make O busy, signal C done -> queued (no delivery); then O done -> flush delivers it.
  signal "$O" init
  signal "$O" working
  status="$(json_field "$("$SPACES_CLI" agent status --session "$O" --json)" 'd.get("status") or ""')"
  [[ "$status" == "spinning" ]] || fail "expected O busy (spinning) before queue test, got: $status"
  # The needle pins the block's `note:` continuation line carrying the annotation set in step 1b, so a
  # status transition must not drop the note from the injected notification. The note text is unique to C
  # in this fixture, so counting its line tracks C's done block specifically.
  local done_needle="note: investigating flaky test"
  local before_done
  before_done="$(tail_count "$O" "$done_needle")"
  signal "$C" "done"
  sleep 1.5
  local queued
  queued="$(tail_count "$O" "$done_needle")"
  [[ "$queued" == "$before_done" ]] || fail "C done leaked to a busy O (before=$before_done now=$queued): expected it queued"
  pass "step 3a: C done while O busy was queued, not delivered"
  signal "$O" "done"
  local flush_start after_done
  flush_start="$(now_ms)"
  while true; do
    after_done="$(tail_count "$O" "$done_needle")"
    (( after_done > before_done )) && break
    if (( "$(now_ms)" - flush_start >= 15000 )); then
      fail "queued done notification was not flushed after O became idle (count still $after_done)"
    fi
    sleep 0.2
  done
  pass "step 3b: queued done notification flushed once O went idle"

  # Step 4: subscribing C to O closes the O->C cycle and must be rejected loudly.
  local cycle_err
  if cycle_err="$("$SPACES_CLI" agent subscribe "$O" --subscriber "$C" 2>&1)"; then
    fail "cycle-closing subscribe unexpectedly succeeded: $cycle_err"
  fi
  printf '%s' "$cycle_err" | grep -Fqi "cycle" || fail "cycle rejection lacked a cycle message: $cycle_err"
  pass "step 4: cycle-closing subscribe was rejected"

  # Step 5: kill notifies watchers and removes the row; a bogus session id is a loud error. C is
  # sitting `.done` (turn-complete, still live) from step 3 — the most common kill scenario — so the
  # kill must still deliver O exactly one exited notice: `.done` is a live resting state, not a
  # finalized one.
  "$SPACES_CLI" agent kill "$C" >/dev/null || fail "kill C failed"
  wait_for_notification "$O" exited "$C" || fail "exited notification never reached O after killing turn-complete C"
  pass "step 5a-exit: killing turn-complete (.done) C delivered the exited notice to O"
  sleep 1
  local still_present
  still_present="$(json_field "$("$SPACES_CLI" agent list --json)" '"yes" if any(r.get("terminalSessionID")=="'"$C"'" for r in d) else "no"')"
  [[ "$still_present" == "no" ]] || fail "C still present in agent list after kill"
  pass "step 5a: kill C removed its row from agent list"
  # A session that never existed has neither an agent row nor an on-disk terminal record, so it hits
  # the loud "no agent session" error. (Re-killing C itself is not a loud error: the killed session's
  # on-disk record lingers, so a second kill re-terminates it and returns success -- see the report.)
  local bogus_err
  if bogus_err="$("$SPACES_CLI" agent kill "00000000-0000-0000-0000-000000000000" 2>&1)"; then
    fail "killing a nonexistent session unexpectedly succeeded: $bogus_err"
  fi
  printf '%s' "$bogus_err" | grep -Fqi "no agent session" || fail "bogus kill lacked the expected error: $bogus_err"
  pass "step 5b: killing a nonexistent session errored loudly"

  spawn_fails_fast_when_the_child_exits
  spawn_runs_the_command_through_the_login_environment
  part_a_hookless_exit

  printf '=== Part A passed ===\n'
}

# Step 6: a spawn whose command cannot run must fail as soon as the daemon records the child's exit,
# naming that exit — not the foreground classifier, which never had anything to classify. The command
# passes spawn's supported-agent gate (the gate reads the executable basename) but names a path that does
# not exist, so the child dies within a second while the detection budget is 90s.
spawn_fails_fast_when_the_child_exits() {
  local missing_command start_ms elapsed_ms spawn_out spawn_status session_id
  missing_command="$FIXTURE_DIR/no-such-bin/claude"
  start_ms="$(now_ms)"
  set +e
  spawn_out="$("$SPACES_CLI" agent spawn --workspace "$FIXTURE_WORKSPACE_ID" --command "$missing_command" 2>&1)"
  spawn_status=$?
  set -e
  # Unquoted on purpose: `$(( ))` does not strip quotes the way `(( ))` does, so a quoted command
  # substitution here is a literal token and an arithmetic syntax error.
  elapsed_ms=$(( $(now_ms) - start_ms ))
  # The failed spawn leaves its session record behind; record it so cleanup tears it down.
  session_id="$(printf '%s' "$spawn_out" | sed -nE 's/.*Agent session ([0-9A-F-]{36}).*/\1/p' | head -n 1)"
  if [[ -n "$session_id" ]]; then
    CREATED_SESSIONS+=("$session_id")
  fi

  (( spawn_status != 0 )) || fail "spawning a command that cannot run unexpectedly succeeded: $spawn_out"
  (( elapsed_ms < 10000 )) || fail "spawn took ${elapsed_ms}ms to report a child that exited immediately (detection budget is 90s): $spawn_out"
  printf '%s' "$spawn_out" | grep -Fq "before it was detected as a running coding agent" \
    || fail "spawn failure did not name the child's exit: $spawn_out"
  if printf '%s' "$spawn_out" | grep -Fq "foreground classification"; then
    fail "spawn failure blamed foreground classification for a child that never ran: $spawn_out"
  fi
  pass "step 6: spawn of an unrunnable command failed in ${elapsed_ms}ms naming the child's exit"
}

# Step 7: a spawned command runs through the interactive login shell, so it resolves whatever the user's
# own terminal resolves — `claude` in `~/.local/bin`, an fnm/nvm/asdf-managed runtime — instead of only
# what the profile files put on PATH.
#
# The fixture agent is a symlink to zsh named `opencode`: the name is what spawn's supported-agent gate
# and the daemon's foreground classifier match on (the classifier reads argv[0], which carries the
# symlink path), and a symlink runs the real signed zsh, which a copy of a system binary would not. It
# runs a probe script that counts the PATH entries it was given that a NON-interactive login shell would
# not have produced, then blocks on the `read` builtin so it stays the terminal's foreground process for
# detection to identify.
#
# That count is the regression guard: it is zero for a `-l`-only shell and non-zero once `~/.zshrc` runs.
# The same probe is run locally under a scrubbed interactive login shell first; when it finds nothing
# there, this machine's shell setup has nothing to assert and the step says so instead of pretending to
# cover it.
spawn_runs_the_command_through_the_login_environment() {
  local bin_dir agent_path probe_script spawn_out child detected tail_text baseline_extra
  bin_dir="$FIXTURE_DIR/login-path-bin"
  agent_path="$bin_dir/opencode"
  probe_script="$FIXTURE_DIR/login-path-probe.zsh"
  mkdir -p "$bin_dir"
  rm -f "$agent_path"
  ln -s /bin/zsh "$agent_path"
  cat > "$probe_script" <<'PROBE'
baseline=("${(@f)$(env -i HOME=$HOME /bin/zsh -l -c 'print -rl -- $path')}")
extra=(${path:|baseline})
print -r -- "spawnpathextra=${#extra}"
# Blocks so the spawned agent stays the terminal's foreground process for detection to identify. The
# baseline run below feeds it /dev/null, where `read` returns 1 at EOF — tolerated so that a probe
# doing exactly what it was asked cannot fail the step under `set -e`/`pipefail`.
read || true
PROBE

  baseline_extra="$(env -i HOME="$HOME" TERM=dumb /bin/zsh -l -i "$probe_script" </dev/null 2>/dev/null \
    | sed -nE 's/^spawnpathextra=([0-9]+)$/\1/p' | tail -n 1)"
  if [[ -z "$baseline_extra" || "$baseline_extra" == "0" ]]; then
    printf '[agent-e2e] step 7 skipped: this machine'"'"'s interactive login shell adds no PATH entries a login shell alone lacks.\n'
    return 0
  fi

  spawn_out="$("$SPACES_CLI" agent spawn --workspace "$FIXTURE_WORKSPACE_ID" --json --command "$agent_path -f $probe_script")" \
    || fail "spawning the fixture agent failed: $spawn_out"
  child="$(json_field "$spawn_out" 'd.get("terminalSessionID")')"
  [[ -n "$child" ]] || fail "fixture agent spawn returned no session: $spawn_out"
  CREATED_SESSIONS+=("$child")
  detected="$(json_field "$spawn_out" 'd.get("detectedAgent") or "?"')"
  [[ "$detected" == "opencode" ]] || fail "fixture agent was detected as '$detected', expected opencode"
  pass "step 7a: spawn detected the fixture coding agent and returned"

  # The rendered tail wraps at the terminal width, so newlines are stripped before matching. The probe
  # prints before the agent is detectable, so this is a short settle poll rather than a real wait.
  local start_ms
  start_ms="$(now_ms)"
  while true; do
    tail_text="$("$SPACES_CLI" terminal tail "$child" --lines 120 | tr -d '\n')"
    if printf '%s' "$tail_text" | grep -Eq 'spawnpathextra=[0-9]'; then
      break
    fi
    if (( "$(now_ms)" - start_ms >= 10000 )); then
      fail "fixture agent never reported its PATH entry count: $tail_text"
    fi
    sleep 0.2
  done
  printf '%s' "$tail_text" | grep -Eq 'spawnpathextra=[1-9]' \
    || fail "spawned command did not get the interactive-login PATH (local shell adds $baseline_extra entries): $tail_text"
  pass "step 7b: spawned command ran with the interactive-login PATH"
}

# Step 8: a coding agent that emits no session-end hook (codex and opencode never do) quits on its own,
# leaving its shell alive. Only the daemon's foreground reconciler can observe that, and two of its
# reconcile loops see the same transition, so this pins the two facts a subscribed orchestrator depends
# on: one exit is announced exactly once, and the announcement names the child's coding agent.
part_a_hookless_exit() {
  [[ -n "${SHELL:-}" ]] || fail "SHELL must be set: this step runs the same login shell Spaces launches sessions with."
  local K W agent_id agent_pid
  # The inner interactive login shell is what hands the agent the terminal foreground (job control),
  # exactly as a user-typed `codex` gets it. `read` is a shell builtin, so once the agent is gone the
  # shell ITSELF is the foreground process — the plain-shell revert the reconciler finalizes on, with the
  # terminal still alive.
  open_session child-K "exec $SHELL -ilc '\"$FAKE_AGENT_BIN\" 600; read -r _'"
  K="$OPENED_SESSION_ID"
  open_session orch-W 'stty -echo; cat'
  W="$OPENED_SESSION_ID"
  printf '[agent-e2e] hookless child K=%s watcher W=%s\n' "$K" "$W"

  # Wait for foreground detection to classify the child, which is also what proves the kind is known
  # BEFORE the exit — the state the exited block has to still report afterwards.
  local detect_start list_json detected
  detect_start="$(now_ms)"
  while true; do
    list_json="$("$SPACES_CLI" agent list --json)"
    detected="$(json_field "$list_json" 'next((r.get("agent") or "" for r in d if r.get("terminalSessionID")=="'"$K"'"), "")')"
    if [[ "$detected" == "codex" ]]; then
      break
    fi
    if (( "$(now_ms)" - detect_start >= 45000 )); then
      fail "foreground detection never classified K=$K as codex: $list_json"
    fi
    sleep 0.3
  done
  agent_id="$(json_field "$list_json" 'next((r["id"] for r in d if r.get("terminalSessionID")=="'"$K"'"), "")')"
  [[ -n "$agent_id" ]] || fail "could not resolve the agent row id for K=$K"
  pass "step 8a: the child was detected as codex before it exited"

  # A subscribe requires hook evidence, which a hookless agent still produces for its turns; only its
  # session END is missing.
  signal "$K" working
  "$SPACES_CLI" agent subscribe "$K" --subscriber "$W" >/dev/null || fail "subscribe W->K failed"

  agent_pid="$(foreground_pid "$K")"
  [[ -n "$agent_pid" ]] || fail "no foreground pid recorded for K=$K"
  kill "$agent_pid" || fail "could not quit the detected agent process (pid=$agent_pid) for K=$K"

  wait_for_notification "$W" exited "$K" || fail "the hookless exit never reached the subscriber W"
  pass "step 8b: the hookless exit was announced to the subscriber"

  # Settle before counting: the duplicate this pins was a second reconcile pass recording the same exit
  # within the same second as the first.
  sleep 3
  local exited_blocks kind_blocks reconciler_exits
  exited_blocks="$(tail_count "$W" "is exited")"
  [[ "$exited_blocks" == "1" ]] || fail "expected exactly one injected exited block in W's tail, got $exited_blocks"
  pass "step 8c: one child exit injected exactly one exited block"
  kind_blocks="$(tail_count "$W" "(codex) is exited")"
  if [[ "$kind_blocks" != "1" ]]; then
    "$SPACES_CLI" terminal tail "$W" --lines 120 >&2
    fail "the injected block did not name the child's coding agent (codex)"
  fi
  pass "step 8d: the injected block named the child's coding agent"
  reconciler_exits="$(agent_event_count "$agent_id" exit foreground_reconciler)"
  [[ "$reconciler_exits" == "1" ]] || fail "expected exactly one reconciler exit event for K=$K, got $reconciler_exits"
  pass "step 8e: exactly one reconciler exit was recorded for the child"
}

# ---------------------------------------------------------------------------
# Part B: opt-in real-provider matrix
# ---------------------------------------------------------------------------

MATRIX_FAILURES=0

# Drives one provider. Prints a `provider=... SKIP/FAIL/OK ...` report line. Never aborts the script:
# a provider failure increments MATRIX_FAILURES and returns so the next provider still runs.
matrix_provider() {
  local binary="$1"
  if ! command -v "$binary" >/dev/null 2>&1; then
    printf 'provider=%s SKIP reason=binary-not-on-path\n' "$binary"
    return 0
  fi

  # Spawn is detection-only now: it blocks until the daemon's foreground classifier identifies the agent
  # and delivers no prompt. A non-zero spawn is a detection failure and a real per-provider FAIL. Measure
  # how long the blocking spawn took.
  local spawn_out spawn_status start_ms end_ms child
  start_ms="$(now_ms)"
  set +e
  spawn_out="$("$SPACES_CLI" agent spawn --command "$binary" --workspace "$FIXTURE_WORKSPACE_ID" --timeout 120 --json 2>&1)"
  spawn_status=$?
  set -e
  end_ms="$(now_ms)"
  if (( spawn_status != 0 )); then
    printf 'provider=%s FAIL reason=spawn-detection-error detail=%s\n' "$binary" "$(printf '%s' "$spawn_out" | tr '\n' ' ')"
    MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
    return 0
  fi

  child="$(json_field "$spawn_out" 'd.get("terminalSessionID")')"
  CREATED_SESSIONS+=("$child")
  local spawn_ms detected
  spawn_ms=$((end_ms - start_ms))
  detected="$(json_field "$spawn_out" 'd.get("detectedAgent") or "?"')"

  # This is the real orchestrator flow spawn no longer does: submit the prompt text with one call.
  # `--submit` is provider-neutral (Claude Code, Codex, OpenCode all submit on it), so no separate
  # carriage-return send is needed. If a trust/onboarding/auth dialog is holding input, the send lands
  # in the dialog and no reply comes — recorded, not failed.
  "$SPACES_CLI" terminal send text "$child" 'reply with exactly: pong' --submit >/dev/null 2>&1 || true

  # Poll the hook status sequence (distinct consecutive statuses), the first-signal marker (lastSignalAt
  # becomes set on the agent's first hook signal), and watch the tail for the reply. Signals enrich this
  # record but are not required — spawn already unblocked on detection alone.
  local sequence="" seq_start last=""
  seq_start="$(now_ms)"
  local saw_reply=0 first_signal=no
  while true; do
    local status_json st
    status_json="$("$SPACES_CLI" agent status --session "$child" --json 2>/dev/null || echo '{}')"
    st="$(json_field "$status_json" 'd.get("status") or "?"')"
    if [[ "$first_signal" == "no" ]]; then
      first_signal="$(json_field "$status_json" '"yes" if d.get("lastSignalAt") else "no"')"
    fi
    if [[ "$st" != "$last" && "$st" != "?" ]]; then
      sequence="${sequence:+$sequence,}$st"
      last="$st"
    fi
    if "$SPACES_CLI" terminal tail "$child" --lines 120 2>/dev/null | grep -Fqi "pong"; then
      saw_reply=1
    fi
    if [[ "$st" == "done" ]]; then
      break
    fi
    if (( "$(now_ms)" - seq_start >= 90000 )); then
      break
    fi
    sleep 0.5
  done

  printf 'provider=%s detected=%s spawn_ms=%s first_signal=%s signal_sequence=%s saw_reply=%s\n' \
    "$binary" "$detected" "$spawn_ms" "$first_signal" "${sequence:-none}" "$saw_reply"

  "$SPACES_CLI" agent kill "$child" >/dev/null 2>&1 || true
  sleep 1
  local gone
  gone="$(json_field "$("$SPACES_CLI" agent list --json)" '"yes" if not any(r.get("terminalSessionID")=="'"$child"'" for r in d) else "no"')"
  if [[ "$gone" != "yes" ]]; then
    printf 'provider=%s FAIL reason=row-survived-kill\n' "$binary"
    MATRIX_FAILURES=$((MATRIX_FAILURES + 1))
    return 0
  fi
  # The per-provider pass criterion is spawn detection + clean kill. saw_reply is reported but NOT
  # required: whether the agent answers depends on the environment (auth-gated or dialog-blocked
  # providers reply nothing until a human intervenes), and driving the prompt is the orchestrator's job,
  # which this script only exercises opportunistically.
  printf 'provider=%s OK saw_reply=%s\n' "$binary" "$saw_reply"
}

part_b() {
  printf '\n=== Part B: opt-in provider matrix ===\n'
  local binary
  for binary in "${MATRIX_PROVIDERS[@]}"; do
    matrix_provider "$binary"
  done
  if (( MATRIX_FAILURES > 0 )); then
    fail "provider matrix had $MATRIX_FAILURES failing provider(s) (skips do not fail)."
  fi
  printf '=== Part B passed (no attempted provider failed) ===\n'
}

main() {
  require_binaries
  resolve_worktree_profile
  provision_fixture
  part_a
  if [[ "$MATRIX_ENABLED" == "1" ]]; then
    part_b
  else
    printf '\n[agent-e2e] Part B provider matrix skipped (set SPACES_E2E_AGENT_MATRIX=1 to run it).\n'
  fi
  printf '\nSpaces agent orchestration E2E passed.\n'
}

main "$@"
