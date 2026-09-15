import Foundation

/// Which set of windows the next/previous window shortcuts rotate over.
///
/// Case order is the order the cycle-mode shortcut steps through, and the raw values are a stored
/// format rather than display text: they persist in the client database under
/// `ClientSettingsKey.windowCycleMode` and appear as `mode=` on the `window_cycle` perf line.
enum WindowCycleMode: String, CaseIterable, Sendable {
    /// The windows of the one workspace the cycle resolves from what is focused.
    case workspace
    /// Everything the Alerts pane lists that has a window to land in, on any device.
    case alerts
    /// Coding agents on any device that have been launched and have not exited.
    case allAgents
    /// Open terminal-backed panes and open browser sessions on any device.
    case openSessions

    var displayName: String {
        switch self {
        case .workspace: return "Workspace"
        case .alerts: return "Alerts"
        case .allAgents: return "All agents"
        case .openSessions: return "Open sessions"
        }
    }

    /// The mode the cycle-mode shortcut steps to, wrapping past the last one.
    var next: WindowCycleMode {
        let cases = Self.allCases
        let index = cases.firstIndex(of: self) ?? 0
        return cases[(index + 1) % cases.count]
    }

    /// The mode a stored setting selects. A value this build cannot parse is not a preference it can
    /// honor, so it reads as the Workspace default, the same as an unset value.
    static func resolved(persistedRawValue: String?) -> WindowCycleMode { persistedRawValue.flatMap(WindowCycleMode.init(rawValue:)) ?? .workspace }
}
