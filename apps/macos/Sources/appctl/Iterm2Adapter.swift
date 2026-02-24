import Foundation

open class Iterm2Adapter: @unchecked Sendable {
    public init() {}

    open func isAvailable() -> Bool { (try? AppleScript.run("tell application \"iTerm2\" to version")) != nil }

    open func openWindowAndRun(command: String, background: Bool = false) throws -> ItermWindowInfo {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let activateLine = background ? "" : "activate"
        let script = """
            tell application "iTerm2"
              \(activateLine)
              set newWindow to (create window with default profile)
              tell current session of newWindow
                write text "\(escaped)"
              end tell
              -- Newly created iTerm2 windows start with a single tab, so tab index is deterministically 1.
              return (id of newWindow as string) & "|" & (id of current session of newWindow as string) & "|1"
            end tell
            """
        let output = try AppleScript.run(script)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let windowID = Int(parts.first ?? trimmed) ?? -1
        let sessionID = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let tabIndex = parts.count > 2 ? Int(parts[2]) : nil
        return ItermWindowInfo(id: windowID, sessionID: sessionID, tabIndex: tabIndex)
    }

    open func runInWindow(id: Int, command: String) throws {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "iTerm2"
              repeat with w in windows
                if id of w is \(id) then
                  tell current session of w
                    write text "\(escaped)"
                  end tell
                end if
              end repeat
            end tell
            """
        _ = try AppleScript.run(script)
    }

    open func closeWindow(id: Int) throws {
        let script = """
            tell application "iTerm2"
              repeat with w in windows
                if id of w is \(id) then
                  close w
                end if
              end repeat
            end tell
            """
        _ = try AppleScript.run(script)
    }

    open func closeSessionOrTab(preferredSessionID: String?, tabIndex: Int?, windowID: Int?) throws -> Bool {
        let escapedSessionID = (preferredSessionID ?? "").replacingOccurrences(of: "\"", with: "\\\"")
        let targetTabIndex = tabIndex ?? -1
        let targetWindowID = windowID ?? -1
        let script = """
            tell application "iTerm2"
              set targetSessionID to "\(escapedSessionID)"
              set targetTabIndex to \(targetTabIndex)
              set targetWindowID to \(targetWindowID)

              if targetSessionID is not "" then
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if (id of s as string) is targetSessionID then
                        -- Do not select window/tab before close: `tell w to select`
                        -- reorders the window list and invalidates the index-based
                        -- s reference, causing the wrong session to be closed.
                        try
                          close s
                        on error
                          return ""
                        end try
                        return "session"
                      end if
                    end repeat
                  end repeat
                end repeat
                return ""
              end if

              if targetWindowID > 0 then
                repeat with w in windows
                  if id of w is targetWindowID then
                    if targetTabIndex > 0 then
                      set tabCounter to 0
                      repeat with t in tabs of w
                        set tabCounter to tabCounter + 1
                        if tabCounter is targetTabIndex then
                          if (count of tabs of w) > 1 then
                            close t
                            return "tab"
                          end if
                          close w
                          return "window"
                        end if
                      end repeat
                    end if
                    close w
                    return "window"
                  end if
                end repeat
              end if

              return ""
            end tell
            """
        let output = try AppleScript.run(script)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Pulses the background color of the given iTerm2 window to `pulseColor` (0–255 per channel) and back.
    open func pulseBackground(windowID: Int, pulseColor: (r: Int, g: Int, b: Int)) throws {
        // iTerm2 AppleScript uses 16-bit color values (0–65535); convert from 8-bit.
        let r = pulseColor.r * 257
        let g = pulseColor.g * 257
        let b = pulseColor.b * 257
        let script = """
            tell application "iTerm2"
              repeat with w in windows
                if id of w is \(windowID) then
                  tell current session of w
                    set c to background color
                    set background color to {\(r), \(g), \(b)}
                    delay 0.3
                    set background color to c
                  end tell
                  exit repeat
                end if
              end repeat
            end tell
            """
        _ = try? AppleScript.run(script)
    }

    open func listSessionIDs() throws -> Set<String> {
        let script = """
            tell application "iTerm2"
              set sessionIDs to {}
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    set end of sessionIDs to (id of s as string)
                  end repeat
                end repeat
              end repeat
              set AppleScript's text item delimiters to "\n"
              return sessionIDs as string
            end tell
            """
        let output = try AppleScript.run(script)
        let ids = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Set(ids)
    }

    open func focusSessionOrTab(preferredSessionID: String?, tabIndex: Int?, windowID: Int?) throws -> Bool {
        let escapedSessionID = (preferredSessionID ?? "").replacingOccurrences(of: "\"", with: "\\\"")
        let targetTabIndex = tabIndex ?? -1
        let targetWindowID = windowID ?? -1
        let script = """
            tell application "iTerm2"
              set targetSessionID to "\(escapedSessionID)"
              set targetTabIndex to \(targetTabIndex)
              set targetWindowID to \(targetWindowID)

              if targetSessionID is not "" then
                repeat with w in windows
                  repeat with t in tabs of w
                    repeat with s in sessions of t
                      if (id of s as string) is targetSessionID then
                        tell w to select
                        select t
                        tell s to select
                        activate
                        return "session"
                      end if
                    end repeat
                  end repeat
                end repeat
              end if

              if targetWindowID > 0 then
                repeat with w in windows
                  if id of w is targetWindowID then
                    if targetTabIndex > 0 then
                      set tabCounter to 0
                      repeat with t in tabs of w
                        set tabCounter to tabCounter + 1
                        if tabCounter is targetTabIndex then
                          set current window to w
                          select t
                          tell w to select
                          activate
                          return "tab"
                        end if
                      end repeat
                    end if
                    set current window to w
                    tell w to select
                    activate
                    return "window"
                  end if
                end repeat
              end if

              return ""
            end tell
            """
        let output = try AppleScript.run(script)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
