import Foundation

open class TmuxAdapter: @unchecked Sendable {
    private let windowFieldSeparator = "\u{1F}"
    private let windowIDFormat = "#{window_id}"
    private var createdWindowFormat: String {
        ["#{window_id}", "#{window_index}", "#{window_active}", "#{pane_pid}"].joined(separator: windowFieldSeparator)
    }
    private var windowFormat: String {
        // tmux can preserve tabs and printable user input inside names, so use
        // an ASCII unit separator rather than a visible token that could collide
        // with workspace, window, or session names.
        ["#{window_id}", "#{window_index}", "#{window_name}", "#{session_name}", "#{window_active}", "#{pane_pid}"].joined(
            separator: windowFieldSeparator)
    }

    public init() {}

    open func isAvailable() -> Bool { (try? runAndCapture(["-V"])) != nil }

    open func hasSession(named sessionName: String) -> Bool { (try? runAndCapture(["has-session", "-t", sessionName])) != nil }

    open func killSession(named sessionName: String) throws { _ = try run(["kill-session", "-t", sessionName]) }

    open func listWindows(sessionName: String) throws -> [TmuxWindowInfo] {
        guard hasSession(named: sessionName) else { return [] }
        let output: String
        do { output = try runAndCapture(["list-windows", "-t", sessionName, "-F", windowFormat]) } catch {
            if isMissingTmuxTargetError(error) { return [] }
            throw error
        }
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parseWindow(line: String($0)) }
    }

    open func currentWindow(sessionName: String) throws -> TmuxWindowInfo? {
        guard hasSession(named: sessionName) else { return nil }
        let windowIDOutput: String
        do { windowIDOutput = try displayMessage(target: sessionName, format: windowIDFormat) } catch {
            if isMissingTmuxTargetError(error) { return nil }
            throw error
        }
        guard let windowID = parseWindowID(output: windowIDOutput) else { return nil }
        do { return try windowInfo(target: windowID) } catch {
            if isMissingTmuxTargetError(error) { return nil }
            throw error
        }
    }

    open func currentWindow() throws -> TmuxWindowInfo? {
        guard let windowID = parseWindowID(output: try displayMessage(target: nil, format: windowIDFormat)) else { return nil }
        return try windowInfo(target: windowID)
    }

    open func createWindow(sessionName: String, name: String, command: String? = nil, detached: Bool = true) throws -> TmuxWindowInfo {
        var arguments = ["new-window"]
        if detached { arguments.append("-d") }
        arguments += ["-P", "-F", createdWindowFormat, "-t", sessionName, "-n", name]
        if let command, !command.isEmpty { arguments.append(command) }
        let output = try runAndCapture(arguments)
        guard let window = parseCreatedWindow(output: output, fallbackName: name, sessionName: sessionName) else {
            throw NSError(domain: "spaces.tmux", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create tmux window."])
        }
        return bestEffortRefinedCreatedWindow(window)
    }

    open func startSession(named sessionName: String, windowName: String, cwd: String, env: [String: String] = [:], command: [String]) throws
        -> TmuxWindowInfo
    {
        var arguments = ["new-session", "-d", "-P", "-F", createdWindowFormat, "-s", sessionName, "-n", windowName, "-c", cwd]
        for (key, value) in env.sorted(by: { $0.key < $1.key }) { arguments += ["-e", "\(key)=\(value)"] }
        arguments.append(contentsOf: command)
        let output = try runAndCapture(arguments)
        guard let window = parseCreatedWindow(output: output, fallbackName: windowName, sessionName: sessionName) else {
            throw NSError(domain: "spaces.tmux", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create tmux session."])
        }
        return bestEffortRefinedCreatedWindow(window)
    }

    open func renameWindow(windowID: String, name: String) throws { _ = try run(["rename-window", "-t", windowID, name]) }

    open func respawnWindow(windowID: String, command: String) throws { _ = try run(["respawn-window", "-k", "-t", windowID, command]) }

    open func setRemainOnExit(windowID: String, enabled: Bool) throws {
        _ = try run(["set-option", "-t", windowID, "remain-on-exit", enabled ? "on" : "off"])
    }

    open func isPaneDead(windowID: String) throws -> Bool { try displayMessage(target: windowID, format: "#{pane_dead}") == "1" }

    open func paneExitStatus(windowID: String) throws -> Int? { Int(try displayMessage(target: windowID, format: "#{pane_dead_status}")) }

    open func capturePane(windowID: String) throws -> String {
        try runAndCapture(["capture-pane", "-p", "-t", windowID]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    open func selectWindow(windowID: String) throws -> Bool { (try? run(["select-window", "-t", windowID])) == 0 }

    open func killWindow(windowID: String) throws { _ = try run(["kill-window", "-t", windowID]) }

    func parseWindowID(output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func parseCreatedWindow(output: String, fallbackName: String, sessionName: String) -> TmuxWindowInfo? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let unitSeparated = trimmed.components(separatedBy: windowFieldSeparator)
        if let window = parseCreatedWindow(parts: unitSeparated, fallbackName: fallbackName, sessionName: sessionName) { return window }

        let underscoreSeparated = trimmed.components(separatedBy: "_")
        return parseCreatedWindow(parts: underscoreSeparated, fallbackName: fallbackName, sessionName: sessionName)
    }

    private func parseCreatedWindow(parts: [String], fallbackName: String, sessionName: String) -> TmuxWindowInfo? {
        guard parts.count >= 4, let index = Int(parts[1]) else { return nil }
        return TmuxWindowInfo(
            id: parts[0], index: index, name: fallbackName, sessionName: sessionName, isActive: parts[2] == "1", panePID: Int(parts[3]))
    }

    private func bestEffortRefinedCreatedWindow(_ window: TmuxWindowInfo) -> TmuxWindowInfo {
        guard let refined = try? windowInfo(target: window.id) else { return window }
        return refined
    }

    private func displayMessage(target: String?, format: String) throws -> String {
        var arguments = ["display-message", "-p"]
        if let target, !target.isEmpty { arguments += ["-t", target] }
        arguments.append(format)
        return try runAndCapture(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func windowInfo(target: String) throws -> TmuxWindowInfo {
        let indexOutput = try displayMessage(target: target, format: "#{window_index}")
        guard let index = Int(indexOutput) else {
            throw NSError(domain: "spaces.tmux", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to inspect tmux window."])
        }
        let name = try displayMessage(target: target, format: "#{window_name}")
        let sessionName = try displayMessage(target: target, format: "#{session_name}")
        let isActive = try displayMessage(target: target, format: "#{window_active}") == "1"
        let panePID = Int(try displayMessage(target: target, format: "#{pane_pid}"))
        return TmuxWindowInfo(id: target, index: index, name: name, sessionName: sessionName, isActive: isActive, panePID: panePID)
    }

    func parseWindow(line: String) -> TmuxWindowInfo? {
        guard !line.isEmpty else { return nil }
        let parts = line.components(separatedBy: windowFieldSeparator)
        if let window = parseWindow(parts: parts) { return window }
        let underscoreSeparated = line.components(separatedBy: "_")
        return parseWindow(parts: underscoreSeparated)
    }

    func isMissingTmuxTargetError(_ error: Error) -> Bool {
        let description = (error as NSError).localizedDescription.lowercased()
        return description.contains("can't find session") || description.contains("can't find window")
    }

    private func parseWindow(parts: [String]) -> TmuxWindowInfo? {
        guard parts.count >= 5, let index = Int(parts[1]) else { return nil }
        return TmuxWindowInfo(
            id: parts[0], index: index, name: parts[2], sessionName: parts[3], isActive: parts[4] == "1",
            panePID: parts.count > 5 ? Int(parts[5]) : nil)
    }

    open func executablePath() -> String? { ExecutableLocator.resolve(.tmux) }

    private func run(_ arguments: [String]) throws -> Int32 {
        let command = try command(arguments)
        return try Shell.run(command)
    }

    private func runAndCapture(_ arguments: [String]) throws -> String {
        let command = try command(arguments)
        return try Shell.runAndCapture(command)
    }

    private func command(_ arguments: [String]) throws -> [String] {
        guard let executablePath = executablePath() else {
            throw NSError(domain: "spaces.tmux", code: 127, userInfo: [NSLocalizedDescriptionKey: "tmux executable not found"])
        }
        return [executablePath] + arguments
    }
}
