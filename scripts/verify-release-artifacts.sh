#!/usr/bin/env bash
set -euo pipefail

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

require_universal_binary() {
  local binary_path="$1"
  local label="$2"
  local archs

  if [[ ! -f "$binary_path" ]]; then
    echo "Error: Missing $label at $binary_path" >&2
    exit 1
  fi

  archs="$(lipo -archs "$binary_path")"
  echo "$label architectures: $archs"

  case " $archs " in
    *" arm64 "* ) ;;
    *)
      echo "Error: $label is missing arm64 support." >&2
      exit 1
      ;;
  esac

  case " $archs " in
    *" x86_64 "* ) ;;
    *)
      echo "Error: $label is missing x86_64 support." >&2
      exit 1
      ;;
  esac
}

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
require_universal_binary \
  "$mountpoint/Spaces.app/Contents/MacOS/SpacesApp" \
  "Spaces.app main executable"
require_universal_binary \
  "$mountpoint/Spaces.app/Contents/Resources/spaces" \
  "Spaces.app bundled CLI"

echo "✓ Release artifacts verified"
