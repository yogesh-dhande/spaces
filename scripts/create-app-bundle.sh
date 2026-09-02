#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 4 ] || [ $# -gt 5 ]; then
  echo "Usage: $0 <Spaces-app-path> <spaces-cli-path> <spacesd-path> <bundle-output-path> [caddy-path]" >&2
  exit 1
fi

SPACES_APP="$1"
SPACES_CLI="$2"
SPACESD="$3"
BUNDLE_OUTPUT="$4"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/spaces-release-helpers.sh"
DEFAULT_CADDY_BIN="$REPO_ROOT/apps/macos/.local/caddy/caddy"
CADDY_BIN="${5:-$DEFAULT_CADDY_BIN}"
SPARKLE_FRAMEWORK="$REPO_ROOT/apps/macos/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
GHOSTTYVT_LIB_DIR="${SPACES_GHOSTTY_VT_LIB_DIR:-$REPO_ROOT/apps/macos/.local/ghosttyvt/lib}"
GHOSTTY_RESOURCES_DIR="${SPACES_GHOSTTY_RESOURCES_DIR:-$REPO_ROOT/apps/macos/.local/ghosttykit/Resources/ghostty}"
GHOSTTY_TERMINFO_DIR="$(dirname "$GHOSTTY_RESOURCES_DIR")/terminfo"

if [[ ! -f "$SPACES_APP" ]]; then
  echo "Error: app binary not found at $SPACES_APP" >&2
  exit 1
fi

if [[ ! -f "$SPACES_CLI" ]]; then
  echo "Error: CLI binary not found at $SPACES_CLI" >&2
  exit 1
fi

if [[ ! -f "$SPACESD" ]]; then
  echo "Error: spacesd daemon binary not found at $SPACESD" >&2
  exit 1
fi

if [[ $# -eq 4 ]]; then
  "$REPO_ROOT/apps/macos/scripts/setup_caddy.sh"
fi

if [[ ! -f "$CADDY_BIN" ]]; then
  echo "Error: caddy binary not found at $CADDY_BIN" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Error: Sparkle framework not found at $SPARKLE_FRAMEWORK. Run scripts/swiftpm.sh build first." >&2
  exit 1
fi

if [[ ! -d "$GHOSTTY_RESOURCES_DIR" ]]; then
  echo "Error: Ghostty runtime resources not found at $GHOSTTY_RESOURCES_DIR. Run apps/macos/scripts/setup_ghostty.sh first." >&2
  exit 1
fi
for required_resource in shell-integration themes; do
  if [[ ! -d "$GHOSTTY_RESOURCES_DIR/$required_resource" ]]; then
    echo "Error: Ghostty runtime resources are missing $required_resource at $GHOSTTY_RESOURCES_DIR." >&2
    exit 1
  fi
done
if [[ ! -d "$GHOSTTY_TERMINFO_DIR" ]]; then
  echo "Error: Ghostty terminfo database not found at $GHOSTTY_TERMINFO_DIR. Run apps/macos/scripts/setup_ghostty.sh first." >&2
  exit 1
fi
if [[ -z "$(find "$GHOSTTY_TERMINFO_DIR" -type f -name xterm-ghostty -print -quit)" ]]; then
  echo "Error: Ghostty terminfo database is missing the xterm-ghostty entry at $GHOSTTY_TERMINFO_DIR." >&2
  exit 1
fi

shopt -s nullglob
ghostty_vt_dylibs=("$GHOSTTYVT_LIB_DIR"/libghostty-vt*.dylib)
shopt -u nullglob

copy_or_build_universal_ghostty_vt_dylibs() {
  local destination_dir="$1"
  local source_dylib="$GHOSTTYVT_LIB_DIR/libghostty-vt.dylib"
  local real_source_dylib

  if spaces_release_dylib_copy_candidate "$source_dylib"; then
    if real_source_dylib="$(realpath "$source_dylib" 2>/dev/null)" && spaces_release_is_universal_binary "$real_source_dylib"; then
      cp -P "${ghostty_vt_dylibs[@]}" "$destination_dir/"
      spaces_release_require_universal_binary "$destination_dir/$(basename "$real_source_dylib")" "bundled libghostty-vt dylib"
      return
    fi
  fi

  local universal_static="$GHOSTTYVT_LIB_DIR/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a"
  spaces_release_require_universal_binary "$universal_static" "Ghostty VT static xcframework library"

  echo "Building universal libghostty-vt dylib from $universal_static"
  xcrun clang \
    -dynamiclib \
    -arch arm64 \
    -arch x86_64 \
    -mmacosx-version-min=14.0 \
    -install_name @rpath/libghostty-vt.dylib \
    -compatibility_version 0.1.0 \
    -current_version 0.1.0 \
    -o "$destination_dir/libghostty-vt.0.1.0.dylib" \
    -Wl,-all_load \
    "$universal_static"
  ln -s libghostty-vt.0.1.0.dylib "$destination_dir/libghostty-vt.0.dylib"
  ln -s libghostty-vt.0.dylib "$destination_dir/libghostty-vt.dylib"
  spaces_release_require_universal_binary "$destination_dir/libghostty-vt.0.1.0.dylib" "bundled libghostty-vt dylib"
}

rm -rf "$BUNDLE_OUTPUT"
mkdir -p "$BUNDLE_OUTPUT/Contents/MacOS" "$BUNDLE_OUTPUT/Contents/Resources" "$BUNDLE_OUTPUT/Contents/Frameworks"

cp "$SPACES_APP" "$BUNDLE_OUTPUT/Contents/MacOS/SpacesApp"
chmod +x "$BUNDLE_OUTPUT/Contents/MacOS/SpacesApp"
cp "$REPO_ROOT/apps/macos/Sources/SpacesApp/Info.plist" "$BUNDLE_OUTPUT/Contents/Info.plist"
cp "$REPO_ROOT/apps/macos/Sources/SpacesApp/AppIcon.icns" "$BUNDLE_OUTPUT/Contents/Resources/AppIcon.icns"
cp "$SPACES_CLI" "$BUNDLE_OUTPUT/Contents/Resources/spaces"
chmod +x "$BUNDLE_OUTPUT/Contents/Resources/spaces"
cp "$SPACESD" "$BUNDLE_OUTPUT/Contents/Resources/spacesd"
chmod +x "$BUNDLE_OUTPUT/Contents/Resources/spacesd"

# SwiftPM emits each target's resource bundle (backing Bundle.module) next to the built
# binaries. The app loads them from Contents/Resources at runtime; a missing
# spaces_spacesui.bundle makes the packaged app trap on first Bundle.module access (#632).
SWIFTPM_PRODUCTS_DIR="$(cd "$(dirname "$SPACES_APP")" && pwd)"
for resource_bundle in spaces_spacesui.bundle spaces_SpacesApp.bundle; do
  resource_bundle_source="$SWIFTPM_PRODUCTS_DIR/$resource_bundle"
  if [[ ! -d "$resource_bundle_source" ]]; then
    echo "Error: SwiftPM resource bundle not found at $resource_bundle_source. Build the app before packaging." >&2
    exit 1
  fi
  cp -R "$resource_bundle_source" "$BUNDLE_OUTPUT/Contents/Resources/$resource_bundle"
done

cp -R "$GHOSTTY_RESOURCES_DIR" "$BUNDLE_OUTPUT/Contents/Resources/ghostty"
cp -R "$GHOSTTY_TERMINFO_DIR" "$BUNDLE_OUTPUT/Contents/Resources/terminfo"
spaces_release_require_universal_binary "$CADDY_BIN" "caddy router binary"
cp "$CADDY_BIN" "$BUNDLE_OUTPUT/Contents/Resources/caddy"
chmod +x "$BUNDLE_OUTPUT/Contents/Resources/caddy"
cp -R "$SPARKLE_FRAMEWORK" "$BUNDLE_OUTPUT/Contents/Frameworks/"
copy_or_build_universal_ghostty_vt_dylibs "$BUNDLE_OUTPUT/Contents/Frameworks"
