#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_TAG_FILE="$APP_ROOT/ghosttykit-release-tag.txt"
LOCAL_ROOT="$APP_ROOT/.local/ghosttykit"
XCFRAMEWORK_ROOT="$LOCAL_ROOT/GhosttyKit.xcframework"
RESOURCES_ROOT="$LOCAL_ROOT/Resources"
SOURCE_PROJECT_DIR="${SPACES_PROJECT_DIR:-}"
FORK_REPO="${SPACES_GHOSTTYKIT_REPO:-yogesh-dhande/ghostty}"

if [[ -f "$RELEASE_TAG_FILE" ]]; then
    DEFAULT_RELEASE_TAG="$(tr -d '[:space:]' < "$RELEASE_TAG_FILE")"
else
    DEFAULT_RELEASE_TAG="build-2026-04-29"
fi

RELEASE_TAG="${1:-${SPACES_GHOSTTYKIT_RELEASE_TAG:-$DEFAULT_RELEASE_TAG}}"

mkdir -p "$LOCAL_ROOT"

download_release_asset() {
    local pattern="$1"
    local destination_dir="$2"
    mkdir -p "$destination_dir"
    (
        cd "$destination_dir"
        gh release download "$RELEASE_TAG" --pattern "$pattern" --repo "$FORK_REPO"
    )
}

copy_from_existing_checkout_if_available() {
    [[ -n "$SOURCE_PROJECT_DIR" ]] || return 0
    local source_root="$SOURCE_PROJECT_DIR/apps/macos/.local/ghosttykit"
    [[ -d "$source_root" ]] || return 0

    if [[ ! -d "$XCFRAMEWORK_ROOT" && -d "$source_root/GhosttyKit.xcframework" ]]; then
        echo "==> Copying GhosttyKit.xcframework from $source_root"
        cp -R "$source_root/GhosttyKit.xcframework" "$XCFRAMEWORK_ROOT"
    fi

    if [[ ! -d "$RESOURCES_ROOT/ghostty/shell-integration" && -d "$source_root/Resources" ]]; then
        echo "==> Copying Ghostty runtime resources from $source_root"
        mkdir -p "$RESOURCES_ROOT"
        cp -R "$source_root/Resources/." "$RESOURCES_ROOT/"
    fi
}

copy_from_existing_checkout_if_available

if [[ ! -d "$XCFRAMEWORK_ROOT" ]]; then
    echo "==> Downloading GhosttyKit.xcframework from $FORK_REPO ($RELEASE_TAG)"
    download_release_asset "GhosttyKit.xcframework.tar.gz" "$LOCAL_ROOT"
    (
        cd "$LOCAL_ROOT"
        tar xzf GhosttyKit.xcframework.tar.gz
        rm GhosttyKit.xcframework.tar.gz
    )
else
    echo "==> GhosttyKit.xcframework already present at $XCFRAMEWORK_ROOT"
fi

MACOS_LIB_DIR="$XCFRAMEWORK_ROOT/macos-arm64_x86_64"
if [[ -f "$MACOS_LIB_DIR/ghostty-internal.a" && ! -f "$MACOS_LIB_DIR/libghostty-internal.a" ]]; then
    echo "==> Normalizing macOS Ghostty static library name for SwiftPM"
    cp "$MACOS_LIB_DIR/ghostty-internal.a" "$MACOS_LIB_DIR/libghostty-internal.a"
fi
if [[ -f "$XCFRAMEWORK_ROOT/Info.plist" ]]; then
    /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:1:BinaryPath libghostty-internal.a" "$XCFRAMEWORK_ROOT/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:1:LibraryPath libghostty-internal.a" "$XCFRAMEWORK_ROOT/Info.plist" >/dev/null 2>&1 || true
fi

if [[ ! -d "$RESOURCES_ROOT/ghostty/shell-integration" || ! -d "$RESOURCES_ROOT/terminfo" ]]; then
    echo "==> Downloading Ghostty runtime resources from $FORK_REPO ($RELEASE_TAG)"
    download_release_asset "GhosttyKit-resources.tar.gz" "$RESOURCES_ROOT"
    (
        cd "$RESOURCES_ROOT"
        tar xzf GhosttyKit-resources.tar.gz
        rm GhosttyKit-resources.tar.gz
    )
else
    echo "==> Ghostty runtime resources already present at $RESOURCES_ROOT"
fi

echo
echo "GhosttyKit setup complete."
echo "  xcframework: $XCFRAMEWORK_ROOT"
echo "  resources:   $RESOURCES_ROOT/ghostty"
echo
echo "Use these overrides for embedded-ghostty development:"
echo "  export SPACES_GHOSTTYKIT_XCFRAMEWORK=\"$XCFRAMEWORK_ROOT\""
echo "  export SPACES_GHOSTTY_RESOURCES_DIR=\"$RESOURCES_ROOT/ghostty\""
