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
set +e
run_with_silence_watchdog 1 /bin/bash -c 'sleep 30 & echo $! >"$1"; wait' _ "$child_pid_path" >"$TMP_ROOT/stall.out" 2>&1
stall_status=$?
set -e
[[ "$stall_status" -eq 124 ]] || fail "silent command returned $stall_status instead of timeout status 124"
grep -q "produced no output for 1s" "$TMP_ROOT/stall.out" || fail "stall diagnostic was not emitted"
child_pid="$(cat "$child_pid_path")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$child_pid" 2>/dev/null && fail "silent command left child process $child_pid running"

echo "silence watchdog tests passed"
