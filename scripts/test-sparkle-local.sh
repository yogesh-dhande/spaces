#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_VERSION_PLIST="$REPO_ROOT/apps/macos/AppVersion.plist"
APP_VERSION_SWIFT="$REPO_ROOT/apps/macos/Sources/workspacecore/AppVersion.swift"
INFO_PLIST="$REPO_ROOT/apps/macos/Sources/SpacesApp/Info.plist"
RELEASES_DIR="$REPO_ROOT/apps/web/public/releases"

: "${SPARKLE_PUBLIC_ED_KEY:?Set SPARKLE_PUBLIC_ED_KEY to your Sparkle public Ed25519 key.}"
: "${SPARKLE_PRIVATE_ED_KEY:?Set SPARKLE_PRIVATE_ED_KEY to your Sparkle private Ed25519 key.}"

BASE_VERSION="${BASE_VERSION:-0.1.0}"
BASE_BUILD="${BASE_BUILD:-100}"
UPDATE_VERSION="${UPDATE_VERSION:-0.1.1}"
UPDATE_BUILD="${UPDATE_BUILD:-101}"
LOCAL_FEED_URL="${LOCAL_FEED_URL:-http://127.0.0.1:8000/releases/appcast.xml}"
LOCAL_DOWNLOAD_URL_PREFIX="${LOCAL_DOWNLOAD_URL_PREFIX:-http://127.0.0.1:8000/releases}"
LOCAL_SERVER_DIR="$REPO_ROOT/apps/web/public"

backup_dir="$(mktemp -d)"
cleanup() {
  cp "$backup_dir/AppVersion.plist" "$APP_VERSION_PLIST"
  cp "$backup_dir/AppVersion.swift" "$APP_VERSION_SWIFT"
  cp "$backup_dir/Info.plist" "$INFO_PLIST"
  rm -rf "$RELEASES_DIR"
  if [[ -d "$backup_dir/releases" ]]; then
    mkdir -p "$RELEASES_DIR"
    cp -R "$backup_dir/releases"/. "$RELEASES_DIR"/
  else
    mkdir -p "$RELEASES_DIR"
    touch "$RELEASES_DIR/.gitkeep"
  fi
  rm -rf "$backup_dir"
}
trap cleanup EXIT

cp "$APP_VERSION_PLIST" "$backup_dir/AppVersion.plist"
cp "$APP_VERSION_SWIFT" "$backup_dir/AppVersion.swift"
cp "$INFO_PLIST" "$backup_dir/Info.plist"
if [[ -d "$RELEASES_DIR" ]]; then
  mkdir -p "$backup_dir/releases"
  cp -R "$RELEASES_DIR"/. "$backup_dir/releases"/
fi

echo "Preparing base build $BASE_VERSION ($BASE_BUILD)..."
"$REPO_ROOT/scripts/sync-app-version.sh" \
  --short "$BASE_VERSION" \
  --build "$BASE_BUILD" \
  --feed-url "$LOCAL_FEED_URL" \
  --public-ed-key "$SPARKLE_PUBLIC_ED_KEY"
BUILD_DIR="$REPO_ROOT/apps/macos/.build/apple/Products/Release"
"$REPO_ROOT/scripts/swiftpm.sh" build -c release --arch arm64 --arch x86_64
"$REPO_ROOT/scripts/create-dmg.sh" \
  "$BUILD_DIR/SpacesApp" \
  "$BUILD_DIR/spaces" \
  "$BUILD_DIR/spacesd" \
  "$BASE_VERSION"

echo "Preparing update build $UPDATE_VERSION ($UPDATE_BUILD)..."
"$REPO_ROOT/scripts/sync-app-version.sh" \
  --short "$UPDATE_VERSION" \
  --build "$UPDATE_BUILD" \
  --feed-url "$LOCAL_FEED_URL" \
  --public-ed-key "$SPARKLE_PUBLIC_ED_KEY"
"$REPO_ROOT/scripts/swiftpm.sh" build -c release --arch arm64 --arch x86_64
"$REPO_ROOT/scripts/create-sparkle-archive.sh" \
  "$BUILD_DIR/SpacesApp" \
  "$BUILD_DIR/spaces" \
  "$BUILD_DIR/spacesd" \
  "$UPDATE_VERSION"

SPARKLE_DOWNLOAD_URL_PREFIX="$LOCAL_DOWNLOAD_URL_PREFIX" \
  SPARKLE_PRIVATE_ED_KEY="$SPARKLE_PRIVATE_ED_KEY" \
  "$REPO_ROOT/scripts/publish-sparkle-appcast.sh" "$UPDATE_VERSION"

cat <<EOF
Local Sparkle test assets are ready.

1. Install the base app from:
   $REPO_ROOT/dist/releases/$BASE_VERSION/Spaces-$BASE_VERSION.dmg

2. Serve the static files directly:
   cd "$LOCAL_SERVER_DIR" && python3 -m http.server 8000

3. Launch /Applications/Spaces.app and run "Check for Updates..."

Expected test feed:
  $LOCAL_FEED_URL

Generated update archive:
  $REPO_ROOT/dist/releases/$UPDATE_VERSION/Spaces-$UPDATE_VERSION.zip
EOF
