#!/usr/bin/env bash
set -euo pipefail

if ! command -v yabai >/dev/null 2>&1; then
  echo "error: yabai is not installed" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if ! command -v osascript >/dev/null 2>&1; then
  echo "error: osascript is not available" >&2
  exit 1
fi

osascript <<'APPLESCRIPT'
tell application "Google Chrome"
  if not running then error "Google Chrome is not running."
  activate
  set originalWindowIDs to id of every window
end tell

delay 0.3

repeat with wid in originalWindowIDs
  repeat
    tell application "Google Chrome"
      if not (exists window id wid) then exit repeat

      set index of window id wid to 1
      activate
      delay 0.1

      set tabCount to count of tabs of window id wid
      if tabCount ≤ 1 then exit repeat

      set active tab index of window id wid to 2
    end tell

    delay 0.15

    tell application "System Events"
      tell process "Google Chrome"
        click menu item "Move Tab to New Window" of menu 1 of menu bar item "Tab" of menu bar 1
      end tell
    end tell

    delay 0.35
  end repeat
end repeat
APPLESCRIPT

sleep 0.8

tmp_file="$(mktemp)"

osascript <<'APPLESCRIPT' > "$tmp_file"
tell application "Google Chrome"
  repeat with w in every window
    set wid to id of w
    set u to ""
    try
      set u to URL of active tab of w
      if u is missing value then set u to ""
    on error
      set u to ""
    end try
    do shell script "printf '%s\t%s\n' " & quoted form of (wid as text) & " " & quoted form of (u as text)
  end repeat
end tell
APPLESCRIPT

while IFS=$'\t' read -r chrome_wid url; do
  [[ -z "${chrome_wid:-}" ]] && continue

  yabai_id="$(
    yabai -m query --windows |
      jq -r --argjson wid "$chrome_wid" '
        .[]
        | select(.app == "Google Chrome" and ."native-window-id" == $wid)
        | .id
      ' | head -n1
  )"

  if [[ -n "${yabai_id:-}" ]]; then
    printf '%s\t%s\t%s\n' "$yabai_id" "$chrome_wid" "$url"
  fi
done < "$tmp_file"

rm -f "$tmp_file"