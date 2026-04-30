#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: $0 <Spaces-app-path> <spaces-cli-path> <version>"
  exit 1
fi

SPACES_APP="$1"
SPACES_CLI="$2"
VERSION="$3"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$REPO_ROOT/dist/releases/$VERSION"
DMG_NAME="Spaces-${VERSION}.dmg"
DMG_PATH="$RELEASES_DIR/$DMG_NAME"
VOLUME_NAME="Spaces-${VERSION}"

# Create releases directory if it doesn't exist
mkdir -p "$RELEASES_DIR"

# Create temporary directory for DMG contents
staging=$(mktemp -d)
temp_dmg=""
trap 'rm -rf "$staging"; [ -n "$temp_dmg" ] && rm -f "$temp_dmg"' EXIT

# Create app bundle structure
app_bundle="$staging/Spaces.app"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"

# Copy Spaces binary
cp "$SPACES_APP" "$app_bundle/Contents/MacOS/SpacesApp"
chmod +x "$app_bundle/Contents/MacOS/SpacesApp"

# Copy Info.plist
cp apps/macos/Sources/SpacesApp/Info.plist "$app_bundle/Contents/Info.plist"

# Copy app icon
cp apps/macos/Sources/SpacesApp/AppIcon.icns "$app_bundle/Contents/Resources/AppIcon.icns"

# Create CLI installer package
cli_installer="$staging/Install spaces CLI"
cat > "$cli_installer" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Determine installation directory
if [ -w /usr/local/bin ]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

# Copy spaces CLI
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/Spaces.app/Contents/Resources/spaces" "$INSTALL_DIR/spaces"
chmod +x "$INSTALL_DIR/spaces"

echo "✓ spaces CLI installed to $INSTALL_DIR/spaces"

# Check if directory is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo ""
  echo "⚠️  $INSTALL_DIR is not in your PATH"
  echo "Add this line to your shell profile (~/.zshrc or ~/.bash_profile):"
  echo ""
  echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
  echo ""
fi

# Keep terminal open to show message
read -p "Press Enter to close..."
EOF
chmod +x "$cli_installer"

# Copy spaces CLI to Resources
mkdir -p "$app_bundle/Contents/Resources"
cp "$SPACES_CLI" "$app_bundle/Contents/Resources/spaces"

# Sign the complete app bundle (required for notarization)
IDENTITY="${CODESIGN_IDENTITY:--}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"
echo "Signing app bundle with identity: $IDENTITY"
codesign --force --deep --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$app_bundle"

# Verify signature
codesign --verify --verbose=2 "$app_bundle"
echo "✓ App bundle signature verified"

# Staple notarization ticket (if notarized)
# This embeds the ticket so the app can be verified offline
if xcrun stapler staple "$app_bundle" 2>/dev/null; then
  echo "✓ Notarization ticket stapled"
  xcrun stapler validate "$app_bundle"
else
  echo "⚠️  No notarization ticket found (app not notarized or stapling failed)"
fi

# Create symlink to Applications
ln -s /Applications "$staging/Applications"

# Create compressed DMG directly (skip window customization to avoid AppleScript issues)
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$staging" -ov -format UDZO "$DMG_PATH"

echo "✓ Created $DMG_PATH"
