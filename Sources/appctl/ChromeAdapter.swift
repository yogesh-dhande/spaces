import Foundation

public final class ChromeAdapter {
    public init() {}

    public func isAvailable() -> Bool {
        (try? AppleScript.run("tell application \"Google Chrome\" to version")) != nil
    }

    public func openWindow(url: String) throws -> Int {
        let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Google Chrome"
              activate
              set newWindow to make new window
              set URL of active tab of newWindow to "\(escaped)"
              return id of newWindow
            end tell
            """
        let output = try AppleScript.run(script)
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    public func windowMatches(forURLPrefix prefix: String) throws -> [ChromeWindowMatch] {
        try queryTabs(urlPrefix: prefix)
    }

    public func allTabs() throws -> [ChromeWindowMatch] {
        try queryTabs(urlPrefix: nil)
    }

    public func focusTab(forURLPrefix prefix: String) throws -> Bool {
        let escaped = prefix.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Google Chrome"
              repeat with w in windows
                set tabCount to count of tabs of w
                repeat with i from 1 to tabCount
                  set u to URL of tab i of w
                  if u starts with "\(escaped)" then
                    set active tab index of w to i
                    set index of w to 1
                    activate
                    return "1"
                  end if
                end repeat
              end repeat
            end tell
            return "0"
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    public func focusTab(forExactURL url: String) throws -> Bool {
        let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Google Chrome"
              repeat with w in windows
                set tabCount to count of tabs of w
                repeat with i from 1 to tabCount
                  set u to URL of tab i of w
                  if u is "\(escaped)" then
                    set active tab index of w to i
                    set index of w to 1
                    activate
                    return "1"
                  end if
                end repeat
              end repeat
            end tell
            return "0"
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    public func focusTab(forURLPrefix prefix: String, windowID: Int) throws -> Bool {
        let escaped = prefix.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Google Chrome"
              repeat with w in windows
                if id of w is \(windowID) then
                  set tabCount to count of tabs of w
                  repeat with i from 1 to tabCount
                    set u to URL of tab i of w
                    if u starts with "\(escaped)" then
                      set active tab index of w to i
                      set index of w to 1
                      activate
                      return "1"
                    end if
                  end repeat
                end if
              end repeat
            end tell
            return "0"
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    public func focusTab(forExactURL url: String, windowID: Int) throws -> Bool {
        let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Google Chrome"
              repeat with w in windows
                if id of w is \(windowID) then
                  set tabCount to count of tabs of w
                  repeat with i from 1 to tabCount
                    set u to URL of tab i of w
                    if u is "\(escaped)" then
                      set active tab index of w to i
                      set index of w to 1
                      activate
                      return "1"
                    end if
                  end repeat
                end if
              end repeat
            end tell
            return "0"
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    public func frontmostActiveTabURL() throws -> String? {
        let script = """
            tell application "Google Chrome"
              if (count of windows) is 0 then
                return ""
              end if
              set u to URL of active tab of front window
              if u is missing value then
                return ""
              end if
              return u
            end tell
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func queryTabs(urlPrefix: String?) throws -> [ChromeWindowMatch] {
        let filterCondition: String
        if let urlPrefix {
            let escaped = urlPrefix.replacingOccurrences(of: "\"", with: "\\\"")
            filterCondition = "if u starts with \"\(escaped)\" then"
        } else {
            filterCondition = "if true then"
        }
        let script = """
            set output to ""
            tell application "Google Chrome"
              repeat with w in windows
                set wid to id of w
                set titleText to title of w
                repeat with t in tabs of w
                  set u to URL of t
                  if u is not missing value then
                    \(filterCondition)
                      set output to output & wid & "\\t" & titleText & "\\t" & u & "\\n"
                    end if
                  end if
                end repeat
              end repeat
            end tell
            return output
            """
        let output = try AppleScript.run(script)
        return
            output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3, let id = Int(parts[0]) else { return nil }
                return ChromeWindowMatch(windowID: id, title: parts[1], url: parts[2])
            }
    }
}
