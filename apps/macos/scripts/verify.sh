#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
source "$repo_root/scripts/ios-simulator-lifecycle.sh"
source "$root/scripts/silence-watchdog.sh"

# Builds and coverage export can legitimately produce no output for long stretches. The silence
# watchdog therefore wraps only the already-built SwiftPM and iOS test processes, where a long
# silent interval means a test worker or simulator test launch is hung.
# Override with SPACES_VERIFY_STALL_SECONDS (0 disables, e.g. when attaching a debugger).
# shellcheck disable=SC2034 # Kept here (in addition to ios-test-lane.sh's own copy) purely so this
# override knob stays documented where a reader of verify.sh will see it; coverage.sh and
# ios-test-lane.sh each read the SPACES_VERIFY_STALL_SECONDS env var directly rather than this
# shell variable.
verify_stall_seconds="${SPACES_VERIFY_STALL_SECONDS:-600}"

# PID of the backgrounded iOS lane process started by run_verify_steps, so
# handle_interrupt() can tear it down. Empty until that lane is launched.
ios_lane_pid=""

# Prints the closing report: which lanes this run executed, with their results, and what no lane here
# covers. A pass otherwise reads as "everything is checked", which is how a green local run coexists
# with a CI lane that rejects the same commit. Printed on failure as well, so a failing run still
# says how wide its coverage was.
print_lane_summary() {
  local coverage_result="$1"
  local ios_result="$2"

  printf '\n'
  printf '========================================================================\n'
  printf 'verify.sh lane summary\n'
  printf '  macOS build, lint, unit tests   RAN   %s\n' "$coverage_result"
  printf '  iOS unit tests                  RAN   %s\n' "$ios_result"
  printf 'Not covered by any verify.sh lane:\n'
  printf '  the desktop, mobile, and remote-daemon E2E suites\n'
  printf '  the Linux daemon unit lane and the Linux artifact smoke test (CI only)\n'
  printf '========================================================================\n'
}

run_verify_steps() {
  cd "$root"

  source "$root/scripts/verify-prep.sh"

  # The iOS lane only drives xcodebuild and its own DerivedData; it never calls swiftpm.sh, so it
  # does not contend with coverage.sh for the SwiftPM exec lock (see swiftpm.sh's acquire_lock).
  # Run it in the background while coverage.sh runs in the foreground so the two independent test
  # lanes overlap instead of adding end to end. It runs as its own script/process (ios-test-lane.sh)
  # rather than a backgrounded shell function, so it owns its own traps outright with no
  # subshell-wrapping to get right. Its stdout/stderr go to a log file (not the terminal) so they
  # cannot interleave with coverage.sh's output; the log is tailed once the lane finishes.
  local ios_log="$root/.build/ios-verify.log"
  : >"$ios_log"
  printf 'Starting iOS unit test lane in the background (log: %s)...\n' "$ios_log"
  "$root/scripts/ios-test-lane.sh" >"$ios_log" 2>&1 &
  ios_lane_pid=$!

  local coverage_status=0
  "$root/scripts/coverage.sh" || coverage_status=$?

  local ios_status=0
  wait "$ios_lane_pid" || ios_status=$?
  ios_lane_pid=""

  printf '\n--- iOS unit test lane log (last 60 lines) ---\n'
  tail -n 60 "$ios_log" || true
  printf -- '--- end iOS unit test lane log ---\n\n'
  if [ "$ios_status" -eq 0 ]; then
    echo "iOS unit test lane: PASSED"
  else
    echo "iOS unit test lane: FAILED (exit $ios_status)"
  fi

  local coverage_result="PASSED"
  [ "$coverage_status" -eq 0 ] || coverage_result="FAILED (exit $coverage_status)"
  local ios_result="PASSED"
  [ "$ios_status" -eq 0 ] || ios_result="FAILED (exit $ios_status)"
  print_lane_summary "$coverage_result" "$ios_result"

  if [ "$coverage_status" -ne 0 ]; then
    exit "$coverage_status"
  fi
  if [ "$ios_status" -ne 0 ]; then
    exit "$ios_status"
  fi
}

cleanup() {
  local exit_code=$?
  spaces_ios_simulator_shutdown_owned "$exit_code"
}

handle_interrupt() {
  if [ -n "$ios_lane_pid" ]; then
    # Force-kill (not just signal) the whole background iOS lane tree, including any still
    # running xcodebuild/watchdog process: this shell may currently be blocked inside a
    # synchronous nested subshell call (e.g. run_with_silence_watchdog), and a plain `kill -TERM`
    # of ios_lane_pid alone would not be noticed until that nested call returns on its own,
    # leaving xcodebuild running past this script's exit. kill_silence_watchdog_process_tree walks
    # descendants by PID, not by process group, so this only touches the iOS lane's own tree and
    # cannot reach coverage.sh's sibling processes under the main verify.sh process. It kills
    # leaf processes (e.g. xcodebuild) first, then its own SIGKILL of ios_lane_pid; because this
    # script runs under `set -e`, a killed child usually makes each enclosing subshell (including
    # run_ios_lane) exit through its own trap chain as soon as it notices, so simulator shutdown
    # below in run_ios_lane still generally runs. It is not guaranteed: the final SIGKILL of
    # ios_lane_pid can race ahead of that propagation, in which case a simulator booted by this
    # lane is left running. That residual gap mirrors any other hard-kill of verify.sh and is left
    # for a future pass if it proves disruptive in practice.
    kill_silence_watchdog_process_tree "$ios_lane_pid"
  fi
  exit 130
}

trap cleanup EXIT
trap handle_interrupt INT TERM

run_verify_steps
