#!/usr/bin/env bash
# Daemon+CLI end-to-end for the `spaces agent` orchestration surface. No app, desktop control, or
# hotkeys: it drives the worktree-scoped profile daemon purely through the `spaces` CLI.
#
# The script binds to the current worktree profile (SPACES_DB_PATH / SPACES_RUNTIME_DIR from
# `spacese2e profile-show --shell`) so it only ever talks to this checkout's daemon and never another
# worktree's. The daemon is autolaunched on the first CLI call; the script never stops another
# profile's daemon or app.
#
# Part A (always runnable, no real coding agents): the orchestration lifecycle is driven with explicit
# `spaces agent signal` events against two ordinary shell sessions (orchestrator O and child C). It does
# not use `agent spawn` — spawn readiness is foreground detection of a real coding agent, which is not
# hermetic, and these flows (list/annotate/status, subscribe + notification injection, busy-subscriber
# queue/flush, cycle rejection, interrupt, kill) need deterministic signal control that real agents
# cannot give. Spawn's detection readiness is covered by unit tests and the opt-in Part B matrix.
#
# Part B (opt-in, real coding agents; SPACES_E2E_AGENT_MATRIX=1): for each provider whose binary is on
# PATH, spawn the agent (detection-only — spawn delivers no prompt), then drive the real orchestrator
# flow itself: `terminal send` the prompt text plus a carriage return, poll `terminal tail` for the
# reply, and record the hook signal sequence via `agent status` polling. A non-zero spawn (detection
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

bind_worktree_profile() {
  # Bind to this worktree's profile so the daemon this script drives is scoped to the checkout.
  eval "$("$SPACES_E2E" profile-show --shell)"
  # Pin the daemon binary to the debug build so autolaunch uses this checkout's spacesd.
  export SPACESD_EXECUTABLE="$SPACESD_BIN"
  [[ -n "${SPACES_DB_PATH:-}" ]] || fail "profile-show did not export SPACES_DB_PATH"
  printf '[agent-e2e] profile db=%s\n' "$SPACES_DB_PATH"
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

provision_fixture() {
  # Stable fixture directory under the profile root so re-runs reuse one project row instead of
  # accumulating (there is no project-removal CLI). register-project is idempotent for the same dir.
  local profile_root
  profile_root="$(dirname "$SPACES_DB_PATH")"
  FIXTURE_DIR="$profile_root/agent-orchestration-e2e-fixture"
  mkdir -p "$FIXTURE_DIR"
  local register_json
  register_json="$("$SPACES_E2E" register-project --project-dir "$FIXTURE_DIR")"
  FIXTURE_WORKSPACE_ID="$(json_field "$register_json" 'd["id"]')"
  [[ -n "$FIXTURE_WORKSPACE_ID" ]] || fail "could not resolve fixture workspace id from: $register_json"
  printf '[agent-e2e] fixture workspace=%s dir=%s\n' "$FIXTURE_WORKSPACE_ID" "$FIXTURE_DIR"
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

  # Step 5: interrupt succeeds; kill notifies watchers and removes the row; a bogus session id is a
  # loud error. C is sitting `.done` (turn-complete, still live) from step 3 — the most common kill
  # scenario — so the kill must still deliver O exactly one exited notice: `.done` is a live resting
  # state, not a finalized one.
  "$SPACES_CLI" agent interrupt "$C" >/dev/null || fail "interrupt C failed"
  pass "step 5a: interrupt C succeeded"
  "$SPACES_CLI" agent kill "$C" >/dev/null || fail "kill C failed"
  wait_for_notification "$O" exited "$C" || fail "exited notification never reached O after killing turn-complete C"
  pass "step 5b-exit: killing turn-complete (.done) C delivered the exited notice to O"
  sleep 1
  local still_present
  still_present="$(json_field "$("$SPACES_CLI" agent list --json)" '"yes" if any(r.get("terminalSessionID")=="'"$C"'" for r in d) else "no"')"
  [[ "$still_present" == "no" ]] || fail "C still present in agent list after kill"
  pass "step 5b: kill C removed its row from agent list"
  # A session that never existed has neither an agent row nor an on-disk terminal record, so it hits
  # the loud "no agent session" error. (Re-killing C itself is not a loud error: the killed session's
  # on-disk record lingers, so a second kill re-terminates it and returns success -- see the report.)
  local bogus_err
  if bogus_err="$("$SPACES_CLI" agent kill "00000000-0000-0000-0000-000000000000" 2>&1)"; then
    fail "killing a nonexistent session unexpectedly succeeded: $bogus_err"
  fi
  printf '%s' "$bogus_err" | grep -Fqi "no agent session" || fail "bogus kill lacked the expected error: $bogus_err"
  pass "step 5c: killing a nonexistent session errored loudly"

  printf '=== Part A passed ===\n'
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

  # This is the real orchestrator flow spawn no longer does: send the prompt text, then a carriage return
  # (byte 13, which every supported TUI accepts as submit). If a trust/onboarding/auth dialog is holding
  # input, the send lands in the dialog and no reply comes — recorded, not failed.
  "$SPACES_CLI" terminal send text "$child" 'reply with exactly: pong' >/dev/null 2>&1 || true
  "$SPACES_CLI" terminal send bytes "$child" 13 >/dev/null 2>&1 || true

  # Poll the hook status sequence (distinct consecutive statuses), the first-signal marker (lastSignalAt
  # becomes set on the agent's first hook signal), best-effort interrupt once during a working phase, and
  # watch the tail for the reply. Signals enrich this record but are not required — spawn already
  # unblocked on detection alone.
  local sequence="" seq_start last=""
  seq_start="$(now_ms)"
  local interrupted=0 saw_reply=0 first_signal=no
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
    # Best-effort interrupt during a working phase; only attempt once.
    if [[ "$st" == "spinning" && "$interrupted" == "0" ]]; then
      "$SPACES_CLI" agent interrupt "$child" >/dev/null 2>&1 || true
      interrupted=1
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

  printf 'provider=%s detected=%s spawn_ms=%s first_signal=%s signal_sequence=%s saw_reply=%s interrupted=%s\n' \
    "$binary" "$detected" "$spawn_ms" "$first_signal" "${sequence:-none}" "$saw_reply" "$interrupted"

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
  bind_worktree_profile
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
