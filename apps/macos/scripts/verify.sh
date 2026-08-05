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

# Per-lane state for the closing summary. Each lane advances from "not started" to "started" to a
# result as run_verify_steps progresses, so the summary describes what this run actually did. The
# distinction matters in both directions: most runs that fail do so inside verify-prep.sh (lint, the
# SwiftPM build, release bundle signing) before either lane exists, and a summary that reported those
# lanes as having run would overstate the run's coverage.
coverage_lane_state="not started"
ios_lane_state="not started"
verify_interrupted=0

render_lane_state() {
  case "$1" in
    "not started") printf 'NOT STARTED' ;;
    started) printf 'DID NOT FINISH' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Prints the closing report: what each lane did, and what no lane here covers. A pass otherwise reads
# as "everything is checked", which is how a green local run coexists with a CI lane that rejects the
# same commit. Called only from cleanup(), the EXIT trap, so it prints exactly once and on every way
# this script can end — including the `set -e` failures inside verify-prep.sh that are the most
# common way the gate fails, and an interrupt.
print_lane_summary() {
  printf '\n'
  printf '========================================================================\n'
  printf 'verify.sh lane summary\n'
  if [ "$verify_interrupted" -eq 1 ]; then
    printf '  run INTERRUPTED before it finished\n'
  fi
  printf '  macOS build, lint, unit tests   %s\n' "$(render_lane_state "$coverage_lane_state")"
  printf '  iOS unit tests                  %s\n' "$(render_lane_state "$ios_lane_state")"
  if [ "$coverage_lane_state" = "not started" ] && [ "$ios_lane_state" = "not started" ]; then
    printf '  the run ended during preparation (simulator lifecycle checks, Ghostty artifact sync,\n'
    printf '  formatting, lint, the SwiftPM build, or release bundle signing)\n'
  fi
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
  ios_lane_state="started"

  coverage_lane_state="started"
  local coverage_status=0
  "$root/scripts/coverage.sh" || coverage_status=$?
  if [ "$coverage_status" -eq 0 ]; then
    coverage_lane_state="PASSED"
  else
    coverage_lane_state="FAILED (exit $coverage_status)"
  fi

  local ios_status=0
  wait "$ios_lane_pid" || ios_status=$?
  ios_lane_pid=""
  if [ "$ios_status" -eq 0 ]; then
    ios_lane_state="PASSED"
  else
    ios_lane_state="FAILED (exit $ios_status)"
  fi

  printf '\n--- iOS unit test lane log (last 60 lines) ---\n'
  tail -n 60 "$ios_log" || true
  printf -- '--- end iOS unit test lane log ---\n\n'
  if [ "$ios_status" -eq 0 ]; then
    echo "iOS unit test lane: PASSED"
  else
    echo "iOS unit test lane: FAILED (exit $ios_status)"
  fi

  if [ "$coverage_status" -ne 0 ]; then
    exit "$coverage_status"
  fi
  if [ "$ios_status" -ne 0 ]; then
    exit "$ios_status"
  fi
}

cleanup() {
  local exit_code=$?
  # Tolerate a shutdown failure rather than letting `set -e` abort this trap partway through and
  # suppress the summary. The run's exit status is $exit_code either way: a command failing inside an
  # EXIT trap never changed it.
  spaces_ios_simulator_shutdown_owned "$exit_code" || true
  print_lane_summary
}

handle_interrupt() {
  # Recorded so the summary cleanup() prints says the run was cut short, rather than presenting a
  # half-finished run as a set of lane results.
  verify_interrupted=1
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
