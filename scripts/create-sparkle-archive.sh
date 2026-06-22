#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 4 ]; then
  echo "Usage: $0 <Spaces-app-path> <spaces-cli-path> <spacesd-path> <version>" >&2
  exit 1
fi

SPACES_APP="$1"
SPACES_CLI="$2"
SPACESD="$3"
VERSION="$4"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$REPO_ROOT/dist/releases/$VERSION"
ARCHIVE_NAME="Spaces-${VERSION}.zip"
ARCHIVE_PATH="$RELEASES_DIR/$ARCHIVE_NAME"
IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="$REPO_ROOT/scripts/entitlements.plist"

mkdir -p "$RELEASES_DIR"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
app_bundle="$staging/Spaces.app"

"$REPO_ROOT/scripts/create-app-bundle.sh" "$SPACES_APP" "$SPACES_CLI" "$SPACESD" "$app_bundle"

echo "Signing Sparkle app bundle with identity: $IDENTITY"
codesign --force --deep --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$app_bundle"
codesign --verify --verbose=2 "$app_bundle"

rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent --norsrc "$app_bundle" "$ARCHIVE_PATH"

echo "✓ Created $ARCHIVE_PATH"
