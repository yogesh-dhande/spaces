#!/usr/bin/env bash
# Runs the Linux daemon-side unit suites inside the swift:6.2-noble container.
# Invoked INSIDE the container by the `docker run` command in docs/dev.md, which mounts
# the repo at /workspace and named volumes for the staged sources, build scratch, and caches.
set -euo pipefail
apt-get update -qq
apt-get install -y -qq pkg-config libsqlite3-dev libssl-dev openssl rsync >/dev/null

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
export SPACES_GHOSTTY_VT_DYLIB_PATH=/root/src/apps/macos/.local/ghosttyvt/lib/libghostty-vt.so
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
for suite in \
  GhosttyLinuxHeadlessSessionResizeTests \
  GhosttyLinuxHeadlessSessionTranscriptTrimTests \
  GhosttyLinuxHeadlessSessionHandoffTests \
  GhosttyLinuxHeadlessSubmitOrderingTests; do
  swift test \
    --scratch-path /root/spaces-test-build \
    --jobs 4 \
    --filter "$suite" 2>&1
done
