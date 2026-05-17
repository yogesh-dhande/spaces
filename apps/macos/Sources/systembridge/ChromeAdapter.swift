import Foundation

public final class ChromeAdapter {
    public init() {}

    public func isAvailable() -> Bool { (try? AppleScript.run("tell application \"Google Chrome\" to version")) != nil }

    public func openWindow(url: String, background: Bool = false) throws -> Int {
        let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
        let activateLine = background ? "" : "activate"
        let script = """
            tell application "Google Chrome"
              \(activateLine)
              set newWindow to make new window
              set URL of active tab of newWindow to "\(escaped)"
              return id of newWindow
            end tell
            """
        let output = try AppleScript.run(script)
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    public func allTabs() throws -> [ChromeWindowMatch] { try queryTabs(urlPrefix: nil) }

    public func focusTab(windowID: Int, tabIndex: Int) throws -> Bool {
        let script = """
            tell application "Google Chrome"
              set requestedWindowID to "\(windowID)"
              set requestedTabIndex to \(tabIndex)
              repeat with w in windows
                if (id of w as string) is requestedWindowID then
                  set tabCount to count of tabs of w
                  if requestedTabIndex < 1 or requestedTabIndex > tabCount then
                    return "0"
                  end if
                  set active tab index of w to requestedTabIndex
                  set index of w to 1
                  activate
                  return "1"
                end if
              end repeat
            end tell
            return "0"
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    public func focusFirstTabOfFrontWindow() throws -> Bool {
        let script = """
            tell application "Google Chrome"
              if (count of windows) is 0 then
                return "0"
              end if
              set active tab index of front window to 1
              set index of front window to 1
              activate
              return "1"
            end tell
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    public func focusFirstMatchingTab(urlPrefix: String) throws -> Bool {
        let escaped = urlPrefix.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Google Chrome"
              repeat with w in windows
                set tabCount to count of tabs of w
                repeat with i from 1 to tabCount
                  set u to URL of tab i of w
                  if u is not missing value then
                    if u starts with "\(escaped)" then
                      set active tab index of w to i
                      set index of w to 1
                      activate
                      return "1"
                    end if
                  end if
                end repeat
              end repeat
            end tell
            return "0"
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    public func extractTabToWindow(windowID: Int, tabIndex: Int) throws -> Int? {
        let script = """
            tell application "Google Chrome"
              set requestedWindowID to "\(windowID)"
              set requestedTabIndex to \(tabIndex)
              repeat with w in windows
                if (id of w as string) is requestedWindowID then
                  set tabCount to count of tabs of w
                  if requestedTabIndex < 1 or requestedTabIndex > tabCount then
                    return ""
                  end if
                  set targetTab to tab requestedTabIndex of w
                  set sourceURL to URL of targetTab
                  if sourceURL is missing value or sourceURL is "" then
                    return ""
                  end if
                  set newWindow to make new window
                  set URL of active tab of newWindow to sourceURL
                  close targetTab
                  return id of newWindow
                end if
              end repeat
            end tell
            return ""
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let extractedWindowID = Int(output), extractedWindowID > 0 else { return nil }
        return extractedWindowID
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
                set tabCount to count of tabs of w
                repeat with i from 1 to tabCount
                  set u to URL of tab i of w
                  if u is not missing value then
                    \(filterCondition)
                      set output to output & wid & "\\t" & i & "\\t" & titleText & "\\t" & u & "\\n"
                    end if
                  end if
                end repeat
              end repeat
            end tell
            return output
            """
        let output = try AppleScript.run(script)
        var parsed: [ChromeWindowMatch] = []
        var syntheticTabIndexByWindow: [Int: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
            if parts.count == 4, let windowID = Int(parts[0]), let tabIndex = Int(parts[1]) {
                parsed.append(ChromeWindowMatch(windowID: windowID, tabIndex: tabIndex, title: parts[2], url: parts[3]))
                continue
            }
            if parts.count == 3, let windowID = Int(parts[0]) {
                let nextIndex = (syntheticTabIndexByWindow[windowID] ?? 0) + 1
                syntheticTabIndexByWindow[windowID] = nextIndex
                parsed.append(ChromeWindowMatch(windowID: windowID, tabIndex: nextIndex, title: parts[1], url: parts[2]))
            }
        }
        return parsed
    }
}
