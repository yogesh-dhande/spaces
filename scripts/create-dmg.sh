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

app_bundle="$staging/Spaces.app"
"$REPO_ROOT/scripts/create-app-bundle.sh" "$SPACES_APP" "$SPACES_CLI" "$app_bundle"

# Create installer helper script used by the DMG wizard app.
installer_script="$staging/.install-spaces.sh"
cat > "$installer_script" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <system|user> <dmg-root>" >&2
  exit 1
fi

MODE="$1"
DMG_ROOT="$2"
SOURCE_APP="$DMG_ROOT/Spaces.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing app bundle at $SOURCE_APP" >&2
  exit 1
fi

emit_result() {
  printf 'APP_PATH=%s\n' "$1"
  printf 'CLI_PATH=%s\n' "$2"
  printf 'PATH_HINT=%s\n' "${3:-}"
}

case "$MODE" in
  system)
    APP_PATH="/Applications/Spaces.app"
    CLI_PATH="/usr/local/bin/spaces"
    /bin/mkdir -p /Applications /usr/local/bin
    /bin/rm -rf "$APP_PATH"
    /usr/bin/ditto "$SOURCE_APP" "$APP_PATH"
    /bin/cp "$APP_PATH/Contents/Resources/spaces" "$CLI_PATH"
    /bin/chmod 755 "$CLI_PATH"
    emit_result "$APP_PATH" "$CLI_PATH"
    ;;
  user)
    APP_DIR="$HOME/Applications"
    CLI_DIR="$HOME/.local/bin"
    APP_PATH="$APP_DIR/Spaces.app"
    CLI_PATH="$CLI_DIR/spaces"
    PATH_HINT=""
    /bin/mkdir -p "$APP_DIR" "$CLI_DIR"
    /bin/rm -rf "$APP_PATH"
    /usr/bin/ditto "$SOURCE_APP" "$APP_PATH"
    /bin/cp "$APP_PATH/Contents/Resources/spaces" "$CLI_PATH"
    /bin/chmod 755 "$CLI_PATH"
    if [[ ":$PATH:" != *":$CLI_DIR:"* ]]; then
      PATH_HINT='export PATH="$PATH:$HOME/.local/bin"'
    fi
    emit_result "$APP_PATH" "$CLI_PATH" "$PATH_HINT"
    ;;
  *)
    echo "Unsupported install mode: $MODE" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$installer_script"

# Create a single visible installer app so the DMG behaves like a guided wizard.
installer_source="$staging/install-spaces.applescript"
cat > "$installer_source" << 'EOF'
on parseInstallResult(shellOutput)
    set appPath to ""
    set cliPath to ""
    set pathHint to ""
    repeat with outputLine in paragraphs of shellOutput
        set currentLine to contents of outputLine
        if currentLine starts with "APP_PATH=" then
            set appPath to text 10 thru -1 of currentLine
        else if currentLine starts with "CLI_PATH=" then
            set cliPath to text 10 thru -1 of currentLine
        else if currentLine starts with "PATH_HINT=" then
            if (length of currentLine) > 10 then
                set pathHint to text 11 thru -1 of currentLine
            end if
        end if
    end repeat
    return {appPath, cliPath, pathHint}
end parseInstallResult

on installerRootPOSIX()
    set installerAppPath to POSIX path of (path to me)
    return do shell script "/usr/bin/dirname " & quoted form of installerAppPath
end installerRootPOSIX

on run
    set dmgRoot to installerRootPOSIX()
    set helperScript to quoted form of (dmgRoot & "/.install-spaces.sh")

    try
        display dialog "Spaces installs the app and the required spaces CLI together. Continue to install both now?" buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel" with icon note
    on error number -128
        return
    end try

    try
        set installOutput to do shell script helperScript & " system " & quoted form of dmgRoot with administrator privileges
    on error errMsg number errNum
        if errNum is -128 then
            try
                display dialog "Administrator access was cancelled. Install Spaces for just this user instead? The app will go in ~/Applications and the CLI in ~/.local/bin." buttons {"Cancel", "Install for This User"} default button "Install for This User" cancel button "Cancel" with icon caution
            on error number -128
                return
            end try
            try
                set installOutput to do shell script helperScript & " user " & quoted form of dmgRoot
            on error fallbackMessage number fallbackNumber
                display dialog "Spaces could not finish installation.\n\n" & fallbackMessage buttons {"OK"} default button "OK" with icon stop
                return
            end try
        else
            display dialog "Spaces could not finish installation.\n\n" & errMsg buttons {"OK"} default button "OK" with icon stop
            return
        end if
    end try

    set {appPath, cliPath, pathHint} to parseInstallResult(installOutput)
    set successText to "Spaces installed successfully.\n\nApp: " & appPath & "\nCLI: " & cliPath
    if pathHint is not "" then
        set successText to successText & "\n\nAdd this to your shell profile if the command is not found:\n" & pathHint
    end if

    set actionButton to button returned of (display dialog successText buttons {"Close", "Open Spaces"} default button "Open Spaces" with icon note)
    if actionButton is "Open Spaces" then
        do shell script "/usr/bin/open " & quoted form of appPath
    end if
end run
EOF

installer_app="$staging/Install Spaces.app"
osacompile -o "$installer_app" "$installer_source" >/dev/null
cp "$REPO_ROOT/apps/macos/Sources/SpacesApp/AppIcon.icns" "$installer_app/Contents/Resources/applet.icns"
rm -f "$installer_source"

# Sign the complete app bundle (required for notarization)
IDENTITY="${CODESIGN_IDENTITY:--}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"
echo "Signing app bundle with identity: $IDENTITY"
codesign --force --deep --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$app_bundle"

# Verify signature
codesign --verify --verbose=2 "$app_bundle"
echo "✓ App bundle signature verified"

codesign --force --deep --timestamp --options runtime --sign "$IDENTITY" "$installer_app"
codesign --verify --verbose=2 "$installer_app"
echo "✓ Installer app signature verified"

# Staple notarization ticket (if notarized)
# This embeds the ticket so the app can be verified offline
if xcrun stapler staple "$app_bundle" 2>/dev/null; then
  echo "✓ Notarization ticket stapled"
  xcrun stapler validate "$app_bundle"
else
  echo "⚠️  No notarization ticket found (app not notarized or stapling failed)"
fi

# Only the wizard app should be visible in Finder. The source app bundle stays hidden
# in the mounted DMG and is copied by the installer.
SetFile -a V "$app_bundle"

# Create compressed DMG directly (skip window customization to avoid AppleScript issues)
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$staging" -ov -format UDZO "$DMG_PATH"

echo "✓ Created $DMG_PATH"
