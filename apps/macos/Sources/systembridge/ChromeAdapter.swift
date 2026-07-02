import Foundation

#if canImport(AppKit)
    import AppKit
#endif

public final class ChromeAdapter {
    private static let appleScriptTimeoutSeconds = 10
    private static let chromeBundleID = "com.google.Chrome"

    public init() {}

    public func isAvailable() -> Bool { (try? runChromeScript("tell application \"Google Chrome\" to version")) != nil }

    /// Whether Chrome is already running, checked without sending Apple Events so the check itself
    /// never launches Chrome. Teardown paths use this to skip browser cleanup when the user has
    /// already quit Chrome: scripting it then (via `isAvailable`/`closeMatchingTabsInWindow`) would
    /// relaunch Chrome just to close tabs that no longer exist.
    public func isRunning() -> Bool {
        #if canImport(AppKit)
            return !NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleID).isEmpty
        #else
            return false
        #endif
    }

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
        let output = try runChromeScript(script)
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Closes the tabs whose URL begins with `urlPrefix` inside the Chrome window with the given
    /// AppleScript window id. Returns true when at least one matching tab was closed.
    ///
    /// Used to tear down a workspace browser session's tab when the workspace stops. Only the
    /// matching tabs are closed, never the whole window, so any other tabs the user opened in that
    /// window survive (and Chrome closes the window itself only if the session tab was its last).
    /// The URL guard mirrors `focusMatchingTabInWindow`: Chrome reuses AppleScript window ids after
    /// a restart, so a tracked id can point at an unrelated user window — without the URL match a
    /// tab there could be closed by mistake.
    @discardableResult public func closeMatchingTabsInWindow(windowID: Int, urlPrefix: String) throws -> Bool {
        let escaped = urlPrefix.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Google Chrome"
              set requestedWindowID to "\(windowID)"
              set closedCount to 0
              repeat with w in windows
                if (id of w as string) is requestedWindowID then
                  set tabCount to count of tabs of w
                  repeat with i from tabCount to 1 by -1
                    set u to URL of tab i of w
                    if u is not missing value then
                      if u starts with "\(escaped)" then
                        close tab i of w
                        set closedCount to closedCount + 1
                      end if
                    end if
                  end repeat
                  exit repeat
                end if
              end repeat
              return (closedCount as string)
            end tell
            """
        let output = try runChromeScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return (Int(output) ?? 0) > 0
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
        let output = try runChromeScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let output = try runChromeScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    }

    /// Focuses the tab matching `urlPrefix` within a specific window, raising that window.
    /// Returns false when the window no longer exists or no longer holds a matching tab, so
    /// callers can reopen a dedicated window. Scoping to one window id (rather than scanning
    /// all windows) keeps a browser session's focus on its own window and never on an
    /// unrelated window that happens to have the same URL open.
    public func focusMatchingTabInWindow(windowID: Int, urlPrefix: String) throws -> Bool {
        let escaped = urlPrefix.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Google Chrome"
              set requestedWindowID to "\(windowID)"
              repeat with w in windows
                if (id of w as string) is requestedWindowID then
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
                  return "0"
                end if
              end repeat
            end tell
            return "0"
            """
        let output = try runChromeScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let output = try runChromeScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let output = try runChromeScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let output = try runChromeScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let output = try runChromeScript(script)
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

    private func runChromeScript(_ script: String) throws -> String { try AppleScript.run(script, timeoutSeconds: Self.appleScriptTimeoutSeconds) }
}
