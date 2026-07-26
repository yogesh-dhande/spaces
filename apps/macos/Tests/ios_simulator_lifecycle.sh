#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
LIFECYCLE_HELPER="$REPO_ROOT/scripts/ios-simulator-lifecycle.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-ios-simulator-lifecycle.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "iOS simulator lifecycle test failed: $*" >&2
  exit 1
}

STUB_BIN="$TMP_ROOT/bin"
STATE_ROOT="$TMP_ROOT/state"
SIMCTL_LOG="$TMP_ROOT/simctl.log"
mkdir -p "$STUB_BIN" "$STATE_ROOT"

cat >"$STUB_BIN/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail

[[ "${1:-}" == "simctl" ]] || exit 2
shift
command="$1"
shift

case "$command" in
  list)
    python3 - "$SPACES_TEST_SIMULATOR_STATE_ROOT" <<'PY'
import json
import pathlib
import sys

state_root = pathlib.Path(sys.argv[1])
devices = []
for path in sorted(state_root.iterdir()):
    devices.append({
        "name": path.name,
        "udid": path.name,
        "state": path.read_text().strip(),
        "isAvailable": True,
    })
print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-Test": devices}}))
PY
    ;;
  boot)
    udid="$1"
    printf 'boot %s\n' "$udid" >>"$SPACES_TEST_SIMCTL_LOG"
    if [[ "${SPACES_TEST_SIMCTL_BOOT_RACE_UDID:-}" == "$udid" ]]; then
      printf 'Booted\n' >"$SPACES_TEST_SIMULATOR_STATE_ROOT/$udid"
      echo "Unable to boot device in current state: Booted" >&2
      exit 149
    fi
    printf 'Booted\n' >"$SPACES_TEST_SIMULATOR_STATE_ROOT/$udid"
    ;;
  bootstatus)
    udid="$1"
    printf 'bootstatus %s\n' "$udid" >>"$SPACES_TEST_SIMCTL_LOG"
    if [[ "${SPACES_TEST_SIMCTL_BOOTSTATUS_HANG_UDID:-}" == "$udid" ]]; then
      # Opt-in hang for the timeout/recovery tests: the production code SIGKILLs this process
      # on deadline, so `exec` replaces this shell with `sleep` -- the killed pid IS the sleep,
      # leaving no orphan behind. A marker file makes the hang single-shot: once set, the first
      # call touches it and hangs; later calls for the same udid see it exists and succeed
      # normally, which is how the "recovery succeeds on retry" test lets attempt 2 through. The
      # both-attempts-wedge test simply leaves the marker var unset, so every call hangs.
      marker="${SPACES_TEST_SIMCTL_BOOTSTATUS_HANG_MARKER:-}"
      if [[ -z "$marker" || ! -e "$marker" ]]; then
        [[ -n "$marker" ]] && : >"$marker"
        exec sleep 60
      fi
    fi
    ;;
  shutdown)
    udid="$1"
    printf 'shutdown %s\n' "$udid" >>"$SPACES_TEST_SIMCTL_LOG"
    # The wedge recovery shuts every device down at once; there is no device named "all" to
    # record a state for, so mark each known device instead.
    if [[ "$udid" == "all" ]]; then
      for device in "$SPACES_TEST_SIMULATOR_STATE_ROOT"/*; do
        [[ -e "$device" ]] || continue
        printf 'Shutdown\n' >"$device"
      done
    else
      printf 'Shutdown\n' >"$SPACES_TEST_SIMULATOR_STATE_ROOT/$udid"
    fi
    ;;
  erase)
    udid="$1"
    printf 'erase %s\n' "$udid" >>"$SPACES_TEST_SIMCTL_LOG"
    printf 'Shutdown\n' >"$SPACES_TEST_SIMULATOR_STATE_ROOT/$udid"
    ;;
  *)
    echo "unexpected simctl command: $command $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$STUB_BIN/xcrun"

# The wedge recovery kills the CoreSimulator daemon. Stub killall so this test records the call
# instead of taking down the real service on a developer's machine mid-run.
cat >"$STUB_BIN/killall" <<'EOF'
#!/bin/bash
printf 'killall %s\n' "$*" >>"$SPACES_TEST_SIMCTL_LOG"
EOF
chmod +x "$STUB_BIN/killall"

export PATH="$STUB_BIN:$PATH"
export SPACES_TEST_SIMULATOR_STATE_ROOT="$STATE_ROOT"
export SPACES_TEST_SIMCTL_LOG="$SIMCTL_LOG"

reset_fixture() {
  rm -f "$STATE_ROOT"/* "$SIMCTL_LOG"
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local actual
  actual="$(grep -c -F "$pattern" "$SIMCTL_LOG" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || fail "expected $expected occurrences of '$pattern', found $actual"
}

reset_fixture
printf 'Shutdown\n' >"$STATE_ROOT/iphone-shutdown"
(
  # shellcheck source=/dev/null
  source "$LIFECYCLE_HELPER"
  spaces_ios_simulator_boot_if_needed iphone-shutdown
  spaces_ios_simulator_shutdown_owned 0
)
assert_count 1 "boot iphone-shutdown"
assert_count 1 "bootstatus iphone-shutdown"
assert_count 1 "shutdown iphone-shutdown"
[[ "$(cat "$STATE_ROOT/iphone-shutdown")" == "Shutdown" ]] || fail "owned simulator was not shut down"

reset_fixture
printf 'Booted\n' >"$STATE_ROOT/iphone-booted"
(
  # shellcheck source=/dev/null
  source "$LIFECYCLE_HELPER"
  spaces_ios_simulator_boot_if_needed iphone-booted
  spaces_ios_simulator_shutdown_owned 0
)
assert_count 0 "boot iphone-booted"
assert_count 1 "bootstatus iphone-booted"
assert_count 0 "shutdown iphone-booted"
[[ "$(cat "$STATE_ROOT/iphone-booted")" == "Booted" ]] || fail "pre-booted simulator was changed"

reset_fixture
printf 'Shutdown\n' >"$STATE_ROOT/iphone-boot-race"
set +e
SPACES_TEST_SIMCTL_BOOT_RACE_UDID=iphone-boot-race bash -c '
  set -euo pipefail
  source "$1"
  trap '\''status=$?; spaces_ios_simulator_shutdown_owned "$status"'\'' EXIT
  spaces_ios_simulator_boot_if_needed iphone-boot-race
' _ "$LIFECYCLE_HELPER"
boot_race_status=$?
set -e
[[ "$boot_race_status" == "149" ]] || fail "competing boot returned $boot_race_status instead of 149"
assert_count 1 "boot iphone-boot-race"
assert_count 0 "bootstatus iphone-boot-race"
assert_count 0 "shutdown iphone-boot-race"
[[ "$(cat "$STATE_ROOT/iphone-boot-race")" == "Booted" ]] || fail "competing owner's simulator was changed"

reset_fixture
printf 'Shutdown\n' >"$STATE_ROOT/iphone-one"
printf 'Shutdown\n' >"$STATE_ROOT/ipad-two"
(
  # shellcheck source=/dev/null
  source "$LIFECYCLE_HELPER"
  spaces_ios_simulator_boot_if_needed iphone-one
  spaces_ios_simulator_boot_if_needed ipad-two
  spaces_ios_simulator_shutdown_owned 0
  spaces_ios_simulator_shutdown_owned 0
)
assert_count 1 "shutdown iphone-one"
assert_count 1 "shutdown ipad-two"

reset_fixture
printf 'Shutdown\n' >"$STATE_ROOT/iphone-failure"
set +e
bash -c '
  set -euo pipefail
  source "$1"
  trap '\''status=$?; spaces_ios_simulator_shutdown_owned "$status"'\'' EXIT
  spaces_ios_simulator_boot_if_needed iphone-failure
  exit 23
' _ "$LIFECYCLE_HELPER"
failure_status=$?
set -e
[[ "$failure_status" == "23" ]] || fail "failure cleanup returned $failure_status instead of 23"
assert_count 1 "shutdown iphone-failure"

reset_fixture
printf 'Shutdown\n' >"$STATE_ROOT/iphone-interrupt"
ready_path="$TMP_ROOT/interrupt-ready"
rm -f "$ready_path"
bash -c '
  set -euo pipefail
  source "$1"
  trap '\''status=$?; spaces_ios_simulator_shutdown_owned "$status"'\'' EXIT
  trap '\''exit 130'\'' INT TERM
  spaces_ios_simulator_boot_if_needed iphone-interrupt
  : >"$2"
  while true; do sleep 1; done
' _ "$LIFECYCLE_HELPER" "$ready_path" &
interrupt_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$ready_path" ]] && break
  sleep 0.1
done
[[ -f "$ready_path" ]] || fail "interrupt fixture did not become ready"
kill -TERM "$interrupt_pid"
set +e
wait "$interrupt_pid"
interrupt_status=$?
set -e
[[ "$interrupt_status" == "130" ]] || fail "interrupt cleanup returned $interrupt_status instead of 130"
assert_count 1 "shutdown iphone-interrupt"

reset_fixture
printf 'Shutdown\n' >"$STATE_ROOT/iphone-wedged"
hang_marker="$TMP_ROOT/wedge-hang-marker"
rm -f "$hang_marker"
(
  # shellcheck source=/dev/null
  source "$LIFECYCLE_HELPER"
  export SPACES_IOS_SIMULATOR_BOOT_TIMEOUT=1
  export SPACES_TEST_SIMCTL_BOOTSTATUS_HANG_UDID=iphone-wedged
  export SPACES_TEST_SIMCTL_BOOTSTATUS_HANG_MARKER="$hang_marker"
  spaces_ios_simulator_boot_if_needed iphone-wedged
  spaces_ios_simulator_shutdown_owned 0
)
# Attempt 1 wedges (bootstatus #1), then recovery resets the service (shutdown all + killall);
# attempt 2 boots again (boot #2, bootstatus #2) and succeeds since the hang is single-shot. The
# only per-device shutdown is the owned-simulator teardown at the end.
assert_count 2 "boot iphone-wedged"
assert_count 2 "bootstatus iphone-wedged"
assert_count 1 "shutdown all"
assert_count 1 "killall -9 com.apple.CoreSimulator.CoreSimulatorService"
assert_count 0 "erase iphone-wedged"
assert_count 1 "shutdown iphone-wedged"
[[ "$(cat "$STATE_ROOT/iphone-wedged")" == "Shutdown" ]] || fail "recovered simulator was not shut down at teardown"

reset_fixture
printf 'Shutdown\n' >"$STATE_ROOT/iphone-double-wedged"
set +e
(
  # shellcheck source=/dev/null
  source "$LIFECYCLE_HELPER"
  export SPACES_IOS_SIMULATOR_BOOT_TIMEOUT=1
  export SPACES_TEST_SIMCTL_BOOTSTATUS_HANG_UDID=iphone-double-wedged
  spaces_ios_simulator_boot_if_needed iphone-double-wedged
)
double_wedge_status=$?
set -e
[[ "$double_wedge_status" != "0" ]] || fail "expected boot_if_needed to fail when both attempts wedge"
assert_count 2 "boot iphone-double-wedged"
assert_count 2 "bootstatus iphone-double-wedged"
# One recovery, after the first attempt only: the last attempt's wedge gives up rather than
# resetting a service nothing will use again.
assert_count 1 "shutdown all"
assert_count 1 "killall -9 com.apple.CoreSimulator.CoreSimulatorService"
assert_count 0 "erase iphone-double-wedged"

echo "iOS simulator lifecycle tests passed"
