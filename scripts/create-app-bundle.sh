#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: $0 <Spaces-app-path> <spaces-cli-path> <bundle-output-path>" >&2
  exit 1
fi

SPACES_APP="$1"
SPACES_CLI="$2"
BUNDLE_OUTPUT="$3"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_FRAMEWORK="$REPO_ROOT/apps/macos/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

if [[ ! -f "$SPACES_APP" ]]; then
  echo "Error: app binary not found at $SPACES_APP" >&2
  exit 1
fi

if [[ ! -f "$SPACES_CLI" ]]; then
  echo "Error: CLI binary not found at $SPACES_CLI" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Error: Sparkle framework not found at $SPARKLE_FRAMEWORK. Run scripts/swiftpm.sh build first." >&2
  exit 1
fi

rm -rf "$BUNDLE_OUTPUT"
mkdir -p "$BUNDLE_OUTPUT/Contents/MacOS" "$BUNDLE_OUTPUT/Contents/Resources" "$BUNDLE_OUTPUT/Contents/Frameworks"

cp "$SPACES_APP" "$BUNDLE_OUTPUT/Contents/MacOS/SpacesApp"
chmod +x "$BUNDLE_OUTPUT/Contents/MacOS/SpacesApp"
cp "$REPO_ROOT/apps/macos/Sources/SpacesApp/Info.plist" "$BUNDLE_OUTPUT/Contents/Info.plist"
cp "$REPO_ROOT/apps/macos/Sources/SpacesApp/AppIcon.icns" "$BUNDLE_OUTPUT/Contents/Resources/AppIcon.icns"
cp "$SPACES_CLI" "$BUNDLE_OUTPUT/Contents/Resources/spaces"
chmod +x "$BUNDLE_OUTPUT/Contents/Resources/spaces"
cp -R "$SPARKLE_FRAMEWORK" "$BUNDLE_OUTPUT/Contents/Frameworks/"
