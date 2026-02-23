import Foundation

open class Iterm2Adapter {
    public init() {}

    open func isAvailable() -> Bool { (try? AppleScript.run("tell application \"iTerm2\" to version")) != nil }

    open func openWindowAndRun(command: String) throws -> ItermWindowInfo {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "iTerm2"
              activate
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

    open func closeWindowIfSingleton(id: Int) throws -> Bool {
        let script = """
            tell application "iTerm2"
              repeat with w in windows
                if id of w is \(id) then
                  if (count of tabs of w) is not 1 then return ""
                  set onlyTab to item 1 of tabs of w
                  if (count of sessions of onlyTab) is not 1 then return ""
                  close w
                  return "window"
                end if
              end repeat
              return ""
            end tell
            """
        let output = try AppleScript.run(script)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        tell w to select
                        select t
                        set closeFailed to false
                        try
                          close s
                        on error
                          set closeFailed to true
                        end try
                        repeat with w2 in windows
                          repeat with t2 in tabs of w2
                            repeat with s2 in sessions of t2
                              if (id of s2 as string) is targetSessionID then
                                return ""
                              end if
                            end repeat
                          end repeat
                        end repeat
                        if closeFailed then
                          return ""
                        end if
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
