import AppKit
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Host hooks for the panel coordinator that don't need `AppKitController.swift`'s
/// private state; the pane content factory itself (`makeTerminalPaneContent`) lives in
/// `AppKitController.swift` beside the terminal state-model machinery it reuses.
extension AppKitController {
    /// Starts a fresh ad hoc terminal session for the panel's workspace and opens it as
    /// a new tab (the "+" button and the New-terminal shortcut).
    func openNewTerminalTab(scope: PanelScope) {
        let workspaceID: String?
        switch scope {
        case .workspace(_, let scopeWorkspaceID): workspaceID = scopeWorkspaceID
        case .globalWindow:
            // A global panel's new tab targets the focused pane's workspace.
            workspaceID = panelCoordinator.focusedSessionID().flatMap { clientWorkspaceID(forTerminalSession: $0) } ?? selectedWorkspaceID
        }
        guard let workspaceID else { return }
        createTerminalSessionForPane(workspaceID: workspaceID) { [weak self] request in
            guard let self, let request else { return }
            self.panelCoordinator.openSessionInNewTab(request, in: scope)
        }
    }

    /// Brings the panel's scope on screen: selects the workspace in the main window for
    /// a workspace scope. (Global panel windows arrive with the multi-window phase.)
    func showPanelScope(_ scope: PanelScope) {
        switch scope {
        case .workspace(_, let workspaceID):
            if selectedWorkspaceID != workspaceID, let (_, workspace) = findWorkspace(id: workspaceID) { selectWorkspace(workspace) }
            if window?.isVisible != true { window?.makeKeyAndOrderFront(nil) }
        case .globalWindow: break
        }
    }
}

// MARK: - Panel layout persistence

extension AppKitController {
    /// Persists a panel's layout to the client database so tabs/panes and the focused
    /// pane survive app relaunch. Wired to `PanelCoordinator.onLayoutChanged`.
    func persistPanelLayout(scope: PanelScope, layout: PanelLayout) {
        do {
            let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            switch scope {
            case .workspace(let deviceID, let workspaceID):
                if layout.isEmpty {
                    try clientDatabase().deleteWorkspacePanelLayout(deviceID: deviceID, workspaceID: workspaceID)
                } else {
                    try clientDatabase().writeWorkspacePanelLayout(deviceID: deviceID, workspaceID: workspaceID, layoutJSON: json)
                }
            case .globalWindow(let panelWindowID):
                if layout.isEmpty {
                    try clientDatabase().deletePanelWindow(id: panelWindowID)
                } else {
                    try clientDatabase().upsertPanelWindow(.init(id: panelWindowID, layoutJSON: json, frame: nil))
                }
            }
        } catch {
            // Persistence failures must not break live panel interaction; the layout
            // simply won't survive relaunch.
            logHotkeyDebug("persist_panel_layout_failed error=\(error.localizedDescription)")
        }
    }

    /// The pane open request for a session already known to the overview (layout
    /// restore path).
    func paneOpenRequest(workspaceID: String, sessionID: String) -> DeviceTerminalOpenRequest? {
        Self.deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: sessionID, overview: overview(forWorkspaceID: workspaceID))
    }

    /// Loads a workspace panel's persisted layout, pruned against the overview's live
    /// session catalog so dead sessions drop before the panel materializes.
    func restoredWorkspacePanelLayout(deviceID: String, workspaceID: String) -> PanelLayout? {
        guard let json = try? clientDatabase().workspacePanelLayout(deviceID: deviceID, workspaceID: workspaceID),
            let layout = try? JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8)), layout.version == PanelLayout.currentVersion
        else { return nil }
        let liveSessionIDs = Set(overview(forWorkspaceID: workspaceID)?.sessions.map(\.id) ?? [])
        return PanelLayoutEngine.prunedLayout(layout, keepingSessionIDs: liveSessionIDs)
    }
}

// MARK: - Split-fill session picker

extension AppKitController {
    /// What the pane-split session picker resolved to.
    enum SessionPickerChoice {
        case newTerminalSession(workspaceID: String)
        case existingSession(DeviceTerminalOpenRequest)
    }

    /// Presents the command palette in session-picker mode for filling a pane split and
    /// delivers the resulting open request (creating a fresh session when "New terminal
    /// session" is chosen), or nil when dismissed.
    func presentPaneSplitSessionPicker(
        scope: PanelScope, newTerminalWorkspaceID: String, completion: @escaping (DeviceTerminalOpenRequest?) -> Void
    ) {
        let presentation = sessionPickerPresentation(scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID)
        commandPalette.presentSessionPicker(
            scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID, items: presentation.items, choicesByItemID: presentation.choices
        ) { [weak self] choice in
            switch choice {
            case nil: completion(nil)
            case .existingSession(let request): completion(request)
            case .newTerminalSession(let workspaceID): self?.createTerminalSessionForPane(workspaceID: workspaceID, completion: completion)
            }
        }
    }

    /// Builds the picker rows: "New terminal session" first, then every terminal
    /// session in scope (the selected workspace's sessions, or all sessions across
    /// loaded devices for a global panel).
    func sessionPickerPresentation(scope: PanelScope, newTerminalWorkspaceID: String) -> (
        items: [CommandPaletteItem], choices: [String: SessionPickerChoice]
    ) {
        var items: [CommandPaletteItem] = []
        var choices: [String: SessionPickerChoice] = [:]

        func workspaceSummary(workspaceID: String, in overview: SpacesDeviceOverviewPayload) -> SpacesDeviceWorkspaceSummary? {
            overview.workspaces.first { $0.id == workspaceID }
        }

        func appendItem(
            id: String, workspaceID: String, workspace: SpacesDeviceWorkspaceSummary?, label: String, detail: String?,
            choice: SessionPickerChoice
        ) {
            items.append(
                CommandPaletteItem(
                    id: id, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspaceID,
                    workspaceTitle: workspace?.displayName ?? workspaceID, workspaceBranch: workspace?.branch,
                    projectTitle: workspace?.projectName ?? "", kind: .window, label: label, detail: detail, status: .none,
                    // Never executed: picker mode resolves the choice mapping instead of
                    // running a focus request.
                    focusRequest: .workspaceWindow(workspaceID: workspaceID, index: 1), recentFocusIdentity: ""))
            choices[id] = choice
        }

        let newTerminalOverview = overview(forWorkspaceID: newTerminalWorkspaceID)
        appendItem(
            id: "picker:new", workspaceID: newTerminalWorkspaceID,
            workspace: newTerminalOverview.flatMap { workspaceSummary(workspaceID: newTerminalWorkspaceID, in: $0) },
            label: "New terminal session", detail: "Start a fresh terminal", choice: .newTerminalSession(workspaceID: newTerminalWorkspaceID))

        func appendSessions(from overview: SpacesDeviceOverviewPayload, limitToWorkspaceID: String?) {
            for session in overview.sessions {
                guard let workspaceID = session.workspaceID else { continue }
                if let limitToWorkspaceID, workspaceID != limitToWorkspaceID { continue }
                guard let request = Self.deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: session.id, overview: overview) else {
                    continue
                }
                appendItem(
                    id: "picker:\(session.id)", workspaceID: workspaceID, workspace: workspaceSummary(workspaceID: workspaceID, in: overview),
                    label: session.title, detail: session.workingDirectory, choice: .existingSession(request))
            }
        }

        switch scope {
        case .workspace(_, let workspaceID):
            if let overview = overview(forWorkspaceID: workspaceID) { appendSessions(from: overview, limitToWorkspaceID: workspaceID) }
        case .globalWindow:
            for section in deviceSections where section.loadState == .loaded {
                guard let overview = section.overview else { continue }
                appendSessions(from: overview, limitToWorkspaceID: nil)
            }
        }
        return (items, choices)
    }
}
