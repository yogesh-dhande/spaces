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
}

extension GhosttyAdapter: TerminalAdapter {
    public var appName: String { "Ghostty" }
    public var bundleIdentifier: String { "com.mitchellh.ghostty" }

    public func openWindowAndRun(command: String, cwd: String, background: Bool) throws -> TerminalLaunchResult {
        let window: GhosttyWindowInfo = try self.openWindowAndRun(command: command, cwd: cwd, background: background)
        return TerminalLaunchResult(
            terminalID: window.terminalID,
            containerID: window.windowID,
            fallbackWindowID: nil)
    }

    public func focusTrackedTerminal(_ target: TerminalFocusTarget) throws -> Bool {
        guard let terminalID = target.terminalID, !terminalID.isEmpty else { return false }
        return try focusTerminal(id: terminalID) != nil
    }

    public func listLiveTerminalIDs() throws -> Set<String> { Set(try listWindowTabAndTerminalIDs().map(\.terminalID)) }
}
