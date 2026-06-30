import Testing
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import workspacecore

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

    @Test func singleOfflineLocalDeviceStillRendersADeviceHeaderRow() {
        // A single loaded device stays a flat project list (no header).
        #expect(!AppKitController.sidebarShowsDeviceHeaders(deviceCount: 1, hasOfflineSection: false))
        // A single offline device forces a header row so its "offline" caption/tooltip has somewhere to
        // render — otherwise it has no project rows and the sidebar would show nothing.
        #expect(AppKitController.sidebarShowsDeviceHeaders(deviceCount: 1, hasOfflineSection: true))
        // More than one device always groups under headers.
        #expect(AppKitController.sidebarShowsDeviceHeaders(deviceCount: 2, hasOfflineSection: false))

        #expect(AppKitController.SidebarDeviceLoadState.offline("daemon down").isOffline)
        #expect(!AppKitController.SidebarDeviceLoadState.loaded.isOffline)
        #expect(!AppKitController.SidebarDeviceLoadState.loading.isOffline)
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

    @Test func remoteWorkspacePathActionsKeepControlsButUseSSHDependentErrorText() {
        let editorMessage = AppKitController.remoteWorkspacePathActionErrorMessage(action: .openEditor, deviceName: "Build Host")
        let revealMessage = AppKitController.remoteWorkspacePathActionErrorMessage(action: .revealInFinder, deviceName: "Build Host")

        #expect(editorMessage.contains("Open editor"))
        #expect(revealMessage.contains("Reveal in Finder"))
        #expect(editorMessage.contains("Build Host"))
        #expect(revealMessage.contains("SSH-capable workflow"))
    }

    @Test func deviceOverviewMappingPreservesProjectWorkspaceAndRuntimeControls() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [
                SpacesDeviceProjectSummary(
                    id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main",
                    config: SpacesDeviceProjectConfig(
                        setupScript: "make setup", stopScript: "make stop", ports: [SpacesDevicePortDefinition(id: "port-web", name: "WEB")],
                        processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev", onExit: "restart")],
                        browserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:$WEB")],
                        agentLaunchers: [SpacesDeviceAgentLauncher(id: "agent-codex", name: "Codex", command: "codex")]))
            ],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false,
                    notes: "Remote and local use this same payload.", sessionCount: 1,
                    assignedPorts: [SpacesDeviceAssignedPort(name: "WEB", port: 3000)],
                    setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded),
                    config: SpacesDeviceWorkspaceConfig(
                        stopScript: "make stop", ports: [SpacesDevicePortDefinition(id: "port-web", name: "WEB")],
                        processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev", onExit: "restart")],
                        browserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:$WEB")],
                        resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:3000")],
                        agentLaunchers: [SpacesDeviceAgentLauncher(id: "agent-codex", name: "Codex", command: "codex")]),
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-1", name: "web", command: "npm run dev", templateID: "process-web",
                            processID: "running-web", sessionID: "session-web", runState: .running, canRun: false, canStop: true, canRestart: true)
                    ],
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent-codex", workspaceID: "workspace-1", name: "Codex", command: "codex", launcherID: "agent-codex",
                            agentID: "running-agent", sessionID: "session-agent", isConfigured: true, runState: .running, activityState: .waiting,
                            canRun: false, canStop: true, canRestart: true)
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
                    dir: "/device/project-feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false, notes: nil,
                    sessionCount: 3, assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded),
                    config: SpacesDeviceWorkspaceConfig(
                        processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev")],
                        browserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:$WEB")],
                        resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:3000")],
                        agentLaunchers: [SpacesDeviceAgentLauncher(id: "agent-codex", name: "Codex", command: "codex")]),
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-1", name: "web", command: "npm run dev", templateID: "process-web",
                            processID: "running-web", sessionID: "session-web", runState: .running, canRun: false, canStop: true, canRestart: true)
                    ],
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent-codex", workspaceID: "workspace-1", name: "Codex", command: "codex", launcherID: "agent-codex",
                            agentID: "running-agent", sessionID: "session-agent", isConfigured: true, runState: .running, activityState: .waiting,
                            canRun: false, canStop: true, canRestart: true)
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

    @Test func deviceTerminalRowsRenderThroughWorkspaceRuntimeRows() {
        let terminalRows = [
            SpacesDeviceWorkspaceTerminalRow(
                id: "terminal-shell", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/project-feature",
                sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
        ]

        let windows = AppKitController.deviceTerminalWindows(from: terminalRows)
        let entries = AppKitController.orderedWorkspaceRunProcessEntries(configuredProcesses: [], windows: windows, processes: [], agentWindows: [])
        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: [], processEntries: entries, processesByID: [:], configuredAgentLaunchers: [], agentWindows: [])

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
                terminalApp: "Spaces", windowID: nil, terminalTrackingID: "session-web", pid: 123, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil)
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
                    dir: "/device/project-feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false, notes: nil,
                    sessionCount: 1, assignedPorts: [], setupState: SpacesDeviceWorkspaceSetupState(status: .succeeded),
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
                    dir: "/device/project-feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1,
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

    @Test func deviceTerminalOpenRequestPreservesStartingSessionMetadata() {
        let session = SpacesDeviceTerminalSessionSummary(
            id: "session-starting", title: "shell-1", workingDirectory: "/device/project-feature", state: .starting, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 321, childPID: nil, workspaceID: "workspace-1", workspaceTitle: "Feature",
            projectID: "project-1", projectName: "Project", createdAt: "2026-06-22T12:00:00Z", updatedAt: "2026-06-22T12:00:01Z",
            isControlAvailable: false, isSubscriptionAvailable: false, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .liveSession)
        let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [session])

        let request = AppKitController.deviceTerminalOpenRequest(workspaceID: "workspace-fallback", sessionID: "session-starting", overview: overview)

        #expect(
            request
                == AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: "workspace-1", sessionID: "session-starting", title: "shell-1", workingDirectory: "/device/project-feature",
                    kind: .shell, initialState: .starting, servicePID: 321, childPID: nil, createdAt: "2026-06-22T12:00:00Z",
                    updatedAt: "2026-06-22T12:00:01Z"))
    }

    @Test func deviceShortcutResolvesStartingTerminalRowWithSessionMetadata() {
        let session = startingSessionSummary(id: "session-starting-shell", title: "shell-1", rowKind: .liveSession)
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1,
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
                        workingDirectory: "/device/project-feature", kind: .shell, initialState: .starting, servicePID: 321, childPID: nil,
                        createdAt: "2026-06-22T12:00:00Z", updatedAt: "2026-06-22T12:00:01Z")))
    }

    @Test func deviceShortcutResolvesStartingProcessWithSessionMetadata() {
        let session = startingSessionSummary(id: "session-starting-process", title: "web", rowKind: .process)
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1,
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
                        kind: .process, initialState: .starting, servicePID: 321, childPID: nil, createdAt: "2026-06-22T12:00:00Z",
                        updatedAt: "2026-06-22T12:00:01Z")))
    }

    @Test func deviceShortcutResolvesStartingAgentWithSessionMetadata() {
        let session = startingSessionSummary(id: "session-starting-agent", title: "Codex", rowKind: .agent)
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1,
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent-codex", workspaceID: "workspace-1", name: "Codex", command: "codex", launcherID: "agent-codex",
                            agentID: "running-agent", sessionID: "session-starting-agent", isConfigured: true, runState: .running,
                            activityState: .waiting, canRun: false, canStop: true, canRestart: true)
                    ])
            ], sessions: [session])

        let resolution = AppKitController.deviceWindowShortcutResolution(index: 1, selectedWorkspaceID: "workspace-1", overview: overview)

        #expect(
            resolution
                == .openTerminal(
                    AppKitController.DeviceTerminalOpenRequest(
                        workspaceID: "workspace-1", sessionID: "session-starting-agent", title: "Codex", workingDirectory: "/device/project-feature",
                        kind: .agent, initialState: .starting, servicePID: 321, childPID: nil, createdAt: "2026-06-22T12:00:00Z",
                        updatedAt: "2026-06-22T12:00:01Z")))
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

    private func startingSessionSummary(id: String, title: String, rowKind: SpacesDeviceTerminalSessionRowKind) -> SpacesDeviceTerminalSessionSummary
    {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: title, workingDirectory: "/device/project-feature", state: .starting, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 321, childPID: nil, workspaceID: "workspace-1", workspaceTitle: "Feature",
            projectID: "project-1", projectName: "Project", createdAt: "2026-06-22T12:00:00Z", updatedAt: "2026-06-22T12:00:01Z",
            isControlAvailable: false, isSubscriptionAvailable: false, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: rowKind)
    }
}
