import AppKit
import spacesdevicecore

extension AppKitController {
    /// The toggle for the pane `scope`'s chrome names (the workspace's focused pane, or a global window's
    /// strip pane), resolved on the device that owns its session.
    func comeBackLaterToggle(scope: PanelScope) -> (toggle: ComeBackLaterToggle, deviceID: String)? {
        guard let sessionID = panelCoordinator.briefToggleSessionID(scope: scope), let deviceID = deviceID(forSessionID: sessionID),
            let overview = deviceSection(id: deviceID)?.overview, let toggle = ComeBackLaterToggle.forSession(sessionID, in: overview)
        else { return nil }
        return (toggle, deviceID)
    }

    func focusedPaneComeBackLaterToggle(workspaceID: String) -> ComeBackLaterToggle? {
        guard let deviceID = deviceID(forWorkspaceID: workspaceID) else { return nil }
        return comeBackLaterToggle(scope: .workspace(deviceID: deviceID, workspaceID: workspaceID))?.toggle
    }

    /// Flips the mark on the row `scope`'s pane shows. Returns false when there is nothing to flip, so a
    /// shortcut leaves the chord unclaimed.
    @discardableResult func toggleComeBackLater(scope: PanelScope) -> Bool {
        guard let (toggle, deviceID) = comeBackLaterToggle(scope: scope), toggle.hasStarted, deviceAcceptsDaemonActions(forDeviceID: deviceID) else {
            return false
        }
        setComeBackLater(rowKind: toggle.rowKind, rowID: toggle.rowID, isOn: !toggle.isOn, deviceID: deviceID)
        return true
    }

    /// The configured Come Back Later shortcut (default leader+L), acting on the same pane the brief
    /// shortcut does.
    func handleToggleComeBackLaterShortcut(event: NSEvent) -> Bool {
        guard let spec = shortcuts.toggleComeBackLaterShortcutSpec, shortcuts.matches(event: event, spec: spec) else { return false }
        if let panelWindowID = panelCoordinator.panelWindowID(forWindow: NSApp.keyWindow) {
            return toggleComeBackLater(scope: .globalWindow(panelWindowID: panelWindowID))
        }
        guard NSApp.keyWindow === window, let workspaceID = selectedWorkspaceID, let deviceID = deviceID(forWorkspaceID: workspaceID) else {
            return false
        }
        return toggleComeBackLater(scope: .workspace(deviceID: deviceID, workspaceID: workspaceID))
    }

    /// The workspace footer glyph and the ⋯ menu item. Both carry the workspace id and act on its panel's
    /// focused pane.
    @objc func toggleWorkspaceFocusedPaneComeBackLater(_ sender: Any) {
        guard let workspaceID = Self.senderIdentifier(sender), let deviceID = deviceID(forWorkspaceID: workspaceID) else { return }
        toggleComeBackLater(scope: .workspace(deviceID: deviceID, workspaceID: workspaceID))
    }

    /// Flips the mark on a sidebar runtime-target row.
    func toggleSidebarRuntimeTargetComeBackLater(workspaceID: String, item: SidebarRuntimeTargetItem) {
        guard let toggle = item.comeBackLater, toggle.hasStarted, let deviceID = deviceID(forWorkspaceID: workspaceID),
            deviceAcceptsDaemonActions(forDeviceID: deviceID)
        else { return }
        setComeBackLater(rowKind: toggle.rowKind, rowID: toggle.rowID, isOn: !toggle.isOn, deviceID: deviceID)
    }
}
