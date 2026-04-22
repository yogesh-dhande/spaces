import Foundation

open class GhosttyAdapter: @unchecked Sendable {
    public init() {}

    open func isAvailable() -> Bool { (try? AppleScript.run(#"tell application id "com.mitchellh.ghostty" to version"#)) != nil }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func commandApplyingEnvironment(_ command: String, environment: [String: String]) -> String {
        guard !environment.isEmpty else { return command }
        let exports = environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellSingleQuoted($0.value))" }
            .joined(separator: "; ")
        return "\(exports); \(command)"
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
                domain: "muxy.ghostty", code: 1,
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

    open func listWindowTabAndTerminalIDs() throws -> [(windowID: String, tabID: String, terminalID: String)] {
        let script = """
            tell application id "com.mitchellh.ghostty"
              set out to ""
              repeat with w in windows
                set out to out & (id of w as string) & "|" & (id of selected tab of w as string) & "|" & (id of focused terminal of selected tab of w as string) & linefeed
              end repeat
              return out
            end tell
            """
        return try AppleScript.run(script)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
                return (windowID: parts[0], tabID: parts[1], terminalID: parts[2])
            }
    }

    private func resolveGhosttyWindowID(environmentVariableNamed name: String, equals value: String) throws -> Int? {
        let escapedName = appleScriptEscaped(name)
        let escapedValue = appleScriptEscaped(value)
        let script = """
            tell application id "com.mitchellh.ghostty"
              repeat with t in terminals
                if (environment variables of t) contains "\(escapedName)=\(escapedValue)" then
                  return id of window of t
                end if
              end repeat
            end tell
            """
        let output = try AppleScript.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowID = Int(output) else { return nil }
        return windowID
    }

    open func openWindowAndRun(command: String, cwd: String, environment: [String: String], background: Bool) throws -> TerminalLaunchResult {
        let window: GhosttyWindowInfo = try self.openWindowAndRun(
            command: commandApplyingEnvironment(command, environment: environment),
            cwd: cwd,
            background: background)
        return TerminalLaunchResult(
            trackingIdentity: environment["MUXY_TERMINAL_TRACKING_ID"].map(TerminalTrackingIdentity.session)
                ?? .session(window.terminalID),
            containerID: window.windowID,
            fallbackWindowID: nil)
    }
}

extension GhosttyAdapter: TerminalAdapter {
    public var appName: String { "Ghostty" }
    public var bundleIdentifier: String { "com.mitchellh.ghostty" }

    public func resolveCurrentTrackingIdentity(environment: [String: String], yabaiFocusedWindowID: Int?) throws -> TerminalTrackingIdentity? {
        if let trackingID = environment["MUXY_TERMINAL_TRACKING_ID"], !trackingID.isEmpty {
            return .session(trackingID)
        }
        if let codexThreadID = environment["CODEX_THREAD_ID"], !codexThreadID.isEmpty,
            let windowID = try? resolveGhosttyWindowID(environmentVariableNamed: "CODEX_THREAD_ID", equals: codexThreadID)
        {
            return .window(windowID)
        }
        return yabaiFocusedWindowID.map(TerminalTrackingIdentity.window)
    }

    public func focusTrackedTerminal(_ target: TerminalFocusTarget) throws -> Bool {
        switch target.trackingIdentity {
        case .session(let id):
            if let windowID = try? resolveGhosttyWindowID(environmentVariableNamed: "MUXY_TERMINAL_TRACKING_ID", equals: id) {
                return (try? YabaiAdapter().focusWindow(id: windowID)) ?? false
            }
            return try focusTerminal(id: id) != nil
        case .window(let id):
            return try YabaiAdapter().focusWindow(id: id)
        case .tmux, nil:
            guard let windowID = target.windowID else { return false }
            return try YabaiAdapter().focusWindow(id: windowID)
        }
    }

    public func listLiveTrackingIdentities() throws -> Set<TerminalTrackingIdentity> {
        Set(try listWindowTabAndTerminalIDs().map { .session($0.terminalID) })
    }
}
