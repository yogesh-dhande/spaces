#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 4 ]; then
  echo "Usage: $0 <Spaces-app-path> <spaces-cli-path> <spacesd-path> <version>"
  exit 1
fi

SPACES_APP="$1"
SPACES_CLI="$2"
SPACESD="$3"
VERSION="$4"
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
"$REPO_ROOT/scripts/create-app-bundle.sh" "$SPACES_APP" "$SPACES_CLI" "$SPACESD" "$app_bundle"

# Create installer helper script used by the DMG wizard app.
installer_script="$staging/.install-spaces.sh"
cat > "$installer_script" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: $0 <dmg-root> <user-home> <user-uid>" >&2
  exit 1
fi

DMG_ROOT="$1"
INSTALL_HOME="$2"
INSTALL_UID="$3"
SOURCE_APP="$DMG_ROOT/Spaces.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing app bundle at $SOURCE_APP" >&2
  exit 1
fi

emit_result() {
  printf 'APP_PATH=%s\n' "$1"
  printf 'CLI_PATH=%s\n' "$2"
  printf 'SERVICE_PATH=%s\n' "$3"
  printf 'LAUNCH_AGENT_PATH=%s\n' "$4"
}

copy_ghostty_vt_dylibs() {
  local copied=0
  local source_dylib
  for source_dylib in "$APP_PATH"/Contents/Frameworks/libghostty-vt*.dylib; do
    [[ -e "$source_dylib" || -L "$source_dylib" ]] || continue
    /bin/cp -P "$source_dylib" "$CLI_DIR/"
    copied=1
  done

  if [[ "$copied" -eq 0 ]]; then
    echo "Missing libghostty-vt dylibs in $APP_PATH/Contents/Frameworks" >&2
    exit 1
  fi

  local installed_dylib
  for installed_dylib in "$CLI_DIR"/libghostty-vt*.dylib; do
    [[ -e "$installed_dylib" || -L "$installed_dylib" ]] || continue
    /bin/chmod 755 "$installed_dylib" 2>/dev/null || true
    /usr/bin/xattr -d com.apple.quarantine "$installed_dylib" 2>/dev/null || true
  done
}

install_user_state_paths() {
  local user_home="$1"
  local state_root="$user_home/.spaces"
  local data_root="$user_home/spaces"
  local bin_dir="$state_root/bin"
  local runtime_dir="$state_root/runtime"
  local workspaces_dir="$data_root/workspaces"
  local repos_dir="$data_root/repos"
  local install_user
  install_user="$(/usr/bin/stat -f %Su "$user_home" 2>/dev/null || true)"

  /bin/mkdir -p "$bin_dir" "$runtime_dir" "$workspaces_dir" "$repos_dir"
  /bin/ln -sfn "$CLI_PATH" "$bin_dir/spaces"
  /bin/ln -sfn "$SERVICE_PATH" "$bin_dir/spacesd"

  if [[ -n "$install_user" ]]; then
    /usr/sbin/chown "$install_user" "$state_root" "$data_root" "$bin_dir" "$runtime_dir" "$workspaces_dir" "$repos_dir" 2>/dev/null || true
    /usr/sbin/chown -h "$install_user" "$bin_dir/spaces" "$bin_dir/spacesd" 2>/dev/null || true
  fi
}

install_launch_agent() {
  local daemon_path="$1"
  local user_home="$2"
  local user_uid="$3"
  local plist_dir="$user_home/Library/LaunchAgents"
  local plist_path="$plist_dir/dev.usespaces.spacesd.plist"
  local runtime_dir="$user_home/.spaces/runtime"
  local install_user
  install_user="$(/usr/bin/stat -f %Su "$user_home" 2>/dev/null || true)"

  /bin/mkdir -p "$plist_dir" "$runtime_dir"
  /bin/cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.usespaces.spacesd</string>
  <key>ProgramArguments</key>
  <array>
    <string>$daemon_path</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>$user_home</string>
  <key>StandardOutPath</key>
  <string>$runtime_dir/spacesd.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$runtime_dir/spacesd.launchd.err.log</string>
</dict>
</plist>
PLIST

  /bin/chmod 644 "$plist_path"
  if [[ -n "$install_user" ]]; then
    /usr/sbin/chown "$install_user" "$plist_path" "$plist_dir" "$runtime_dir" 2>/dev/null || true
  fi

  /bin/launchctl bootout "gui/$user_uid" "$plist_path" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "gui/$user_uid" "$plist_path"
  /bin/launchctl kickstart -k "gui/$user_uid/dev.usespaces.spacesd"
  printf '%s\n' "$plist_path"
}

APP_PATH="/Applications/Spaces.app"
CLI_DIR="/usr/local/bin"
CLI_PATH="$CLI_DIR/spaces"
SERVICE_PATH="$CLI_DIR/spacesd"
/bin/mkdir -p /Applications /usr/local/bin
/bin/rm -rf "$APP_PATH"
/usr/bin/ditto "$SOURCE_APP" "$APP_PATH"
/usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
/bin/cp "$APP_PATH/Contents/Resources/spaces" "$CLI_PATH"
/bin/cp "$APP_PATH/Contents/Resources/spacesd" "$SERVICE_PATH"
/bin/chmod 755 "$CLI_PATH"
/bin/chmod 755 "$SERVICE_PATH"
copy_ghostty_vt_dylibs
/usr/bin/xattr -d com.apple.quarantine "$CLI_PATH" 2>/dev/null || true
/usr/bin/xattr -d com.apple.quarantine "$SERVICE_PATH" 2>/dev/null || true
install_user_state_paths "$INSTALL_HOME"
LAUNCH_AGENT_PATH="$(install_launch_agent "$SERVICE_PATH" "$INSTALL_HOME" "$INSTALL_UID")"
emit_result "$APP_PATH" "$CLI_PATH" "$SERVICE_PATH" "$LAUNCH_AGENT_PATH"
EOF
chmod +x "$installer_script"

# Create a single visible installer app so the DMG behaves like a guided wizard.
installer_source="$staging/install-spaces.applescript"
cat > "$installer_source" << 'EOF'
on parseInstallResult(shellOutput)
    set appPath to ""
    set cliPath to ""
    set servicePath to ""
    set launchAgentPath to ""
    repeat with outputLine in paragraphs of shellOutput
        set currentLine to contents of outputLine
        if currentLine starts with "APP_PATH=" then
            set appPath to text 10 thru -1 of currentLine
        else if currentLine starts with "CLI_PATH=" then
            set cliPath to text 10 thru -1 of currentLine
        else if currentLine starts with "SERVICE_PATH=" then
            set servicePath to text 14 thru -1 of currentLine
        else if currentLine starts with "LAUNCH_AGENT_PATH=" then
            if (length of currentLine) > 18 then
                set launchAgentPath to text 19 thru -1 of currentLine
            end if
        end if
    end repeat
    return {appPath, cliPath, servicePath, launchAgentPath}
end parseInstallResult

on installerRootPOSIX()
    set installerAppPath to POSIX path of (path to me)
    return do shell script "/usr/bin/dirname " & quoted form of installerAppPath
end installerRootPOSIX

on run
    set dmgRoot to installerRootPOSIX()
    set helperScript to quoted form of (dmgRoot & "/.install-spaces.sh")
    set userHome to POSIX path of (path to home folder)
    set userUID to do shell script "/usr/bin/id -u"

    try
        display dialog "Spaces installs the app, the required spaces CLI, and the spacesd daemon together. Continue to install them now?" buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel" with icon note
    on error number -128
        return
    end try

    try
        set installOutput to do shell script helperScript & " " & quoted form of dmgRoot & " " & quoted form of userHome & " " & quoted form of userUID with administrator privileges
    on error errMsg number errNum
        if errNum is not -128 then
            display dialog "Spaces could not finish installation.\n\n" & errMsg buttons {"OK"} default button "OK" with icon stop
        end if
        return
    end try

    set {appPath, cliPath, servicePath, launchAgentPath} to parseInstallResult(installOutput)
    set successText to "Spaces installed successfully.\n\nApp: " & appPath & "\nCLI: " & cliPath & "\nspacesd daemon: " & servicePath & "\nLaunchAgent: " & launchAgentPath

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

# Only the wizard app should be visible in Finder. The source app bundle stays hidden
# in the mounted DMG and is copied by the installer.
SetFile -a V "$app_bundle"

# Create compressed DMG directly (skip window customization to avoid AppleScript issues)
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$staging" -ov -format UDZO "$DMG_PATH"

echo "Signing DMG with identity: $IDENTITY"
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
echo "✓ DMG signature verified"

echo "✓ Created $DMG_PATH"
