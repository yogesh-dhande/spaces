import Foundation

public struct ChromeWindowMatch: Sendable {
    public let windowID: Int
    public let title: String
    public let url: String
}

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
        let escaped = prefix.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        set output to ""
        tell application "Google Chrome"
          repeat with w in windows
            set wid to id of w
            set titleText to title of w
            repeat with t in tabs of w
              set u to URL of t
              if u starts with "\(escaped)" then
                set output to output & wid & "\\t" & titleText & "\\t" & u & "\\n"
              end if
            end repeat
          end repeat
        end tell
        return output
        """
        let output = try AppleScript.run(script)
        return output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3, let id = Int(parts[0]) else { return nil }
                return ChromeWindowMatch(windowID: id, title: parts[1], url: parts[2])
            }
    }
}
