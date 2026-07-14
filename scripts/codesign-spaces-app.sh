#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <Spaces-app-path>" >&2
  exit 1
fi

APP_BUNDLE="$1"
IDENTITY="${CODESIGN_IDENTITY:--}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"
CADDY="$APP_BUNDLE/Contents/Resources/caddy"

if [[ ! -x "$CADDY" ]]; then
  echo "Error: bundled Caddy executable not found at $CADDY" >&2
  exit 1
fi

# Caddy lives under Resources, so codesign --deep does not discover it as nested code. Sign it
# explicitly before sealing the enclosing app bundle or Apple notarization rejects the archive.
echo "Signing bundled Caddy with identity: $IDENTITY"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$CADDY"

echo "Signing app bundle with identity: $IDENTITY"
codesign --force --deep --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_BUNDLE"

codesign --verify --strict --verbose=2 "$CADDY"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
