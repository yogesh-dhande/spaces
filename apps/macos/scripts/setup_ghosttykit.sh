#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify_ghosttykit.sh"
RELEASE_TAG_FILE="$APP_ROOT/ghosttykit-release-tag.txt"
ARTIFACT_RUN_FILE="$APP_ROOT/ghosttykit-artifact-run.txt"
GHOSTTYVT_REVISION_FILE="$APP_ROOT/ghosttyvt-revision.txt"
LOCAL_ROOT="$APP_ROOT/.local/ghosttykit"
XCFRAMEWORK_ROOT="$LOCAL_ROOT/GhosttyKit.xcframework"
RESOURCES_ROOT="$LOCAL_ROOT/Resources"
GHOSTTYVT_LOCAL_ROOT="$APP_ROOT/.local/ghosttyvt"
GHOSTTYVT_SOURCE_ROOT="${SPACES_GHOSTTYVT_SOURCE_ROOT:-$GHOSTTYVT_LOCAL_ROOT/src}"
GHOSTTYVT_TOOLCHAIN_ROOT="$GHOSTTYVT_LOCAL_ROOT/toolchain/zig-aarch64-macos-0.15.2"
SOURCE_PROJECT_DIR="${SPACES_PROJECT_DIR:-}"
FORK_REPO="${SPACES_GHOSTTYKIT_REPO:-yogesh-dhande/ghostty}"
BUILD_FROM_SOURCE="${SPACES_GHOSTTYKIT_BUILD_FROM_SOURCE:-0}"
XCFRAMEWORK_ARTIFACT_NAME="${SPACES_GHOSTTYKIT_XCFRAMEWORK_ARTIFACT_NAME:-GhosttyKit.xcframework.tar.gz}"
RESOURCES_ARTIFACT_NAME="${SPACES_GHOSTTYKIT_RESOURCES_ARTIFACT_NAME:-GhosttyKit-resources.tar.gz}"

if [[ -f "$RELEASE_TAG_FILE" ]]; then
    DEFAULT_RELEASE_TAG="$(tr -d '[:space:]' < "$RELEASE_TAG_FILE")"
else
    DEFAULT_RELEASE_TAG="build-2026-04-29"
fi

if [[ -f "$ARTIFACT_RUN_FILE" ]]; then
    DEFAULT_ACTIONS_RUN_ID="$(tr -d '[:space:]' < "$ARTIFACT_RUN_FILE")"
else
    DEFAULT_ACTIONS_RUN_ID=""
fi

RELEASE_TAG="${1:-${SPACES_GHOSTTYKIT_RELEASE_TAG:-$DEFAULT_RELEASE_TAG}}"
ACTIONS_RUN_ID="${SPACES_GHOSTTYKIT_ACTIONS_RUN_ID:-$DEFAULT_ACTIONS_RUN_ID}"

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

read_pinned_ghostty_revision() {
    [[ -f "$GHOSTTYVT_REVISION_FILE" ]] || return 0
    tr -d '[:space:]' < "$GHOSTTYVT_REVISION_FILE"
}

validate_actions_run() {
    [[ -n "$ACTIONS_RUN_ID" ]] || return 0

    local status conclusion head_sha run_url expected_revision
    IFS=$'\t' read -r status conclusion head_sha run_url <<<"$(
        gh run view "$ACTIONS_RUN_ID" \
            --repo "$FORK_REPO" \
            --json status,conclusion,headSha,url \
            --jq '[.status, (.conclusion // ""), .headSha, .url] | @tsv'
    )"

    if [[ "$status" != "completed" || "$conclusion" != "success" ]]; then
        echo "GhosttyKit artifact run is not a successful completed run: $run_url ($status/$conclusion)" >&2
        exit 1
    fi

    expected_revision="$(read_pinned_ghostty_revision)"
    if [[ -n "$expected_revision" && "$head_sha" != "$expected_revision" ]]; then
        echo "GhosttyKit artifact run $ACTIONS_RUN_ID points at $head_sha, but ghosttyvt-revision.txt pins $expected_revision" >&2
        echo "update apps/macos/ghosttyvt-revision.txt to the artifact run commit or use a matching run" >&2
        exit 1
    fi
}

download_actions_artifact_file() {
    local artifact_name="$1"
    local expected_file="$2"
    local destination_dir="$3"
    local tmp_dir downloaded_file

    tmp_dir="$(mktemp -d)"
    gh run download "$ACTIONS_RUN_ID" --repo "$FORK_REPO" --name "$artifact_name" --dir "$tmp_dir"

    downloaded_file="$(find "$tmp_dir" -type f -name "$expected_file" -print -quit)"
    if [[ -z "$downloaded_file" ]]; then
        echo "GhosttyKit artifact '$artifact_name' from run $ACTIONS_RUN_ID did not contain $expected_file" >&2
        exit 1
    fi

    mkdir -p "$destination_dir"
    cp "$downloaded_file" "$destination_dir/$expected_file"
    rm -rf "$tmp_dir"
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

patch_libxev_for_ios_simulator() {
    local zig_bin="$1"
    local zon_file="$GHOSTTYVT_SOURCE_ROOT/build.zig.zon"
    [[ -f "$zon_file" ]] || return 0

    local global_cache_dir
    global_cache_dir="$("$zig_bin" env | awk -F'"' '/global_cache_dir/ { print $2; exit }')"
    [[ -n "$global_cache_dir" ]] || return 0

    local libxev_hash
    libxev_hash="$(
        awk '
            /\.libxev = \{/ { in_dep = 1; next }
            in_dep && /hash = / {
                if (match($0, /"[^"]+"/)) {
                    print substr($0, RSTART + 1, RLENGTH - 2)
                    exit
                }
            }
            in_dep && /\},/ { in_dep = 0 }
        ' "$zon_file"
    )"
    [[ -n "$libxev_hash" ]] || return 0

    local backend_file="$global_cache_dir/p/$libxev_hash/src/backend/kqueue.zig"
    [[ -f "$backend_file" ]] || return 0

    if grep -q 'builtin\.os\.tag != \.macos' "$backend_file"; then
        echo "==> Patching libxev Mach-port kqueue registration for iOS builds"
        perl -0pi -e 's/builtin\.os\.tag != \.macos/!builtin.os.tag.isDarwin()/g' "$backend_file"
    fi
}

build_local_source_if_requested() {
    [[ "$BUILD_FROM_SOURCE" == "1" ]] || return 0

    if [[ ! -d "$GHOSTTYVT_SOURCE_ROOT" ]]; then
        echo "Ghostty source checkout not found at $GHOSTTYVT_SOURCE_ROOT. Run apps/macos/scripts/setup_ghosttyvt.sh first." >&2
        exit 1
    fi

    local zig_bin="${SPACES_GHOSTTYKIT_ZIG_BIN:-$GHOSTTYVT_TOOLCHAIN_ROOT/zig}"
    if [[ ! -x "$zig_bin" ]]; then
        if command -v zig >/dev/null 2>&1; then
            zig_bin="$(command -v zig)"
        else
            echo "Zig compiler not found. Run apps/macos/scripts/setup_ghosttyvt.sh first or set SPACES_GHOSTTYKIT_ZIG_BIN." >&2
            exit 1
        fi
    fi

    local version_line
    version_line="$(grep -m1 '\.version = ' "$GHOSTTYVT_SOURCE_ROOT/build.zig.zon" || true)"
    local app_version
    app_version="$(sed -E 's/.*"([^"]+)".*/\1/' <<<"$version_line")"
    if [[ -z "$app_version" || "$app_version" == "$version_line" ]]; then
        echo "Failed to determine Ghostty version string from $GHOSTTYVT_SOURCE_ROOT/build.zig.zon" >&2
        exit 1
    fi

    echo "==> Building GhosttyKit.xcframework from local Ghostty source at $GHOSTTYVT_SOURCE_ROOT"
    patch_libxev_for_ios_simulator "$zig_bin"
    (
        cd "$GHOSTTYVT_SOURCE_ROOT"
        "$zig_bin" build -Demit-xcframework=true -Demit-macos-app=false -Di18n=false -Dversion-string="$app_version"
    )
}

copy_from_local_source_build_if_requested() {
    [[ "$BUILD_FROM_SOURCE" == "1" ]] || return 0

    local source_xcframework="$GHOSTTYVT_SOURCE_ROOT/macos/GhosttyKit.xcframework"
    local source_ghostty_resources="$GHOSTTYVT_SOURCE_ROOT/zig-out/share/ghostty"
    local source_terminfo_resources="$GHOSTTYVT_SOURCE_ROOT/zig-out/share/terminfo"

    if [[ ! -d "$source_xcframework" || ! -d "$source_ghostty_resources" || ! -d "$source_terminfo_resources" ]]; then
        echo "Local Ghostty source build artifacts are incomplete under $GHOSTTYVT_SOURCE_ROOT." >&2
        exit 1
    fi

    echo "==> Installing GhosttyKit artifacts from local Ghostty source build"
    rm -rf "$XCFRAMEWORK_ROOT"
    cp -R "$source_xcframework" "$XCFRAMEWORK_ROOT"

    mkdir -p "$RESOURCES_ROOT"
    rm -rf "$RESOURCES_ROOT/ghostty" "$RESOURCES_ROOT/terminfo"
    cp -R "$source_ghostty_resources" "$RESOURCES_ROOT/ghostty"
    cp -R "$source_terminfo_resources" "$RESOURCES_ROOT/terminfo"
}

copy_from_existing_checkout_if_available
build_local_source_if_requested
copy_from_local_source_build_if_requested

if [[ ! -d "$XCFRAMEWORK_ROOT" ]]; then
    if [[ -n "$ACTIONS_RUN_ID" ]]; then
        validate_actions_run
        echo "==> Downloading GhosttyKit.xcframework from $FORK_REPO Actions run $ACTIONS_RUN_ID"
        download_actions_artifact_file "$XCFRAMEWORK_ARTIFACT_NAME" "GhosttyKit.xcframework.tar.gz" "$LOCAL_ROOT"
    else
        echo "==> Downloading GhosttyKit.xcframework from $FORK_REPO ($RELEASE_TAG)"
        download_release_asset "GhosttyKit.xcframework.tar.gz" "$LOCAL_ROOT"
    fi
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
if [[ -f "$MACOS_LIB_DIR/ghostty-internal.a" && -f "$MACOS_LIB_DIR/libghostty-internal.a" ]]; then
    rm "$MACOS_LIB_DIR/ghostty-internal.a"
fi
if [[ -f "$XCFRAMEWORK_ROOT/Info.plist" ]]; then
    for library_index in 0 1 2 3 4 5; do
        platform="$(
            /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${library_index}:SupportedPlatform" "$XCFRAMEWORK_ROOT/Info.plist" 2>/dev/null || true
        )"
        if [[ "$platform" == "macos" ]]; then
            /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:${library_index}:BinaryPath libghostty-internal.a" \
                "$XCFRAMEWORK_ROOT/Info.plist" >/dev/null 2>&1 || true
            /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:${library_index}:LibraryPath libghostty-internal.a" \
                "$XCFRAMEWORK_ROOT/Info.plist" >/dev/null 2>&1 || true
        fi
    done
fi

if [[ ! -d "$RESOURCES_ROOT/ghostty/shell-integration" || ! -d "$RESOURCES_ROOT/terminfo" ]]; then
    if [[ -n "$ACTIONS_RUN_ID" ]]; then
        validate_actions_run
        echo "==> Downloading Ghostty runtime resources from $FORK_REPO Actions run $ACTIONS_RUN_ID"
        download_actions_artifact_file "$RESOURCES_ARTIFACT_NAME" "GhosttyKit-resources.tar.gz" "$RESOURCES_ROOT"
    else
        echo "==> Downloading Ghostty runtime resources from $FORK_REPO ($RELEASE_TAG)"
        download_release_asset "GhosttyKit-resources.tar.gz" "$RESOURCES_ROOT"
    fi
    (
        cd "$RESOURCES_ROOT"
        tar xzf GhosttyKit-resources.tar.gz
        rm GhosttyKit-resources.tar.gz
    )
else
    echo "==> Ghostty runtime resources already present at $RESOURCES_ROOT"
fi

if [[ -x "$VERIFY_SCRIPT" ]]; then
    echo "==> Verifying GhosttyKit embedded terminal API contract"
    "$VERIFY_SCRIPT" "$XCFRAMEWORK_ROOT"
fi

echo
echo "GhosttyKit setup complete."
echo "  xcframework: $XCFRAMEWORK_ROOT"
echo "  resources:   $RESOURCES_ROOT/ghostty"
echo
echo "Use these overrides for embedded-ghostty development:"
echo "  export SPACES_GHOSTTYKIT_XCFRAMEWORK=\"$XCFRAMEWORK_ROOT\""
echo "  export SPACES_GHOSTTY_RESOURCES_DIR=\"$RESOURCES_ROOT/ghostty\""
