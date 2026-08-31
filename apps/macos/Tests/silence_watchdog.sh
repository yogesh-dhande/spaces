#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$APP_ROOT/scripts/silence-watchdog.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-silence-watchdog-test.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "silence watchdog test failed: $*" >&2
    exit 1
}

success_output="$(run_with_silence_watchdog 2 /bin/bash -c 'for value in 1 2 3 4 5 6; do echo "tick-$value"; sleep 0.4; done')"
[[ "$success_output" == *"tick-6"* ]] || fail "output-producing command was killed before completion"

disabled_output="$(run_with_silence_watchdog 0 /bin/bash -c 'echo watchdog-disabled')"
[[ "$disabled_output" == "watchdog-disabled" ]] || fail "zero duration did not disable the watchdog"

set +e
run_with_silence_watchdog 2 /bin/bash -c 'exit 23' >"$TMP_ROOT/failure.out" 2>&1
failure_status=$?
set -e
[[ "$failure_status" -eq 23 ]] || fail "command exit status was not preserved: $failure_status"

child_pid_path="$TMP_ROOT/child.pid"
root_pid_path="$TMP_ROOT/root.pid"
set +e
run_with_silence_watchdog 1 /bin/bash -c 'echo $$ >"$2"; sleep 30 & echo $! >"$1"; wait' _ "$child_pid_path" "$root_pid_path" >"$TMP_ROOT/stall.out" 2>&1
stall_status=$?
set -e
[[ "$stall_status" -eq 124 ]] || fail "silent command returned $stall_status instead of timeout status 124"
grep -q "produced no output for 1s" "$TMP_ROOT/stall.out" || fail "stall diagnostic was not emitted"
# The kill destroys the evidence, so the diagnostic must carry the tree listing
# and a per-process stack section (the stacks themselves are best-effort).
grep -q "process tree at kill time" "$TMP_ROOT/stall.out" || fail "hang process-tree capture was not emitted"
grep -q "thread stacks for pid" "$TMP_ROOT/stall.out" || fail "hang stack capture was not emitted"
child_pid="$(cat "$child_pid_path")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$child_pid" 2>/dev/null && fail "silent command left child process $child_pid running"
# The root is frozen with SIGSTOP for evidence capture before the kill, so it
# can never exit on its own once its children die: only the tree kill reaching
# the root itself (not just its descendants) ends it.
root_pid="$(cat "$root_pid_path")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$root_pid" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$root_pid" 2>/dev/null && fail "silent command left root process $root_pid running"

# Pins the #583 false-kill: a stalled downstream consumer must not be able to
# starve the liveness signal. The producer writes a 512KB burst (overfilling the
# ~64KB fifo/pipe buffers upstream of a consumer that doesn't read for 8s), then
# ticks for several more seconds. A healthy producer must survive even though its
# stdout is backed up the whole time.
backpressure_out="$TMP_ROOT/backpressure.out"
backpressure_err="$TMP_ROOT/backpressure.err"
backpressure_status_path="$TMP_ROOT/backpressure.status"
set +e
{
    run_with_silence_watchdog 2 /bin/bash -c \
        'head -c 524288 /dev/zero | tr "\0" "x"; echo; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "backpressure-tick-$i"; sleep 0.4; done; echo "backpressure-done"' \
        2>"$backpressure_err"
    echo "$?" >"$backpressure_status_path"
} | { sleep 8; cat >"$backpressure_out"; }
set -e
backpressure_status="$(cat "$backpressure_status_path")"
[[ "$backpressure_status" -eq 0 ]] || fail "healthy producer behind a stalled consumer was killed (status $backpressure_status)"
grep -q "backpressure-done" "$backpressure_out" || fail "output lost under consumer backpressure"

# A background child that inherits stdout and writes shortly after the work
# process exits still gets its output forwarded (the forwarder drains until the
# log stays quiet after exit, rather than stopping at the parent's exit).
straggler_output="$(run_with_silence_watchdog 5 /bin/bash -c '(sleep 1; echo "straggler-output") & exit 0')"
[[ "$straggler_output" == *"straggler-output"* ]] || fail "output written by a surviving child after work exit was lost"

echo "silence watchdog tests passed"
