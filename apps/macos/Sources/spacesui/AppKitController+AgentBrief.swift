import AppKit
import spacesdevicecore

extension AppKitController {
    /// The coding-agent row whose session is `sessionID`, from the overview of the device owning
    /// `workspaceID`. It carries the agent's brief.
    func codingAgentRow(forSessionID sessionID: String, workspaceID: String) -> SpacesDeviceWorkspaceCodingAgentRow? {
        overview(forWorkspaceID: workspaceID)?.workspaces.first { $0.id == workspaceID }?.codingAgentRows.first { $0.sessionID == sessionID }
    }

    /// The brief toggle state of `workspaceID`'s focused pane, which the footer glyph and the ⋯ menu
    /// item draw. A workspace with no known owning device has no panel, so nothing to toggle.
    func focusedPaneBriefToggleState(workspaceID: String) -> AgentBriefToggleState {
        guard let deviceID = deviceID(forWorkspaceID: workspaceID) else { return .unavailable }
        return panelCoordinator.agentBriefToggleState(scope: .workspace(deviceID: deviceID, workspaceID: workspaceID))
    }

    /// ⌥⌘B: shows or hides the focused pane's brief. A global panel window acts on the pane its identity
    /// strip shows; the main window acts on the selected workspace's focused pane. A pane with no brief
    /// leaves the chord unclaimed.
    func handleToggleBriefShortcut(event: NSEvent) -> Bool {
        guard
            Self.isToggleBriefShortcut(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                eventModifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        else { return false }
        if let panelWindowID = panelCoordinator.panelWindowID(forWindow: NSApp.keyWindow) {
            return panelCoordinator.toggleAgentBrief(scope: .globalWindow(panelWindowID: panelWindowID))
        }
        guard NSApp.keyWindow === window, let workspaceID = selectedWorkspaceID, let deviceID = deviceID(forWorkspaceID: workspaceID) else {
            return false
        }
        return panelCoordinator.toggleAgentBrief(scope: .workspace(deviceID: deviceID, workspaceID: workspaceID))
    }

    /// ⌥⌘B exactly, so a chord that adds Shift or Control stays with the terminal.
    nonisolated static func isToggleBriefShortcut(charactersIgnoringModifiers: String?, eventModifiers: NSEvent.ModifierFlags) -> Bool {
        guard charactersIgnoringModifiers?.lowercased() == "b" else { return false }
        return eventModifiers.intersection([.command, .option, .control, .shift]) == [.command, .option]
    }

    /// The workspace footer's brief glyph and the ⋯ menu's Hide/Show Brief item. Both carry the
    /// workspace id and act on its panel's focused pane.
    @objc func toggleWorkspaceFocusedPaneBrief(_ sender: Any) {
        guard let workspaceID = Self.senderIdentifier(sender), let deviceID = deviceID(forWorkspaceID: workspaceID) else { return }
        panelCoordinator.toggleAgentBrief(scope: .workspace(deviceID: deviceID, workspaceID: workspaceID))
    }
}
