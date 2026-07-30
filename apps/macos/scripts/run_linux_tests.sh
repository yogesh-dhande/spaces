#!/usr/bin/env bash
# Runs the Linux daemon-side unit suites inside the swift:6.2-noble container.
# Invoked INSIDE the container by the `docker run` command in docs/dev.md, which mounts
# the repo at /workspace and named volumes for the staged sources, build scratch, and caches.
set -euo pipefail
apt-get update -qq
# procps supplies the `ps` the failure-time state dump below uses; the swift base image does not carry it.
apt-get install -y -qq pkg-config libsqlite3-dev libssl-dev openssl rsync procps >/dev/null

# Stage sources onto container-native fs: resource copies (e.g. AppIcon.icns) from the
# virtiofs bind mount fail deterministically with EINTR under the amd64 runner, and
# native-fs reads compile faster. The staged tree lives in a named volume so paths stay
# stable across runs and the swift scratch cache remains incremental.
mkdir -p /root/src/apps/macos
rsync -a --delete \
  --exclude '.build/' \
  --exclude 'vendor/' \
  --exclude '.local/ghosttykit/' \
  /workspace/apps/macos/ /root/src/apps/macos/

cd /root/src/apps/macos
# The Linux ELF build of libghostty-vt stages into lib-linux (the shared lib/ holds the macOS
# artifacts); it is produced by build_linux_spacesd_artifact.sh — see docs/dev.md for the
# docker invocation. Fail up front with instructions rather than letting every suite die with
# an opaque vtSessionUnavailable.
export SPACES_GHOSTTY_VT_DYLIB_PATH=/root/src/apps/macos/.local/ghosttyvt/lib-linux/libghostty-vt.so
if [ ! -e "$SPACES_GHOSTTY_VT_DYLIB_PATH" ]; then
  echo "error: $SPACES_GHOSTTY_VT_DYLIB_PATH is missing." >&2
  echo "Build the Linux artifacts first: run the build_linux_spacesd_artifact.sh docker command from docs/dev.md." >&2
  exit 1
fi
# Linux daemon-side test suites must use Swift Testing (async-main runner), not XCTest:
# corelibs-xctest's blocked main thread never drains queued async work, so an async XCTest
# deadlocks before its first line ever runs (observed as the runner sitting at 0% CPU
# indefinitely). Convert a suite to Swift Testing and add it below to bring it into the lane.
#
# Each Swift Testing suite here mutates the process-wide SPACES_DB_PATH/SPACES_RUNTIME_DIR
# in its init/deinit, and `.serialized` only orders tests WITHIN a suite — Swift Testing
# still runs distinct suites in parallel, so two env-mutating suites in one `swift test` run
# clobber each other's environment. Run each suite in its OWN invocation so each gets an
# isolated process; the shared build is cached, so the extra invocations are cheap.
#
# A suite named here that the Linux test targets do not compile is a silent hole, not an error:
# `swift test --filter` finds nothing, reports "Test run with 0 tests in 0 suites passed", and exits
# 0, so the lane stays green while the suite never runs. That is what happened to
# GhosttyLinuxHeadlessKeyEncodingTests, which sat in this list while Package.swift's Linux `sources:`
# whitelist omitted its file. Every invocation is therefore checked for that zero-match line and
# fails the lane.
suite_log="$(mktemp)"
trap 'rm -f "$suite_log"' EXIT

# Issue #371: the x86_64 lane intermittently fails a PTY-backed suite whose child never writes a byte,
# while the same suites take under a second everywhere else. The machine's own state around the failure
# is the missing evidence, so the lane records what it is running on and, when an invocation fails, what
# every process on the box was doing at that moment.
echo "lane host: nproc=$(nproc) loadavg=$(cat /proc/loadavg)"

dump_lane_state() {
  echo "----- lane process table -----" >&2
  ps -eo pid,ppid,state,etime,time,wchan:32,args >&2
  echo "----- lane loadavg: $(cat /proc/loadavg) -----" >&2
}

for suite in \
  SpacesTestHostDetectionTests \
  TerminalServiceSystemdUnitTests \
  TerminalServiceSystemdStartDeadlineTests \
  GhosttyVtSessionEventSinkTests \
  GhosttyLinuxHeadlessKeyEncodingTests \
  GhosttyLinuxHeadlessMouseEncodingTests \
  GhosttyLinuxHeadlessSessionBellTests \
  GhosttyLinuxHeadlessSessionClipboardTests \
  GhosttyLinuxHeadlessSessionGraphemeTests \
  GhosttyLinuxHeadlessSessionMetadataTests \
  GhosttyLinuxHeadlessSessionQueryResponseTests \
  GhosttyLinuxHeadlessSessionResizeTests \
  GhosttyLinuxHeadlessSessionTranscriptTrimTests \
  GhosttyLinuxHeadlessSessionHandoffTests \
  GhosttyLinuxHeadlessSubmitOrderingTests \
  GhosttyLinuxHeadlessSpawnStressTests; do
  suite_started="$(date +%s)"
  echo "==> $suite start $(date -Is)"
  # `set -e` would abandon the run before the state dump, so the invocation's status is captured
  # instead of exiting on it; the dump runs and then the lane exits with that status.
  suite_status=0
  swift test \
    --scratch-path /root/spaces-test-build \
    --jobs 4 \
    --filter "$suite" 2>&1 | tee "$suite_log" || suite_status=$?
  echo "==> $suite end $(date -Is) duration=$(( $(date +%s) - suite_started ))s status=$suite_status"
  if [ "$suite_status" -ne 0 ]; then
    dump_lane_state
    exit "$suite_status"
  fi
  if grep -q 'Test run with 0 tests in 0 suites' "$suite_log"; then
    echo "error: $suite matched no tests, so it did not run." >&2
    echo "The Linux test targets do not compile it. Add its source file to the Linux 'sources:' list" >&2
    echo "for the matching test target in apps/macos/Package.swift, or remove it from this list." >&2
    exit 1
  fi
done
