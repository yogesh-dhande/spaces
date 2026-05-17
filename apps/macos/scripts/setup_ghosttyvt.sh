#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REVISION_FILE="$APP_ROOT/ghosttyvt-revision.txt"
LOCAL_ROOT="$APP_ROOT/.local/ghosttyvt"
SOURCE_ROOT="$LOCAL_ROOT/src"
TOOLCHAIN_ROOT="$LOCAL_ROOT/toolchain"
DEFAULT_REPO="https://github.com/ghostty-org/ghostty.git"
REPO_URL="${SPACES_GHOSTTYVT_REPO:-$DEFAULT_REPO}"

if [[ -f "$REVISION_FILE" ]]; then
    REVISION="$(tr -d '[:space:]' < "$REVISION_FILE")"
else
    echo "missing pinned revision file: $REVISION_FILE" >&2
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)
        ZIG_ARCHIVE_NAME="zig-aarch64-macos-0.15.2"
        ;;
    x86_64)
        ZIG_ARCHIVE_NAME="zig-x86_64-macos-0.15.2"
        ;;
    *)
        echo "unsupported macOS architecture for local ghostty-vt setup: $ARCH" >&2
        exit 1
        ;;
esac

ZIG_VERSION="0.15.2"
ZIG_ARCHIVE="$ZIG_ARCHIVE_NAME.tar.xz"
ZIG_URL="https://ziglang.org/download/$ZIG_VERSION/$ZIG_ARCHIVE"
ZIG_INSTALL_ROOT="$TOOLCHAIN_ROOT/$ZIG_ARCHIVE_NAME"
ZIG_BIN="$ZIG_INSTALL_ROOT/zig"

mkdir -p "$LOCAL_ROOT" "$TOOLCHAIN_ROOT"

if [[ ! -x "$ZIG_BIN" ]]; then
    echo "==> Downloading Zig $ZIG_VERSION for ghostty-vt"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    curl -fL "$ZIG_URL" -o "$TMP_DIR/$ZIG_ARCHIVE"
    tar -xJf "$TMP_DIR/$ZIG_ARCHIVE" -C "$TOOLCHAIN_ROOT"
    rm -rf "$TMP_DIR"
    trap - EXIT
else
    echo "==> Zig $ZIG_VERSION already present at $ZIG_BIN"
fi

if [[ ! -d "$SOURCE_ROOT/.git" ]]; then
    echo "==> Cloning ghostty source for libghostty-vt"
    git clone "$REPO_URL" "$SOURCE_ROOT"
else
    echo "==> ghostty source already present at $SOURCE_ROOT"
fi

(
    cd "$SOURCE_ROOT"

    if [[ -n "$(git status --porcelain)" ]]; then
        echo "ghostty source tree has local modifications; refusing to change revisions automatically" >&2
        exit 1
    fi

    CURRENT_REVISION="$(git rev-parse HEAD)"
    if [[ "$CURRENT_REVISION" != "$REVISION" ]]; then
        echo "==> Checking out ghostty revision $REVISION"
        git fetch --tags origin
        git checkout "$REVISION"
    else
        echo "==> ghostty source already at pinned revision $REVISION"
    fi

    echo "==> Building libghostty-vt"
    "$ZIG_BIN" build -Demit-lib-vt=true
)

echo
echo "ghostty-vt setup complete."
echo "  source:    $SOURCE_ROOT"
echo "  headers:   $SOURCE_ROOT/zig-out/include/ghostty/vt.h"
echo "  library:   $SOURCE_ROOT/zig-out/lib"
echo "  zig:       $ZIG_BIN"
