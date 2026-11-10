#!/usr/bin/env bash
# Single source of truth for what the Linux builder image contains, and for the libghostty-vt
# build settings. Sourced by ensure_linux_builder_image.sh (which bakes the image values into
# the image), build_linux_ghostty_vt.sh (which asserts it is running inside an image built
# from them), and build_linux_spacesd_artifact.sh. Changing an image value changes the image
# tag, so the next build provisions a new image instead of reusing a stale one.

# Toolchain the Linux daemon and CLI compile against.
SPACES_LINUX_BUILDER_BASE_IMAGE="swift:6.2-noble"

# Everything build_linux_spacesd_artifact.sh needs beyond the Swift toolchain: the artifact
# build itself, the packaging steps, and the in-container smoke test.
SPACES_LINUX_BUILDER_APT_PACKAGES="curl git xz-utils python3 pkg-config libsqlite3-dev libssl-dev zlib1g-dev openssl coreutils"

# Zig builds libghostty-vt. It is baked into the image rather than downloaded per build, so a
# fresh worktree does not re-fetch the toolchain and no build writes it to the bind mount.
SPACES_LINUX_ZIG_VERSION="0.17.0"

# Zig runs only in the builder image of the Docker host's own architecture: Zig 0.17's x86_64
# Linux binary cannot run under Rosetta, so an emulated amd64 container on Apple Silicon cannot
# build libghostty-vt. Zig cross-compiles, so that one container builds the library for either
# artifact architecture (see build_linux_ghostty_vt.sh).
#
# The glibc the library is built against is pinned rather than taken from the build container,
# so the floor is the same on every builder. It must not exceed the glibc 2.38 floor of the
# distributions the artifact supports (docs/dev.md).
SPACES_LINUX_GLIBC_FLOOR="2.38"
SPACES_LINUX_GHOSTTY_VT_OPTIMIZE="ReleaseFast"
