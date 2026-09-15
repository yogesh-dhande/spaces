import Foundation

/// What the sidebar's cycling row and the mode-change HUD say about the cycling mode in effect.
///
/// Pure, so the row, the overlay, and the tests all read one description of the same state. The
/// counts come from the target-set builders the cycle itself walks, so the number on the row is the
/// number of windows the next press can land on.
struct CycleModeRowModel: Equatable, Sendable {
    let mode: WindowCycleMode
    /// How many targets the mode's set holds right now.
    let count: Int
    /// How many devices contribute a target to that set. Workspace mode leaves it at the one device
    /// the selected workspace lives on, since its summary names the workspace instead.
    let deviceCount: Int
    /// The resolved workspace's display name, which Workspace mode's summary names. Nil when no
    /// workspace resolves, which is also when that mode has nothing to cycle.
    let workspaceName: String?

    var isEmpty: Bool { count == 0 }

    /// The count slot on the sidebar row. An empty Alerts set is the one state worth spelling out
    /// there: a bare "0" beside "Alerts" reads as a broken count rather than as the good news that
    /// nothing is asking for the user.
    var countText: String {
        if mode == .alerts, isEmpty { return "no alerts" }
        return "\(count)"
    }

    /// Read by the window-cycle E2E out of the row's accessibility label, so the mode and the count
    /// are both assertable without screen scraping.
    var accessibilityLabel: String { "Cycling \(mode.displayName), \(countText)" }

    /// The HUD's one summary line under the mode name: what the mode's set currently holds, in the
    /// terms that mode is about.
    var hudSummary: String {
        switch mode {
        case .workspace:
            guard let workspaceName else { return "no workspace selected" }
            if isEmpty { return "no windows in \(workspaceName)" }
            return "\(count) \(Self.pluralized("window", count)) in \(workspaceName)"
        case .alerts:
            if isEmpty { return "no alerts" }
            return "\(count) \(Self.pluralized("alert", count)) across \(deviceCount) \(Self.pluralized("device", deviceCount))"
        case .allAgents:
            if isEmpty { return "no agents" }
            return "\(count) \(Self.pluralized("agent", count)) across \(deviceCount) \(Self.pluralized("device", deviceCount))"
        case .openSessions:
            if isEmpty { return "no open sessions" }
            return "\(count) open \(Self.pluralized("session", count))"
        }
    }

    private static func pluralized(_ noun: String, _ count: Int) -> String { count == 1 ? noun : "\(noun)s" }

    /// The one-line description each mode carries as its menu item's tooltip.
    static func menuItemDescription(for mode: WindowCycleMode) -> String {
        switch mode {
        case .workspace: return "The open windows of the workspace the cycle resolves from what is focused."
        case .alerts: return "Everything in Alerts on any device that has a window: exited processes, agents waiting or done, and bells."
        case .allAgents: return "Coding agents on any device that have been launched and have not exited."
        case .openSessions: return "Every open terminal pane and open browser session, on any device."
        }
    }
}
