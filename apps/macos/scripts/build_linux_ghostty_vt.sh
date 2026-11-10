#!/usr/bin/env bash
set -euo pipefail

# Builds the Linux libghostty-vt for one artifact architecture and stages it where
# build_linux_spacesd_artifact.sh and run_linux_tests.sh read it:
#   apps/macos/.local/ghosttyvt/include
#   apps/macos/.local/ghosttyvt/lib-linux
#
# Runs inside the builder image of the Docker host's own architecture, whatever --arch names
# (see build_linux_ghostty_vt_in_docker.sh). The target is always passed to Zig explicitly, so
# a same-architecture build and a cross build take the same path.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
SUBMODULE_PATH="apps/macos/vendor/ghostty"
GHOSTTY_SOURCE_ROOT="$REPO_ROOT/$SUBMODULE_PATH"
GHOSTTYVT_ROOT="$APP_ROOT/.local/ghosttyvt"
# The C API header is platform-independent, so headers stay in the shared `include` dir. The
# compiled libraries are not interchangeable, so the ELF output goes to a Linux-scoped
# `lib-linux` dir instead of the shared `lib` dir that setup_ghostty.sh fills with macOS
# artifacts; writing ELF files there broke macOS tests until setup_ghostty.sh restored them.
GHOSTTYVT_INCLUDE_ROOT="$GHOSTTYVT_ROOT/include"
GHOSTTYVT_LINUX_LIB_ROOT="$GHOSTTYVT_ROOT/lib-linux"

source "$SCRIPT_DIR/linux-builder-versions.sh"

die() {
    echo "$*" >&2
    exit 1
}

ARTIFACT_ARCH=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --arch)
            [[ "$#" -ge 2 ]] || die "--arch requires x86_64 or arm64"
            ARTIFACT_ARCH="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: apps/macos/scripts/build_linux_ghostty_vt.sh --arch x86_64|arm64"
            exit 0
            ;;
        *)
            die "unknown build_linux_ghostty_vt.sh argument: $1"
            ;;
    esac
done

case "$ARTIFACT_ARCH" in
    x86_64) zig_arch="x86_64" ;;
    arm64) zig_arch="aarch64" ;;
    *) die "build_linux_ghostty_vt.sh requires --arch x86_64 or --arch arm64" ;;
esac

# -Dcpu=baseline: without it a Zig target query resolves the *build host's* CPU for the named
# architecture, so the artifact would only run on CPUs at least as capable as the machine that
# built it. On an AVX-512 runner libghostty-vt gets EVEX-encoded instructions and spacesd dies
# with SIGILL on the first terminal page allocation on every device without AVX-512.
# `verify_artifact_cpu_baseline` in build_linux_spacesd_artifact.sh asserts the pin held.
ZIG_TARGET="$zig_arch-linux-gnu.$SPACES_LINUX_GLIBC_FLOOR"

ghostty_submodule_is_initialized() {
    [[ -e "$GHOSTTY_SOURCE_ROOT/.git" ]] || return 1
    git -C "$GHOSTTY_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1
}

ensure_ghostty_submodule() {
    if [[ -f "$GHOSTTY_SOURCE_ROOT/build.zig.zon" ]]; then
        return
    fi
    if ghostty_submodule_is_initialized; then
        return
    fi
    echo "==> Initializing Ghostty submodule"
    git -C "$REPO_ROOT" submodule update --init --recursive -- "$SUBMODULE_PATH"
}

ghostty_is_dirty() {
    ghostty_submodule_is_initialized || return 1
    [[ -n "$(git -C "$GHOSTTY_SOURCE_ROOT" status --porcelain)" ]]
}

ghostty_app_version() {
    local version_line app_version
    version_line="$(grep -m1 '\.version = ' "$GHOSTTY_SOURCE_ROOT/build.zig.zon" || true)"
    app_version="$(sed -E 's/.*"([^"]+)".*/\1/' <<<"$version_line")"
    if [[ -z "$app_version" || "$app_version" == "$version_line" ]]; then
        die "failed to determine Ghostty version string from $GHOSTTY_SOURCE_ROOT/build.zig.zon"
    fi
    echo "$app_version"
}

# Zig comes from the builder image this script runs inside, never from a download into the
# workspace. Asserting the pinned version here is what makes running in the wrong image a loud
# failure rather than a libghostty-vt built by an unpinned compiler.
resolve_zig() {
    local zig_bin installed_version
    zig_bin="$(command -v zig || true)"
    [[ -n "$zig_bin" ]] || die "zig is not on PATH; run this build inside the image apps/macos/scripts/ensure_linux_builder_image.sh provisions"
    installed_version="$("$zig_bin" version)"
    [[ "$installed_version" == "$SPACES_LINUX_ZIG_VERSION" ]] || die "zig $installed_version is on PATH but Linux spacesd artifacts pin zig $SPACES_LINUX_ZIG_VERSION; rebuild the builder image with apps/macos/scripts/ensure_linux_builder_image.sh"
    echo "$zig_bin"
}

ensure_ghostty_submodule
if ghostty_is_dirty && [[ "${SPACES_LINUX_ALLOW_DIRTY_GHOSTTY:-0}" != "1" ]]; then
    die "Ghostty submodule has local modifications; commit them before building Linux spacesd artifacts"
fi

zig_bin="$(resolve_zig)"
app_version="$(ghostty_app_version)"

echo "==> Building Linux libghostty-vt ($ZIG_TARGET) from $GHOSTTY_SOURCE_ROOT"
(
    cd "$GHOSTTY_SOURCE_ROOT"
    # Ghostty's vendored translate_c build helper shells out to a bare `zig env`, so the
    # pinned toolchain must be first on PATH.
    PATH="$(dirname "$zig_bin"):$PATH"
    export PATH
    "$zig_bin" build -Doptimize="$SPACES_LINUX_GHOSTTY_VT_OPTIMIZE" -Dtarget="$ZIG_TARGET" -Dcpu=baseline -Demit-lib-vt=true -Dversion-string="$app_version"
)

source_include="$GHOSTTY_SOURCE_ROOT/zig-out/include"
source_lib="$GHOSTTY_SOURCE_ROOT/zig-out/lib"
[[ -f "$source_include/ghostty/vt.h" ]] || die "libghostty-vt headers missing at $source_include"
compgen -G "$source_lib/libghostty-vt.so*" >/dev/null || die "libghostty-vt.so output missing under $source_lib"

rm -rf "$GHOSTTYVT_INCLUDE_ROOT" "$GHOSTTYVT_LINUX_LIB_ROOT"
mkdir -p "$GHOSTTYVT_ROOT"
cp -a "$source_include" "$GHOSTTYVT_INCLUDE_ROOT"
cp -a "$source_lib" "$GHOSTTYVT_LINUX_LIB_ROOT"
