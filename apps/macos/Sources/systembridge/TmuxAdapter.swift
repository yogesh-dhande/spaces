import Foundation

open class TmuxAdapter: @unchecked Sendable {
    private let windowFormat = "#{window_id}\t#{window_index}\t#{window_name}\t#{session_name}\t#{window_active}\t#{pane_pid}"

    public init() {}

    open func isAvailable() -> Bool { (try? Shell.runAndCapture(["tmux", "-V"])) != nil }

    open func hasSession(named sessionName: String) -> Bool { (try? Shell.runAndCapture(["tmux", "has-session", "-t", sessionName])) != nil }

    open func killSession(named sessionName: String) throws { _ = try Shell.run(["tmux", "kill-session", "-t", sessionName]) }

    open func listWindows(sessionName: String) throws -> [TmuxWindowInfo] {
        guard hasSession(named: sessionName) else { return [] }
        let output = try Shell.runAndCapture(["tmux", "list-windows", "-t", sessionName, "-F", windowFormat])
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parseWindow(line: String($0)) }
    }

    open func currentWindow(sessionName: String) throws -> TmuxWindowInfo? {
        guard hasSession(named: sessionName) else { return nil }
        let output = try Shell.runAndCapture(["tmux", "display-message", "-p", "-t", sessionName, windowFormat])
        return parseWindow(line: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    open func currentWindow() throws -> TmuxWindowInfo? {
        let output = try Shell.runAndCapture(["tmux", "display-message", "-p", windowFormat])
        return parseWindow(line: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    open func createWindow(sessionName: String, name: String, command: String? = nil, detached: Bool = true) throws -> TmuxWindowInfo {
        var arguments = ["tmux", "new-window"]
        if detached { arguments.append("-d") }
        arguments += ["-P", "-F", windowFormat, "-t", sessionName, "-n", name]
        if let command, !command.isEmpty { arguments.append(command) }
        let output = try Shell.runAndCapture(arguments)
        guard let window = parseWindow(line: output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "spaces.tmux", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create tmux window."])
        }
        return window
    }

    open func startSession(named sessionName: String, windowName: String, cwd: String, env: [String: String] = [:], command: [String]) throws
        -> TmuxWindowInfo
    {
        var arguments = ["tmux", "new-session", "-d", "-P", "-F", windowFormat, "-s", sessionName, "-n", windowName, "-c", cwd]
        for (key, value) in env.sorted(by: { $0.key < $1.key }) { arguments += ["-e", "\(key)=\(value)"] }
        arguments.append(contentsOf: command)
        let output = try Shell.runAndCapture(arguments)
        guard let window = parseWindow(line: output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "spaces.tmux", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create tmux session."])
        }
        return window
    }

    open func renameWindow(windowID: String, name: String) throws { _ = try Shell.run(["tmux", "rename-window", "-t", windowID, name]) }

    open func respawnWindow(windowID: String, command: String) throws {
        _ = try Shell.run(["tmux", "respawn-window", "-k", "-t", windowID, command])
    }

    open func setRemainOnExit(windowID: String, enabled: Bool) throws {
        _ = try Shell.run(["tmux", "set-option", "-t", windowID, "remain-on-exit", enabled ? "on" : "off"])
    }

    open func selectWindow(windowID: String) throws -> Bool { (try? Shell.run(["tmux", "select-window", "-t", windowID])) == 0 }

    open func killWindow(windowID: String) throws { _ = try Shell.run(["tmux", "kill-window", "-t", windowID]) }

    private func parseWindow(line: String) -> TmuxWindowInfo? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5, let index = Int(parts[1]) else { return nil }
        return TmuxWindowInfo(
            id: parts[0], index: index, name: parts[2], sessionName: parts[3], isActive: parts[4] == "1",
            panePID: parts.count > 5 ? Int(parts[5]) : nil)
    }
}
