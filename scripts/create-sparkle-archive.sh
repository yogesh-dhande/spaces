#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <signed-app-bundle-path> <version>" >&2
  exit 1
fi

APP_BUNDLE_INPUT="$1"
VERSION="$2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$REPO_ROOT/dist/releases/$VERSION"
ARCHIVE_NAME="Spaces-${VERSION}.zip"
ARCHIVE_PATH="$RELEASES_DIR/$ARCHIVE_NAME"

if [[ ! -d "$APP_BUNDLE_INPUT" ]]; then
  echo "Error: app bundle not found at $APP_BUNDLE_INPUT" >&2
  exit 1
fi

mkdir -p "$RELEASES_DIR"

# Zip the exact same signed (and, when notarization secrets are configured, notarized and
# stapled) Spaces.app the caller built once and also handed to create-dmg.sh, so the Sparkle
# update archive ships the identical notarized bundle rather than a separately signed copy whose
# notarization ticket, if any, was never submitted for that copy (#696). The notarization ticket
# stapled to an app is stored as a regular file inside it, so ditto carries it into the zip with
# no separate notarization step for the zip itself. --keepParent names the top-level zip entry
# after the input directory's basename, so the input must already be named Spaces.app.
rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent --norsrc "$APP_BUNDLE_INPUT" "$ARCHIVE_PATH"

echo "✓ Created $ARCHIVE_PATH"
