#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/spaces-release-helpers.sh"

require_notarization=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-notarization)
      require_notarization=1
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 [--require-notarization] <dmg-path>" >&2
  exit 1
fi

DMG_PATH="$1"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Error: DMG not found at $DMG_PATH" >&2
  exit 1
fi

echo "Verifying signed DMG..."
codesign --verify --verbose=2 "$DMG_PATH"

if [[ $require_notarization -eq 1 ]]; then
  spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"
  echo "Validating DMG notarization ticket..."
  xcrun stapler validate "$DMG_PATH"
fi

mountpoint="$(mktemp -d "${TMPDIR%/}/spaces-release-verify-XXXXXX")"
mountpoint="$(cd "$mountpoint" && pwd -P)"
cleanup() {
  if mount | grep -q "on $mountpoint "; then
    hdiutil detach "$mountpoint" >/dev/null
  fi
  rm -rf "$mountpoint"
}
trap cleanup EXIT

echo "Mounting DMG to inspect bundled apps..."
hdiutil attach -nobrowse -readonly -mountpoint "$mountpoint" "$DMG_PATH" >/dev/null

for app_path in "$mountpoint/Install Spaces.app" "$mountpoint/Spaces.app"; do
  if [[ ! -d "$app_path" ]]; then
    echo "Error: Missing app bundle at $app_path" >&2
    exit 1
  fi

  echo "Verifying $(basename "$app_path")..."
  codesign --verify --verbose=2 "$app_path"
  if [[ $require_notarization -eq 1 ]]; then
    spctl -a -vvv -t exec "$app_path"
  fi
done

echo "Verifying bundled binary architectures..."
spaces_release_require_universal_binary_verbose \
  "$mountpoint/Spaces.app/Contents/MacOS/SpacesApp" \
  "Spaces.app main executable"
spaces_release_require_universal_binary_verbose \
  "$mountpoint/Spaces.app/Contents/Resources/spaces" \
  "Spaces.app bundled CLI"
spaces_release_require_universal_binary_verbose \
  "$mountpoint/Spaces.app/Contents/Resources/spacesd" \
  "Spaces.app bundled spacesd daemon"
bundled_caddy="$mountpoint/Spaces.app/Contents/Resources/caddy"
spaces_release_require_universal_binary_verbose "$bundled_caddy" "Spaces.app bundled Caddy"
echo "Verifying bundled Caddy signature..."
codesign --verify --strict --verbose=2 "$bundled_caddy"

ghostty_resources="$mountpoint/Spaces.app/Contents/Resources/ghostty"
if [[ ! -d "$ghostty_resources" ]]; then
  echo "Error: Missing bundled Ghostty runtime resources at $ghostty_resources" >&2
  exit 1
fi
for required_resource in shell-integration themes; do
  if [[ ! -d "$ghostty_resources/$required_resource" ]]; then
    echo "Error: Bundled Ghostty runtime resources are missing $required_resource at $ghostty_resources" >&2
    exit 1
  fi
done

ghostty_terminfo="$mountpoint/Spaces.app/Contents/Resources/terminfo"
if [[ ! -d "$ghostty_terminfo" ]]; then
  echo "Error: Missing bundled Ghostty terminfo database at $ghostty_terminfo" >&2
  exit 1
fi
if [[ -z "$(find "$ghostty_terminfo" -type f -name xterm-ghostty -print -quit)" ]]; then
  echo "Error: Bundled Ghostty terminfo database is missing the xterm-ghostty entry at $ghostty_terminfo" >&2
  exit 1
fi

spacesui_bundle="$mountpoint/Spaces.app/Contents/Resources/spaces_spacesui.bundle"
if [[ ! -d "$spacesui_bundle" ]]; then
  echo "Error: Missing SwiftPM resource bundle at $spacesui_bundle" >&2
  exit 1
fi
# The universal (--arch arm64 --arch x86_64) build emits the deep bundle layout
# (Contents/Resources/CodePane/...), flat builds emit CodePane/ at the top; search
# instead of hard-coding either layout.
if [[ -z "$(find "$spacesui_bundle" -type f -path '*/CodePane/index.html' -print -quit)" ]]; then
  echo "Error: Bundled spaces_spacesui.bundle is missing CodePane/index.html at $spacesui_bundle" >&2
  exit 1
fi
spacesapp_bundle="$mountpoint/Spaces.app/Contents/Resources/spaces_SpacesApp.bundle"
if [[ ! -d "$spacesapp_bundle" ]]; then
  echo "Error: Missing SwiftPM resource bundle at $spacesapp_bundle" >&2
  exit 1
fi

ghostty_vt_dylib="$mountpoint/Spaces.app/Contents/Frameworks/libghostty-vt.dylib"
ghostty_vt_real_dylib="$mountpoint/Spaces.app/Contents/Frameworks/libghostty-vt.0.1.0.dylib"
if [[ ! -e "$ghostty_vt_dylib" && ! -L "$ghostty_vt_dylib" ]]; then
  echo "Error: Missing bundled libghostty-vt dylib at $ghostty_vt_dylib" >&2
  exit 1
fi
if [[ ! -f "$ghostty_vt_real_dylib" ]]; then
  echo "Error: Missing bundled libghostty-vt real dylib at $ghostty_vt_real_dylib" >&2
  exit 1
fi
spaces_release_require_universal_binary_verbose \
  "$ghostty_vt_real_dylib" \
  "Spaces.app bundled libghostty-vt"

echo "✓ Release artifacts verified"
