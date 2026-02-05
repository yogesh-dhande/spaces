import Foundation

public final class TerminalAdapter {
    public init() {}

    @discardableResult
    public func openWindow(worktreePath: String, command: String?, title: String) throws -> Int? {
        let escapedWorktree = shellEscaped(worktreePath)
        let line: String
        if let command, !command.isEmpty {
            line = "cd \"\(escapedWorktree)\"; \(command)"
        } else {
            line = "cd \"\(escapedWorktree)\""
        }

        let escapedLine = appleScriptEscaped(line)
        let escapedTitle = appleScriptEscaped(title)

        let script = """
        tell application "Terminal"
          activate
          do script "\(escapedLine)"
          delay 0.1
          set targetWindow to front window
          try
            set custom title of selected tab of targetWindow to "\(escapedTitle)"
          end try
          try
            return (id of targetWindow as string)
          end try
          return ""
        end tell
        """

        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output)
    }

    @discardableResult
    public func focusWindows(prefix: String) throws -> Int {
        let escapedPrefix = appleScriptEscaped(prefix)
        let script = """
        set titlePrefix to "\(escapedPrefix)"
        tell application "Terminal"
          activate
          set hitCount to 0
          repeat with w in windows
            set thisTitle to ""
            try
              set thisTitle to custom title of selected tab of w
            end try
            if thisTitle starts with titlePrefix then
              set index of w to 1
              set hitCount to hitCount + 1
            end if
          end repeat
          return (hitCount as string)
        end tell
        """

        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 0
    }

    @discardableResult
    public func closeWindows(prefix: String) throws -> Int {
        let escapedPrefix = appleScriptEscaped(prefix)
        let script = """
        set titlePrefix to "\(escapedPrefix)"
        tell application "Terminal"
          set idsToClose to {}
          repeat with w in windows
            set thisTitle to ""
            try
              set thisTitle to custom title of selected tab of w
            end try
            if thisTitle starts with titlePrefix then
              set end of idsToClose to (id of w)
            end if
          end repeat

          set closeCount to 0
          repeat with wid in idsToClose
            try
              close (first window whose id is wid)
              set closeCount to closeCount + 1
            end try
          end repeat
          return (closeCount as string)
        end tell
        """

        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 0
    }

    @discardableResult
    public func hideWindows(prefix: String) throws -> Int {
        let escapedPrefix = appleScriptEscaped(prefix)
        let script = """
        set titlePrefix to "\(escapedPrefix)"
        tell application "Terminal"
          set hitCount to 0
          repeat with w in windows
            set thisTitle to ""
            try
              set thisTitle to custom title of selected tab of w
            end try
            if thisTitle starts with titlePrefix then
              set miniaturized of w to true
              set hitCount to hitCount + 1
            end if
          end repeat
          return (hitCount as string)
        end tell
        """

        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 0
    }

    @discardableResult
    public func countWindows(prefix: String) throws -> Int {
        let escapedPrefix = appleScriptEscaped(prefix)
        let script = """
        set titlePrefix to "\(escapedPrefix)"
        tell application "Terminal"
          set hitCount to 0
          repeat with w in windows
            set thisTitle to ""
            try
              set thisTitle to custom title of selected tab of w
            end try
            if thisTitle starts with titlePrefix then
              set hitCount to hitCount + 1
            end if
          end repeat
          return (hitCount as string)
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 0
    }

    @discardableResult
    public func focusWindow(id: Int) throws -> Bool {
        let script = """
        set targetID to \(id)
        tell application "Terminal"
          activate
          try
            set targetWindow to (first window whose id is targetID)
            set index of targetWindow to 1
            return "1"
          on error
            return "0"
          end try
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    @discardableResult
    public func hideWindow(id: Int) throws -> Bool {
        let script = """
        set targetID to \(id)
        tell application "Terminal"
          try
            set targetWindow to (first window whose id is targetID)
            set miniaturized of targetWindow to true
            return "1"
          on error
            return "0"
          end try
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    @discardableResult
    public func closeWindow(id: Int) throws -> Bool {
        let script = """
        set targetID to \(id)
        tell application "Terminal"
          try
            close (first window whose id is targetID)
            return "1"
          on error
            return "0"
          end try
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    @discardableResult
    public func hasWindow(id: Int) throws -> Bool {
        let script = """
        set targetID to \(id)
        tell application "Terminal"
          try
            set _ to (first window whose id is targetID)
            return "1"
          on error
            return "0"
          end try
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    private func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
