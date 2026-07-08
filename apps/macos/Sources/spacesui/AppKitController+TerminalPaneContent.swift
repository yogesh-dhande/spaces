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
        guard pendingNewTerminalPaneScopes.insert(scope).inserted else { return }
        createTerminalSessionForPane(workspaceID: workspaceID) { [weak self] request in
            guard let self else { return }
            defer { self.pendingNewTerminalPaneScopes.remove(scope) }
            guard let request else { return }
            self.panelCoordinator.openSessionInNewTab(request, in: scope)
        }
    }

    /// Brings the panel's scope on screen: selects the workspace in the main window for
    /// a workspace scope, or fronts the global panel's own window.
    func showPanelScope(_ scope: PanelScope) {
        switch scope {
        case .workspace(_, let workspaceID):
            if selectedWorkspaceID != workspaceID, let (_, workspace) = findWorkspace(id: workspaceID) { selectWorkspace(workspace) }
            // Explicitly focusing/opening a workspace terminal (sidebar row, numbered shortcut,
            // window cycle, `open`/`focus-workspace-process`) must bring Spaces to the foreground,
            // mirroring how focusing a browser target activates Chrome. Post-panel-rework the
            // terminal is a pane inside the main window, so an already-visible-but-backgrounded
            // window would otherwise stay behind the frontmost app — leaving `NSApp.isActive`
            // false, which makes global window-cycle navigation unable to resolve the focused
            // terminal as the current target (`focusedBuiltInTerminalSessionIDForGlobalNavigation`).
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        case .globalWindow(let panelWindowID):
            // Same reasoning as the workspace case: fronting a global panel (e.g. a
            // `spaces terminal show <id>` for a workspace-less session) must foreground
            // Spaces, otherwise `makeKeyAndOrderFront` leaves the panel window behind the
            // frontmost app when Spaces is backgrounded and the IPC still reports success.
            NSApp.activate(ignoringOtherApps: true)
            panelCoordinator.showPanelWindow(panelWindowID: panelWindowID, makeKey: true)
        }
    }

    /// Moves a sidebar runtime target's terminal session into its own panel window
    /// (the "Open in New Window" context-menu action).
    func openSidebarRuntimeTargetInNewWindow(workspaceID: String, item: SidebarRuntimeTargetItem) {
        guard let sessionID = item.sessionID, let request = paneOpenRequest(workspaceID: workspaceID, sessionID: sessionID) else { return }
        panelCoordinator.moveSessionToNewPanelWindow(request)
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
                    try clientDatabase().upsertPanelWindow(
                        .init(id: panelWindowID, layoutJSON: json, frame: panelCoordinator.panelWindowFrame(panelWindowID: panelWindowID)))
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

// MARK: - Panel window startup reopen

extension AppKitController {
    /// What to do with one persisted `panel_windows` row during startup reopen.
    enum PanelWindowRestoreDecision: Equatable {
        /// Some referenced device has no loaded overview yet — keep the row pending.
        case waitForDevices
        /// The row can't be interpreted (decode failure or a future layout version) —
        /// leave the row in the database untouched and stop considering it this launch.
        case skip
        /// Every referenced device is loaded and no session survived pruning — the
        /// window has nothing to show, delete the row.
        case discard
        /// Open a window with this pruned layout.
        case open(PanelLayout)
    }

    nonisolated static func panelWindowRestoreDecision(layoutJSON: String, loadedDeviceIDs: Set<String>, liveSessionIDs: Set<String>)
        -> PanelWindowRestoreDecision
    {
        guard let layout = try? JSONDecoder().decode(PanelLayout.self, from: Data(layoutJSON.utf8)), layout.version == PanelLayout.currentVersion
        else { return .skip }
        let referencedDeviceIDs = Set(
            PanelLayoutEngine.allPanes(in: layout).map { pane in
                switch pane.content {
                case .terminalSession(let deviceID, _): deviceID
                }
            })
        guard referencedDeviceIDs.isSubset(of: loadedDeviceIDs) else { return .waitForDevices }
        let pruned = PanelLayoutEngine.prunedLayout(layout, keepingSessionIDs: liveSessionIDs)
        return pruned.isEmpty ? .discard : .open(pruned)
    }

    /// Reopens persisted global panel windows eagerly once possible. Called after
    /// every device-section load; each row waits for the devices its panes reference
    /// (a wire-incompatible or offline device has no overview, so its rows are never
    /// pruned against an empty catalog and destroyed — they simply stay pending).
    func reopenPersistedPanelWindowsIfPossible() {
        if pendingPanelWindowRestores == nil { pendingPanelWindowRestores = (try? clientDatabase().panelWindows()) ?? [] }
        guard let pending = pendingPanelWindowRestores, !pending.isEmpty else { return }
        let readySections = deviceSections.filter { $0.loadState == .loaded && $0.overview != nil }
        let loadedDeviceIDs = Set(readySections.map(\.deviceID))
        let liveSessionIDs = Set(readySections.flatMap { $0.overview?.sessions.map(\.id) ?? [] })
        var remaining: [SpacesClientDatabase.PanelWindowRecord] = []
        for record in pending {
            switch Self.panelWindowRestoreDecision(layoutJSON: record.layoutJSON, loadedDeviceIDs: loadedDeviceIDs, liveSessionIDs: liveSessionIDs) {
            case .waitForDevices: remaining.append(record)
            case .skip: break
            case .discard: try? clientDatabase().deletePanelWindow(id: record.id)
            case .open(let layout):
                let frame = record.frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                panelCoordinator.restorePanelWindow(panelWindowID: record.id, layout: layout, frame: frame)
            }
        }
        pendingPanelWindowRestores = remaining
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
    func presentPaneSplitSessionPicker(scope: PanelScope, newTerminalWorkspaceID: String, completion: @escaping (DeviceTerminalOpenRequest?) -> Void)
    {
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
            id: String, workspaceID: String, workspace: SpacesDeviceWorkspaceSummary?, label: String, detail: String?, choice: SessionPickerChoice
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
            workspace: newTerminalOverview.flatMap { workspaceSummary(workspaceID: newTerminalWorkspaceID, in: $0) }, label: "New terminal session",
            detail: "Start a fresh terminal", choice: .newTerminalSession(workspaceID: newTerminalWorkspaceID))

        func appendSessions(from overview: SpacesDeviceOverviewPayload, limitToWorkspaceID: String?) {
            for session in overview.sessions {
                let workspaceID = session.workspaceID
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
