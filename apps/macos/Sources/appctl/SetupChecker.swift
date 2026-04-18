import Foundation

/// Identifies each prerequisite check in display order.
public enum SetupCheckID: String, CaseIterable {
    case iterm2Installed
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

/// Runs prerequisite checks for Muxy dependencies (iTerm2, tmux, and yabai).
/// Injecting custom adapter subclasses enables unit testing without real apps.
public final class SetupChecker {
    private let iterm2: Iterm2Adapter
    private let tmux: TmuxAdapter

    public init(iterm2: Iterm2Adapter = Iterm2Adapter(), tmux: TmuxAdapter = TmuxAdapter()) {
        self.iterm2 = iterm2
        self.tmux = tmux
    }

    /// Runs a single check and returns whether it passed.
    public func run(_ id: SetupCheckID) -> Bool {
        switch id {
        case .iterm2Installed:
            return isIterm2Installed()
        case .tmuxInstalled:
            return isTmuxInstalled()
        case .yabaiInstalled:
            return isYabaiInstalled()
        case .yabaiServiceRunning:
            return isYabaiServiceRunning()
        case .yabaiAccessibility:
            return hasYabaiAccessibility()
        }
    }

    /// Runs all checks in display order and returns results.
    public func runAll() -> [SetupCheckResult] {
        SetupCheckID.allCases.map { id in SetupCheckResult(id: id, passed: run(id)) }
    }

    // MARK: - Individual checks

    private func isIterm2Installed() -> Bool {
        iterm2.isAvailable()
    }

    private func isTmuxInstalled() -> Bool {
        tmux.isAvailable()
    }

    private func isYabaiInstalled() -> Bool {
        (try? Shell.runAndCapture(["yabai", "--version"])) != nil
    }

    private func isYabaiServiceRunning() -> Bool {
        guard let output = try? Shell.runAndCapture(["yabai", "-m", "query", "--spaces"]) else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[")
    }

    private func hasYabaiAccessibility() -> Bool {
        guard let output = try? Shell.runAndCapture(["yabai", "-m", "query", "--windows"]) else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty array means AX is not granted; Finder always has windows when permission is granted.
        return trimmed != "[]" && trimmed.hasPrefix("[")
    }
}
