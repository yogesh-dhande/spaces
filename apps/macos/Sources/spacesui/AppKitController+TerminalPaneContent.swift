import AppKit
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Host hooks for the panel coordinator that don't need `AppKitController.swift`'s
/// private state; the pane content factory itself (`makeTerminalPaneContent`) lives in
/// `AppKitController.swift` beside the terminal state-model machinery it reuses.
extension AppKitController {
    /// Picker-backed new tab (⌘T and the workspace tab strip's "+"): choose a
    /// not-yet-open target or create a fresh session; the result lands as a new
    /// selected, focused tab in the workspace's panel. Global windows carry no tabs and
    /// no "+" of their own, so only `.workspace` scopes ever reach this — the
    /// completion routes through the open-or-focus chokepoint rather than appending
    /// unconditionally, so a session that opened elsewhere while the picker was up
    /// (panel-window restore, IPC) focuses its existing pane instead of duplicating it.
    func presentNewTabSessionPicker(scope: PanelScope) {
        guard case .workspace(_, let workspaceID) = scope else { return }
        presentPaneSessionPicker(scope: scope, newTerminalWorkspaceID: workspaceID) { [weak self] result in
            guard let self, let result else { return }
            switch result {
            case .terminal(let request): self.panelCoordinator.openOrFocusTerminalPane(request, openIntent: .focused)
            }
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
    ///
    /// Also unconditionally drops every code pane (`keepingWorkspaceKeys: []`): the editor's only
    /// legitimate placement is the global singleton window (`.globalWindow` scope), so a code pane
    /// found in a `.workspace`-scope layout can only be a leftover from before that constraint —
    /// pruned here rather than migrated, since decode-time pruning already carries every other kind of
    /// staleness in this layout.
    /// - Parameter additionalKeepSessionIDs: Sessions this particular restoration must not prune, beyond
    ///   the recorded holds. A replacement's open restores the panel itself, and when it is processed
    ///   before its predecessor's close there is no hold yet: the open passes its own predecessor here so
    ///   it protects the pane it is about to claim whichever order the two messages arrive in. Scoped to
    ///   the call rather than recorded, so `panesHeldForReplacement` keeps meaning only what the daemon
    ///   asked the client to hold.
    func restoredWorkspacePanelLayout(deviceID: String, workspaceID: String, additionalKeepSessionIDs: Set<String> = []) -> PanelLayout? {
        guard let json = try? clientDatabase().workspacePanelLayout(deviceID: deviceID, workspaceID: workspaceID),
            let layout = try? JSONDecoder().decode(PanelLayout.self, from: Data(json.utf8)), layout.version == PanelLayout.currentVersion
        else { return nil }
        let retainedSessionIDs = OpenPanePruning.restorationKeepSet(
            overview: overview(forWorkspaceID: workspaceID),
            heldForReplacementSessionIDs: panelCoordinator.sessionIDsHeldForReplacement.union(additionalKeepSessionIDs))
        return PanelLayoutEngine.prunedLayout(layout, keepingSessionIDs: retainedSessionIDs, keepingWorkspaceKeys: [])
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

    /// - Parameter retainedWorkspaceKeys: The live `(deviceID, workspaceID)` pairs across every
    ///   ready device's overview — a global panel window's code panes can reference any workspace, not
    ///   only one belonging to the window's own scope, unlike a workspace panel's own restore, so this
    ///   decision (unlike `restoredWorkspacePanelLayout`) prunes code panes against workspace liveness
    ///   too. A workspace deleted while the app was closed must not reopen its code pane on relaunch.
    /// - Parameter editorAlreadyOpen: Whether a live global code pane (the Editor) already exists in
    ///   some other window (`PanelCoordinator.anyGlobalCodePanePlacement()`), evaluated fresh for each
    ///   pending record so a window this same restore pass just opened counts too. Enforces the Editor
    ///   singleton against the offline-device race: a persisted window whose code pane's device was
    ///   unreachable at launch stays pending, and by the time its device reconnects the user may already
    ///   have opened a fresh Editor via ⌘⌥E — restoring this window's own code pane on top would
    ///   duplicate the singleton, so it is dropped here instead, same as any other dead pane.
    /// - Parameter orphanedEditorFallback: A live workspace selected through the same fallback chain
    ///   used for an Editor whose workspace is deleted while the app is running. Before pruning, a
    ///   persisted code pane whose workspace disappeared while the app was closed is retargeted here,
    ///   preserving its pane and window identity. Nil keeps the close-when-no-workspace-remains rule.
    nonisolated static func panelWindowRestoreDecision(
        layoutJSON: String, loadedDeviceIDs: Set<String>, retainedSessionIDs: Set<String>, retainedWorkspaceKeys: Set<PanelLayoutEngine.WorkspaceKey>,
        editorAlreadyOpen: Bool, orphanedEditorFallback: PanelLayoutEngine.WorkspaceKey? = nil
    ) -> PanelWindowRestoreDecision {
        guard var layout = try? JSONDecoder().decode(PanelLayout.self, from: Data(layoutJSON.utf8)), layout.version == PanelLayout.currentVersion
        else { return .skip }
        let referencedDeviceIDs = Set(
            PanelLayoutEngine.allPanes(in: layout).map { pane in
                switch pane.content {
                case .terminalSession(let deviceID, _): deviceID
                case .codePane(let deviceID, _): deviceID
                }
            })
        guard referencedDeviceIDs.isSubset(of: loadedDeviceIDs) else { return .waitForDevices }
        if !editorAlreadyOpen, let fallback = orphanedEditorFallback, retainedWorkspaceKeys.contains(fallback) {
            for pane in PanelLayoutEngine.allPanes(in: layout) {
                guard case .codePane(let deviceID, let workspaceID) = pane.content,
                    !retainedWorkspaceKeys.contains(.init(deviceID: deviceID, workspaceID: workspaceID))
                else { continue }
                layout = PanelLayoutEngine.retargetPane(
                    paneID: pane.id, to: .codePane(deviceID: fallback.deviceID, workspaceID: fallback.workspaceID), in: layout)
            }
        }
        let pruned = PanelLayoutEngine.prunedLayout(
            layout, keepingSessionIDs: retainedSessionIDs, keepingWorkspaceKeys: retainedWorkspaceKeys, droppingAllCodePanes: editorAlreadyOpen)
        return pruned.isEmpty ? .discard : .open(pruned)
    }

    /// Reopens persisted global panel windows eagerly once possible. Called after
    /// every device-section load; each row waits for the devices its panes reference.
    /// A device that is not loaded is never ready: a pane needs a live daemon to attach
    /// its session to, so an unreachable device's panes stay pending for the outage even
    /// though it keeps its overview — and because the record is only ever deferred, its
    /// panes are never pruned against a catalog the outage made unavailable.
    /// Points a still-pending global panel window's persisted pane at a replacement session.
    ///
    /// A window whose devices are not all loaded is deferred rather than restored, so a restart of a
    /// process whose pane lives there has no in-memory placement for the ordinary claim to retarget. The
    /// same `PanelLayoutEngine.retargetPane` runs against the record's stored layout instead, so the pane
    /// keeps its window, tab, and split and comes back carrying the replacement once the window restores.
    /// Answers false when no pending record holds that session, leaving the caller on its install path.
    func retargetPendingPanelWindowPane(replacing oldSessionID: String, with content: PaneContentDescriptor) -> Bool {
        if pendingPanelWindowRestores == nil { pendingPanelWindowRestores = (try? clientDatabase().panelWindows()) ?? [] }
        guard let pending = pendingPanelWindowRestores else { return false }
        let decoder = JSONDecoder()
        for (index, record) in pending.enumerated() {
            guard let layout = try? decoder.decode(PanelLayout.self, from: Data(record.layoutJSON.utf8)),
                let paneID = PanelLayoutEngine.allPanes(in: layout).first(where: { $0.content.terminalSessionID == oldSessionID })?.id
            else { continue }
            let retargeted = PanelLayoutEngine.retargetPane(paneID: paneID, to: content, in: layout)
            guard let json = try? JSONEncoder().encode(retargeted) else { return false }
            let updated = SpacesClientDatabase.PanelWindowRecord(
                id: record.id, layoutJSON: String(decoding: json, as: UTF8.self), frame: record.frame)
            pendingPanelWindowRestores?[index] = updated
            try? clientDatabase().upsertPanelWindow(updated)
            return true
        }
        return false
    }

    func reopenPersistedPanelWindowsIfPossible() {
        if pendingPanelWindowRestores == nil { pendingPanelWindowRestores = (try? clientDatabase().panelWindows()) ?? [] }
        guard let pending = pendingPanelWindowRestores, !pending.isEmpty else { return }
        let readySections = deviceModel.deviceSections.filter { $0.loadState == .loaded && $0.overview != nil }
        let loadedDeviceIDs = Set(readySections.map(\.deviceID))
        let retainedSessionIDs = OpenPanePruning.restorationKeepSet(
            overviews: readySections.map(\.overview), heldForReplacementSessionIDs: panelCoordinator.sessionIDsHeldForReplacement)
        // Hidden workspaces stay listed in their device's overview with `isHidden` set, so this is a
        // deletion-only keep-set exactly like the live overview-driven code-pane prune
        // (`PanelCoordinator.pruneOpenCodePanes`).
        let retainedWorkspaceKeys = Set(
            readySections.flatMap { section in
                (section.overview?.workspaces ?? []).map { PanelLayoutEngine.WorkspaceKey(deviceID: section.deviceID, workspaceID: $0.id) }
            })
        let orphanedEditorFallback = globalEditorFallbackWorkspaceID(excluding: nil, allowedWorkspaceKeys: retainedWorkspaceKeys).map {
            PanelLayoutEngine.WorkspaceKey(deviceID: $0.deviceID, workspaceID: $0.workspaceID)
        }
        var remaining: [SpacesClientDatabase.PanelWindowRecord] = []
        for record in pending {
            // Re-read fresh on every iteration, not hoisted above the loop: a `.open` decision below
            // installs the window's panes synchronously (`restorePanelWindow`), so a code pane this
            // same pass just restored must already count as "live" for the next pending record.
            switch Self.panelWindowRestoreDecision(
                layoutJSON: record.layoutJSON, loadedDeviceIDs: loadedDeviceIDs, retainedSessionIDs: retainedSessionIDs,
                retainedWorkspaceKeys: retainedWorkspaceKeys, editorAlreadyOpen: panelCoordinator.hasLiveGlobalCodePane,
                orphanedEditorFallback: orphanedEditorFallback)
            {
            case .waitForDevices: remaining.append(record)
            case .skip: break
            case .discard: try? clientDatabase().deletePanelWindow(id: record.id)
            case .open(let layout):
                // Keep the row aligned with the effective restored layout. This makes an offline
                // deletion's Editor retarget durable (and avoids re-pruning dead panes on every launch)
                // while preserving the stored frame before the window exists to report one itself.
                if let data = try? JSONEncoder().encode(layout) {
                    try? clientDatabase().upsertPanelWindow(
                        .init(id: record.id, layoutJSON: String(decoding: data, as: UTF8.self), frame: record.frame))
                }
                let frame = record.frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                reopenPersistedPanelWindow(record: record, layout: layout, frame: frame)
            }
        }
        pendingPanelWindowRestores = remaining
    }

    /// Restores one `.open` decision's window, splitting a legacy multi-tab global window (from
    /// before global windows dropped tabs) into one single-tab window per tab so no tab is lost or
    /// silently collapsed into another. The record's own id and frame stay with its first tab; every
    /// other tab gets a freshly minted, persisted row of its own, cascaded off the original frame so
    /// the split-off windows don't stack exactly on top of one another. Persisting the split result
    /// (rather than leaving the original multi-tab JSON on disk) makes this a one-time migration: the
    /// next launch finds only single-tab rows and takes the ordinary, non-splitting branch below.
    private func reopenPersistedPanelWindow(record: SpacesClientDatabase.PanelWindowRecord, layout: PanelLayout, frame: NSRect?) {
        guard layout.tabs.count > 1 else {
            panelCoordinator.restorePanelWindow(panelWindowID: record.id, layout: layout, frame: frame)
            return
        }
        let soloLayouts = PanelLayoutEngine.splitIntoSoloTabLayouts(layout)
        panelCoordinator.restorePanelWindow(panelWindowID: record.id, layout: soloLayouts[0], frame: frame)
        persistPanelLayout(scope: .globalWindow(panelWindowID: record.id), layout: soloLayouts[0])
        for (offset, soloLayout) in soloLayouts.dropFirst().enumerated() {
            let newPanelWindowID = UUID().uuidString
            let cascadedOffset = CGFloat(offset + 1) * 24
            let newFrame = frame.map { $0.offsetBy(dx: cascadedOffset, dy: -cascadedOffset) }
            panelCoordinator.restorePanelWindow(panelWindowID: newPanelWindowID, layout: soloLayout, frame: newFrame)
            persistPanelLayout(scope: .globalWindow(panelWindowID: newPanelWindowID), layout: soloLayout)
        }
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
    }

    /// What a pane-split/new-tab session picker resolved to. A code pane is never a picker result: it
    /// has no in-panel placement, so it is never one of the split/new-tab picker's rows — see
    /// `openOrFocusGlobalEditorWindow` for its one entry point.
    enum PaneSessionPickerResult { case terminal(DeviceTerminalOpenRequest) }

    /// Presents the command palette in session-picker mode for filling a pane split or
    /// opening a new tab, and delivers the resulting choice (creating a fresh session when
    /// "New terminal session" is chosen), or nil when dismissed.
    func presentPaneSessionPicker(scope: PanelScope, newTerminalWorkspaceID: String, completion: @escaping (PaneSessionPickerResult?) -> Void) {
        let presentation = sessionPickerPresentation(scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID)
        commandPalette.presentSessionPicker(
            scope: scope, newTerminalWorkspaceID: newTerminalWorkspaceID, items: presentation.items, choicesByItemID: presentation.choices
        ) { [weak self] choice in
            switch choice {
            case nil: completion(nil)
            case .existingSession(let request): completion(.terminal(request))
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
                    completion(request.map { .terminal($0) })
                }
            case .startProcess(let workspaceID, let processKey, let processTemplateID):
                guard let self else {
                    completion(nil)
                    return
                }
                Task { @MainActor in
                    let request = await self.runTerminalSessionMutation(workspaceID: workspaceID) { device in
                        try SpacesDeviceClient.runWorkspaceProcess(
                            workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID,
                            context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                    }
                    completion(request.map { .terminal($0) })
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
            // Deliberately no hidden-visibility check here: this scope is the picker inside an open
            // panel of exactly this workspace, and hiding suppresses rows on listing surfaces without
            // tearing down open panels — a panel that stays open keeps its own picker (and its "New
            // terminal session" row) working even if the workspace was hidden from another client.
            scopedWorkspaces =
                overview(forWorkspaceID: workspaceID).map { [SessionPickerWorkspaceContext(workspaceID: workspaceID, overview: $0)] } ?? []
        case .globalWindow:
            // The invoking workspace's overview is passed along only while its device section is
            // loaded: the visible walk lists loaded sections only, and a section that is not loaded
            // (its device offline, say) retains its last overview, so an unguarded lookup would
            // mistake that omission for hiding and resurrect rows the device cannot serve.
            let invokingSectionIsLoaded = deviceID(forWorkspaceID: newTerminalWorkspaceID).flatMap { deviceSection(id: $0) }?.loadState == .loaded
            scopedWorkspaces = Self.globalSessionPickerScopedWorkspaces(
                ordered: orderedSessionPickerWorkspaceContexts(), newTerminalWorkspaceID: newTerminalWorkspaceID,
                newTerminalOverview: invokingSectionIsLoaded ? overview(forWorkspaceID: newTerminalWorkspaceID) : nil)
        }
        return Self.sessionPickerPresentation(
            newTerminalWorkspaceID: newTerminalWorkspaceID, newTerminalOverview: overview(forWorkspaceID: newTerminalWorkspaceID),
            scopedWorkspaces: scopedWorkspaces, openSessionIDs: panelCoordinator.openSessionIDs())
    }

    /// Every loaded device's workspaces in sidebar order (the command palette's device →
    /// project → workspace walk), each paired with its owning overview for row building.
    /// Hidden projects and hidden workspaces are excluded exactly as the sidebar excludes
    /// them, through the same `SidebarVisibility` rules.
    private func orderedSessionPickerWorkspaceContexts() -> [SessionPickerWorkspaceContext] {
        var contexts: [SessionPickerWorkspaceContext] = []
        for section in deviceModel.deviceSections where section.loadState == .loaded {
            guard let overview = section.overview else { continue }
            let mapped = Self.deviceSidebarData(from: overview, deviceID: section.deviceID)
            for project in SidebarVisibility.deviceProjects(
                mapped.projects, deviceID: section.deviceID, workspacesByProject: mapped.workspacesByProject)
            {
                for workspace in mapped.workspacesByProject[project.id] ?? []
                where SidebarVisibility.isVisibleWorkspace(workspace, inProject: project) {
                    contexts.append(SessionPickerWorkspaceContext(workspaceID: workspace.id, overview: overview))
                }
            }
        }
        return contexts
    }

    /// The global picker's workspace contexts: the sidebar-visible walk, with the invoking pane's own
    /// workspace prepended when hiding removed it from that walk. The workspace scope keeps a hidden
    /// workspace's picker working because the open pane is that workspace's own surface; a pane moved
    /// to a global window is the same open pane, so its workspace keeps its session rows here too
    /// (right after "New terminal session"), while every other hidden workspace stays excluded. The
    /// caller passes `newTerminalOverview` only when the invoking workspace's device section is
    /// loaded, so a workspace omitted for any other reason (its device offline, its overview never
    /// loaded) stays omitted.
    /// `nonisolated static` so it's testable without a live `AppKitController`.
    nonisolated static func globalSessionPickerScopedWorkspaces(
        ordered: [SessionPickerWorkspaceContext], newTerminalWorkspaceID: String, newTerminalOverview: SpacesDeviceOverviewPayload?
    ) -> [SessionPickerWorkspaceContext] {
        guard !ordered.contains(where: { $0.workspaceID == newTerminalWorkspaceID }), let newTerminalOverview,
            newTerminalOverview.workspaces.contains(where: { $0.id == newTerminalWorkspaceID })
        else { return ordered }
        return [SessionPickerWorkspaceContext(workspaceID: newTerminalWorkspaceID, overview: newTerminalOverview)] + ordered
    }

    /// Pure picker-row builder: "New terminal session" first, then each workspace's
    /// ordered sidebar runtime targets. Targets come from the same enumeration the sidebar
    /// and command palette use (`orderedWorkspaceRunShortcutTargets`) and keep sidebar
    /// order. Browser targets are excluded (they can't live in a terminal pane), and any
    /// target whose live session already occupies a pane (`openSessionIDs`) is dropped.
    /// Live and exited targets resolve to an open request exactly as
    /// `windowShortcutTargetResolution` does — an exited target intentionally still shows,
    /// so picking it reproduces its sidebar row's ended-state pane. Not-started configured
    /// processes carry a start choice and are always listed.
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

        // Deliberately no hidden-visibility check on this row: `newTerminalWorkspaceID` is the invoking
        // pane's own workspace (workspace-scoped or moved to a global window alike), and hiding
        // suppresses listing surfaces without tearing down open panels — a pane that stays open keeps
        // its primary new-session action even if its workspace was hidden meanwhile.
        appendItem(
            id: "picker:new", workspaceID: newTerminalWorkspaceID,
            workspace: newTerminalOverview?.workspaces.first { $0.id == newTerminalWorkspaceID }, kind: .window, label: "New terminal session",
            detail: "Start a fresh terminal", status: .none, choice: .newTerminalSession(workspaceID: newTerminalWorkspaceID))

        for context in scopedWorkspaces {
            guard let deviceWorkspace = context.overview.workspaces.first(where: { $0.id == context.workspaceID }) else { continue }
            let overview = context.overview
            let workspaceID = context.workspaceID
            let sessionsByID = Dictionary(overview.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID, agentWindows: agentWindowRecords)
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
                    let window = windows[windowListIndex]
                    let rowText = terminalFallbackRowText(name: window.name, detail: window.detail, app: window.app)
                    label = rowText.label
                    detailText = terminalPaletteSecondaryLabel(
                        liveTitle: rowText.detail, sessionID: window.terminalTrackingID, sessionsByID: sessionsByID)
                    status = .none
                case .missingConfiguredProcess:
                    guard let processKey = target.processKey else { continue }
                    label = processKey
                    detailText = nil
                    status = .idle
                case .agent:
                    guard let agentWindow = target.agentWindow,
                        let agentRow = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == agentWindow.id })
                    else { continue }
                    label = agentWindow.label?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).nilIfEmpty ?? "Coding Agent"
                    detailText = terminalPaletteSecondaryLabel(
                        liveTitle: agentRow.liveTitle, sessionID: agentRow.sessionID, sessionsByID: sessionsByID)
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
