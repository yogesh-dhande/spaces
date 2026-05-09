import Foundation

private let setupProfileEnabled = ProcessInfo.processInfo.environment["SPACES_STARTUP_PROFILE"] == "1"

/// Identifies each prerequisite check in display order.
public enum SetupCheckID: String, CaseIterable, Sendable {
    case terminalInstalled
    case tmuxInstalled
    case yabaiInstalled
    case yabaiServiceRunning
    case yabaiAccessibility
}

/// The result of a single prerequisite check.
public struct SetupCheckResult {
    public let id: SetupCheckID
    public let passed: Bool

    public init(id: SetupCheckID, passed: Bool) {
        self.id = id
        self.passed = passed
    }
}

/// Runs prerequisite checks for Spaces dependencies and optional external hosts.
/// Injecting custom adapter subclasses enables unit testing without real apps.
public final class SetupChecker {
    public static var startupBlockingCheckIDs: [SetupCheckID] { [.tmuxInstalled, .yabaiInstalled] }

    private let iterm2: Iterm2Adapter
    private let ghostty: GhosttyAdapter
    private let tmux: TmuxAdapter

    public init(iterm2: Iterm2Adapter = Iterm2Adapter(), ghostty: GhosttyAdapter = GhosttyAdapter(), tmux: TmuxAdapter = TmuxAdapter()) {
        self.iterm2 = iterm2
        self.ghostty = ghostty
        self.tmux = tmux
    }

    /// Runs a single check and returns whether it passed.
    public func run(_ id: SetupCheckID) -> Bool {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let passed =
            switch id {
            case .terminalInstalled: isTerminalInstalled()
            case .tmuxInstalled: isTmuxInstalled()
            case .yabaiInstalled: isYabaiInstalled()
            case .yabaiServiceRunning: isYabaiServiceRunning()
            case .yabaiAccessibility: hasYabaiAccessibility()
            }
        logSetupCheckProfile(id: id, passed: passed, startedAt: startedAt)
        return passed
    }

    /// Runs all checks in display order and returns results.
    public func runAll() -> [SetupCheckResult] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let results = run(SetupCheckID.allCases)
        if setupProfileEnabled {
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            fputs("spaces: setup_check stage=run_all elapsed_ms=\(elapsedMS)\n", stderr)
        }
        return results
    }

    /// Runs only the checks that should block initial app launch.
    public func runStartupBlockingChecks() -> [SetupCheckResult] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let results = run(Self.startupBlockingCheckIDs)
        if setupProfileEnabled {
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            fputs("spaces: setup_check stage=startup_blocking elapsed_ms=\(elapsedMS)\n", stderr)
        }
        return results
    }

    private func run(_ ids: [SetupCheckID]) -> [SetupCheckResult] { ids.map { id in SetupCheckResult(id: id, passed: run(id)) } }

    // MARK: - Individual checks

    public func isTerminalHostAvailable(named host: String) -> Bool {
        switch host.lowercased() {
        case "spaces": true
        case "iterm2": iterm2.isAvailable()
        case "ghostty": ghostty.isAvailable()
        default: false
        }
    }

    private func isTerminalInstalled() -> Bool { true }

    private func isTmuxInstalled() -> Bool { tmux.isAvailable() }

    private func isYabaiInstalled() -> Bool {
        guard let yabai = ExecutableLocator.resolve(.yabai) else { return false }
        return (try? Shell.runAndCapture([yabai, "--version"])) != nil
    }

    private func isYabaiServiceRunning() -> Bool {
        guard let yabai = ExecutableLocator.resolve(.yabai) else { return false }
        guard (try? Shell.runAndCapture([yabai, "-m", "signal", "--list"])) != nil else { return false }
        return true
    }

    private func hasYabaiAccessibility() -> Bool {
        guard let yabai = ExecutableLocator.resolve(.yabai) else { return false }
        guard let output = try? Shell.runAndCapture([yabai, "-m", "query", "--windows"]) else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty array means AX is not granted; Finder always has windows when permission is granted.
        return trimmed != "[]" && trimmed.hasPrefix("[")
    }

    private func logSetupCheckProfile(id: SetupCheckID, passed: Bool, startedAt: TimeInterval) {
        guard setupProfileEnabled else { return }
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        fputs("spaces: setup_check id=\(id.rawValue) elapsed_ms=\(elapsedMS) passed=\(passed ? 1 : 0)\n", stderr)
    }
}
