#!/usr/bin/env bash
set -euo pipefail

# Complete release workflow: build, package, and publish a GitHub release plus
# a Sparkle appcast/update archive.
#
# The release is created as a prerelease, exactly like the tag-push workflow: a
# release reaches the stable Sparkle feed only when it is promoted by unticking
# "This is a pre-release" on the GitHub release.
#
# Usage:
#   scripts/release-and-deploy.sh <version> [build-number]
#
# Example:
#   scripts/release-and-deploy.sh 0.2.0 42
#
# Required environment variables:
#   CODESIGN_IDENTITY  - Developer ID certificate (optional; ad-hoc if unset)
#   SPARKLE_PUBLIC_ED_KEY  - Public Sparkle EdDSA key embedded in Info.plist
#   SPARKLE_PRIVATE_ED_KEY - Private Sparkle EdDSA key used for appcast signing
#   REMOTE_ARTIFACT_PUBLIC_ED25519_KEY - Public Ed25519 key embedded for remote artifact manifest verification
#   REMOTE_ARTIFACT_PRIVATE_ED25519_KEY - Private Ed25519 key used to sign remote artifact manifests
# Optional environment variables:
#   SPARKLE_FEED_URL   - Sparkle appcast URL (default: https://usespaces.dev/releases/appcast.xml)
#   SPARKLE_DOWNLOAD_URL_PREFIX - Base HTTPS URL for update archives (default: https://usespaces.dev/releases)
#   SPARKLE_RELEASE_NOTES_URL_PREFIX - Base URL for hosted release notes files
#   SPARKLE_FULL_RELEASE_NOTES_URL - URL for full release notes
#   SPARKLE_LINK       - Product URL included in appcast items
#   NOTARIZE           - Set to "1" to notarize via xcrun notarytool
#   APPLE_ID           - Apple ID for notarization
#   TEAM_ID            - Apple Developer Team ID for notarization
#   APP_PASSWORD       - App-specific password for notarization
#   GH_TOKEN           - GitHub token with permission to create releases

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <version> [build-number]"
  echo "Example: $0 0.2.0 42"
  exit 1
fi

VERSION="$1"
BUILD_NUMBER="${2:-$(date +%Y%m%d%H%M%S)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
MACOS_DIR="$REPO_ROOT/apps/macos"
GIT_COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)"
TAG="v$VERSION"
RELEASE_URL="https://github.com/yogesh-dhande/spaces/releases/tag/$TAG"
REMOTE_ARTIFACT_DIR="$REPO_ROOT/dist/remote"

source "$SCRIPTS_DIR/spaces-e2e-env.sh"
spaces_e2e_require_env "$REPO_ROOT"

SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://usespaces.dev/releases/appcast.xml}"

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI is required. Install it from https://cli.github.com/" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker is required to build Ubuntu remote spacesd artifacts." >&2
  exit 1
fi

if [[ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  echo "Error: SPARKLE_PUBLIC_ED_KEY is required." >&2
  exit 1
fi

if [[ -z "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
  echo "Error: SPARKLE_PRIVATE_ED_KEY is required." >&2
  exit 1
fi

if [[ -z "${REMOTE_ARTIFACT_PUBLIC_ED25519_KEY:-}" ]]; then
  echo "Error: REMOTE_ARTIFACT_PUBLIC_ED25519_KEY is required." >&2
  exit 1
fi

if [[ -z "${REMOTE_ARTIFACT_PRIVATE_ED25519_KEY:-}" ]]; then
  echo "Error: REMOTE_ARTIFACT_PRIVATE_ED25519_KEY is required." >&2
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
echo "  Spaces Release v$VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

build_linux_remote_artifact() {
  local arch="$1"
  local platform="$2"
  local docker_args=(run --rm --platform "$platform")
  local builder_image
  builder_image="$("$REPO_ROOT/apps/macos/scripts/ensure_linux_builder_image.sh" --arch "$arch")"

  if [[ "$GIT_COMMON_DIR" != "$REPO_ROOT/.git" ]]; then
    docker_args+=(-v "$GIT_COMMON_DIR:$GIT_COMMON_DIR")
  fi

  docker "${docker_args[@]}" \
    -v "$REPO_ROOT":/workspace \
    -w /workspace \
    "$builder_image" \
    bash -lc "git config --global --add safe.directory /workspace && git config --global --add safe.directory /workspace/apps/macos/vendor/ghostty && apps/macos/scripts/build_linux_spacesd_artifact.sh --output-dir dist/remote --arch $arch"
}

verify_remote_artifact() {
  local archive_name="$1"

  (
    cd "$REMOTE_ARTIFACT_DIR"
    shasum -a 256 -c "$archive_name.sha256"
    tar -tzf "$archive_name" >/dev/null
  )
}

# Step 1: Build macOS app in release mode
echo "🧾 Step 1/13: Syncing release metadata..."
"$SCRIPTS_DIR/sync-app-version.sh" \
  --short "$VERSION" \
  --build "$BUILD_NUMBER" \
  --feed-url "$SPARKLE_FEED_URL" \
  --public-ed-key "$SPARKLE_PUBLIC_ED_KEY" \
  --remote-artifact-public-ed-key "$REMOTE_ARTIFACT_PUBLIC_ED25519_KEY"
echo "✓ Release metadata synced"
echo ""

echo "📦 Step 2/13: Building macOS app..."
"$SCRIPTS_DIR/swiftpm.sh" build -c release --arch arm64 --arch x86_64
echo "✓ Build complete"
echo ""

# Step 3: Code sign binaries
echo "🔐 Step 3/13: Code signing binaries..."
BUILD_DIR="$MACOS_DIR/.build/apple/Products/Release"
SPACES_APP="$BUILD_DIR/SpacesApp"
SPACES_CLI="$BUILD_DIR/spaces"
SPACESD="$BUILD_DIR/spacesd"

if [[ ! -f "$SPACES_APP" ]] || [[ ! -f "$SPACES_CLI" ]] || [[ ! -f "$SPACESD" ]]; then
  echo "Error: Release binaries not found in $BUILD_DIR" >&2
  exit 1
fi

"$SCRIPTS_DIR/codesign.sh" "$SPACES_APP" "$SPACES_CLI" "$SPACESD"
echo "✓ Code signing complete"
echo ""

echo "🐧 Step 4/13: Building and smoke-testing Ubuntu remote spacesd artifacts..."
rm -rf "$REMOTE_ARTIFACT_DIR"
mkdir -p "$REMOTE_ARTIFACT_DIR"
build_linux_remote_artifact x86_64 linux/amd64
build_linux_remote_artifact arm64 linux/arm64
echo "✓ Ubuntu remote artifacts built"
echo ""

echo "🔎 Step 5/13: Verifying and signing remote artifact manifest..."
verify_remote_artifact "spacesd-ubuntu-24.04-x86_64.tar.gz"
verify_remote_artifact "spacesd-ubuntu-24.04-arm64.tar.gz"
"$SCRIPTS_DIR/create-remote-artifact-manifest.sh" "$VERSION" "$TAG" "$REMOTE_ARTIFACT_DIR"
echo "✓ Remote artifact manifest signed"
echo ""

# Step 6: Build and sign the Spaces.app bundle exactly once. The DMG and the Sparkle zip are
# packaged from this one signed (and, once notarized below, stapled) bundle rather than each
# building and signing its own copy: independently signed copies differ byte for byte (each
# signing pass embeds its own secure timestamp), so only the copy submitted for notarization
# would ever carry a valid ticket (#696).
echo "📦 Step 6/13: Building signed app bundle..."
APP_BUNDLE="$REPO_ROOT/dist/releases/$VERSION/Spaces.app"
"$SCRIPTS_DIR/create-app-bundle.sh" "$SPACES_APP" "$SPACES_CLI" "$SPACESD" "$APP_BUNDLE"
"$SCRIPTS_DIR/codesign-spaces-app.sh" "$APP_BUNDLE"
echo "✓ App bundle built and signed"
echo ""

# Step 7: Notarize the app bundle (optional). Notarizing and stapling the app itself, rather than
# only the DMG, is what lets a stapled ticket travel inside the Sparkle zip: Gatekeeper validates
# a stapled .app offline with no notarization ticket of its own required for the zip container
# (zip carries no notarization concept, unlike DMG/PKG). The DMG still gets its own separate
# submission in Step 10 because it is itself a distinct artifact Gatekeeper evaluates when a user
# downloads and opens the DMG.
if [[ "${NOTARIZE:-}" == "1" ]]; then
  echo "🍎 Step 7/13: Notarizing app bundle..."
  if [[ -z "${APPLE_ID:-}" ]] || [[ -z "${TEAM_ID:-}" ]] || [[ -z "${APP_PASSWORD:-}" ]]; then
    echo "Error: APPLE_ID, TEAM_ID, and APP_PASSWORD are required for notarization" >&2
    exit 1
  fi
  # notarytool only accepts a flat archive, not a directory; this submission zip is a throwaway
  # transport container, not the Sparkle zip Spaces ships (that one is built from the stapled app
  # in Step 9).
  submission_zip="$(mktemp -d)/Spaces-notarize-submission.zip"
  ditto -c -k --keepParent --norsrc "$APP_BUNDLE" "$submission_zip"
  xcrun notarytool submit "$submission_zip" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait
  rm -f "$submission_zip"
  xcrun stapler staple "$APP_BUNDLE"
  echo "✓ App bundle notarized and stapled"
  echo ""
else
  echo "⏭️  Step 7/13: Skipping app bundle notarization (set NOTARIZE=1 to enable)"
  echo ""
fi

# Step 8: Create DMG installer
echo "💿 Step 8/13: Creating DMG installer..."
"$SCRIPTS_DIR/create-dmg.sh" "$APP_BUNDLE" "$VERSION"
DMG_NAME="Spaces-${VERSION}.dmg"
DMG_PATH="$REPO_ROOT/dist/releases/$VERSION/$DMG_NAME"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Error: DMG not created at $DMG_PATH" >&2
  exit 1
fi
echo "✓ DMG created: $DMG_NAME"
echo ""

# Step 9: Create Sparkle archive
echo "📦 Step 9/13: Creating Sparkle archive..."
"$SCRIPTS_DIR/create-sparkle-archive.sh" "$APP_BUNDLE" "$VERSION"
ZIP_NAME="Spaces-${VERSION}.zip"
ZIP_PATH="$REPO_ROOT/dist/releases/$VERSION/$ZIP_NAME"
echo "✓ Sparkle archive created: $ZIP_NAME"
echo ""

# Step 10: Notarize the DMG container itself (optional)
if [[ "${NOTARIZE:-}" == "1" ]]; then
  echo "🍎 Step 10/13: Notarizing DMG..."
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  echo "✓ Notarization complete"
  echo ""
else
  echo "⏭️  Step 10/13: Skipping DMG notarization (set NOTARIZE=1 to enable)"
  echo ""
fi

echo "🔎 Verifying release artifacts..."
verify_args=()
if [[ "${NOTARIZE:-}" == "1" ]]; then
  verify_args+=(--require-notarization)
fi
"$SCRIPTS_DIR/verify-release-artifacts.sh" "${verify_args[@]}" "$DMG_PATH" "$ZIP_PATH"
echo ""

# Step 11: Generate and publish the Sparkle appcast. This must
# happen before the GitHub release is created below: the release upload
# includes the appcast, and the website build (after the release) fetches its
# copy of the appcast and zip back from that same release, so the release has
# to exist and carry both assets first.
echo "🛰️  Step 11/13: Publishing Sparkle appcast..."
"$SCRIPTS_DIR/publish-sparkle-appcast.sh" "$VERSION"
APPCAST_PATH="$REPO_ROOT/dist/updates/appcast.xml"
echo "✓ Sparkle appcast updated"
echo ""

# Step 12: Create the GitHub release
echo "🚀 Step 12/13: Creating GitHub release..."
cd "$REPO_ROOT"
release_assets=(
  "$DMG_PATH"
  "$ZIP_PATH"
  "$APPCAST_PATH"
  "$REMOTE_ARTIFACT_DIR/spacesd-ubuntu-24.04-x86_64.tar.gz"
  "$REMOTE_ARTIFACT_DIR/spacesd-ubuntu-24.04-x86_64.tar.gz.sha256"
  "$REMOTE_ARTIFACT_DIR/spacesd-ubuntu-24.04-arm64.tar.gz"
  "$REMOTE_ARTIFACT_DIR/spacesd-ubuntu-24.04-arm64.tar.gz.sha256"
  "$REMOTE_ARTIFACT_DIR/spaces-remote-artifacts.json"
  "$REMOTE_ARTIFACT_DIR/spaces-remote-artifacts.json.sig"
)
# Created as a prerelease and never marked latest: releases/latest/download (the
# install.sh no-version path and the stable Sparkle feed) keeps pointing at the
# newest promoted release until this one is promoted in the GitHub releases UI.
gh release create "$TAG" "${release_assets[@]}" \
  --title "Spaces $VERSION" \
  --prerelease \
  --generate-notes
echo "✓ GitHub release created"
echo ""

# Step 13: Build website static output. prebuild downloads the appcast and
# Sparkle zip from the GitHub release created above, so this must run after
# that release exists.
echo "🌐 Step 13/13: Building website..."
(
  cd "$REPO_ROOT/apps/web"
  npm run build
)
echo "✓ Website build complete"
echo ""

echo "⏭️  Local script stops after building the website with Sparkle artifacts staged from the GitHub release; deploy apps/web/out to Firebase Hosting separately."
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✨ Release v$VERSION Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📍 URLs:"
echo "  • Release:  $RELEASE_URL"
echo "  • DMG:      $RELEASE_URL"
echo "  • Appcast:  $SPARKLE_FEED_URL"
echo ""
