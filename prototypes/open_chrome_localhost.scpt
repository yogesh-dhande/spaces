on run argv
  tell application "Google Chrome"
    activate
    set w to make new window
    set baseTabs to {"http://localhost:3001", "http://localhost:3002", "http://localhost:3003"}
    repeat with u in baseTabs
      tell w to make new tab at end of tabs with properties {URL:u}
    end repeat
    -- optional: close the default new tab if it exists and is blank
  end tell

  -- print resulting tab URLs
  tell application "Google Chrome"
    set out to ""
    repeat with t in tabs of front window
      set out to out & (URL of t) & linefeed
    end repeat
    return out
  end tell
end run
