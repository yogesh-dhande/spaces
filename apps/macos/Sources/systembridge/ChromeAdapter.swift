import Foundation

#if canImport(AppKit)
    import AppKit
#endif

public final class ChromeAdapter {
    private static let chromeBundleID = "com.google.Chrome"

    private let appleScriptTimeoutSeconds: Int

    /// The timeout only exists as a parameter so tests exercising mocked osascript output can
    /// widen it beyond spawn latency on a loaded machine; production callers use the default.
    public init(appleScriptTimeoutSeconds: Int = 10) { self.appleScriptTimeoutSeconds = appleScriptTimeoutSeconds }

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
        let script = """
            tell application "Google Chrome"
              set newWindow to make new window
              set URL of active tab of newWindow to "\(escaped)"
              return id of newWindow
            end tell
            """
        let output = try runChromeScript(script)
        let windowID = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        if !background, windowID > 0 { bringChromeForward(raisedWindowID: windowID) }
        return windowID
    }

    public func openTabInFirstAvailableWindow(windowIDs: [Int], containingAnyURLPrefix urlPrefixes: [String], url: String, background: Bool = false)
        throws -> Int?
    {
        var seenWindowIDs = Set<Int>()
        let uniqueWindowIDs = windowIDs.filter { $0 > 0 && seenWindowIDs.insert($0).inserted }
        var seenURLPrefixes = Set<String>()
        let uniqueURLPrefixes = urlPrefixes.filter { !$0.isEmpty && seenURLPrefixes.insert($0).inserted }
        guard !uniqueWindowIDs.isEmpty, !uniqueURLPrefixes.isEmpty else { return nil }
        let requestedIDs = uniqueWindowIDs.map { "\"\($0)\"" }.joined(separator: ", ")
        let requiredURLPrefixes = uniqueURLPrefixes.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
        let escaped = url.replacingOccurrences(of: "\"", with: "\\\"")
        let focusLines =
            background
            ? ""
            : """
                  set active tab index of w to count of tabs of w
                  set minimized of w to false
                  set index of w to 1
            """
        let script = """
            set requestedWindowIDs to {\(requestedIDs)}
            set workspaceURLPrefixes to {\(requiredURLPrefixes)}
            tell application "Google Chrome"
              repeat with requestedWindowID in requestedWindowIDs
                repeat with w in windows
                  if (id of w as string) is (requestedWindowID as string) then
                    set hasWorkspaceTab to false
                    repeat with existingTab in tabs of w
                      set existingURL to URL of existingTab
                      if existingURL is not missing value then
                        repeat with workspaceURLPrefix in workspaceURLPrefixes
                          if existingURL starts with (workspaceURLPrefix as string) then
                            set hasWorkspaceTab to true
                            exit repeat
                          end if
                        end repeat
                      end if
                      if hasWorkspaceTab then exit repeat
                    end repeat
                    if hasWorkspaceTab then
                      make new tab at end of tabs of w with properties {URL:"\(escaped)"}
            \(focusLines)
                      return id of w as string
                    end if
                  end if
                end repeat
              end repeat
            end tell
            return ""
            """
        let output = try runChromeScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowID = Int(output), windowID > 0 else { return nil }
        if !background { bringChromeForward(raisedWindowID: windowID) }
        return windowID
    }

    /// Closes the tabs whose URL matches `urlPrefix` inside the Chrome window with the given
    /// AppleScript window id. Returns true when at least one matching tab was closed.
    ///
    /// Used to tear down a workspace browser session's tab when the workspace stops. Only the
    /// matching tabs are closed, never the whole window, so any other tabs the user opened in that
    /// window survive (and Chrome closes the window itself only if the session tab was its last).
    /// The URL guard mirrors `focusMatchingTabInWindow`: Chrome reuses AppleScript window ids after
    /// a restart, so a tracked id can point at an unrelated user window — without the URL match a
    /// tab there could be closed by mistake.
    @discardableResult public func closeMatchingTabsInWindow(windowID: Int, urlPrefix: String, excludingURLPrefixes: [String] = []) throws -> Bool {
        let escaped = Self.escapedAppleScriptString(urlPrefix)
        let exactURLs = Self.appleScriptStringList(Self.exactURLCandidates(for: urlPrefix))
        let excludedPrefixes = Self.appleScriptStringList(Self.uniqueNonEmptyURLPrefixes(excludingURLPrefixes))
        let script = """
            set targetURLPrefix to "\(escaped)"
            set exactTargetURLs to {\(exactURLs)}
            set excludedURLPrefixes to {\(excludedPrefixes)}
            tell application "Google Chrome"
              set requestedWindowID to "\(windowID)"
              set closedCount to 0
              repeat with w in windows
                if (id of w as string) is requestedWindowID then
                  set tabCount to count of tabs of w
                  repeat with i from tabCount to 1 by -1
                    set u to URL of tab i of w
                    if u is not missing value then
                      set shouldClose to false
                      repeat with exactTargetURL in exactTargetURLs
                        if u is (exactTargetURL as string) then
                          set shouldClose to true
                          exit repeat
                        end if
                      end repeat
                      if shouldClose is false and u starts with targetURLPrefix then
                        set excludedMatch to false
                        repeat with excludedURLPrefix in excludedURLPrefixes
                          if u starts with (excludedURLPrefix as string) then
                            set excludedMatch to true
                            exit repeat
                          end if
                        end repeat
                        if excludedMatch is false then set shouldClose to true
                      end if
                      if shouldClose then
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

    /// Returns the requested-window tab list and the frontmost active tab URL from one Chrome
    /// AppleScript invocation. Window cycling needs both values to build the open target set and
    /// locate the current browser target, so keeping them together avoids an extra Apple Events round trip.
    public func tabSnapshot(inWindowIDs windowIDs: [Int]) throws -> ChromeTabSnapshot {
        let uniqueWindowIDs = Array(Set(windowIDs.filter { $0 > 0 })).sorted()
        guard !uniqueWindowIDs.isEmpty else { return ChromeTabSnapshot(tabs: [], frontmostActiveTabURL: nil) }
        let requestedIDs = uniqueWindowIDs.map { "\"\($0)\"" }.joined(separator: ", ")
        let separator = "__SPACES_FRONTMOST_TABS__"
        let script = """
            set requestedWindowIDs to {\(requestedIDs)}
            set frontmostURL to ""
            set output to ""
            tell application "Google Chrome"
              if (count of windows) is not 0 then
                set frontmostURL to URL of active tab of front window
                if frontmostURL is missing value then
                  set frontmostURL to ""
                end if
              end if
              repeat with w in windows
                set wid to id of w
                if requestedWindowIDs contains (wid as string) then
                  set titleText to title of w
                  set tabCount to count of tabs of w
                  repeat with i from 1 to tabCount
                    set u to URL of tab i of w
                    if u is not missing value then
                      set output to output & wid & "\\t" & i & "\\t" & titleText & "\\t" & u & "\\n"
                    end if
                  end repeat
                end if
              end repeat
            end tell
            return frontmostURL & "\\n\(separator)\\n" & output
            """
        let output = try runChromeScript(script)
        let split = output.components(separatedBy: separator)
        let frontmostURL = split.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tabRows = split.dropFirst().joined(separator: separator)
        return ChromeTabSnapshot(tabs: Self.parseTabRows(tabRows), frontmostActiveTabURL: frontmostURL?.isEmpty == false ? frontmostURL : nil)
    }

    /// Focuses the tab matching `urlPrefix` within a specific window, raising that window.
    /// Returns false when the window no longer exists or no longer holds a matching tab, so
    /// callers can adopt a moved tab or reopen the session. Scoping to one window id keeps the
    /// fast path on the window currently tracked for that browser-session URL.
    public func focusMatchingTabInWindow(windowID: Int, urlPrefix: String, excludingURLPrefixes: [String] = []) throws -> Bool {
        let escaped = Self.escapedAppleScriptString(urlPrefix)
        let exactURLs = Self.appleScriptStringList(Self.exactURLCandidates(for: urlPrefix))
        let excludedPrefixes = Self.appleScriptStringList(Self.uniqueNonEmptyURLPrefixes(excludingURLPrefixes))
        let script = """
            set targetURLPrefix to "\(escaped)"
            set exactTargetURLs to {\(exactURLs)}
            set excludedURLPrefixes to {\(excludedPrefixes)}
            tell application "Google Chrome"
              set requestedWindowID to "\(windowID)"
              repeat with w in windows
                if (id of w as string) is requestedWindowID then
                  set tabCount to count of tabs of w
                  repeat with i from 1 to tabCount
                    set u to URL of tab i of w
                    if u is not missing value then
                      repeat with exactTargetURL in exactTargetURLs
                        if u is (exactTargetURL as string) then
                          set active tab index of w to i
                          set minimized of w to false
                          set index of w to 1
                          return "1"
                        end if
                      end repeat
                    end if
                  end repeat
                  repeat with i from 1 to tabCount
                    set u to URL of tab i of w
                    if u is not missing value then
                      if u starts with targetURLPrefix then
                        set excludedMatch to false
                        repeat with excludedURLPrefix in excludedURLPrefixes
                          if u starts with (excludedURLPrefix as string) then
                            set excludedMatch to true
                            exit repeat
                          end if
                        end repeat
                        if excludedMatch is false then
                          set active tab index of w to i
                          set minimized of w to false
                          set index of w to 1
                          return "1"
                        end if
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
        let focused = output == "1"
        if focused { bringChromeForward(raisedWindowID: windowID) }
        return focused
    }

    public func focusFirstMatchingTabMatch(urlPrefix: String, excludingURLPrefixes: [String] = []) throws -> ChromeWindowMatch? {
        let escaped = Self.escapedAppleScriptString(urlPrefix)
        let exactURLs = Self.appleScriptStringList(Self.exactURLCandidates(for: urlPrefix))
        let excludedPrefixes = Self.appleScriptStringList(Self.uniqueNonEmptyURLPrefixes(excludingURLPrefixes))
        let script = """
            set targetURLPrefix to "\(escaped)"
            set exactTargetURLs to {\(exactURLs)}
            set excludedURLPrefixes to {\(excludedPrefixes)}
            tell application "Google Chrome"
              repeat with w in windows
                set wid to id of w
                set titleText to title of w
                set tabCount to count of tabs of w
                repeat with i from 1 to tabCount
                  set u to URL of tab i of w
                  if u is not missing value then
                    repeat with exactTargetURL in exactTargetURLs
                      if u is (exactTargetURL as string) then
                        set active tab index of w to i
                        set minimized of w to false
                        set index of w to 1
                        return wid & "\\t" & i & "\\t" & titleText & "\\t" & u
                      end if
                    end repeat
                  end if
                end repeat
              end repeat
              repeat with w in windows
                set wid to id of w
                set titleText to title of w
                set tabCount to count of tabs of w
                repeat with i from 1 to tabCount
                  set u to URL of tab i of w
                  if u is not missing value then
                    if u starts with targetURLPrefix then
                      set excludedMatch to false
                      repeat with excludedURLPrefix in excludedURLPrefixes
                        if u starts with (excludedURLPrefix as string) then
                          set excludedMatch to true
                          exit repeat
                        end if
                      end repeat
                      if excludedMatch is false then
                        set active tab index of w to i
                        set minimized of w to false
                        set index of w to 1
                        return wid & "\\t" & i & "\\t" & titleText & "\\t" & u
                      end if
                    end if
                  end if
                end repeat
              end repeat
            end tell
            return ""
            """
        let output = try runChromeScript(script)
        let match = Self.parseTabRows(output).first
        if let match { bringChromeForward(raisedWindowID: match.windowID) }
        return match
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

    private static func uniqueNonEmptyURLPrefixes(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func exactURLCandidates(for urlPrefix: String) -> [String] {
        var candidates = [urlPrefix]
        if !urlPrefix.contains("?"), !urlPrefix.contains("#") {
            if urlPrefix.hasSuffix("/") {
                let trimmed = String(urlPrefix.dropLast())
                if !trimmed.isEmpty { candidates.append(trimmed) }
            } else {
                candidates.append(urlPrefix + "/")
            }
        }
        return uniqueNonEmptyURLPrefixes(candidates)
    }

    private static func escapedAppleScriptString(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "\\\"") }

    private static func appleScriptStringList(_ values: [String]) -> String {
        values.map { "\"\(escapedAppleScriptString($0))\"" }.joined(separator: ", ")
    }

    private static func parseTabRows(_ output: String) -> [ChromeWindowMatch] {
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

    /// Brings Chrome forward and leaves the window the calling script targeted frontmost, including when
    /// that window sits on a desktop Space other than the one being displayed.
    ///
    /// The activation never crosses Spaces; the raise does. `NSRunningApplication.activate(options: [])`
    /// is front-window-only and leaves the displayed Space exactly as it was. Sending
    /// `set index of w to 1` to an off-Space window while Chrome is *already* the active app is what
    /// switches the desktop to that window's Space and raises it there.
    ///
    /// Which is why the order matters: the same `set index` issued while another app (Spaces) is still
    /// frontmost does not apply to the current state at all, it applies to Chrome's *next* activation,
    /// one request late. Raising first and activating second therefore activates onto whatever stale
    /// window Chrome still considers its main one. Activating first and re-raising after needs no settle
    /// delay for the Space-switch animation itself, but the activation must be confirmed to have landed
    /// before the raise is issued; see `waitForChromeActivation`.
    ///
    /// The caller's own in-script `set index of w to 1` stays, and is not redundant with the re-raise
    /// here. For a target already on the displayed Space the window is reachable, so that `set index`
    /// applies immediately rather than to the next activation, and the activation raises the target
    /// directly with no flash of an unrelated Chrome window. The re-raise below is what lands the
    /// off-Space case. The callers also un-minimize the target (`set minimized of w to false`) right
    /// before their raise, so the window is already restored by the time this runs.
    ///
    /// AppleScript's own `activate` is never used, in either case: it behaves like `.activateAllWindows`
    /// and lifts every Chrome window above the app that was frontmost, burying the Spaces window.
    ///
    /// Skipped under XCTest for the reason the tests mock `osascript`: activation is a real system
    /// effect, and a unit test must not raise the Chrome running on the machine it runs on.
    private func bringChromeForward(raisedWindowID: Int) {
        #if canImport(AppKit)
            guard !Self.isRunningUnderXCTest else { return }
            guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleID).first else { return }
            chrome.activate(options: [])
            Self.waitForChromeActivation(chrome)
            _ = try? runChromeScript(Self.raiseWindowScript(windowID: raisedWindowID))
        #endif
    }

    #if canImport(AppKit)
        /// How long `waitForChromeActivation` polls before giving up and proceeding anyway.
        private static let chromeActivationWaitDeadlineSeconds: TimeInterval = 0.5

        /// Blocks the calling thread until `app.isActive` is true or `chromeActivationWaitDeadlineSeconds`
        /// elapses, whichever comes first.
        ///
        /// `NSRunningApplication.activate(options:)` reports only that the activation request was sent,
        /// not that Chrome has actually become the active app. The raise in `bringChromeForward` is only
        /// valid once Chrome is active (see that method's doc comment), which is exactly what this wait
        /// confirms before the raise script runs.
        ///
        /// The poll depends on the app's main run loop pumping the workspace notifications that update
        /// `isActive`, which holds for the shipping app (this call always runs off the main thread; see
        /// `bringChromeForward`'s callers). Measured inside an `NSApplication`, `isActive` flips 3-4ms
        /// after the activate, so the wait costs about one poll interval. Do not measure it from a bare
        /// command-line harness: with no `NSApplication` the notifications never arrive, `isActive` stays
        /// false, and the deadline burns in full. When Chrome is already active, the first check succeeds
        /// and this is a no-op, which is the common case.
        ///
        /// If the deadline passes without Chrome becoming active, this simply returns and the caller
        /// proceeds to the raise anyway: that is exactly today's behavior without this wait, so the wait
        /// can only improve the outcome here, never regress it.
        private static func waitForChromeActivation(_ app: NSRunningApplication) {
            let deadline = Date().addingTimeInterval(chromeActivationWaitDeadlineSeconds)
            while !app.isActive, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
    #endif

    /// Raises the Chrome window with the given AppleScript id, crossing to the Space that window lives on
    /// when it is not the displayed one. Only valid once Chrome is the active app, which is what makes
    /// the reorder apply to the current state instead of to Chrome's next activation.
    static func raiseWindowScript(windowID: Int) -> String {
        """
        tell application "Google Chrome"
          repeat with w in windows
            if (id of w as string) is "\(windowID)" then
              set index of w to 1
              exit repeat
            end if
          end repeat
        end tell
        """
    }

    /// Mirrors `SpacesTestHost.isRunningUnderXCTest()`, which this target cannot call: `systembridge`
    /// is declared with no dependencies. Xcode sets the environment variable, but `swift test` runs out
    /// of the toolchain without it, so the linked-in `XCTestCase` class is the only signal on that lane.
    private static let isRunningUnderXCTest: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        #if canImport(ObjectiveC)
            if NSClassFromString("XCTestCase") != nil { return true }
        #endif
        return false
    }()

    private func runChromeScript(_ script: String) throws -> String { try AppleScript.run(script, timeoutSeconds: appleScriptTimeoutSeconds) }
}
