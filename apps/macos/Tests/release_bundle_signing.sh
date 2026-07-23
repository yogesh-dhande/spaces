#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
VERSION="signing-test-$$"
RELEASE_DIR="$REPO_ROOT/dist/releases/$VERSION"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-release-signing.XXXXXX")"
MOUNT_POINT="$WORK_ROOT/dmg"

# A freshly mounted DMG is often briefly held busy by Spotlight/fseventsd even with
# -nobrowse, making a single immediate detach flaky ("Resource busy"). Retry with short
# pauses; force-detach as a last resort (the mount is read-only, so force loses nothing).
detach_mount() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  hdiutil detach -force "$MOUNT_POINT" >/dev/null
}

cleanup() {
  if mount | grep -q "on $MOUNT_POINT "; then
    detach_mount
  fi
  rm -rf "$WORK_ROOT" "$RELEASE_DIR"
}
trap cleanup EXIT

assert_caddy_signature() {
  local caddy="$1"
  local details

  codesign --verify --strict --verbose=2 "$caddy"
  details="$(codesign --display --verbose=4 "$caddy" 2>&1)"
  grep -q "flags=.*runtime" <<<"$details" || {
    echo "Bundled Caddy signature does not enable hardened runtime: $caddy" >&2
    exit 1
  }
}

mkdir -p "$MOUNT_POINT"
CODESIGN_IDENTITY=- "$REPO_ROOT/scripts/create-dmg.sh" \
  "$APP_ROOT/.build/debug/SpacesApp" \
  "$APP_ROOT/.build/debug/spaces" \
  "$APP_ROOT/.build/debug/spacesd" \
  "$VERSION"

DMG_PATH="$RELEASE_DIR/Spaces-$VERSION.dmg"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
assert_caddy_signature "$MOUNT_POINT/Spaces.app/Contents/Resources/caddy"
detach_mount

CODESIGN_IDENTITY=- "$REPO_ROOT/scripts/create-sparkle-archive.sh" \
  "$APP_ROOT/.build/debug/SpacesApp" \
  "$APP_ROOT/.build/debug/spaces" \
  "$APP_ROOT/.build/debug/spacesd" \
  "$VERSION"

ditto -x -k "$RELEASE_DIR/Spaces-$VERSION.zip" "$WORK_ROOT/sparkle"
assert_caddy_signature "$WORK_ROOT/sparkle/Spaces.app/Contents/Resources/caddy"

echo "release bundle signing test passed"
