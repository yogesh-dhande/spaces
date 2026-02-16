#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: $0 <Muxy-app-path> <mx-cli-path> <version>"
  exit 1
fi

MUXY_APP="$1"
MX_CLI="$2"
VERSION="$3"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$REPO_ROOT/releases"
DMG_NAME="Muxy-${VERSION}.dmg"
DMG_PATH="$RELEASES_DIR/$DMG_NAME"
VOLUME_NAME="Muxy-${VERSION}"

# Create releases directory if it doesn't exist
mkdir -p "$RELEASES_DIR"

# Create temporary directory for DMG contents
staging=$(mktemp -d)
temp_dmg=""
trap 'rm -rf "$staging"; [ -n "$temp_dmg" ] && rm -f "$temp_dmg"' EXIT

# Create app bundle structure
app_bundle="$staging/Muxy.app"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"

# Copy Muxy binary
cp "$MUXY_APP" "$app_bundle/Contents/MacOS/Muxy"
chmod +x "$app_bundle/Contents/MacOS/Muxy"

# Copy Info.plist
cp apps/macos/Sources/Muxy/Info.plist "$app_bundle/Contents/Info.plist"

# Create CLI installer package
cli_installer="$staging/Install mx CLI"
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

# Copy mx CLI
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/../Resources/mx" "$INSTALL_DIR/mx"
chmod +x "$INSTALL_DIR/mx"

echo "✓ mx CLI installed to $INSTALL_DIR/mx"

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

# Copy mx CLI to Resources
mkdir -p "$app_bundle/Contents/Resources"
cp "$MX_CLI" "$app_bundle/Contents/Resources/mx"

# Create symlink to Applications
ln -s /Applications "$staging/Applications"

# Create compressed DMG directly (skip window customization to avoid AppleScript issues)
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$staging" -ov -format UDZO "$DMG_PATH"

echo "✓ Created $DMG_PATH"
