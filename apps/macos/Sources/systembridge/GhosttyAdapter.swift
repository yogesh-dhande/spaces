import Foundation

open class GhosttyAdapter: @unchecked Sendable {
    public init() {}

    open func isAvailable() -> Bool { (try? AppleScript.run(#"tell application id "com.mitchellh.ghostty" to version"#)) != nil }

    private func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func shellSingleQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private func commandApplyingEnvironment(_ command: String, environment: [String: String]) -> String {
        guard !environment.isEmpty else { return command }
        let exports = environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(shellSingleQuoted($0.value))" }.joined(separator: "; ")
        return "\(exports); \(command)"
    }

    /// Ghostty's AppleScript dictionary does not reliably support property access like
    /// `environment variables of every terminal`. Keep terminal scans on the explicit
    /// window -> tab -> terminal traversal path so lookups behave consistently.
    private func terminalTraversalScript(lines: [String]) -> String {
        ([
            #"tell application id "com.mitchellh.ghostty""#, "  set out to \"\"", "  repeat with w in windows", "    repeat with t in tabs of w",
            "      repeat with term in terminals of t",
        ] + lines.map { "        \($0)" } + ["      end repeat", "    end repeat", "  end repeat", "  return out", "end tell"]).joined(
            separator: "\n")
    }

    open func openWindowAndRun(command: String, cwd: String, background: Bool = false) throws -> GhosttyWindowInfo {
        let escapedDirectory = appleScriptEscaped(cwd)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedInput = appleScriptEscaped(trimmedCommand.isEmpty ? "" : "\(trimmedCommand)\n")
        let activateLine = background ? "" : "activate"
        let script = """
            tell application id "com.mitchellh.ghostty"
              set cfg to new surface configuration
              set initial working directory of cfg to "\(escapedDirectory)"
              set initial input of cfg to "\(escapedInput)"
              \(activateLine)
              set w to new window with configuration cfg
              set t to selected tab of w
              set term to focused terminal of t
              return (id of w as string) & "|" & (id of t as string) & "|" & (id of term as string)
            end tell
            """
        let output = try AppleScript.run(script)
        let parts = output.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
            throw NSError(
                domain: "spaces.ghostty", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ghostty did not return expected window, tab, and terminal identifiers."])
        }
        return GhosttyWindowInfo(windowID: parts[0], tabID: parts[1], terminalID: parts[2])
    }

    open func focusTerminal(id: String) throws -> String? {
        let escapedID = appleScriptEscaped(id)
        let script = """
            tell application id "com.mitchellh.ghostty"
              tell terminal id "\(escapedID)" to focus
              return id of front window
            end tell
            """
        let output = try AppleScript.run(script)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    open func closeWindow(id: String) throws {
        let escapedID = appleScriptEscaped(id)
        let script = """
            tell application id "com.mitchellh.ghostty"
              tell window id "\(escapedID)" to close window
            end tell
            """
        _ = try AppleScript.run(script)
    }

    open func closeTab(id: String) throws {
        let escapedID = appleScriptEscaped(id)
        let script = """
            tell application id "com.mitchellh.ghostty"
              tell tab id "\(escapedID)" to close tab
            end tell
            """
        _ = try AppleScript.run(script)
    }

    open func listWindowTabAndTerminalIDs() throws -> [(windowID: String, tabID: String, terminalID: String)] {
        let script = terminalTraversalScript(lines: [
            "set out to out & (id of w as string) & \"|\" & (id of t as string) & \"|\" & (id of term as string) & linefeed"
        ])
        return try AppleScript.run(script).split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            return (windowID: parts[0], tabID: parts[1], terminalID: parts[2])
        }
    }

    open func openWindowAndRun(command: String, cwd: String, environment: [String: String], background: Bool) throws -> TerminalLaunchResult {
        let window: GhosttyWindowInfo = try self.openWindowAndRun(
            command: commandApplyingEnvironment(command, environment: environment), cwd: cwd, background: background)
        return TerminalLaunchResult(
            trackingIdentity: .session(window.terminalID), hookSessionID: environment["SPACES_TERMINAL_TRACKING_ID"], containerID: window.tabID,
            fallbackWindowID: nil)
    }
}

extension GhosttyAdapter: TerminalAdapter {
    public var appName: String { "Ghostty" }
    public var bundleIdentifier: String { "com.mitchellh.ghostty" }

    public func resolveCurrentTrackingIdentity(environment: [String: String], yabaiFocusedWindowID: Int?) throws -> TerminalTrackingIdentity? {
        // Ghostty hook attribution must come from the injected shell token. Falling back to a
        // frontmost terminal or window here misattributes background hooks to whichever Ghostty
        // tab the user happens to be viewing when `spaces signal` runs.
        if let trackingID = environment["SPACES_TERMINAL_TRACKING_ID"], !trackingID.isEmpty { return .session(trackingID) }
        return nil
    }

    public func focusTrackedTerminal(_ target: TerminalFocusTarget) throws -> Bool {
        switch target.trackingIdentity {
        case .session(let id):
            // Focus is intentionally more permissive than event attribution: once Spaces already
            // knows which Ghostty terminal it wants, a direct terminal focus is preferred, but
            // falling back to the tracked yabai window is still useful if Ghostty refuses the
            // terminal-level focus request.
            if try focusTerminal(id: id) != nil { return true }
            guard let windowID = target.windowID else { return false }
            return try YabaiAdapter().focusWindow(id: windowID)
        case .window(let id): return try YabaiAdapter().focusWindow(id: id)
        case .tmux, nil:
            guard let windowID = target.windowID else { return false }
            return try YabaiAdapter().focusWindow(id: windowID)
        }
    }

    public func listLiveTrackingIdentities() throws -> Set<TerminalTrackingIdentity> {
        Set(try listWindowTabAndTerminalIDs().map { .session($0.terminalID) })
    }
}
