import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import workspacecore

@testable import spacesdeviceapi
@testable import spacesterminalcore
@testable import spacesui

@Suite struct AppKitControllerDeviceParityTests {
    @Test func sidebarProjectActionsDoNotDependOnDeviceLocation() {
        let gitProjectActions = AppKitController.sidebarProjectActions(isGitRepo: true)
        #expect(gitProjectActions.showsSettings)
        #expect(gitProjectActions.showsAddWorkspace)

        let folderProjectActions = AppKitController.sidebarProjectActions(isGitRepo: false)
        #expect(folderProjectActions.showsSettings)
        #expect(!folderProjectActions.showsAddWorkspace)
    }

    @Test func localDeviceShowsOfflineWhenDaemonUnreachableMirroringRemote() {
        // An unreachable local daemon must surface as offline (carrying the reason), the same state a
        // remote device enters when its overview fails to load — not a loaded-but-empty device.
        let offline = AppKitController.localDeviceLoadState(offlineMessage: "Timed out waiting for spacesd to start.")
        #expect(offline == .offline("Timed out waiting for spacesd to start."))

        // A reachable daemon (nil message) stays loaded.
        #expect(AppKitController.localDeviceLoadState(offlineMessage: nil) == .loaded)
    }

    @Test func localSnapshotPrunesPanesOnlyAgainstAReachableCompatibleOverview() {
        // A reachable, wire-compatible local daemon carries an authoritative overview: its snapshot may
        // prune open local panes against the retained keep-set. `.compatible` and a nil verdict (steady
        // state exposes no verdict) both authorize pruning.
        #expect(AppKitController.localSnapshotAuthorizesPanePrune(loadState: .loaded, compatibility: .compatible))
        #expect(AppKitController.localSnapshotAuthorizesPanePrune(loadState: .loaded, compatibility: nil))

        // An offline local daemon carries only the empty placeholder overview; pruning against it would
        // wrongly close every live local pane, so it must never prune (the CRITICAL invariant).
        #expect(!AppKitController.localSnapshotAuthorizesPanePrune(loadState: .offline("daemon down"), compatibility: nil))
        #expect(!AppKitController.localSnapshotAuthorizesPanePrune(loadState: .loading, compatibility: nil))

        // A reachable-but-wire-incompatible daemon is rendered loaded but also carries only the
        // placeholder overview (mirroring the remote path's `load.overview == nil` branch), so it must
        // not prune either.
        #expect(!AppKitController.localSnapshotAuthorizesPanePrune(loadState: .loaded, compatibility: .daemonTooOld))
        #expect(!AppKitController.localSnapshotAuthorizesPanePrune(loadState: .loaded, compatibility: .clientTooOld))
    }

    @Test func singleOfflineLocalDeviceStillRendersADeviceHeaderRow() {
        // A single loaded device stays a flat project list (no header).
        #expect(!AppKitController.sidebarShowsDeviceHeaders(deviceCount: 1, hasUnloadedSection: false))
        // A single device that is not loaded forces a header row so its caption has somewhere to render:
        // the outage and its recovery button, and the "loading…" that button puts the section in. The
        // device's rows stay listed through the outage, but they are rows, not a caption — nothing else
        // reports the reason or recovers the device, and a first launch against a daemon that is down
        // has no rows at all.
        #expect(AppKitController.sidebarShowsDeviceHeaders(deviceCount: 1, hasUnloadedSection: true))
        // More than one device always groups under headers.
        #expect(AppKitController.sidebarShowsDeviceHeaders(deviceCount: 2, hasUnloadedSection: false))

        #expect(AppKitController.SidebarDeviceLoadState.offline("daemon down").isOffline)
        #expect(!AppKitController.SidebarDeviceLoadState.loaded.isOffline)
        #expect(!AppKitController.SidebarDeviceLoadState.loading.isOffline)
    }

    @Test func addProjectDeviceIsSelectableOnlyWhenReachable() {
        // Offline devices are not selectable in the add-project device step: creating on one would make
        // the source step's Continue hang on a request that only times out.
        #expect(AppKitController.addProjectDeviceIsSelectable(loadState: .loaded))
        #expect(AppKitController.addProjectDeviceIsSelectable(loadState: .loading))
        #expect(!AppKitController.addProjectDeviceIsSelectable(loadState: .offline("daemon down")))
    }

    @Test func onlyALoadedDeviceAcceptsDaemonBackedActions() {
        // Browse, don't act: an unreachable device keeps its projects, workspaces and alerts listed and
        // readable, but every action that has to reach its daemon is refused up front rather than dialled
        // and failed. A section that has not finished loading is equally not actionable — its record may
        // not be installed yet.
        let remoteID = "device-remote"
        #expect(AppKitController.deviceAcceptsDaemonActions(deviceID: remoteID, loadState: .loaded))
        #expect(!AppKitController.deviceAcceptsDaemonActions(deviceID: remoteID, loadState: .offline("Connection refused")))
        #expect(!AppKitController.deviceAcceptsDaemonActions(deviceID: remoteID, loadState: .loading))

        // The same states decide it for this Mac, so an unreachable local daemon refuses exactly like a
        // remote one rather than being trusted for being local.
        let localID = SpacesPairedDeviceRecord.localDeviceID
        #expect(AppKitController.deviceAcceptsDaemonActions(deviceID: localID, loadState: .loaded))
        #expect(!AppKitController.deviceAcceptsDaemonActions(deviceID: localID, loadState: .offline("Connection refused")))
        #expect(!AppKitController.deviceAcceptsDaemonActions(deviceID: localID, loadState: .loading))
    }

    @Test func thisMacIsActionableBeforeTheFirstSidebarSnapshotButAnUnknownDeviceIsNot() {
        // No section yet is not the same fact as offline. An openTerminalSessionWindow/focus IPC arrives
        // on a cold launch before the first sidebar load, and the pane it opens is on this Mac — whose
        // record comes from the local-device bootstrap, not from a sidebar section. Refusing then would
        // fail that open with "Spaces has not finished loading".
        #expect(AppKitController.deviceAcceptsDaemonActions(deviceID: SpacesPairedDeviceRecord.localDeviceID, loadState: nil))
        // A remote id no section claims is genuinely unknown: nothing has told the app that device exists,
        // so it must stay refused rather than falling through to this Mac's daemon.
        #expect(!AppKitController.deviceAcceptsDaemonActions(deviceID: "device-never-seen", loadState: nil))
    }

    @Test func aRetainedWorkspaceDetailIsRebuiltOnlyWhenItsDeviceCrossesTheActionableLine() {
        typealias LoadState = AppKitController.SidebarDeviceLoadState
        let deviceID = "device-remote"
        let offline = LoadState.offline("Connection refused")
        func rebuilds(detailDevice: String?, from: LoadState, to: LoadState) -> Bool {
            AppKitController.shouldRebuildWorkspaceDetailForDeviceLoadStateChange(
                visibleDetailWorkspaceDeviceID: detailDevice, deviceID: deviceID, previousLoadState: from, newLoadState: to)
        }

        // Going offline under the selection: the pane's footer/setup controls were built enabled and
        // would keep offering actions the device now refuses. Coming back: they were built disabled and
        // would stay that way until the user reselected the row.
        #expect(rebuilds(detailDevice: deviceID, from: .loaded, to: offline))
        #expect(rebuilds(detailDevice: deviceID, from: offline, to: .loaded))

        // A device that stays down is re-reported on every probe for the whole outage; rebuilding then
        // would throw away the user's scroll and focus repeatedly for a state that did not move. A newer
        // failure reason changes the caption, not what any control can do.
        #expect(!rebuilds(detailDevice: deviceID, from: offline, to: offline))
        #expect(!rebuilds(detailDevice: deviceID, from: offline, to: .offline("Stream closed")))

        // Another device's outage leaves this pane alone, and a detail showing something other than a
        // workspace (alerts, a compatibility block) has no controls keyed to this device.
        #expect(!rebuilds(detailDevice: "device-other", from: .loaded, to: offline))
        #expect(!rebuilds(detailDevice: nil, from: .loaded, to: offline))
    }

    @Test func anOpenTerminalPaneStaysFocusableWhileOfflineButANewOneIsRefused() {
        // The two operations behind one sidebar click part ways during an outage. Focusing a pane that is
        // already open is client-side — it owns its state model and renders the disconnected notice — so
        // an unreachable device never withholds it.
        #expect(AppKitController.canOpenOrFocusTerminalPane(hasExistingPane: true, deviceAcceptsDaemonActions: false))
        #expect(AppKitController.canOpenOrFocusTerminalPane(hasExistingPane: true, deviceAcceptsDaemonActions: true))

        // Opening a pane the layout does not have yet can only work by attaching to the owning daemon, so
        // it is refused while the device cannot act — and refused before the install, because installing
        // adds the pane to the layout and persists it before credentials are prepared: a pane admitted
        // here is saved as permanently failed and never retries when the device returns.
        #expect(!AppKitController.canOpenOrFocusTerminalPane(hasExistingPane: false, deviceAcceptsDaemonActions: false))
        #expect(AppKitController.canOpenOrFocusTerminalPane(hasExistingPane: false, deviceAcceptsDaemonActions: true))
    }

    @Test func aFreshCodePaneIsRefusedForADeviceThatCannotAct() {
        // A code pane has no daemon-side session to attach, but building its content still means
        // installing a pane into the layout and persisting it, so an unreachable device must not have
        // one created on its behalf — the code-pane counterpart of `canOpenOrFocusTerminalPane`'s
        // creation branch. Unlike that function, there is no `hasExistingPane` flag here:
        // `openOrFocusGlobalEditorWindow` already handles "a pane exists" by focusing it before creation
        // is ever considered, so this only ever answers "can we create."
        #expect(!AppKitController.canCreateCodePane(deviceAcceptsDaemonActions: false))
        #expect(AppKitController.canCreateCodePane(deviceAcceptsDaemonActions: true))
    }

    @Test func actionsRefusedByAnOutageNameTheDeviceInsteadOfClaimingSpacesIsLoading() {
        // The refusal a user reads has to match what they can see: the device's rows are on screen, so
        // "Spaces has not finished loading" would be plainly wrong. It names the device and says offline,
        // matching the add-project device step's refusal.
        let error = AppKitController.deviceUnreachableError(deviceName: "workshop", isLocal: false)
        #expect(error.localizedDescription == "workshop is offline.")
        #expect(error.localizedRecoverySuggestion == "Reconnect it and try again.")
    }

    @Test func theLocalMacIsToldToRestartItsDaemonRatherThanReconnectToItself() {
        // "Reconnect it" sends the user looking for a control that cannot exist for their own Mac; the
        // action that resolves this one is the daemon relaunch in Devices settings.
        let error = AppKitController.deviceUnreachableError(deviceName: "Local", isLocal: true)
        #expect(error.localizedDescription == "Local is offline.")
        #expect(error.localizedRecoverySuggestion == "Restart the local daemon and try again.")
    }

    @Test func localDaemonRestartActionIsOfferedOnlyForRelaunchResolvableFailures() {
        // Known reachability failures a relaunch can resolve — the daemon answered that its Device API is
        // not running, or its control endpoint was unreachable (daemon down) — offer the action.
        #expect(
            DevicePairingController.localDaemonRestartActionIsAvailable(
                responseMessage: SpacesDeviceAPIControlClient.deviceAPINotRunningMessage, isRelaunching: false))
        #expect(
            DevicePairingController.localDaemonRestartActionIsAvailable(
                responseMessage: DevicePairingController.deviceAPIUnreachableMessage, isRelaunching: false))

        // A reachable daemon that returned a real status/settings error carries its own message; restarting
        // would stop live sessions for nothing, so the action is suppressed and the error surfaces instead.
        #expect(
            !DevicePairingController.localDaemonRestartActionIsAvailable(
                responseMessage: "Overview failed: database disk image is malformed.", isRelaunching: false))

        // The Device API disabled-by-override failure: a relaunch inherits the same environment and cannot
        // bring the socket up, so the action is suppressed.
        #expect(
            !DevicePairingController.localDaemonRestartActionIsAvailable(
                responseMessage: DevicePairingController.deviceAPIControlDisabledMessage, isRelaunching: false))

        // While a relaunch is already running, the action is suppressed so a second click cannot start a
        // concurrent relaunch — even for an otherwise relaunch-resolvable failure.
        #expect(
            !DevicePairingController.localDaemonRestartActionIsAvailable(
                responseMessage: SpacesDeviceAPIControlClient.deviceAPINotRunningMessage, isRelaunching: true))
    }

    @Test func localDaemonCompatibilityBlockShowsUpdateGuidanceWhenClientIsTooOld() {
        let incompatibility = TerminalServiceDaemonWireIncompatibility(
            verdict: .clientTooOld, status: nil, message: "The running spacesd daemon is newer than this Spaces build.")
        let error = TerminalServiceError.daemonWireIncompatible(incompatibility)

        #expect(AppKitController.shouldShowLocalDaemonCompatibilityBlock(for: error))
    }

    @Test func remoteWorkspacePathActionsKeepControlsButUseSSHDependentErrorText() {
        let editorMessage = AppKitController.remoteWorkspacePathActionErrorMessage(action: .openEditor, deviceName: "Build Host")
        let revealMessage = AppKitController.remoteWorkspacePathActionErrorMessage(action: .revealInFinder, deviceName: "Build Host")

        #expect(editorMessage.contains("Open Editor"))
        #expect(revealMessage.contains("Reveal in Finder"))
        #expect(editorMessage.contains("Build Host"))
        #expect(revealMessage.contains("SSH-capable workflow"))
    }

    @Test func terminalLinkWorkingDirectoryPrefersLiveForegroundProcessCWD() throws {
        let staleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("stale-\(UUID().uuidString)", isDirectory: true)
        let liveDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "spaces-ui-live-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: staleDirectory)
            try? FileManager.default.removeItem(at: liveDirectory)
        }

        let foreground = Process()
        foreground.executableURL = URL(fileURLWithPath: "/bin/sleep")
        foreground.arguments = ["30"]
        foreground.currentDirectoryURL = liveDirectory
        try foreground.run()
        defer {
            if foreground.isRunning { foreground.terminate() }
            foreground.waitUntilExit()
        }

        let runtimeState = TerminalSessionRuntimeState(
            sessionID: "session-live-cwd", backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier),
            childPID: foreground.processIdentifier, state: .running, updatedAt: "2026-06-09T12:00:00Z", title: "shell",
            workingDirectory: staleDirectory.path, foregroundPID: foreground.processIdentifier)

        #expect(
            AppKitController.terminalLinkWorkingDirectory(
                runtimeState: runtimeState, streamedWorkingDirectory: staleDirectory.path, launchWorkingDirectory: staleDirectory.path,
                requestWorkingDirectory: staleDirectory.path) == liveDirectory.path)
    }

    @Test func deviceOverviewMappingPreservesProjectWorkspaceAndRuntimeControls() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [
                SpacesDeviceProjectSummary(
                    id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main",
                    config: SpacesDeviceProjectConfig(
                        setupScript: "make setup", stopScript: "make stop", ports: [SpacesDeviceServiceDefinition(id: "port-web", name: "WEB")],
                        processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev", onExit: "restart")],
                        browserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:$WEB")]))
            ],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false,
                    notes: "Remote and local use this same payload.", sessionCount: 1,
                    assignedPorts: [SpacesDeviceAssignedPort(name: "WEB", port: 3000)],
                    setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded),
                    config: SpacesDeviceWorkspaceConfig(
                        stopScript: "make stop", ports: [SpacesDeviceServiceDefinition(id: "port-web", name: "WEB")],
                        processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev", onExit: "restart")],
                        browserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:$WEB")],
                        resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:3000")]),
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-1", name: "web", command: "npm run dev", templateID: "process-web",
                            processID: "running-web", sessionID: "session-web", runState: .running, canRun: false, canStop: true, canRestart: true)
                    ],
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:running-agent", workspaceID: "workspace-1", name: "Codex", command: "codex", agentID: "running-agent",
                            sessionID: "session-agent", runState: .running, activityState: .waiting, canStop: true)
                    ],
                    terminalRows: [
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "terminal-shell", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/project-feature",
                            sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
                    ])
            ], sessions: [])

        let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: "remote-device")

        #expect(mapped.projects.map { $0.id } == ["project-1"])
        #expect(mapped.projects.first?.isGitRepo == true)
        #expect(mapped.projects.first?.deviceID == "remote-device")
        #expect(mapped.workspacesByProject["project-1"]?.first?.deviceID == "remote-device")
        #expect(mapped.workspacesByProject["project-1"]?.map { $0.id } == ["workspace-1"])
        #expect(mapped.workspacesByProject["project-1"]?.first?.notes == "Remote and local use this same payload.")

        let runtime = mapped.workspaceRuntimeStatusByID["workspace-1"]
        #expect(runtime?.lifecycleState == .running)
        #expect(runtime?.hasTrackedRuntimeIndicators == true)
        #expect(runtime?.runningProcessCount == 2)
        #expect(runtime?.exitedProcessCount == 0)
        #expect(runtime?.waitingAgentWindowCount == 1)
    }

    @Test func deviceOverviewBuildsCommandPaletteWorkspaceActions() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, notes: nil, sessionCount: 3,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded),
                    config: SpacesDeviceWorkspaceConfig(
                        processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev")],
                        browserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:$WEB")],
                        resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:3000")]),
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-1", name: "web", command: "npm run dev", templateID: "process-web",
                            processID: "running-web", sessionID: "session-web", runState: .running, canRun: false, canStop: true, canRestart: true)
                    ],
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:running-agent", workspaceID: "workspace-1", name: "Codex", command: "codex", agentID: "running-agent",
                            sessionID: "session-agent", runState: .running, activityState: .waiting, canStop: true)
                    ],
                    terminalRows: [
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "terminal-shell", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/project-feature",
                            sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
                    ])
            ], sessions: [])

        let items = AppKitController.deviceCommandPaletteWorkspaceItems(from: overview)

        #expect(items.contains { $0.kind == .browser && $0.label == "web" && $0.detail == "http://localhost:3000" })
        #expect(items.contains { $0.kind == .process && $0.label == "web" && $0.detail == "npm run dev" })
        #expect(items.contains { $0.kind == .agent && $0.label == "Codex" })
        #expect(items.contains { $0.kind == .window && $0.label == "shell-1" })
    }

    /// Every visible workspace gets an "Open in Editor" row, matching the sidebar item's label,
    /// even when the workspace has no running processes, agents, or terminals to surface as
    /// runtime targets: the Editor opens independent of what a workspace is running. Dispatch
    /// carries no `focusRequest`, since opening the Editor is a synchronous in-process call
    /// (`AppKitController.openWorkspaceEditor(workspaceID:)`) rather than a window to focus.
    @Test func deviceOverviewBuildsCommandPaletteEditorAction() throws {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: false, isHidden: false, isDefault: false, notes: nil, sessionCount: 0,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded), config: SpacesDeviceWorkspaceConfig())
            ], sessions: [])

        let items = AppKitController.deviceCommandPaletteWorkspaceItems(from: overview)

        let editorItems = items.filter { $0.workspaceID == "workspace-1" && $0.source == .editorAction }
        #expect(editorItems.count == 1)
        let editorItem = try #require(editorItems.first)
        #expect(editorItem.label == "Open in Editor")
        #expect(editorItem.kind == .window)
        #expect(editorItem.focusRequest == nil)
    }

    /// The palette lists what the sidebar lists: a hidden workspace, and every workspace of a hidden
    /// project, leave it exactly as they leave the outline.
    @Test func commandPaletteWorkspaceWalkExcludesHiddenWorkspacesAndHiddenProjects() {
        func workspace(id: String, projectID: String, isHidden: Bool) -> SpacesDeviceWorkspaceSummary {
            SpacesDeviceWorkspaceSummary(
                id: id, projectID: projectID, projectName: "Project", branch: "feature", baseBranch: "main", dir: "/device/\(id)", isRunning: true,
                isHidden: isHidden, isDefault: false, notes: nil, sessionCount: 1, assignedPorts: [],
                setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded), config: SpacesDeviceWorkspaceConfig(),
                terminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-\(id)", workspaceID: id, title: "shell-\(id)", workingDirectory: "/device/\(id)", sessionID: "session-\(id)",
                        runState: .running, canOpenTerminal: true, canStop: true)
                ])
        }

        let overview = SpacesDeviceOverviewPayload(
            projects: [
                SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main"),
                SpacesDeviceProjectSummary(
                    id: "project-hidden", name: "Hidden Project", dir: "/device/hidden", isGitRepo: true, defaultBranch: "main", isHidden: true),
            ],
            workspaces: [
                workspace(id: "ws-visible", projectID: "project-1", isHidden: false),
                workspace(id: "ws-hidden", projectID: "project-1", isHidden: true),
                workspace(id: "ws-of-hidden-project", projectID: "project-hidden", isHidden: false),
            ], sessions: [])

        let items = AppKitController.deviceCommandPaletteWorkspaceItems(from: overview)

        #expect(items.contains { $0.workspaceID == "ws-visible" })
        #expect(!items.contains { $0.workspaceID == "ws-hidden" })
        #expect(!items.contains { $0.workspaceID == "ws-of-hidden-project" })
    }

    /// Alerts rows reach the palette through the same tag the alerts pane filters on.
    @Test func commandPaletteAlertsItemsExcludeHiddenFlaggedGroups() {
        func group(workspaceID: String, isFromHiddenWorkspace: Bool) -> AppKitController.AlertsGroup {
            AppKitController.AlertsGroup(
                projectName: "Project", workspaceID: workspaceID, workspaceName: workspaceID, workspaceBranch: "feature",
                isFromHiddenWorkspace: isFromHiddenWorkspace,
                items: [
                    AppKitController.AlertsAttentionEntry(
                        attentionID: "alert:\(workspaceID)", icon: "terminal", iconTint: .terminal, label: "shell-1", detail: nil, shortcut: "",
                        processStatus: nil, agentStatus: nil, countsTowardBadge: true, eventDate: nil,
                        focusRequest: .terminalSession(workspaceID: workspaceID, sessionID: "session-1"))
                ])
        }

        let items = AppKitController.buildCommandPaletteItems(
            overview: SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: []),
            alertsGroups: [
                group(workspaceID: "ws-visible", isFromHiddenWorkspace: false), group(workspaceID: "ws-hidden", isFromHiddenWorkspace: true),
            ])

        #expect(items.contains { $0.source == .alertsAttention && $0.workspaceID == "ws-visible" })
        #expect(!items.contains { $0.source == .alertsAttention && $0.workspaceID == "ws-hidden" })
    }

    /// Palette rows for ad hoc shells prefer the live title and otherwise describe the name with the
    /// generic foreground command already carried by the session overview.
    @Test func commandPaletteTerminalRowsPreferLiveTitleThenForegroundCommand() throws {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, notes: nil, sessionCount: 2,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded), config: SpacesDeviceWorkspaceConfig(),
                    terminalRows: [
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "terminal-quiet", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/project-feature",
                            sessionID: "session-quiet", runState: .running, canOpenTerminal: true, canStop: true),
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "terminal-busy", workspaceID: "workspace-1", title: "shell-2", workingDirectory: "/device/project-feature",
                            sessionID: "session-busy", runState: .running, canOpenTerminal: true, canStop: true, liveTitle: "vim main.swift"),
                    ])
            ],
            sessions: [
                terminalSessionSummary(id: "session-quiet", title: "shell-1", foregroundCommand: "pnpm test --watch"),
                terminalSessionSummary(id: "session-busy", title: "shell-2", foregroundCommand: "ignored foreground"),
            ])

        let items = AppKitController.deviceCommandPaletteWorkspaceItems(from: overview)

        #expect(try #require(items.first { $0.label == "shell-1" }).detail == "pnpm test --watch")
        #expect(try #require(items.first { $0.label == "shell-2" }).detail == "vim main.swift")
    }

    @Test func commandPaletteAgentRowsPreferTheirOverviewLiveTitleThenSessionForegroundCommand() throws {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, notes: nil, sessionCount: 2,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded), config: SpacesDeviceWorkspaceConfig(),
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:busy", workspaceID: "workspace-1", name: "Codex busy", command: "codex", agentID: "busy",
                            sessionID: "session-busy", runState: .running, activityState: .spinning, canStop: true, liveTitle: "reviewing PR 493"),
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:quiet", workspaceID: "workspace-1", name: "Codex quiet", command: "codex", agentID: "quiet",
                            sessionID: "session-quiet", runState: .running, activityState: .idle, canStop: true),
                    ])
            ],
            sessions: [
                terminalSessionSummary(id: "session-busy", title: "Codex busy", foregroundCommand: "ignored foreground"),
                terminalSessionSummary(id: "session-quiet", title: "Codex quiet", foregroundCommand: "codex --model gpt-5.6-sol"),
            ])

        let items = AppKitController.deviceCommandPaletteWorkspaceItems(from: overview)

        #expect(try #require(items.first { $0.label == "Codex busy" }).detail == "reviewing PR 493")
        #expect(try #require(items.first { $0.label == "Codex quiet" }).detail == "codex --model gpt-5.6-sol")
    }

    @Test func commandPaletteAgentAlertsPreferLiveTitleThenSessionForegroundCommandAndDedupeWithDetail() throws {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, notes: nil, sessionCount: 2,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded), config: SpacesDeviceWorkspaceConfig(),
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:busy", workspaceID: "workspace-1", name: "Codex busy", command: "codex", agentID: "busy",
                            sessionID: "session-busy", runState: .running, activityState: .waiting, updatedAt: "2026-08-14T09:00:00Z", canStop: true,
                            liveTitle: "waiting for approval"),
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:quiet", workspaceID: "workspace-1", name: "Codex quiet", command: "codex", agentID: "quiet",
                            sessionID: "session-quiet", runState: .running, activityState: .done, updatedAt: "2026-08-14T09:01:00Z", canStop: true),
                    ])
            ],
            sessions: [
                terminalSessionSummary(id: "session-busy", title: "Codex busy", foregroundCommand: "ignored foreground"),
                terminalSessionSummary(id: "session-quiet", title: "Codex quiet", foregroundCommand: "codex --model gpt-5.6-sol"),
            ])
        let alerts = AlertsController.buildOverviewAlertsGroups(from: overview, deviceID: "local")

        let items = AppKitController.buildCommandPaletteItems(overview: overview, alertsGroups: alerts)
        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: items, query: "", currentWorkspaceID: nil, recentFocusIdentities: [], maxEmptyQueryItems: 20)

        let busyRows = visible.filter { $0.label == "Codex busy" }
        #expect(busyRows.count == 1)
        let busy = try #require(busyRows.first)
        #expect(busy.source == .alertsAttention)
        #expect(busy.detail == "waiting for approval")
        let quietRows = visible.filter { $0.label == "Codex quiet" }
        #expect(quietRows.count == 1)
        let quiet = try #require(quietRows.first)
        #expect(quiet.source == .alertsAttention)
        #expect(quiet.detail == "codex --model gpt-5.6-sol")
    }

    /// A workspace-target process row (not the alerts-list row built from the same exit) applies the same
    /// exit-acknowledgment downgrade the sidebar row does: once the exit's alert is dismissed, the
    /// palette status reads idle instead of exited, until a new exit creates a new alert identity.
    @Test func commandPaletteWorkspaceProcessRowDowngradesOnAcknowledgedExit() throws {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, notes: nil, sessionCount: 1,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded),
                    config: SpacesDeviceWorkspaceConfig(processes: [
                        SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev")
                    ]),
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-1", name: "web", command: "npm run dev", templateID: "process-web",
                            processID: "exited-web", sessionID: nil, runState: .exited, exitedAt: "2026-08-18T10:00:00Z", canRun: true,
                            canStop: false, canRestart: true)
                    ])
            ], sessions: [])
        let alerts = AlertsController.buildOverviewAlertsGroups(from: overview, deviceID: "local")
        let exitAlertID = try #require(alerts.first?.items.first { $0.processStatus == .exited }?.attentionID)

        let undismissedRow = try #require(
            AppKitController.buildCommandPaletteItems(overview: overview, alertsGroups: alerts).first {
                $0.source == .workspaceTarget && $0.kind == .process
            })
        guard case .process(.exited) = undismissedRow.status else {
            Issue.record("expected an undismissed exit to read as exited")
            return
        }

        let dismissedRow = try #require(
            AppKitController.buildCommandPaletteItems(overview: overview, alertsGroups: alerts, dismissedAttentionItemIDs: [exitAlertID]).first {
                $0.source == .workspaceTarget && $0.kind == .process
            })
        guard case .idle = dismissedRow.status else {
            Issue.record("expected an acknowledged exit to read as idle")
            return
        }
    }

    @Test func commandPaletteBellAlertFallsBackToSessionForegroundCommand() throws {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, notes: nil, sessionCount: 1,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded), config: SpacesDeviceWorkspaceConfig(),
                    terminalRows: [
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "terminal-shell", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/project-feature",
                            sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
                    ])
            ],
            sessions: [
                SpacesDeviceTerminalSessionSummary(
                    id: "session-shell", title: "shell-1", liveTitle: nil, workingDirectory: "/device/project-feature", shell: "/bin/zsh",
                    command: nil, state: .running, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: nil,
                    workspaceID: "workspace-1", workspaceTitle: nil, projectID: "project-1", projectName: "Project",
                    createdAt: "2026-08-14T09:00:00Z", updatedAt: "2026-08-14T09:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true,
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(), foregroundCommand: "make test", bellAt: "2026-08-14T09:02:00Z")
            ])
        let alerts = AlertsController.buildOverviewAlertsGroups(from: overview, deviceID: "local")

        let items = AppKitController.buildCommandPaletteItems(overview: overview, alertsGroups: alerts)
        let alert = try #require(items.first { $0.source == .alertsAttention && $0.label == "shell-1" })

        #expect(alert.detail == "make test")
    }

    @Test func commandPaletteAgentAlertPreservesLiveDetailWhenOverviewDoesNotContainAgent() throws {
        let focusRequest = AppKitController.WindowFocusRequest.agentWindow(
            AgentWindowRecord(
                id: "remote-agent", workspaceID: "remote-workspace", provider: .spaces, label: "Remote Codex", terminalTrackingID: "remote-session",
                sessionKey: nil, status: .waiting, createdAt: "2026-08-14T09:00:00Z", updatedAt: "2026-08-14T09:00:00Z"))
        let alerts = [
            AppKitController.AlertsGroup(
                projectName: "Remote Project", workspaceID: "remote-workspace", workspaceName: "Remote Workspace", workspaceBranch: "feature",
                isFromHiddenWorkspace: false,
                items: [
                    AppKitController.AlertsAttentionEntry(
                        attentionID: "remote-agent-alert", icon: "cpu.fill", iconTint: .warning, label: "Remote Codex",
                        detail: "  waiting for review  ", shortcut: "", processStatus: nil, agentStatus: .waiting, countsTowardBadge: true,
                        eventDate: nil, focusRequest: focusRequest)
                ])
        ]

        let items = AppKitController.buildCommandPaletteItems(
            overview: SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: []), alertsGroups: alerts)
        let alert = try #require(items.first { $0.source == .alertsAttention })

        #expect(alert.detail == "waiting for review")
    }

    @Test func commandPaletteBellAlertPreservesLiveDetailWhenOverviewDoesNotContainSession() throws {
        let focusRequest = AppKitController.WindowFocusRequest.terminalSession(workspaceID: "remote-workspace", sessionID: "remote-session")
        let alerts = [
            AppKitController.AlertsGroup(
                projectName: "Remote Project", workspaceID: "remote-workspace", workspaceName: "Remote Workspace", workspaceBranch: "feature",
                isFromHiddenWorkspace: false,
                items: [
                    AppKitController.AlertsAttentionEntry(
                        attentionID: "remote-bell-alert", icon: "terminal", iconTint: .terminal, label: "shell-1", detail: "  vim remote.swift  ",
                        shortcut: "", processStatus: nil, agentStatus: nil, countsTowardBadge: true, eventDate: nil, focusRequest: focusRequest)
                ])
        ]

        let items = AppKitController.buildCommandPaletteItems(
            overview: SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: []), alertsGroups: alerts)
        let alert = try #require(items.first { $0.source == .alertsAttention })

        #expect(alert.detail == "vim remote.swift")
    }

    @Test func mergedRemoteAlertsCarryOwningOverviewForegroundCommandsIntoLocalPaletteAndDedupe() throws {
        let remoteOverview = SpacesDeviceOverviewPayload(
            projects: [
                SpacesDeviceProjectSummary(
                    id: "remote-project", name: "Remote Project", dir: "/remote/project", isGitRepo: true, defaultBranch: "main")
            ],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "remote-workspace", projectID: "remote-project", projectName: "Remote Project", branch: "feature", baseBranch: "main",
                    dir: "/remote/project-feature", isRunning: true, isHidden: false, isDefault: false, notes: nil, sessionCount: 2,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded), config: SpacesDeviceWorkspaceConfig(),
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:remote", workspaceID: "remote-workspace", name: "Remote Codex", command: "codex", agentID: "remote-agent",
                            sessionID: "remote-agent-session", runState: .running, activityState: .waiting, updatedAt: "2026-08-14T09:00:00Z",
                            canStop: true)
                    ])
            ],
            sessions: [
                terminalSessionSummary(
                    id: "remote-agent-session", title: "Remote Codex", foregroundCommand: "codex --remote", workspaceID: "remote-workspace"),
                terminalSessionSummary(
                    id: "remote-bell-session", title: "remote-shell", foregroundCommand: "make remote-test", workspaceID: "remote-workspace",
                    bellAt: "2026-08-14T09:01:00Z"),
            ])
        let mergedAlerts = AlertsController.buildOverviewAlertsGroups(from: remoteOverview, deviceID: "remote-device")
        let localOverview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])

        let items = AppKitController.buildCommandPaletteItems(overview: localOverview, alertsGroups: mergedAlerts)
        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: items, query: "", currentWorkspaceID: nil, recentFocusIdentities: [], maxEmptyQueryItems: 20)

        let agentRows = visible.filter { $0.label == "Remote Codex" }
        #expect(agentRows.count == 1)
        #expect(try #require(agentRows.first).detail == "codex --remote")
        let bellRows = visible.filter { $0.label == "remote-shell" }
        #expect(bellRows.count == 1)
        #expect(try #require(bellRows.first).detail == "make remote-test")
    }

    @Test func deviceTerminalRowsRenderThroughWorkspaceRuntimeRows() {
        let terminalRows = [
            SpacesDeviceWorkspaceTerminalRow(
                id: "terminal-shell", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/project-feature",
                sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
        ]

        let windows = AppKitController.deviceTerminalWindows(from: terminalRows)
        let entries = AppKitController.orderedWorkspaceRunProcessEntries(configuredProcesses: [], windows: windows, processes: [], agentWindows: [])
        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: [], processEntries: entries, processesByID: [:], agentWindows: [])

        #expect(windows.map(\.terminalTrackingKey) == ["terminal:session-shell"])
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .window)
        #expect(entries.first?.windowListIndex == 0)
        #expect(shortcutTargets.map(\.kind) == [.window])
    }

    @Test func deviceProcessTerminalRowsDoNotDuplicateProcessRuntimeRows() {
        let terminalRows = [
            SpacesDeviceWorkspaceTerminalRow(
                id: "terminal-web", workspaceID: "workspace-1", title: "web", workingDirectory: "/device/project-feature", sessionID: "session-web",
                runState: .running, canOpenTerminal: true, canStop: true)
        ]
        let configuredProcesses = [ProcessTemplate(id: "process-web", name: "web", command: "npm run dev")]
        let runningProcesses = [
            RunningProcessRecord(
                id: "running-web", workspaceID: "workspace-1", templateID: "process-web", templateName: "web", command: "npm run dev",
                terminalApp: "Spaces", terminalTrackingID: "session-web", pid: 123, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil,
                exitedAt: nil)
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: AppKitController.deviceTerminalWindows(from: terminalRows),
            processes: runningProcesses, agentWindows: [])

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "running-web")
    }

    @Test func deviceShortcutResolvesRunningProcessToRemoteTerminalOpen() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, notes: nil, sessionCount: 1,
                    assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded),
                    config: SpacesDeviceWorkspaceConfig(processes: [
                        SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev")
                    ]),
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-1", name: "web", command: "npm run dev", templateID: "process-web",
                            processID: "running-web", sessionID: "session-web", runState: .running, canRun: false, canStop: true, canRestart: true)
                    ])
            ], sessions: [])

        let resolution = AppKitController.deviceWindowShortcutResolution(index: 1, selectedWorkspaceID: "workspace-1", overview: overview)

        #expect(
            resolution
                == .openTerminal(
                    AppKitController.DeviceTerminalOpenRequest(
                        workspaceID: "workspace-1", sessionID: "session-web", title: "web", workingDirectory: "/device/project-feature",
                        kind: .process)))
    }

    @Test func windowFocusResolutionMapsAlertsRequestsToSharedTargets() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1,
                    config: SpacesDeviceWorkspaceConfig(processes: [
                        SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev")
                    ]),
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-1", name: "web", command: "npm run dev", templateID: "process-web",
                            processID: "running-web", sessionID: "session-web", runState: .running, canRun: false, canStop: true, canRestart: true)
                    ])
            ], sessions: [])

        // A browser attention item maps to the device-agnostic openURL target carrying its workspace.
        #expect(
            AppKitController.windowFocusResolution(
                for: .workspaceBrowserSession(workspaceID: "workspace-1", targetURL: "http://localhost:3000"), overview: overview)
                == .openURL(workspaceID: "workspace-1", targetURL: "http://localhost:3000"))

        // A running-process attention item maps to the same openTerminal target the numbered path produces,
        // falling back to the row's title/dir when the session is not yet in the catalog.
        #expect(
            AppKitController.windowFocusResolution(for: .workspaceProcess(workspaceID: "workspace-1", processID: "running-web"), overview: overview)
                == .openTerminal(
                    AppKitController.DeviceTerminalOpenRequest(
                        workspaceID: "workspace-1", sessionID: "session-web", title: "web", workingDirectory: "/device/project-feature",
                        kind: .process)))

        // A missing-configured-process item maps to a run via the Device API with the resolved template id.
        #expect(
            AppKitController.windowFocusResolution(
                for: .workspaceMissingConfiguredProcess(workspaceID: "workspace-1", processKey: "web"), overview: overview)
                == .runProcess(workspaceID: "workspace-1", processKey: "web", processTemplateID: "process-web"))
    }

    @Test func anUnreachableDeviceKeepsItsRowsInTheMergedSidebarData() {
        // An outage must not erase the device's subtree: its projects, workspaces, runtime state, and
        // alerts stay merged for the whole outage, so the user keeps browsing them, the selection under
        // the device stays valid, and every id-based lookup that reads this merged data still resolves
        // its rows. A device mid-retry (`.loading` after an outage) keeps them for the same reason.
        let offline = deviceSection(deviceID: "remote", loadState: .offline("Connection refused"))
        let retrying = deviceSection(deviceID: "retrying", loadState: .loading)
        let loaded = deviceSection(deviceID: "local", loadState: .loaded)

        let merged = AppKitController.mergedSidebarData(sections: [loaded, offline, retrying])

        #expect(merged.projects.map(\.id) == ["proj-local", "proj-remote", "proj-retrying"])
        #expect(merged.workspacesByProject["proj-remote"]?.map(\.id) == ["ws-remote"])
        #expect(merged.workspaceRuntimeStatusByID["ws-remote"] != nil)
        #expect(merged.alertsGroups.map(\.workspaceID) == ["ws-local", "ws-remote", "ws-retrying"])
    }

    @Test func anUnreachableDevicesRowsAreDimmed() {
        // The rows stay listed but read as not actionable. Dimming plus the section caption is the whole
        // treatment — no per-row icon — and a device mid-retry stays dimmed until its load lands.
        #expect(AppKitController.sidebarRowAlpha(loadState: .loaded) == 1)
        #expect(AppKitController.sidebarRowAlpha(loadState: .offline("Connection refused")) == AppKitController.unreachableDeviceAlpha)
        #expect(AppKitController.sidebarRowAlpha(loadState: .loading) == AppKitController.unreachableDeviceAlpha)
    }

    /// One device section carrying a project, its workspace, that workspace's runtime status, and one
    /// alerts group — enough for the merge to be observable per device.
    private func deviceSection(deviceID: String, loadState: AppKitController.SidebarDeviceLoadState) -> AppKitController.DeviceSection {
        let projectID = "proj-\(deviceID)"
        let workspaceID = "ws-\(deviceID)"
        return AppKitController.DeviceSection(
            deviceID: deviceID, deviceName: deviceID, isLocal: deviceID == "local", loadState: loadState, device: nil,
            projects: [
                ProjectSummary(id: projectID, name: deviceID, dir: "/\(deviceID)", isGitRepo: true, defaultBranch: "main", deviceID: deviceID)
            ],
            workspacesByProject: [
                projectID: [
                    WorkspaceSummary(
                        id: workspaceID, branch: "feature", dir: "/\(deviceID)/feature", isRunning: true, isDefault: false, deviceID: deviceID)
                ]
            ],
            workspaceRuntimeStatusByID: [
                workspaceID: WorkspaceRuntimeStatus(
                    workspaceID: workspaceID, lifecycleState: .running, runtimeHealth: .healthy, hasTrackedRuntimeIndicators: false,
                    runningProcessCount: 1, exitedProcessCount: 0, waitingAgentWindowCount: 0, missingConfiguredProcessCount: 0,
                    missingConfiguredBrowserSessionCount: 0)
            ],
            alertsGroups: [
                AppKitController.AlertsGroup(
                    projectName: deviceID, workspaceID: workspaceID, workspaceName: "feature", workspaceBranch: "feature",
                    isFromHiddenWorkspace: false, items: [])
            ])
    }

    @Test func deviceSectionDisplayNameRendersLocalDeviceAsLocalRegardlessOfStoredName() {
        // The local device's rendered label is always "Local", no matter what machine name is
        // stored for it; a remote device keeps showing its stored name.
        let local = AppKitController.DeviceSection(
            deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: "Yogesh's MacBook Pro", isLocal: true, loadState: .loaded, device: nil)
        #expect(local.displayName == "Local")

        let remote = AppKitController.DeviceSection(deviceID: "remote", deviceName: "Build Host", isLocal: false, loadState: .loaded, device: nil)
        #expect(remote.displayName == "Build Host")
    }

    @Test func waitingAgentAlertResolvesToFocusingItsSession() {
        // An attention alert for a waiting/done agent focuses that agent's existing session. Build the
        // alert through the real overview path, then resolve its focus request end to end.
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1,
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:agent-1", workspaceID: "workspace-1", name: "Codex", command: "codex", agentID: "agent-1",
                            sessionID: "session-agent", runState: .running, activityState: .waiting, updatedAt: "2026-06-28T09:00:00Z", canStop: true)
                    ])
            ], sessions: [])

        let groups = AlertsController.buildOverviewAlertsGroups(from: overview, deviceID: "local")
        guard let focusRequest = groups.first?.items.first?.focusRequest else {
            Issue.record("expected an agent attention alert with a focus request")
            return
        }
        guard case .agentWindow(let record) = focusRequest else {
            Issue.record("expected the agent alert to focus an existing agent window, got \(focusRequest)")
            return
        }
        #expect(record.id == "agent-1")
        #expect(record.workspaceID == "workspace-1")

        // Resolving it opens the agent's terminal session.
        #expect(
            AppKitController.windowFocusResolution(for: focusRequest, overview: overview)
                == .openTerminal(
                    AppKitController.DeviceTerminalOpenRequest(
                        workspaceID: "workspace-1", sessionID: "session-agent", title: "Codex", workingDirectory: "/device/project-feature",
                        kind: .agent)))
    }

    @Test func deviceTerminalOpenRequestPreservesStartingSessionMetadata() {
        let session = SpacesDeviceTerminalSessionSummary(
            id: "session-starting", title: "shell-1", workingDirectory: "/device/project-feature", shell: "/bin/zsh", command: nil, state: .starting,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 321, childPID: nil, workspaceID: "workspace-1",
            workspaceTitle: "Feature", projectID: "project-1", projectName: "Project", createdAt: "2026-06-22T12:00:00Z",
            updatedAt: "2026-06-22T12:00:01Z", isControlAvailable: false, isSubscriptionAvailable: false,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .liveSession)
        let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [session])

        let request = AppKitController.deviceTerminalOpenRequest(workspaceID: "workspace-fallback", sessionID: "session-starting", overview: overview)

        #expect(
            request
                == AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", sessionID: "session-starting", title: "shell-1", workingDirectory: "/device/project-feature",
                    kind: .shell, shell: "/bin/zsh", command: nil, initialState: .starting, servicePID: 321, childPID: nil,
                    createdAt: "2026-06-22T12:00:00Z", updatedAt: "2026-06-22T12:00:01Z"))
    }

    private func automationSummary(
        id: String = "auto-1", name: String, kind: AutomationKind, script: String = "", workspaceID: String = "workspace-1"
    ) -> TerminalServiceAutomationSummary {
        TerminalServiceAutomationSummary(
            id: id, name: name, enabled: true, triggerKind: "manual", cronExpression: nil, kind: kind.rawValue, script: script,
            agentCommand: kind == .agent ? "codex" : nil, agentPrompt: kind == .agent ? "do it" : nil, workspaceID: workspaceID, timeoutSeconds: nil,
            concurrencyPolicy: "allow", missedRunPolicy: "run_once", nextFireTime: nil, createdAt: "2026-06-22T12:00:00Z",
            updatedAt: "2026-06-22T12:00:00Z")
    }

    private func automationRunSummary(
        automationID: String = "auto-1", kind: AutomationKind, status: String, terminalSessionID: String?, workspaceID: String? = "workspace-1"
    ) -> TerminalServiceAutomationRunSummary {
        TerminalServiceAutomationRunSummary(
            id: "run-1", automationID: automationID, automationName: nil, kind: kind.rawValue, status: status, trigger: "manual", skipReason: nil,
            exitCode: nil, terminalSessionID: terminalSessionID, workspaceID: workspaceID, startedAt: nil, endedAt: nil,
            createdAt: "2026-06-22T12:00:00Z")
    }

    // A script-kind run's terminal opens in its persisted workspace.
    @Test func automationRunTerminalRequestSynthesizesScriptKindPane() {
        let automation = automationSummary(name: "Nightly", kind: .script, script: "echo hi")
        let run = automationRunSummary(kind: .script, status: "running", terminalSessionID: "auto-session")

        let request = AppKitController.automationRunTerminalOpenRequest(
            deviceID: "local", sessionID: "auto-session", run: run, automation: automation, overview: nil, loginShell: "/bin/zsh")

        #expect(
            request
                == AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", deviceID: "local", sessionID: "auto-session", title: "Nightly", workingDirectory: "",
                    kind: .automation, shell: "/bin/zsh", command: "echo hi", initialState: .running))
    }

    // A live agent session resolves from the overview.
    @Test func automationRunTerminalRequestResolvesAgentKindFromOverview() {
        let session = SpacesDeviceTerminalSessionSummary(
            id: "agent-session", title: "Codex", workingDirectory: "/device/project-feature", shell: "/bin/zsh", command: "codex", state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 321, childPID: 654, workspaceID: "workspace-1",
            workspaceTitle: "Feature", projectID: "project-1", projectName: "Project", createdAt: "2026-06-22T12:00:00Z",
            updatedAt: "2026-06-22T12:00:01Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .agent)
        let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [session])
        let automation = automationSummary(name: "Reviewer", kind: .agent, workspaceID: "workspace-1")
        let run = automationRunSummary(kind: .agent, status: "running", terminalSessionID: "agent-session")

        let request = AppKitController.automationRunTerminalOpenRequest(
            deviceID: "local", sessionID: "agent-session", run: run, automation: automation, overview: overview, loginShell: "/bin/zsh")

        #expect(
            request
                == AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", deviceID: "local", sessionID: "agent-session", title: "Codex",
                    workingDirectory: "/device/project-feature", kind: .agent, shell: "/bin/zsh", command: "codex", initialState: .running,
                    servicePID: 321, childPID: 654, createdAt: "2026-06-22T12:00:00Z", updatedAt: "2026-06-22T12:00:01Z"))
    }

    // An ended agent session replays in the workspace persisted on its run.
    @Test func automationRunTerminalRequestFallsBackForEndedAgentSession() {
        let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])
        let automation = automationSummary(name: "Reviewer", kind: .agent, workspaceID: "workspace-1")
        let run = automationRunSummary(kind: .agent, status: "succeeded", terminalSessionID: "gone-session")

        let request = AppKitController.automationRunTerminalOpenRequest(
            deviceID: "local", sessionID: "gone-session", run: run, automation: automation, overview: overview, loginShell: "/bin/zsh")

        #expect(
            request
                == AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", deviceID: "local", sessionID: "gone-session", title: "Reviewer", workingDirectory: "", kind: .agent,
                    shell: "/bin/zsh", command: "codex", initialState: .exited))
    }

    // A run without a persisted session workspace has no pane destination.
    @Test func automationRunTerminalRequestFallsBackForEndedAgentSessionWithNoAutomation() {
        let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])
        let run = automationRunSummary(kind: .agent, status: "succeeded", terminalSessionID: "gone-session")

        let request = AppKitController.automationRunTerminalOpenRequest(
            deviceID: "local", sessionID: "gone-session", run: run, automation: nil, overview: overview, loginShell: "/bin/zsh")

        #expect(
            request
                == AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", deviceID: "local", sessionID: "gone-session", title: "Automation", workingDirectory: "", kind: .agent,
                    shell: "/bin/zsh", command: nil, initialState: .exited))
    }

    @Test func automationRunTerminalRequestRequiresPersistedSessionWorkspace() {
        let run = automationRunSummary(kind: .script, status: "succeeded", terminalSessionID: "gone-session", workspaceID: nil)

        #expect(
            AppKitController.automationRunTerminalOpenRequest(
                deviceID: "local", sessionID: "gone-session", run: run, automation: nil, overview: nil, loginShell: "/bin/zsh") == nil)
    }

    // Dispatch keys off the run's kind, not the automation's current kind.
    @Test func automationRunTerminalRequestUsesRunKindWhenAutomationBecameAgent() {
        let automation = automationSummary(name: "Nightly", kind: .agent, script: "echo hi", workspaceID: "edited-workspace")
        let run = automationRunSummary(kind: .script, status: "succeeded", terminalSessionID: "auto-session")

        let request = AppKitController.automationRunTerminalOpenRequest(
            deviceID: "local", sessionID: "auto-session", run: run, automation: automation, overview: nil, loginShell: "/bin/zsh")

        #expect(
            request
                == AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", deviceID: "local", sessionID: "auto-session", title: "Nightly", workingDirectory: "",
                    kind: .automation, shell: "/bin/zsh", command: "echo hi", initialState: .exited))
    }

    // The reverse uses the run's agent shape with its persisted workspace.
    @Test func automationRunTerminalRequestUsesRunKindWhenAutomationBecameScript() {
        let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])
        let automation = automationSummary(name: "Reviewer", kind: .script, script: "echo hi")
        let run = automationRunSummary(kind: .agent, status: "succeeded", terminalSessionID: "gone-session")

        let request = AppKitController.automationRunTerminalOpenRequest(
            deviceID: "local", sessionID: "gone-session", run: run, automation: automation, overview: overview, loginShell: "/bin/zsh")

        #expect(
            request
                == AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", deviceID: "local", sessionID: "gone-session", title: "Reviewer", workingDirectory: "", kind: .agent,
                    shell: "/bin/zsh", command: nil, initialState: .exited))
    }

    @Test func terminalOpenRequestColdResolutionIsSkippedForExistingPane() {
        let fallbackRequest = AppKitController.DeviceTerminalOpenRequest(
            workspaceID: "workspace-1", sessionID: "session-1", title: "shell-1", workingDirectory: "/device/project-feature", kind: .shell)
        let resolvedRequest = AppKitController.DeviceTerminalOpenRequest(
            workspaceID: "workspace-1", sessionID: "session-1", title: "shell-1", workingDirectory: "/device/project-feature", kind: .shell,
            shell: "/bin/zsh")

        #expect(AppKitController.terminalOpenRequestNeedsColdResolution(fallbackRequest, hasExistingPane: false))
        #expect(!AppKitController.terminalOpenRequestNeedsColdResolution(fallbackRequest, hasExistingPane: true))
        #expect(!AppKitController.terminalOpenRequestNeedsColdResolution(resolvedRequest, hasExistingPane: false))
    }

    @Test func deviceShortcutResolvesStartingTerminalRowWithSessionMetadata() {
        let session = startingSessionSummary(id: "session-starting-shell", title: "shell-1", rowKind: .liveSession)
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1,
                    terminalRows: [
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "terminal-shell", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/project-feature",
                            sessionID: "session-starting-shell", runState: .running, canOpenTerminal: true, canStop: true)
                    ])
            ], sessions: [session])

        let resolution = AppKitController.deviceWindowShortcutResolution(index: 1, selectedWorkspaceID: "workspace-1", overview: overview)

        #expect(
            resolution
                == .openTerminal(
                    AppKitController.DeviceTerminalOpenRequest(
                        workspaceID: "workspace-1", sessionID: "session-starting-shell", title: "shell-1",
                        workingDirectory: "/device/project-feature", kind: .shell, shell: "/bin/zsh", command: nil, initialState: .starting,
                        servicePID: 321, childPID: nil, createdAt: "2026-06-22T12:00:00Z", updatedAt: "2026-06-22T12:00:01Z")))
    }

    @Test func deviceShortcutResolvesStartingProcessWithSessionMetadata() {
        let session = startingSessionSummary(id: "session-starting-process", title: "web", rowKind: .process)
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1,
                    config: SpacesDeviceWorkspaceConfig(processes: [
                        SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev")
                    ]),
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-1", name: "web", command: "npm run dev", templateID: "process-web",
                            processID: "running-web", sessionID: "session-starting-process", runState: .running, canRun: false, canStop: true,
                            canRestart: true)
                    ])
            ], sessions: [session])

        let resolution = AppKitController.deviceWindowShortcutResolution(index: 1, selectedWorkspaceID: "workspace-1", overview: overview)

        #expect(
            resolution
                == .openTerminal(
                    AppKitController.DeviceTerminalOpenRequest(
                        workspaceID: "workspace-1", sessionID: "session-starting-process", title: "web", workingDirectory: "/device/project-feature",
                        kind: .process, shell: "/bin/zsh", command: nil, initialState: .starting, servicePID: 321, childPID: nil,
                        createdAt: "2026-06-22T12:00:00Z", updatedAt: "2026-06-22T12:00:01Z")))
    }

    @Test func deviceShortcutResolvesStartingAgentWithSessionMetadata() {
        let session = startingSessionSummary(id: "session-starting-agent", title: "Codex", rowKind: .agent)
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1,
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent:running-agent", workspaceID: "workspace-1", name: "Codex", command: "codex", agentID: "running-agent",
                            sessionID: "session-starting-agent", runState: .running, activityState: .waiting, canStop: true)
                    ])
            ], sessions: [session])

        let resolution = AppKitController.deviceWindowShortcutResolution(index: 1, selectedWorkspaceID: "workspace-1", overview: overview)

        #expect(
            resolution
                == .openTerminal(
                    AppKitController.DeviceTerminalOpenRequest(
                        workspaceID: "workspace-1", sessionID: "session-starting-agent", title: "Codex", workingDirectory: "/device/project-feature",
                        kind: .agent, shell: "/bin/zsh", command: nil, initialState: .starting, servicePID: 321, childPID: nil,
                        createdAt: "2026-06-22T12:00:00Z", updatedAt: "2026-06-22T12:00:01Z")))
    }

    @Test func deviceTerminalControlRequestTranslatesRendererControlPayload() throws {
        let control = TerminalControlRequest(command: "resize", clientID: "mac-client", columns: 120, rows: 40, ownerEpoch: 7, resizeSerial: 3)

        let request = try AppKitController.deviceTerminalControlRequest(sessionID: "session-web", controlRequest: control)

        #expect(request.action == .resize)
        #expect(request.sessionID == "session-web")
        #expect(request.clientID == "mac-client")
        #expect(request.columns == 120)
        #expect(request.rows == 40)
        #expect(request.ownerEpoch == 7)
        #expect(request.resizeSerial == 3)
    }

    @Test func deviceTerminalControlRequestCarriesMouseButtonAndPointerToTheDaemon() throws {
        // The daemon rejects a mouseButton control with no button or pointer, so every field of the
        // click must survive the device-API conversion for a mirror click to reach the application.
        let control = TerminalControlRequest(
            command: .mouseButton(
                TerminalControlMouseButtonPayload(
                    clientID: "mac-client", ownerEpoch: 7, button: 1, pressed: true, pointerX: 0.25, pointerY: 0.75, pointerMods: 4)))

        let request = try AppKitController.deviceTerminalControlRequest(sessionID: "session-web", controlRequest: control)

        #expect(request.action == .mouseButton)
        #expect(request.clientID == "mac-client")
        #expect(request.ownerEpoch == 7)
        #expect(request.mouseButton == 1)
        #expect(request.mousePressed == true)
        #expect(request.mousePointerX == 0.25)
        #expect(request.mousePointerY == 0.75)
        #expect(request.mousePointerMods == 4)
    }

    @Test func deviceTerminalControlRequestPreservesPasteIntent() throws {
        let control = TerminalControlRequest(
            command: .send(
                TerminalControlSendPayload(
                    text: "line one\nline two", bytes: nil, clientID: "mac-client", ownerEpoch: 7, appendNewline: false, asPaste: true)))

        let request = try AppKitController.deviceTerminalControlRequest(sessionID: "session-web", controlRequest: control)

        #expect(request.action == .send)
        #expect(request.text == "line one\nline two")
        #expect(request.asPaste)
    }

    @Test func deviceTerminalControlRequestCarriesAttachAppearanceToTheDaemon() throws {
        // The attaching client's OS appearance must survive the device-API conversion; otherwise the remote
        // Linux daemon never learns the client's light/dark preference and keeps its default theme.
        let control = TerminalControlRequest(command: "attach", attachmentMode: .owner, appearance: .light)

        let request = try AppKitController.deviceTerminalControlRequest(sessionID: "session-web", controlRequest: control)

        #expect(request.action == .attach)
        #expect(request.appearance == .light)
    }

    @Test func deviceTerminalControlRequestMapsSetAppearanceToTheDaemon() throws {
        // A live theme switch flows through the same device-API conversion as attach; the action and
        // the requested appearance must both survive so the remote daemon re-themes its live session.
        let control = TerminalControlRequest(command: .setAppearance(TerminalControlSetAppearancePayload(clientID: "mac-client", appearance: .dark)))

        let request = try AppKitController.deviceTerminalControlRequest(sessionID: "session-web", controlRequest: control)

        #expect(request.action == .setAppearance)
        #expect(request.appearance == .dark)
        #expect(request.clientID == "mac-client")
    }

    @Test func appearanceChangeFansOutSetAppearanceToEachLiveSessionOnceWithResolvedValue() {
        // An app appearance change re-themes every open session once, carrying the resolved light/dark value,
        // and dedupes: a session already on that appearance (or a repeat broadcast of the same value) sends
        // nothing more.
        let recorder = AppearanceControlRecorder()
        let noopApply: @Sendable (GhosttyRemoteSessionStatePayload) -> Void = { _ in }

        var appearanceA: ThemeAppearance = .light
        var appearanceB: ThemeAppearance = .light
        appearanceA = AppKitController.applyAppearanceToLiveSession(
            .dark, sessionID: "session-a", clientID: "client-a", lastAppliedAppearance: appearanceA, requestSender: recorder.send,
            applyState: noopApply)
        appearanceB = AppKitController.applyAppearanceToLiveSession(
            .dark, sessionID: "session-b", clientID: "client-b", lastAppliedAppearance: appearanceB, requestSender: recorder.send,
            applyState: noopApply)

        #expect(appearanceA == .dark)
        #expect(appearanceB == .dark)
        #expect(recorder.sends.count == 2)
        #expect(recorder.sends.contains { $0.sessionID == "session-a" && $0.appearance == .dark })
        #expect(recorder.sends.contains { $0.sessionID == "session-b" && $0.appearance == .dark })

        // A redundant broadcast of the same appearance to an already-dark session sends nothing.
        appearanceA = AppKitController.applyAppearanceToLiveSession(
            .dark, sessionID: "session-a", clientID: "client-a", lastAppliedAppearance: appearanceA, requestSender: recorder.send,
            applyState: noopApply)
        #expect(appearanceA == .dark)
        #expect(recorder.sends.count == 2)
    }

    @Test func appearanceChangeBeforeAttachIsRecordedForThePendingAttachToCarry() {
        // A pane whose client has not attached yet has no clientID to send `setAppearance` with, so the
        // broadcast sends nothing — but it still advances the stored appearance so the pending attach
        // carries the current variant. Without that, a change landing before attach would be lost and the
        // session would attach with the stale variant until the next flip.
        let recorder = AppearanceControlRecorder()

        // Appearance flips to dark while unattached: nothing sent, but the stored value advances to dark.
        let recorded = AppKitController.applyAppearanceToLiveSession(
            .dark, sessionID: "session-a", clientID: nil, lastAppliedAppearance: .light, requestSender: recorder.send, applyState: { _ in })
        #expect(recorded == .dark)
        #expect(recorder.sends.isEmpty)

        // The attach then carries dark and the client is present; a follow-up broadcast of dark dedupes
        // against the recorded value, so it does not double-send what the attach already applied.
        let afterAttach = AppKitController.applyAppearanceToLiveSession(
            .dark, sessionID: "session-a", clientID: "client-a", lastAppliedAppearance: recorded, requestSender: recorder.send, applyState: { _ in })
        #expect(afterAttach == .dark)
        #expect(recorder.sends.isEmpty)
    }

    @Test func remoteBrowserRoutePlanMapsLoopbackServicePortToCaddyURL() throws {
        let plan = try #require(
            BrowserSSHForwardManager.routePlan(
                targetURL: "http://localhost:32001/docs/?tab=api#readme",
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:7391")]))

        #expect(plan.serviceName == "web")
        #expect(plan.remotePort == 32001)
        #expect(plan.routeHost == "web.feature-123.localhost")
        #expect(plan.browserURL.absoluteString == "http://web.feature-123.localhost:7391/docs/?tab=api#readme")
    }

    @Test func remoteBrowserRoutePlanKeepsConfiguredCaddyServiceURL() throws {
        let plan = try #require(
            BrowserSSHForwardManager.routePlan(
                targetURL: "http://web.feature-123.localhost:7391/admin/",
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:7391")]))

        #expect(plan.serviceName == "web")
        #expect(plan.remotePort == 32001)
        #expect(plan.routeHost == "web.feature-123.localhost")
        #expect(plan.browserURL.absoluteString == "http://web.feature-123.localhost:7391/admin/")
    }

    @Test func remoteBrowserRoutePlanUsesLocalCaddyRouterPort() throws {
        let plan = try #require(
            BrowserSSHForwardManager.routePlan(
                targetURL: "http://web.feature-123.localhost:9000/admin/",
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:9000")],
                localRouterPort: 7391))

        #expect(plan.browserURL.absoluteString == "http://web.feature-123.localhost:7391/admin/")
    }

    @Test func remoteBrowserRoutePlanLeavesExternalURLsUnchanged() {
        let plan = BrowserSSHForwardManager.routePlan(
            targetURL: "https://example.com/docs",
            assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:7391")])

        #expect(plan == nil)
    }

    @Test func remoteBrowserSSHArgumentsUsePairedDeviceSSHMetadata() throws {
        let device = SpacesPairedDeviceRecord(
            id: "remote", name: "Build Host", platform: "linux", hosts: ["10.0.0.4"], port: 7443, certificateFingerprint: "fingerprint",
            sshHost: "build.example", sshUser: "dev", sshPort: 2200, createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z")

        let args = try BrowserSSHForwardManager.sshArguments(device: device, localPort: 41001, remotePort: 32001)

        #expect(
            args == [
                "-N", "-L", "127.0.0.1:41001:127.0.0.1:32001", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o",
                "StrictHostKeyChecking=yes", "-p", "2200", "dev@build.example",
            ])
    }

    @Test func remoteBrowserSSHArgumentsUseOneProcessForMultipleForwardBindings() throws {
        let device = SpacesPairedDeviceRecord(
            id: "remote", name: "Build Host", platform: "linux", hosts: ["10.0.0.4"], port: 7443, certificateFingerprint: "fingerprint",
            sshHost: "build.example", sshUser: "dev", sshPort: 2200, createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z")

        let args = try BrowserSSHForwardManager.sshArguments(
            device: device,
            bindings: [
                BrowserSSHForwardManager.SSHForwardBinding(localPort: 41001, remotePort: 32001),
                BrowserSSHForwardManager.SSHForwardBinding(localPort: 41002, remotePort: 32002),
            ])

        #expect(
            args == [
                "-N", "-L", "127.0.0.1:41001:127.0.0.1:32001", "-L", "127.0.0.1:41002:127.0.0.1:32002", "-o", "BatchMode=yes", "-o",
                "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=yes", "-p", "2200", "dev@build.example",
            ])
    }

    @Test func servicePortDisplayShowsRemoteAndForwardedLocalPortPair() {
        #expect(AppKitController.servicePortDisplay(assignedPort: 3000, forwardedLocalPort: 52341) == "3000:52341")
        #expect(AppKitController.servicePortDisplay(assignedPort: 3000, forwardedLocalPort: nil) == "3000")
        #expect(AppKitController.servicePortDisplay(assignedPort: nil, forwardedLocalPort: 52341) == nil)
        #expect(AppKitController.servicePortDisplay(assignedPort: 0, forwardedLocalPort: 52341) == nil)
    }

    @Test func servicePortDisplayTextsMatchForwardsByServiceNameAndRemotePort() {
        let texts = AppKitController.servicePortDisplayTexts(
            assignedPorts: [
                SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:7391"),
                SpacesDeviceAssignedPort(name: "api", port: 32002, url: "http://api.feature-123.localhost:7391"),
            ], forwards: [BrowserSSHForwardManager.ServiceForwardSnapshot(serviceName: "web", remotePort: 32001, localPort: 41001)])

        #expect(texts == ["32001:41001", "32002"])
    }

    @Test func forwardedServicePortsForUnknownWorkspaceIsEmpty() {
        #expect(BrowserSSHForwardManager().forwardedServicePorts(deviceID: "remote", workspaceID: "workspace-1").isEmpty)
    }

    private func terminalSessionSummary(
        id: String, title: String, foregroundCommand: String?, workspaceID: String = "workspace-1", bellAt: String? = nil
    ) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: title, workingDirectory: "/device/project-feature", shell: "/bin/zsh", command: nil, state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 321, childPID: nil, workspaceID: workspaceID,
            workspaceTitle: "Feature", projectID: "project-1", projectName: "Project", createdAt: "2026-06-22T12:00:00Z",
            updatedAt: "2026-06-22T12:00:01Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), foregroundCommand: foregroundCommand, bellAt: bellAt)
    }

    private func startingSessionSummary(id: String, title: String, rowKind: SpacesDeviceTerminalSessionRowKind) -> SpacesDeviceTerminalSessionSummary
    {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: title, workingDirectory: "/device/project-feature", shell: "/bin/zsh", command: nil, state: .starting,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 321, childPID: nil, workspaceID: "workspace-1",
            workspaceTitle: "Feature", projectID: "project-1", projectName: "Project", createdAt: "2026-06-22T12:00:00Z",
            updatedAt: "2026-06-22T12:00:01Z", isControlAvailable: false, isSubscriptionAvailable: false,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: rowKind)
    }

    /// Opening an ended terminal's pane for the first time — the session is in no loaded overview, so the
    /// pane is resolved cold against the device. The session exited and its terminal window record is all
    /// that holds it, which is the state a local daemon restart leaves behind, and the resolve has to come
    /// back with a request that can actually describe the pane: its workspace and its shell. The overview
    /// here is built by the daemon's own row derivation rather than hand-assembled, since whether the
    /// session is published at all is that derivation's decision.
    @Test func coldResolveOpensAnEndedSessionHeldOnlyByItsTerminalWindowRow() async throws {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-ended", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isRunning: true,
            lastLaunchedAt: nil)
        let endedWindow = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "Shell", terminalTrackingID: "session-ended", role: "terminal",
            orderIndex: 0, lastSeenAt: "now")
        let descriptor = SpacesDeviceOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace, windows: [endedWindow])
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-ended", backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "Shell", workingDirectory: "/repo/feature",
            shell: "/bin/zsh", command: "seq 1 300", createdAt: "2026-07-29T12:00:00Z", workspaceID: workspace.id, kind: .shell)
        let endedEntry = TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "session-ended", backend: .ghosttyEmbedded, servicePID: 321, childPID: 654, state: .exited,
                updatedAt: "2026-07-29T12:00:05Z", title: nil, workingDirectory: "/repo/feature"),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), paths: TerminalSessionPaths(rootDirectory: "/tmp/session-ended"),
            isControlAvailable: false, isSubscriptionAvailable: false)
        let rows = SpacesDeviceAPIServer.workspaceTerminalRows(
            workspaces: [descriptor], sessions: [], sessionIDsWithFinalRender: ["session-ended"],
            catalogEntry: { $0 == "session-ended" ? endedEntry : nil }, endedWindowSessions: ["session-ended": endedEntry])
        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [descriptor], workspaceRows: rows, liveSessions: [],
            daemonStatus: TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0))
        let device = SpacesPairedDeviceRecord(
            id: "local", name: "Mac", platform: "macos", hosts: ["127.0.0.1"], port: 19000, certificateFingerprint: "fingerprint",
            createdAt: "2026-06-01T00:00:00Z", updatedAt: "2026-06-01T00:00:00Z")
        let clientApp = SpacesDeviceClientApp(
            installationID: "install", bundleID: "com.example.Spaces", platform: "macos", deviceName: "Mac", appVersion: "1.0")

        let match = await AppKitController.resolveSessionSummaryMatchOffMain(
            sessionID: "session-ended", device: device, clientApp: clientApp,
            resolveOverview: { context in
                SpacesDeviceOverviewResolution(
                    overview: SpacesDeviceOverview(device: context.device, overview: overview), daemonStatus: nil, compatibility: nil)
            })

        let resolved = try #require(match)
        let request = AppKitController.terminalSessionPaneOpenRequest(from: resolved)
        #expect(request.sessionID == "session-ended")
        #expect(request.workspaceID == "workspace-ended")
        #expect(request.shell == "/bin/zsh")
        #expect(request.command == "seq 1 300")
        #expect(request.workingDirectory == "/repo/feature")
        #expect(request.kind == .shell)
        #expect(request.initialState == .exited)
        #expect(request.deviceID == "local")
    }

    @Test func coldTerminalOverviewLookupRunsOffMainThread() async {
        let recorder = ThreadRecorder()
        let device = SpacesPairedDeviceRecord(
            id: "local", name: "Mac", platform: "macos", hosts: ["127.0.0.1"], port: 19000, certificateFingerprint: "fingerprint",
            createdAt: "2026-06-01T00:00:00Z", updatedAt: "2026-06-01T00:00:00Z")
        let clientApp = SpacesDeviceClientApp(
            installationID: "install", bundleID: "com.example.Spaces", platform: "macos", deviceName: "Mac", appVersion: "1.0")
        let summary = SpacesDeviceTerminalSessionSummary(
            id: "session-cold", title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 123, childPID: nil, workspaceID: "workspace-cold", workspaceTitle: nil, projectID: nil,
            projectName: nil, createdAt: "2026-06-01T00:00:00Z", updatedAt: "2026-06-01T00:00:01Z", isControlAvailable: true,
            isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot())

        let match = await AppKitController.resolveSessionSummaryMatchOffMain(
            sessionID: "session-cold", device: device, clientApp: clientApp,
            resolveOverview: { context in
                recorder.record(Thread.isMainThread)
                return SpacesDeviceOverviewResolution(
                    overview: SpacesDeviceOverview(device: context.device, overview: SpacesDeviceOverviewPayload(workspaces: [], sessions: [summary])),
                    daemonStatus: nil, compatibility: nil)
            })

        #expect(match == AppKitController.TerminalSessionSummaryMatch(device: device, summary: summary))
        #expect(recorder.values == [false])
    }

    @Test func attachControlRefreshesSessionStateWhenResponseOmitsIt() throws {
        // A daemon that could not load the post-attach state answers without it, so the control
        // helper falls back to fetching that state and applying the new ownership immediately
        // instead of waiting for the live subscription to redeliver it.
        let refreshedSnapshot = attachmentSnapshot(ownerID: "mac-window")
        let refreshedState = sessionStatePayload(attachmentSnapshot: refreshedSnapshot)
        let recorder = ControlRequestRecorder(stateResponseSnapshot: refreshedState)
        let applied = AppliedStateBox()

        let response = try AppKitController.sendDeviceTerminalControl(
            sessionID: "session-1",
            request: TerminalControlRequest(
                command: "attach",
                client: TerminalClient(
                    id: "mac-window", kind: .localWindow, identity: .init(label: "mac-window"), connectedAt: "2026-06-22T12:00:00Z"),
                attachmentMode: .owner), requestSender: recorder.send, refreshStateAfterControl: true, applyState: { applied.store($0) })

        #expect(response.ok)
        #expect(recorder.issuedStateFetch)
        #expect(applied.payload?.attachmentSnapshot == refreshedSnapshot)
    }

    @Test func attachControlAppliesCarriedStateWithoutASecondRoundTrip() throws {
        // Attach responses carry the session state the attach produced, so the helper applies it
        // directly. Fetching it again would spend a second round trip — and a second full-frame
        // export — on every attach, including the one behind each terminal pane open.
        let carriedSnapshot = attachmentSnapshot(ownerID: "mac-window")
        let carriedState = sessionStatePayload(attachmentSnapshot: carriedSnapshot)
        let recorder = ControlRequestRecorder(stateResponseSnapshot: nil, controlResponseSnapshot: carriedState)
        let applied = AppliedStateBox()

        let response = try AppKitController.sendDeviceTerminalControl(
            sessionID: "session-1",
            request: TerminalControlRequest(
                command: "attach",
                client: TerminalClient(
                    id: "mac-window", kind: .localWindow, identity: .init(label: "mac-window"), connectedAt: "2026-06-22T12:00:00Z"),
                attachmentMode: .owner), requestSender: recorder.send, refreshStateAfterControl: true, applyState: { applied.store($0) })

        #expect(response.ok)
        #expect(!recorder.issuedStateFetch)
        #expect(applied.payload?.attachmentSnapshot == carriedSnapshot)
    }

    @Test func sendControlDoesNotFetchStateWhenRefreshNotRequested() throws {
        // Input controls (send/key) carry no ownership change, so the helper must not
        // pay for a follow-up state fetch and must leave the cached state untouched.
        let recorder = ControlRequestRecorder(stateResponseSnapshot: nil)
        let applied = AppliedStateBox()

        let response = try AppKitController.sendDeviceTerminalControl(
            sessionID: "session-1", request: TerminalControlRequest(command: "send", text: "ls", clientID: "mac-window", appendNewline: true),
            requestSender: recorder.send, refreshStateAfterControl: false, applyState: { applied.store($0) })

        #expect(response.ok)
        #expect(!recorder.issuedStateFetch)
        #expect(applied.payload == nil)
    }

    private func sessionStatePayload(attachmentSnapshot: TerminalSessionAttachmentSnapshot) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: "2026-06-22T12:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: attachmentSnapshot,
            title: "alpha", workingDirectory: "/tmp", outputByteCount: nil)
    }

    private func attachmentSnapshot(ownerID: String) -> TerminalSessionAttachmentSnapshot {
        let client = TerminalClient(id: ownerID, kind: .localWindow, identity: .init(label: ownerID), connectedAt: "2026-06-22T12:00:00Z")
        return TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [TerminalAttachment(sessionID: "session-1", clientID: ownerID, mode: .owner, attachedAt: "2026-06-22T12:00:00Z")])
    }

    /// Records whether the helper issued the follow-up `.state` fetch and replies to it
    /// with a fixed snapshot, so a test can assert the post-control refresh behavior.
    private final class ThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedValues: [Bool] = []

        var values: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return recordedValues
        }

        func record(_ value: Bool) {
            lock.lock()
            recordedValues.append(value)
            lock.unlock()
        }
    }

    private final class ControlRequestRecorder: @unchecked Sendable {
        private let stateResponseSnapshot: GhosttyRemoteSessionStatePayload?
        /// The state the control response itself carries, as an attach/detach/takeover response does.
        private let controlResponseSnapshot: GhosttyRemoteSessionStatePayload?
        private(set) var issuedStateFetch = false

        init(stateResponseSnapshot: GhosttyRemoteSessionStatePayload?, controlResponseSnapshot: GhosttyRemoteSessionStatePayload? = nil) {
            self.stateResponseSnapshot = stateResponseSnapshot
            self.controlResponseSnapshot = controlResponseSnapshot
        }

        var send: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse {
            { [self] request in
                switch request.command {
                case .control:
                    return TerminalServiceResponse(
                        ok: true, message: "", sessionState: controlResponseSnapshot, controlResponse: TerminalControlResponse(ok: true, message: ""))
                case .state:
                    issuedStateFetch = true
                    return TerminalServiceResponse(ok: true, message: "", sessionState: stateResponseSnapshot)
                default: return TerminalServiceResponse(ok: false, message: "unexpected command")
                }
            }
        }
    }

    private final class AppliedStateBox: @unchecked Sendable {
        private(set) var payload: GhosttyRemoteSessionStatePayload?
        func store(_ payload: GhosttyRemoteSessionStatePayload) { self.payload = payload }
    }

    /// Records the `setAppearance` control requests a fan-out issues, so a test can assert which sessions
    /// were re-themed and with what appearance. Replies ok to every request.
    private final class AppearanceControlRecorder: @unchecked Sendable {
        struct RecordedSend: Sendable {
            let sessionID: String
            let appearance: ThemeAppearance?
        }

        private let lock = NSLock()
        private var recorded: [RecordedSend] = []

        var sends: [RecordedSend] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var send: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse {
            { [self] request in
                if case .control(let payload) = request.command, payload.controlRequest.command == "setAppearance" {
                    lock.lock()
                    recorded.append(RecordedSend(sessionID: payload.sessionID, appearance: payload.controlRequest.appearance))
                    lock.unlock()
                }
                return TerminalServiceResponse(
                    ok: true, message: "", sessionState: nil, controlResponse: TerminalControlResponse(ok: true, message: ""))
            }
        }
    }
}
