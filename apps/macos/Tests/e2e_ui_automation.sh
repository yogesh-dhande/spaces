#!/usr/bin/env bash
# Accessibility automation shared by the macOS app E2E lanes: driving the running Spaces app
# through System Events by the stable AXIdentifiers the app publishes, rather than by label or
# position. Sourced by apps/macos/Tests/e2e_macos_app.sh and by the mac-reconnect scenario in
# apps/macos/Tests/e2e_mobile_baseline.sh.
#
# The sourcing script owns the state these functions read:
#   SPACES_PID                  pid of the Spaces app instance to drive
#   ACTION_TIMEOUT_SECONDS      how long every wait_* helper polls before failing
#   AX_PROBE_TIMEOUT_SECONDS    per-osascript probe timeout for frontmost_pid
#   fail()                      prints the message and exits non-zero

activate_spaces_pid() {
  local pid="${1:-$SPACES_PID}"
  [[ -n "$pid" ]] || fail "missing Spaces pid for activation"
  osascript - "$pid" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      set frontmost of proc to true
      try
        if (count of windows of proc) > 0 then
          perform action "AXRaise" of window 1 of proc
        end if
      end try
      return
    end repeat
  end tell
end run
APPLESCRIPT
}
wait_for_spaces_frontmost_ready() {
  # Most GUI actions in this script assume a single visible Spaces window and an
  # active accessibility tree, so block until that state exists and Spaces is
  # actually frontmost. The later UI automation queries `process "SpacesApp"`
  # because the internal executable name differs from the user-facing app name.
  # The strict single-instance checks above are what keep System Events from
  # drifting onto the user's regular app instance here.
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$SPACES_PID" >/dev/null 2>&1; then
      fail "Spaces exited during launch"
    fi
    activate_spaces_pid "$SPACES_PID"
    if [[ "$(frontmost_pid 2>/dev/null || true)" == "$SPACES_PID" ]] && osascript - "$SPACES_PID" <<'APPLESCRIPT' 2>/dev/null | grep -Eiq '^(1|true)$'; then
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      return (count of windows of proc) > 0
    end repeat
  end tell
  return false
end run
APPLESCRIPT
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for Spaces window"
}
ui_click_identifier() {
  # The GUI identifiers added for this suite keep the AppleScript automation
  # resilient when labels or ordering change.
  local identifier="$1"
  osascript - "$SPACES_PID" "$identifier" <<'APPLESCRIPT'
on elementMatchesIdentifier(targetElement, targetID)
  tell application "System Events"
    try
      if ((value of attribute "AXIdentifier" of targetElement) as text) is targetID then return true
    end try
    try
      if ((value of attribute "AXDOMIdentifier" of targetElement) as text) is targetID then return true
    end try
  end tell
  return false
end elementMatchesIdentifier

on clickMatchingIdentifier(targetElement, targetID)
  if my elementMatchesIdentifier(targetElement, targetID) then
    tell application "System Events"
      try
        perform action "AXPress" of targetElement
      on error
        click targetElement
      end try
    end tell
    return true
  end if
  tell application "System Events"
    try
      repeat with childElement in UI elements of targetElement
        if my clickMatchingIdentifier(childElement, targetID) then return true
      end repeat
    end try
    try
      repeat with childElement in rows of targetElement
        if my clickMatchingIdentifier(childElement, targetID) then return true
      end repeat
    end try
  end tell
  return false
end clickMatchingIdentifier

on run argv
  set targetPID to (item 1 of argv) as integer
  set targetID to item 2 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        if my clickMatchingIdentifier(targetWindow, targetID) then return
      end repeat
    end repeat
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}
wait_and_click_ui_identifier() {
  local identifier="$1" description="$2"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  # Search and press in the same accessibility traversal. A separate wait followed by a second
  # traversal can lose the node while a large streamed CodeView subtree is being attached.
  while (( SECONDS < deadline )); do
    if ui_click_identifier "$identifier" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting to click UI identifier: $description ($identifier)"
}
ui_identifier_exists() {
  local identifier="$1"
  osascript - "$SPACES_PID" "$identifier" <<'APPLESCRIPT' >/dev/null 2>/dev/null
on elementMatchesIdentifier(targetElement, targetID)
  tell application "System Events"
    try
      if ((value of attribute "AXIdentifier" of targetElement) as text) is targetID then return true
    end try
    try
      if ((value of attribute "AXDOMIdentifier" of targetElement) as text) is targetID then return true
    end try
  end tell
  return false
end elementMatchesIdentifier

on identifierExistsInElement(targetElement, targetID)
  if my elementMatchesIdentifier(targetElement, targetID) then return true
  tell application "System Events"
    try
      repeat with childElement in UI elements of targetElement
        if my identifierExistsInElement(childElement, targetID) then return true
      end repeat
    end try
    try
      repeat with childElement in rows of targetElement
        if my identifierExistsInElement(childElement, targetID) then return true
      end repeat
    end try
  end tell
  return false
end identifierExistsInElement

on run argv
  set targetPID to (item 1 of argv) as integer
  set targetID to item 2 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        if my identifierExistsInElement(targetWindow, targetID) then return "1"
      end repeat
    end repeat
  end tell
  error "identifier not found: " & targetID
end run
APPLESCRIPT
}
wait_for_ui_identifier() {
  local identifier="$1"
  local description="${2:-$identifier}"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ui_identifier_exists "$identifier"; then
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for UI identifier: $description ($identifier)"
}
# Echoes the first AXIdentifier under the app's windows whose value starts with the given
# prefix (empty when none). Resolves a sidebar runtime-target row whose id embeds a runtime
# value — a browser session's row is sidebar-target-<workspaceID>-browser:<resolved
# service-substituted URL> — without hard-coding that resolved URL.
find_ui_identifier_with_prefix() {
  local prefix="$1"
  osascript - "$SPACES_PID" "$prefix" <<'APPLESCRIPT'
on firstMatchingIdentifier(targetElement, targetPrefix)
  tell application "System Events"
    try
      set idVal to (value of attribute "AXIdentifier" of targetElement) as text
      if idVal starts with targetPrefix then return idVal
    end try
    try
      set idVal to (value of attribute "AXDOMIdentifier" of targetElement) as text
      if idVal starts with targetPrefix then return idVal
    end try
    try
      repeat with childElement in UI elements of targetElement
        set foundID to my firstMatchingIdentifier(childElement, targetPrefix)
        if foundID is not "" then return foundID
      end repeat
    end try
    try
      repeat with childElement in rows of targetElement
        set foundID to my firstMatchingIdentifier(childElement, targetPrefix)
        if foundID is not "" then return foundID
      end repeat
    end try
  end tell
  return ""
end firstMatchingIdentifier

on run argv
  set targetPID to (item 1 of argv) as integer
  set targetPrefix to item 2 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        set foundID to my firstMatchingIdentifier(targetWindow, targetPrefix)
        if foundID is not "" then return foundID
      end repeat
    end repeat
  end tell
  return ""
end run
APPLESCRIPT
}
# Polls until a UI identifier with the given prefix appears, echoing the full identifier.
wait_for_ui_identifier_with_prefix() {
  local prefix="$1"
  local description="${2:-$prefix}"
  local deadline=$((SECONDS + ACTION_TIMEOUT_SECONDS))
  local found=""
  while (( SECONDS < deadline )); do
    found="$(find_ui_identifier_with_prefix "$prefix")"
    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return 0
    fi
    sleep 0.2
  done
  fail "timed out waiting for UI identifier with prefix: $description ($prefix)"
}
ui_select_outline_row_containing_identifier() {
  local identifier="$1"
  osascript - "$SPACES_PID" "$identifier" <<'APPLESCRIPT'
on elementMatchesIdentifier(targetElement, targetID)
  tell application "System Events"
    try
      if ((value of attribute "AXIdentifier" of targetElement) as text) is targetID then return true
    end try
    try
      if ((value of attribute "AXDOMIdentifier" of targetElement) as text) is targetID then return true
    end try
  end tell
  return false
end elementMatchesIdentifier

on identifierExistsInElement(targetElement, targetID)
  if my elementMatchesIdentifier(targetElement, targetID) then return true
  tell application "System Events"
    try
      repeat with childElement in UI elements of targetElement
        if my identifierExistsInElement(childElement, targetID) then return true
      end repeat
    end try
    try
      repeat with childElement in rows of targetElement
        if my identifierExistsInElement(childElement, targetID) then return true
      end repeat
    end try
  end tell
  return false
end identifierExistsInElement

on run argv
  set targetPID to (item 1 of argv) as integer
  set targetID to item 2 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        try
          set sidebarOutline to outline 1 of scroll area 1 of splitter group 1 of targetWindow
          set rowIndex to 1
          repeat with targetRow in rows of sidebarOutline
            if my identifierExistsInElement(targetRow, targetID) then
              select row rowIndex of sidebarOutline
              return
            end if
            set rowIndex to rowIndex + 1
          end repeat
        end try
      end repeat
    end repeat
  end tell
  error "outline row containing identifier not found: " & targetID
end run
APPLESCRIPT
}
frontmost_pid() {
  python3 - "$AX_PROBE_TIMEOUT_SECONDS" <<'PY'
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
script = r'''
tell application "System Events"
  try
    return unix id of first process whose frontmost is true
  on error
    return ""
  end try
end tell
'''
try:
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired:
    sys.exit(0)
if result.returncode == 0:
    sys.stdout.write(result.stdout)
PY
}

# Selects the outline row carrying `identifier` that belongs to the sidebar device section whose
# header reads `section_title`, ignoring rows above that header. The sidebar publishes the same
# `sidebar-workspace-title-<id>` and `sidebar-target-<id>-...` identifiers for every device showing a
# given workspace, and a lane that points a paired device at the local daemon sees both copies, so
# the section header (the device name, uppercased) is what tells them apart.
ui_select_outline_row_containing_identifier_in_section() {
  local section_title="$1"
  local identifier="$2"
  osascript - "$SPACES_PID" "$section_title" "$identifier" <<'APPLESCRIPT'
on elementMatchesIdentifier(targetElement, targetID)
  tell application "System Events"
    try
      if ((value of attribute "AXIdentifier" of targetElement) as text) is targetID then return true
    end try
    try
      if ((value of attribute "AXDOMIdentifier" of targetElement) as text) is targetID then return true
    end try
  end tell
  return false
end elementMatchesIdentifier

on identifierExistsInElement(targetElement, targetID)
  if my elementMatchesIdentifier(targetElement, targetID) then return true
  tell application "System Events"
    try
      repeat with childElement in UI elements of targetElement
        if my identifierExistsInElement(childElement, targetID) then return true
      end repeat
    end try
    try
      repeat with childElement in rows of targetElement
        if my identifierExistsInElement(childElement, targetID) then return true
      end repeat
    end try
  end tell
  return false
end identifierExistsInElement

on elementContainsText(targetElement, targetText)
  tell application "System Events"
    try
      if ((value of attribute "AXValue" of targetElement) as text) is targetText then return true
    end try
    try
      if ((name of targetElement) as text) is targetText then return true
    end try
    try
      repeat with childElement in UI elements of targetElement
        if my elementContainsText(childElement, targetText) then return true
      end repeat
    end try
  end tell
  return false
end elementContainsText

on run argv
  set targetPID to (item 1 of argv) as integer
  set sectionTitle to item 2 of argv
  set targetID to item 3 of argv
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        try
          set sidebarOutline to outline 1 of scroll area 1 of splitter group 1 of targetWindow
          set rowIndex to 1
          set inSection to false
          repeat with targetRow in rows of sidebarOutline
            if inSection then
              if my identifierExistsInElement(targetRow, targetID) then
                select row rowIndex of sidebarOutline
                return
              end if
            else if my elementContainsText(targetRow, sectionTitle) then
              set inSection to true
            end if
            set rowIndex to rowIndex + 1
          end repeat
        end try
      end repeat
    end repeat
  end tell
  error "outline row containing identifier not found in section: " & sectionTitle & " / " & targetID
end run
APPLESCRIPT
}

# Grows the app's first window to fill the screen, which AppKit clamps to the screen's visible
# height. NSOutlineView only materializes row views for the visible area, so a sidebar row below the
# fold is not an accessibility element at all: with the default window height only a handful of rows
# exist to be found, and a device section further down the list looks empty rather than unread.
ui_fill_screen_with_main_window() {
  osascript - "$SPACES_PID" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    repeat with proc in every process whose unix id is targetPID
      repeat with targetWindow in windows of proc
        try
          set position of targetWindow to {0, 25}
          set size of targetWindow to {1200, 2000}
        end try
      end repeat
    end repeat
  end tell
end run
APPLESCRIPT
}
