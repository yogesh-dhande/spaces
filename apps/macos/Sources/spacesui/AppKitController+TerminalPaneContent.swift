import AppKit
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Host hooks for the panel coordinator that don't need `AppKitController.swift`'s
/// private state; the pane content factory itself (`makeTerminalPaneContent`) lives in
/// `AppKitController.swift` beside the terminal state-model machinery it reuses.
extension AppKitController {
    /// The workspace a fresh terminal session in `scope` belongs to: the panel's own
    /// workspace for a workspace scope, or the focused pane's workspace (falling back to
    /// the selected workspace) for a global panel window.
    private func newTerminalWorkspaceID(for scope: PanelScope) -> String? {
        switch scope {
        case .workspace(_, let scopeWorkspaceID): return scopeWorkspaceID
        case .globalWindow:
            // A global panel's new tab targets the focused pane's workspace.
            return panelCoordinator.focusedSessionID().flatMap { clientWorkspaceID(forTerminalSession: $0) } ?? selectedWorkspaceID
        }
    }

    /// Starts a fresh ad hoc terminal session for the panel's workspace and opens it as
    /// a new tab (the leader `New terminal` shortcut, direct creation with no picker).
    func openNewTerminalTab(scope: PanelScope) {
        guard let workspaceID = newTerminalWorkspaceID(for: scope) else { return }
        guard beginNewTerminalSessionCreation(workspaceID: workspaceID) else { return }
        createTerminalSessionForPane(workspaceID: workspaceID) { [weak self] request in
            guard let self else { return }
            defer { self.finishNewTerminalSessionCreation(workspaceID: workspaceID) }
            guard let request else { return }
            self.panelCoordinator.openSessionInNewTab(request, in: scope)
        }
    }

    /// Picker-backed new tab (⌘T and the workspace tab strip's "+"): choose a
    /// not-yet-open target or create a fresh session; the result lands as a new
    /// selected, focused tab in the workspace's panel. Only `.workspace` scopes reach
    /// this (a panel window's "+" creates directly), so the request's workspace panel
    /// and `scope` are the same panel — the completion routes through the
    /// open-or-focus chokepoint rather than appending unconditionally, so a session
    /// that opened elsewhere while the picker was up (panel-window restore, IPC)
    /// focuses its existing pane instead of duplicating it.
    func presentNewTabSessionPicker(scope: PanelScope) {
        guard let workspaceID = newTerminalWorkspaceID(for: scope) else { return }
        presentPaneSessionPicker(scope: scope, newTerminalWorkspaceID: workspaceID) { [weak self] request in
            guard let self, let request else { return }
            self.panelCoordinator.openOrFocusTerminalPane(request)
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

    /// Loads a workspace panel's persisted layout, pruned against the owning daemon's retained
    /// terminal-session keep-set so dead sessions drop before the panel materializes. Uses the same
    /// contract as live pruning (`OpenPanePruning.restorationKeepSet`), so an ended-but-retained shell
    /// survives relaunch exactly as it survives a live overview refresh.
    func restoredWorkspacePanelLayout(deviceID: String, workspaceID: String) -> PanelLayout? {
        guard let json = try? clientDatabase().workspacePanelLayout(deviceID: deviceID, workspaceID: workspaceID),
            let layout = try? JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8)), layout.version == PanelLayout.currentVersion
        else { return nil }
        let retainedSessionIDs = OpenPanePruning.restorationKeepSet(overview: overview(forWorkspaceID: workspaceID))
        return PanelLayoutEngine.prunedLayout(layout, keepingSessionIDs: retainedSessionIDs)
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

    nonisolated static func panelWindowRestoreDecision(layoutJSON: String, loadedDeviceIDs: Set<String>, retainedSessionIDs: Set<String>)
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
        let pruned = PanelLayoutEngine.prunedLayout(layout, keepingSessionIDs: retainedSessionIDs)
        return pruned.isEmpty ? .discard : .open(pruned)
    }

    /// Reopens persisted global panel windows eagerly once possible. Called after
    /// every device-section load; each row waits for the devices its panes reference.
    /// A device that is not loaded is never ready: a pane needs a live daemon to attach
    /// its session to, so an unreachable device's panes stay pending for the outage even
    /// though it keeps its overview — and because the record is only ever deferred, its
    /// panes are never pruned against a catalog the outage made unavailable.
    func reopenPersistedPanelWindowsIfPossible() {
        if pendingPanelWindowRestores == nil { pendingPanelWindowRestores = (try? clientDatabase().panelWindows()) ?? [] }
        guard let pending = pendingPanelWindowRestores, !pending.isEmpty else { return }
        let readySections = deviceSections.filter { $0.loadState == .loaded && $0.overview != nil }
        let loadedDeviceIDs = Set(readySections.map(\.deviceID))
        let retainedSessionIDs = OpenPanePruning.restorationKeepSet(overviews: readySections.map(\.overview))
        var remaining: [SpacesClientDatabase.PanelWindowRecord] = []
        for record in pending {
            switch Self.panelWindowRestoreDecision(
                layoutJSON: record.layoutJSON, loadedDeviceIDs: loadedDeviceIDs, retainedSessionIDs: retainedSessionIDs)
            {
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
        /// A configured process that isn't running yet (its sidebar row is "not started"):
        /// picking it starts the process via the Device API and completes with the resulting
        /// session's open request. Mirrors `DeviceWindowShortcutResolution.runProcess`.
        case startProcess(workspaceID: String, processKey: String, processTemplateID: String?)
        /// An agent launcher that hasn't been started: picking it launches the agent via the
        /// Device API and completes with the resulting session's open request. Mirrors
        /// `DeviceWindowShortcutResolution.runCodingAgent`.
        case startCodingAgent(workspaceID: String, agentName: String, agentLauncherID: String?)
    }

    /// Presents the command palette in session-picker mode for filling a pane split or
    /// opening a new tab, and delivers the resulting open request (creating a fresh
    /// session when "New terminal session" is chosen), or nil when dismissed.
    func presentPaneSessionPicker(scope: PanelScope, newTerminalWorkspaceID: String, completion: @escaping (DeviceTerminalOpenRequest?) -> Void) {
        let presentation = sessionPickerPresentation(scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID)
        commandPalette.presentSessionPicker(
            scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID, items: presentation.items, choicesByItemID: presentation.choices
        ) { [weak self] choice in
            switch choice {
            case nil: completion(nil)
            case .existingSession(let request): completion(request)
            case .newTerminalSession(let workspaceID):
                guard let self else {
                    completion(nil)
                    return
                }
                guard self.beginNewTerminalSessionCreation(workspaceID: workspaceID) else {
                    completion(nil)
                    return
                }
                self.createTerminalSessionForPane(workspaceID: workspaceID) { [weak self] request in
                    guard let self else { return }
                    defer { self.finishNewTerminalSessionCreation(workspaceID: workspaceID) }
                    completion(request)
                }
            case .startProcess(let workspaceID, let processKey, let processTemplateID):
                guard let self else {
                    completion(nil)
                    return
                }
                Task { @MainActor in
                    completion(
                        await self.runTerminalSessionMutation(workspaceID: workspaceID) { device in
                            try SpacesDeviceClient.runWorkspaceProcess(
                                workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID, device: device,
                                clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                        })
                }
            case .startCodingAgent(let workspaceID, let agentName, let agentLauncherID):
                guard let self else {
                    completion(nil)
                    return
                }
                Task { @MainActor in
                    completion(
                        await self.runTerminalSessionMutation(workspaceID: workspaceID) { device in
                            try SpacesDeviceClient.runCodingAgent(
                                workspaceID: workspaceID, agentName: agentName, agentLauncherID: agentLauncherID, device: device,
                                clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                        })
                }
            }
        }
    }

    /// One workspace's row-building inputs for the session picker: the workspace id and
    /// the overview that owns it. The static core derives the sidebar detail model and
    /// runtime targets from these, so a global-window scope simply lists more of them.
    struct SessionPickerWorkspaceContext: Sendable {
        let workspaceID: String
        let overview: SpacesDeviceOverviewPayload
    }

    /// Builds the picker rows: "New terminal session" first, then the scope's sidebar
    /// runtime targets that aren't already open in a pane, in sidebar order. A workspace
    /// scope lists one workspace's targets; a global panel window lists every loaded
    /// device's workspaces in the same order the command palette walks them. Gathers the
    /// ordered workspace contexts and the pane occupancy set, then defers to the pure
    /// static core below.
    func sessionPickerPresentation(scope: PanelScope, newTerminalWorkspaceID: String) -> (
        items: [CommandPaletteItem], choices: [String: SessionPickerChoice]
    ) {
        let scopedWorkspaces: [SessionPickerWorkspaceContext]
        switch scope {
        case .workspace(_, let workspaceID):
            scopedWorkspaces =
                overview(forWorkspaceID: workspaceID).map { [SessionPickerWorkspaceContext(workspaceID: workspaceID, overview: $0)] } ?? []
        case .globalWindow: scopedWorkspaces = orderedSessionPickerWorkspaceContexts()
        }
        return Self.sessionPickerPresentation(
            newTerminalWorkspaceID: newTerminalWorkspaceID, newTerminalOverview: overview(forWorkspaceID: newTerminalWorkspaceID),
            scopedWorkspaces: scopedWorkspaces, openSessionIDs: panelCoordinator.openSessionIDs())
    }

    /// Every loaded device's workspaces in sidebar order (the command palette's device →
    /// project → workspace walk), each paired with its owning overview for row building.
    private func orderedSessionPickerWorkspaceContexts() -> [SessionPickerWorkspaceContext] {
        var contexts: [SessionPickerWorkspaceContext] = []
        for section in deviceSections where section.loadState == .loaded {
            guard let overview = section.overview else { continue }
            let mapped = Self.deviceSidebarData(from: overview, deviceID: section.deviceID)
            for project in mapped.projects {
                for workspace in mapped.workspacesByProject[project.id] ?? [] {
                    contexts.append(SessionPickerWorkspaceContext(workspaceID: workspace.id, overview: overview))
                }
            }
        }
        return contexts
    }

    /// Pure picker-row builder: "New terminal session" first, then each workspace's
    /// ordered sidebar runtime targets. Targets come from the same enumeration the sidebar
    /// and command palette use (`orderedWorkspaceRunShortcutTargets`) and keep sidebar
    /// order. Browser targets are excluded (they can't live in a terminal pane), and any
    /// target whose live session already occupies a pane (`openSessionIDs`) is dropped.
    /// Live and exited targets resolve to an open request exactly as
    /// `windowShortcutTargetResolution` does — an exited target intentionally still shows,
    /// so picking it reproduces its sidebar row's ended-state pane. Not-started configured
    /// processes and agent launchers carry a start choice and are always listed.
    /// `nonisolated static` so it's testable without a live `AppKitController`.
    nonisolated static func sessionPickerPresentation(
        newTerminalWorkspaceID: String, newTerminalOverview: SpacesDeviceOverviewPayload?, scopedWorkspaces: [SessionPickerWorkspaceContext],
        openSessionIDs: Set<String>
    ) -> (items: [CommandPaletteItem], choices: [String: SessionPickerChoice]) {
        var items: [CommandPaletteItem] = []
        var choices: [String: SessionPickerChoice] = [:]

        func appendItem(
            id: String, workspaceID: String, workspace: SpacesDeviceWorkspaceSummary?, kind: WorkspaceRunShortcutTarget.Kind, label: String,
            detail: String?, status: CommandPaletteItem.Status, choice: SessionPickerChoice
        ) {
            items.append(
                CommandPaletteItem(
                    id: id, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspaceID,
                    workspaceTitle: workspace?.displayName ?? workspaceID, workspaceBranch: workspace?.branch,
                    projectTitle: workspace?.projectName ?? "", kind: kind, label: label, detail: detail, status: status,
                    // Never executed: picker mode resolves the choice mapping instead of
                    // running a focus request.
                    focusRequest: .workspaceWindow(workspaceID: workspaceID, index: 1), recentFocusIdentity: ""))
            choices[id] = choice
        }

        appendItem(
            id: "picker:new", workspaceID: newTerminalWorkspaceID,
            workspace: newTerminalOverview?.workspaces.first { $0.id == newTerminalWorkspaceID }, kind: .window, label: "New terminal session",
            detail: "Start a fresh terminal", status: .none, choice: .newTerminalSession(workspaceID: newTerminalWorkspaceID))

        for context in scopedWorkspaces {
            guard let deviceWorkspace = context.overview.workspaces.first(where: { $0.id == context.workspaceID }) else { continue }
            let overview = context.overview
            let workspaceID = context.workspaceID
            let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspace)
            let windows = deviceTerminalWindows(from: detail.terminalRows)
            let processes = runningProcesses(from: detail.processRows)
            let agentWindowRecords = agentWindows(from: detail.codingAgentRows)
            let settings = localWorkspaceSettings(from: detail.config)
            let browserSessions = detail.config.resolvedBrowserSessions.map(localBrowserSession(from:))
            let processEntries = orderedWorkspaceRunProcessEntries(
                configuredProcesses: settings.processes, windows: windows, processes: processes, agentWindows: agentWindowRecords)
            let processesByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
            let shortcutTargets = orderedWorkspaceRunShortcutTargets(
                browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
                configuredAgentLaunchers: settings.agentLaunchers, agentWindows: agentWindowRecords)
            let runtimeWindowTitleByAgentID = codingAgentWindowTitleByAgentID(agentWindows: agentWindowRecords, trackedWindows: windows)
            let configuredAgentByName = Dictionary(uniqueKeysWithValues: settings.agentLaunchers.map { ($0.name, $0) })

            for (offset, target) in shortcutTargets.enumerated() {
                // Browser targets can't live in a terminal pane, so the picker never offers them.
                if target.kind == .browser { continue }
                let label: String
                let detailText: String?
                let status: CommandPaletteItem.Status
                switch target.kind {
                case .process:
                    guard let processID = target.processID, let process = processesByID[processID] else { continue }
                    label = process.templateName
                    detailText = process.command
                    status = .process(process.status)
                case .window:
                    guard let windowListIndex = target.windowListIndex, windows.indices.contains(windowListIndex) else { continue }
                    let rowText = terminalFallbackRowText(
                        name: windows[windowListIndex].name, detail: windows[windowListIndex].detail, app: windows[windowListIndex].app)
                    label = rowText.label
                    detailText = rowText.detail
                    status = .none
                case .missingConfiguredProcess:
                    guard let processKey = target.processKey else { continue }
                    label = processKey
                    detailText = nil
                    status = .idle
                case .agentLauncher:
                    guard let launcherName = target.launcherName else { continue }
                    label = launcherName
                    detailText = configuredAgentByName[launcherName]?.command
                    status = .none
                case .agent:
                    guard let agentWindow = target.agentWindow else { continue }
                    label = agentWindow.label?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).nilIfEmpty ?? "Coding Agent"
                    detailText = runtimeWindowTitleByAgentID[agentWindow.id]
                    status = .agent(agentWindow.status)
                case .browser: continue
                }

                let choice: SessionPickerChoice
                switch windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: detail, overview: overview) {
                case .openTerminal(let request):
                    if openSessionIDs.contains(request.sessionID) { continue }
                    choice = .existingSession(request)
                case .runProcess(let ws, let processKey, let processTemplateID):
                    choice = .startProcess(workspaceID: ws, processKey: processKey, processTemplateID: processTemplateID)
                case .runCodingAgent(let ws, let agentName, let agentLauncherID):
                    choice = .startCodingAgent(workspaceID: ws, agentName: agentName, agentLauncherID: agentLauncherID)
                case .openURL, .noWorkspace, .noMatch: continue
                }

                appendItem(
                    id: "picker:\(workspaceID)::\(offset)", workspaceID: workspaceID, workspace: deviceWorkspace, kind: target.kind, label: label,
                    detail: detailText, status: status, choice: choice)
            }
        }
        return (items, choices)
    }
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
