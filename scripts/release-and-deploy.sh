#!/usr/bin/env bash
set -euo pipefail

# Complete release workflow: build, package, and publish to GitHub Releases
#
# Usage:
#   scripts/release-and-deploy.sh <version>
#
# Example:
#   scripts/release-and-deploy.sh 0.2.0
#
# Environment variables (optional):
#   CODESIGN_IDENTITY  - Developer ID certificate (optional; ad-hoc if unset)
#   NOTARIZE           - Set to "1" to notarize via xcrun notarytool
#   APPLE_ID           - Apple ID for notarization
#   TEAM_ID            - Apple Developer Team ID for notarization
#   APP_PASSWORD       - App-specific password for notarization
#   GH_TOKEN           - GitHub token with permission to create releases

if [ $# -ne 1 ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 0.2.0"
  exit 1
fi

VERSION="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
MACOS_DIR="$REPO_ROOT/apps/macos"
TAG="v$VERSION"
RELEASE_URL="https://github.com/yogesh-dhande/spaces/releases/tag/$TAG"

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI is required. Install it from https://cli.github.com/" >&2
  exit 1
fi

echo "Checking for existing GitHub release $TAG..."
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Error: GitHub release $TAG already exists." >&2
  exit 1
fi
echo "✓ Release tag is available"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Muxy Release v$VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Build macOS app in release mode
echo "📦 Step 1/6: Building macOS app..."
"$SCRIPTS_DIR/swiftpm.sh" build -c release
echo "✓ Build complete"
echo ""

# Step 2: Code sign binaries
echo "🔐 Step 2/6: Code signing binaries..."
BUILD_DIR="$MACOS_DIR/.build/release"
MUXY_APP="$BUILD_DIR/MuxyApp"
MUXY_CLI="$BUILD_DIR/muxy"

if [[ ! -f "$MUXY_APP" ]] || [[ ! -f "$MUXY_CLI" ]]; then
  echo "Error: Release binaries not found in $BUILD_DIR" >&2
  exit 1
fi

set -a          # auto-export all variables defined from now on
source "$REPO_ROOT/.env"
set +a          # stop auto-exporting

"$SCRIPTS_DIR/codesign.sh" "$MUXY_APP" "$MUXY_CLI"
echo "✓ Code signing complete"
echo ""

# Step 3: Create DMG installer
echo "💿 Step 3/6: Creating DMG installer..."
"$SCRIPTS_DIR/create-dmg.sh" "$MUXY_APP" "$MUXY_CLI" "$VERSION"
DMG_NAME="Muxy-${VERSION}.dmg"
DMG_PATH="$REPO_ROOT/dist/releases/$VERSION/$DMG_NAME"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Error: DMG not created at $DMG_PATH" >&2
  exit 1
fi
echo "✓ DMG created: $DMG_NAME"
echo ""

# Step 4: Notarize (optional)
if [[ "${NOTARIZE:-}" == "1" ]]; then
  echo "🍎 Step 4/6: Notarizing DMG..."
  if [[ -z "${APPLE_ID:-}" ]] || [[ -z "${TEAM_ID:-}" ]] || [[ -z "${APP_PASSWORD:-}" ]]; then
    echo "Error: APPLE_ID, TEAM_ID, and APP_PASSWORD are required for notarization" >&2
    exit 1
  fi
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  echo "✓ Notarization complete"
  echo ""
else
  echo "⏭️  Step 4/6: Skipping notarization (set NOTARIZE=1 to enable)"
  echo ""
fi

# Step 5: Create GitHub release
echo "🚀 Step 5/6: Creating GitHub release..."
cd "$REPO_ROOT"
gh release create "$TAG" "$DMG_PATH" \
  --title "Muxy $VERSION" \
  --generate-notes
echo "✓ GitHub release created"
echo ""

# Step 6: Build Next.js website
echo "🌐 Step 6/6: Building Next.js website..."
cd "$REPO_ROOT/apps/web"
npm run build
echo "✓ Next.js build complete"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✨ Release v$VERSION Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📍 URLs:"
echo "  • Release:  $RELEASE_URL"
echo "  • DMG:      $RELEASE_URL"
echo ""
