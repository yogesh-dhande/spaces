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

echo "✓ Release artifacts verified"
