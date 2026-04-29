#!/usr/bin/env bash
set -euo pipefail

# Complete release workflow: build, package, and deploy to Firebase Hosting
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
#   FIREBASE_TOKEN     - Firebase CI token (uses local auth if unset)

if [ $# -ne 1 ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 0.2.0"
  exit 1
fi

VERSION="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
MACOS_DIR="$REPO_ROOT/apps/macos"
WEB_DIR="$REPO_ROOT/apps/web"

# Function to compare semantic versions (returns 0 if v1 > v2, 1 otherwise)
version_gt() {
  test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# Check if this version already exists on Firebase
APPCAST_URL="https://muxy-dev.web.app/releases/appcast.xml"
echo "Checking for existing version on Firebase..."

if DEPLOYED_VERSION=$(curl -sf "$APPCAST_URL" 2>/dev/null | grep -o '<sparkle:version>[^<]*</sparkle:version>' | sed 's/<[^>]*>//g' | head -1); then
  echo "  Current deployed version: $DEPLOYED_VERSION"
  
  # Check if new version is higher than deployed version
  if version_gt "$VERSION" "$DEPLOYED_VERSION"; then
    echo "✓ New version $VERSION is higher than $DEPLOYED_VERSION"
    echo ""
  elif [ "$DEPLOYED_VERSION" = "$VERSION" ]; then
    echo ""
    echo "⚠️  WARNING: Version $VERSION is already deployed!"
    echo "  Appcast URL: $APPCAST_URL"
    echo ""
    echo "Overwriting an existing version can cause issues:"
    echo "  • CDN cache conflicts (DMG cached for 1 year)"
    echo "  • Signature mismatches in appcast.xml"
    echo "  • Auto-update won't trigger (same version number)"
    echo ""
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted. Consider using a higher version number."
      exit 1
    fi
    echo ""
  else
    echo ""
    echo "❌ ERROR: Version $VERSION is lower than or equal to deployed version $DEPLOYED_VERSION"
    echo ""
    echo "Version numbers must increase. Consider using:"
    IFS='.' read -ra PARTS <<< "$DEPLOYED_VERSION"
    MAJOR="${PARTS[0]}"
    MINOR="${PARTS[1]:-0}"
    PATCH="${PARTS[2]:-0}"
    echo "  • Patch: ${MAJOR}.${MINOR}.$((PATCH + 1))"
    echo "  • Minor: ${MAJOR}.$((MINOR + 1)).0"
    echo "  • Major: $((MAJOR + 1)).0.0"
    echo ""
    exit 1
  fi
else
  echo "✓ No existing appcast found (first release or appcast unavailable)"
  echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Muxy Release & Deploy v$VERSION"
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
DMG_PATH="$REPO_ROOT/apps/web/public/releases/$VERSION/$DMG_NAME"

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

# Step 5: Build Next.js website
echo "🌐 Step 5/6: Building Next.js website..."
cd "$WEB_DIR"
npm run build
echo "✓ Next.js build complete"
echo ""

# Step 6: Deploy to Firebase Hosting
echo "🚀 Step 6/6: Deploying to Firebase Hosting..."
cd "$REPO_ROOT"
"$SCRIPTS_DIR/deploy-to-firebase.sh" "$DMG_PATH" "$VERSION"
echo "✓ Deployment complete"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✨ Release v$VERSION Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📍 URLs:"
echo "  • Appcast:  https://muxy-dev.web.app/releases/appcast.xml"
echo "  • Download: https://muxy-dev.web.app/releases/latest"
echo "  • DMG:      https://muxy-dev.web.app/releases/$VERSION/$DMG_NAME"
echo ""
