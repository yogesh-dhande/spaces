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
DEFAULT_CADDY_BIN="$REPO_ROOT/apps/macos/.local/caddy/caddy"
CADDY_BIN="${5:-$DEFAULT_CADDY_BIN}"
SPARKLE_FRAMEWORK="$REPO_ROOT/apps/macos/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
GHOSTTYVT_LIB_DIR="${SPACES_GHOSTTY_VT_LIB_DIR:-$REPO_ROOT/apps/macos/.local/ghosttyvt/lib}"

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

shopt -s nullglob
ghostty_vt_dylibs=("$GHOSTTYVT_LIB_DIR"/libghostty-vt*.dylib)
shopt -u nullglob

binary_has_arch() {
  local archs="$1"
  local arch="$2"
  case " $archs " in
    *" $arch "* ) return 0 ;;
    * ) return 1 ;;
  esac
}

require_universal_macos_binary() {
  local binary_path="$1"
  local label="$2"
  local archs

  if [[ ! -f "$binary_path" ]]; then
    echo "Error: Missing $label at $binary_path" >&2
    exit 1
  fi

  archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  if ! binary_has_arch "$archs" arm64 || ! binary_has_arch "$archs" x86_64; then
    echo "Error: $label must be universal arm64+x86_64, but found: ${archs:-unknown} ($binary_path)" >&2
    exit 1
  fi
}

is_universal_macos_binary() {
  local binary_path="$1"
  local archs

  [[ -f "$binary_path" ]] || return 1
  archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  binary_has_arch "$archs" arm64 && binary_has_arch "$archs" x86_64
}

copy_or_build_universal_ghostty_vt_dylibs() {
  local destination_dir="$1"
  local source_dylib="$GHOSTTYVT_LIB_DIR/libghostty-vt.dylib"
  local real_source_dylib

  if [[ -e "$source_dylib" || -L "$source_dylib" ]]; then
    if real_source_dylib="$(realpath "$source_dylib" 2>/dev/null)" && is_universal_macos_binary "$real_source_dylib"; then
      cp -P "${ghostty_vt_dylibs[@]}" "$destination_dir/"
      require_universal_macos_binary "$destination_dir/$(basename "$real_source_dylib")" "bundled libghostty-vt dylib"
      return
    fi
  fi

  local universal_static="$GHOSTTYVT_LIB_DIR/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a"
  require_universal_macos_binary "$universal_static" "Ghostty VT static xcframework library"

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
  require_universal_macos_binary "$destination_dir/libghostty-vt.0.1.0.dylib" "bundled libghostty-vt dylib"
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
require_universal_macos_binary "$CADDY_BIN" "caddy router binary"
cp "$CADDY_BIN" "$BUNDLE_OUTPUT/Contents/Resources/caddy"
chmod +x "$BUNDLE_OUTPUT/Contents/Resources/caddy"
cp -R "$SPARKLE_FRAMEWORK" "$BUNDLE_OUTPUT/Contents/Frameworks/"
copy_or_build_universal_ghostty_vt_dylibs "$BUNDLE_OUTPUT/Contents/Frameworks"
