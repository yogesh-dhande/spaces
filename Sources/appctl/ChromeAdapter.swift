import Foundation

public final class ChromeAdapter {
    public init() {}

    @discardableResult
    public func ensureTabs(urls: [String]) throws -> Int? {
        guard !urls.isEmpty else {
            return nil
        }

        let quoted = urls.map { "\"\($0.replacingOccurrences(of: "\\\"", with: "\\\\\""))\"" }.joined(separator: ",")

        let script = """
        set requestedUrls to {\(quoted)}
        set anchorUrl to item 1 of requestedUrls

        tell application "Google Chrome"
          activate
          set targetWindow to missing value
          repeat with w in windows
            repeat with t in tabs of w
              if (URL of t) is equal to anchorUrl then
                set targetWindow to w
                exit repeat
              end if
            end repeat
            if targetWindow is not missing value then exit repeat
          end repeat

          if targetWindow is missing value then
            set targetWindow to make new window
            set URL of active tab of targetWindow to anchorUrl
            if (count of requestedUrls) > 1 then
              repeat with i from 2 to (count of requestedUrls)
                set u to item i of requestedUrls
                tell targetWindow to make new tab at end of tabs with properties {URL:u}
              end repeat
            end if
          else
            set existingUrls to {}
            repeat with t in tabs of targetWindow
              set end of existingUrls to (URL of t)
            end repeat
            repeat with u in requestedUrls
              if existingUrls does not contain u then
                tell targetWindow to make new tab at end of tabs with properties {URL:u}
              end if
            end repeat
          end if
          return (id of targetWindow as string)
        end tell
        """

        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output)
    }

    @discardableResult
    public func focusWindow(anchorURL: String) throws -> Bool {
        let anchor = appleScriptEscaped(anchorURL)
        let script = """
        set anchorUrl to "\(anchor)"
        tell application "Google Chrome"
          activate
          set foundWindow to missing value
          repeat with w in windows
            repeat with t in tabs of w
              if (URL of t) is equal to anchorUrl then
                set foundWindow to w
                exit repeat
              end if
            end repeat
            if foundWindow is not missing value then exit repeat
          end repeat

          if foundWindow is missing value then
            return "0"
          else
            set index of foundWindow to 1
            return "1"
          end if
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    @discardableResult
    public func closeWindow(anchorURL: String) throws -> Bool {
        let anchor = appleScriptEscaped(anchorURL)
        let script = """
        set anchorUrl to "\(anchor)"
        tell application "Google Chrome"
          set foundWindow to missing value
          repeat with w in windows
            repeat with t in tabs of w
              if (URL of t) is equal to anchorUrl then
                set foundWindow to w
                exit repeat
              end if
            end repeat
            if foundWindow is not missing value then exit repeat
          end repeat

          if foundWindow is missing value then
            return "0"
          else
            close foundWindow
            return "1"
          end if
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    @discardableResult
    public func hideWindow(anchorURL: String) throws -> Bool {
        let anchor = appleScriptEscaped(anchorURL)
        let script = """
        set anchorUrl to "\(anchor)"
        tell application "Google Chrome"
          set foundWindow to missing value
          repeat with w in windows
            repeat with t in tabs of w
              if (URL of t) is equal to anchorUrl then
                set foundWindow to w
                exit repeat
              end if
            end repeat
            if foundWindow is not missing value then exit repeat
          end repeat

          if foundWindow is missing value then
            return "0"
          else
            set miniaturized of foundWindow to true
            return "1"
          end if
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    @discardableResult
    public func hasWindow(anchorURL: String) throws -> Bool {
        let anchor = appleScriptEscaped(anchorURL)
        let script = """
        set anchorUrl to "\(anchor)"
        tell application "Google Chrome"
          repeat with w in windows
            repeat with t in tabs of w
              if (URL of t) is equal to anchorUrl then
                return "1"
              end if
            end repeat
          end repeat
          return "0"
        end tell
        """
        let output = try Shell.runAndCapture(["osascript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    @discardableResult
    public func focusWindow(windowID: Int) throws -> Bool {
        let script = """
        set targetID to \(windowID)
        tell application "Google Chrome"
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
    public func hideWindow(windowID: Int) throws -> Bool {
        let script = """
        set targetID to \(windowID)
        tell application "Google Chrome"
          try
            set targetWindow to (first window whose id is targetID)
            try
              set minimized of targetWindow to true
            on error
              set miniaturized of targetWindow to true
            end try
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
    public func closeWindow(windowID: Int) throws -> Bool {
        let script = """
        set targetID to \(windowID)
        tell application "Google Chrome"
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
    public func hasWindow(windowID: Int) throws -> Bool {
        let script = """
        set targetID to \(windowID)
        tell application "Google Chrome"
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

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
