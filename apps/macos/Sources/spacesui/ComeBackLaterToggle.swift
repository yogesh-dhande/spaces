import AppKit
import spacesdevicecore
import workspacecore

/// Where one row's Come Back Later mark stands for the surfaces that toggle it (the workspace footer
/// glyph, the pane and sidebar menu items, and the shortcut).
struct ComeBackLaterToggle: Hashable, Sendable {
    let rowKind: SpacesDeviceComeBackLaterRowKind
    let rowID: String
    let isOn: Bool
    /// False for a row that has never started: there is no terminal to come back to yet.
    let hasStarted: Bool

    /// The action a menu item offers: the opposite of the current state.
    var menuTitle: String { isOn ? "Remove from Alerts" : "Come Back Later" }
    var footerTooltip: String { isOn ? "Remove from Alerts" : "Come back later: keep this terminal in Alerts until you return" }

    /// The row a pane showing `sessionID` stands for on the device: its agent row, else its process row,
    /// else its terminal row. Nil when no row shows the session (a loose session has no row to mark).
    static func forSession(_ sessionID: String, in overview: SpacesDeviceOverviewPayload) -> ComeBackLaterToggle? {
        func toggle(_ kind: SpacesDeviceComeBackLaterRowKind, rowID: String, runState: SpacesDeviceRunState) -> ComeBackLaterToggle {
            ComeBackLaterToggle(
                rowKind: kind, rowID: rowID, isOn: overview.comeBackLaterFlags.contains { $0.rowKind == kind && $0.rowID == rowID },
                hasStarted: runState != .notStarted)
        }
        let workspaces = overview.workspaces
        if let row = workspaces.lazy.flatMap(\.codingAgentRows).first(where: { $0.sessionID == sessionID }) {
            return toggle(.agent, rowID: row.id, runState: row.runState)
        }
        if let row = workspaces.lazy.flatMap(\.processRows).first(where: { $0.sessionID == sessionID }) {
            return toggle(.process, rowID: row.id, runState: row.runState)
        }
        if let row = workspaces.lazy.flatMap(\.terminalRows).first(where: { $0.sessionID == sessionID }) {
            return toggle(.terminal, rowID: row.id, runState: row.runState)
        }
        return nil
    }

    /// A menu item for the toggle. It stays listed when there is nothing to toggle or the device cannot
    /// act, and is disabled then, so the menu keeps one shape.
    @MainActor static func menuItem(
        _ toggle: ComeBackLaterToggle?, shortcut: HotkeySpec?, isEnabled: Bool, target: AnyObject?, action: Selector, identifier: String? = nil
    ) -> NSMenuItem {
        // A key with no single-character menu form (an arrow, say) is shown without one and still works
        // through the key monitor.
        let keyEquivalent = shortcut?.menuKeyEquivalent
        let item = NSMenuItem(title: toggle?.menuTitle ?? "Come Back Later", action: action, keyEquivalent: keyEquivalent?.key ?? "")
        item.keyEquivalentModifierMask = keyEquivalent?.modifiers ?? []
        item.target = target
        item.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)
        item.isEnabled = isEnabled && toggle?.hasStarted == true
        if let identifier { item.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return item
    }
}

extension NSButton {
    /// Renders the footer glyph for `toggle`: absent when no row shows the pane's session, accent while
    /// the row is marked, muted otherwise, and disabled while the row has not started or the device
    /// cannot act.
    func applyComeBackLaterToggle(_ toggle: ComeBackLaterToggle?, deviceAcceptsActions: Bool) {
        isHidden = toggle == nil
        contentTintColor = toggle?.isOn == true ? Theme.accent : Theme.muted
        isEnabled = deviceAcceptsActions && toggle?.hasStarted == true
        alphaValue = deviceAcceptsActions ? 1 : AppKitController.unreachableDeviceAlpha
        toolTip = toggle?.footerTooltip
        setAccessibilityLabel(toggle?.menuTitle)
    }
}
