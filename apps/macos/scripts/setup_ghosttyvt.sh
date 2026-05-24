#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REVISION_FILE="$APP_ROOT/ghosttyvt-revision.txt"
GHOSTTYKIT_RELEASE_TAG_FILE="$APP_ROOT/ghosttykit-release-tag.txt"
LOCAL_ROOT="$APP_ROOT/.local/ghosttyvt"
SOURCE_ROOT="$LOCAL_ROOT/src"
TOOLCHAIN_ROOT="$LOCAL_ROOT/toolchain"
DEFAULT_REPO="https://github.com/yogesh-dhande/ghostty.git"
DEFAULT_BRANCH="spaces"
REPO_URL="${SPACES_GHOSTTYVT_REPO:-$DEFAULT_REPO}"
REPO_BRANCH="${SPACES_GHOSTTYVT_BRANCH:-$DEFAULT_BRANCH}"

if [[ -f "$REVISION_FILE" ]]; then
    DEFAULT_REVISION="$(tr -d '[:space:]' < "$REVISION_FILE")"
else
    echo "missing pinned revision file: $REVISION_FILE" >&2
    exit 1
fi

REVISION="${SPACES_GHOSTTYVT_REVISION:-$DEFAULT_REVISION}"

EXPECTED_RELEASE_TAG=""
if [[ -f "$GHOSTTYKIT_RELEASE_TAG_FILE" ]]; then
    EXPECTED_RELEASE_TAG="$(tr -d '[:space:]' < "$GHOSTTYKIT_RELEASE_TAG_FILE")"
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
    git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$SOURCE_ROOT"
else
    echo "==> ghostty source already present at $SOURCE_ROOT"
fi

(
    cd "$SOURCE_ROOT"

    if [[ -n "$(git status --porcelain)" ]]; then
        echo "ghostty source tree has local modifications; refusing to change revisions automatically" >&2
        exit 1
    fi

    CURRENT_REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$CURRENT_REMOTE_URL" != "$REPO_URL" ]]; then
        if [[ -n "$CURRENT_REMOTE_URL" ]]; then
            echo "==> Repointing ghostty source remote from $CURRENT_REMOTE_URL to $REPO_URL"
            git remote set-url origin "$REPO_URL"
        else
            echo "==> Adding ghostty source remote origin $REPO_URL"
            git remote add origin "$REPO_URL"
        fi
    fi

    git fetch origin "refs/heads/$REPO_BRANCH:refs/remotes/origin/$REPO_BRANCH"

    if [[ -n "$EXPECTED_RELEASE_TAG" ]]; then
        git fetch --force origin "refs/tags/$EXPECTED_RELEASE_TAG:refs/tags/$EXPECTED_RELEASE_TAG"
    fi

    if [[ "$REPO_URL" == "$DEFAULT_REPO" && -z "${SPACES_GHOSTTYVT_REVISION:-}" && -n "$EXPECTED_RELEASE_TAG" ]]; then
        EXPECTED_RELEASE_COMMIT="$(git rev-list -n 1 "$EXPECTED_RELEASE_TAG" 2>/dev/null || true)"
        if [[ -z "$EXPECTED_RELEASE_COMMIT" ]]; then
            echo "missing expected GhosttyKit release tag '$EXPECTED_RELEASE_TAG' in $REPO_URL" >&2
            exit 1
        fi
        if [[ "$REVISION" != "$EXPECTED_RELEASE_COMMIT" ]]; then
            echo "ghosttyvt revision $REVISION does not match GhosttyKit release tag $EXPECTED_RELEASE_TAG ($EXPECTED_RELEASE_COMMIT)" >&2
            echo "update apps/macos/ghosttyvt-revision.txt or override SPACES_GHOSTTYVT_REVISION for local experiments" >&2
            exit 1
        fi
    fi

    CURRENT_REVISION="$(git rev-parse HEAD)"
    if [[ "$CURRENT_REVISION" != "$REVISION" ]]; then
        echo "==> Checking out ghostty revision $REVISION"
        git checkout "$REVISION"
    else
        echo "==> ghostty source already at pinned revision $REVISION"
    fi

    APP_VERSION="$(grep -m1 '\.version = ' build.zig.zon | sed -E 's/.*\"([^\"]+)\".*/\1/')"
    if [[ -z "$APP_VERSION" ]]; then
        echo "unable to determine ghostty build version from $SOURCE_ROOT/build.zig.zon" >&2
        exit 1
    fi

    echo "==> Building libghostty-vt"
    "$ZIG_BIN" build -Demit-lib-vt=true -Dversion-string="$APP_VERSION"
)

echo
echo "ghostty-vt setup complete."
echo "  source:    $SOURCE_ROOT"
echo "  headers:   $SOURCE_ROOT/zig-out/include/ghostty/vt.h"
echo "  library:   $SOURCE_ROOT/zig-out/lib"
echo "  zig:       $ZIG_BIN"
