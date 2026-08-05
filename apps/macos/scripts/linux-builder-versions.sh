#!/usr/bin/env bash
# Single source of truth for what the Linux builder image contains. Sourced by
# ensure_linux_builder_image.sh (which bakes these into the image) and by
# build_linux_spacesd_artifact.sh (which asserts it is running inside an image built from
# them). Changing any value here changes the image tag, so the next build provisions a new
# image instead of reusing a stale one.

# Toolchain the Linux daemon and CLI compile against.
SPACES_LINUX_BUILDER_BASE_IMAGE="swift:6.2-noble"

# Everything build_linux_spacesd_artifact.sh needs beyond the Swift toolchain: the artifact
# build itself, the packaging steps, and the in-container smoke test.
SPACES_LINUX_BUILDER_APT_PACKAGES="curl git xz-utils python3 pkg-config libsqlite3-dev libssl-dev openssl coreutils"

# Zig builds libghostty-vt. It is baked into the image rather than downloaded per build, so a
# fresh worktree does not re-fetch the toolchain and no build writes it to the bind mount.
SPACES_LINUX_ZIG_VERSION="0.16.0"
