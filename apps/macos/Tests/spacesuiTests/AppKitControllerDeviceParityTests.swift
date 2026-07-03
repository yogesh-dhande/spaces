import Foundation
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
                        setupScript: "make setup", stopScript: "make stop", ports: [SpacesDeviceServiceDefinition(id: "port-web", name: "WEB")],
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
                        stopScript: "make stop", ports: [SpacesDeviceServiceDefinition(id: "port-web", name: "WEB")],
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

    @Test func offlineTransitionDetectsSelectionOwnedByTheDevice() {
        // When a device goes offline its rows drop from the merged sidebar data; a selection under it
        // must be detected so the detail pane can fall back to the alerts view instead of misrouting
        // follow-up actions to the local daemon.
        let section = AppKitController.DeviceSection(
            deviceID: "remote", deviceName: "Remote", isLocal: false, loadState: .loaded, device: nil,
            projects: [ProjectSummary(id: "proj-r", name: "R", dir: "/r", isGitRepo: true, defaultBranch: "main", deviceID: "remote")],
            workspacesByProject: [
                "proj-r": [
                    WorkspaceSummary(
                        id: "ws-r", branch: "feature", dir: "/r/feature", isRunning: true, isArchived: false, isDefault: false, deviceID: "remote")
                ]
            ])

        // A workspace selection under the device is detected.
        #expect(AppKitController.sidebarSelectionBelongsToDeviceSection(selectedWorkspaceID: "ws-r", selectedProjectID: "proj-r", section: section))
        // A selection on another device is left alone.
        #expect(
            !AppKitController.sidebarSelectionBelongsToDeviceSection(
                selectedWorkspaceID: "ws-local", selectedProjectID: "proj-local", section: section))
        // A project (header) selection with no workspace selected is detected by project id.
        #expect(AppKitController.sidebarSelectionBelongsToDeviceSection(selectedWorkspaceID: nil, selectedProjectID: "proj-r", section: section))
        #expect(!AppKitController.sidebarSelectionBelongsToDeviceSection(selectedWorkspaceID: nil, selectedProjectID: "proj-local", section: section))
        // No selection never triggers reconciliation.
        #expect(!AppKitController.sidebarSelectionBelongsToDeviceSection(selectedWorkspaceID: nil, selectedProjectID: nil, section: section))
    }

    @Test func waitingAgentAlertResolvesToFocusingItsSessionNotANewLaunch() {
        // Regression: an attention alert for a waiting/done agent must focus that agent's existing
        // session, not resolve to `.runCodingAgent` (which would start a second agent). Build the
        // alert through the real overview path, then resolve its focus request end to end.
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
                    dir: "/device/project-feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1,
                    config: SpacesDeviceWorkspaceConfig(agentLaunchers: [
                        SpacesDeviceAgentLauncher(id: "launcher-codex", name: "Codex", command: "codex")
                    ]),
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "row-codex", workspaceID: "workspace-1", name: "Codex", command: "codex", launcherID: "launcher-codex",
                            agentID: "agent-1", sessionID: "session-agent", isConfigured: true, runState: .running, activityState: .waiting,
                            updatedAt: "2026-06-28T09:00:00Z", canRun: false, canStop: true, canRestart: true)
                    ])
            ], sessions: [])

        let groups = AppKitController.buildOverviewAlertsGroups(from: overview, deviceID: "local")
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

        // Resolving it opens the agent's terminal session instead of launching another agent.
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

    @Test func remoteBrowserRoutePlanMapsLoopbackServicePortToCaddyURL() throws {
        let plan = try #require(
            BrowserSSHForwardManager.routePlan(
                targetURL: "http://localhost:32001/docs/?tab=api#readme",
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:8088")]))

        #expect(plan.serviceName == "web")
        #expect(plan.remotePort == 32001)
        #expect(plan.routeHost == "web.feature-123.localhost")
        #expect(plan.browserURL.absoluteString == "http://web.feature-123.localhost:8088/docs/?tab=api#readme")
    }

    @Test func remoteBrowserRoutePlanKeepsConfiguredCaddyServiceURL() throws {
        let plan = try #require(
            BrowserSSHForwardManager.routePlan(
                targetURL: "http://web.feature-123.localhost:8088/admin/",
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:8088")]))

        #expect(plan.serviceName == "web")
        #expect(plan.remotePort == 32001)
        #expect(plan.routeHost == "web.feature-123.localhost")
        #expect(plan.browserURL.absoluteString == "http://web.feature-123.localhost:8088/admin/")
    }

    @Test func remoteBrowserRoutePlanUsesLocalCaddyRouterPort() throws {
        let plan = try #require(
            BrowserSSHForwardManager.routePlan(
                targetURL: "http://web.feature-123.localhost:9000/admin/",
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:9000")],
                localRouterPort: 8088))

        #expect(plan.browserURL.absoluteString == "http://web.feature-123.localhost:8088/admin/")
    }

    @Test func remoteBrowserRoutePlanLeavesExternalURLsUnchanged() {
        let plan = BrowserSSHForwardManager.routePlan(
            targetURL: "https://example.com/docs",
            assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:8088")])

        #expect(plan == nil)
    }

    @Test func remoteBrowserSSHArgumentsUsePairedDeviceSSHMetadata() throws {
        let device = SpacesPairedDeviceRecord(
            id: "remote", name: "Build Host", platform: "linux", host: "10.0.0.4", port: 7443, certificateFingerprint: "fingerprint",
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
            id: "remote", name: "Build Host", platform: "linux", host: "10.0.0.4", port: 7443, certificateFingerprint: "fingerprint",
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
                SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:8088"),
                SpacesDeviceAssignedPort(name: "api", port: 32002, url: "http://api.feature-123.localhost:8088"),
            ],
            forwards: [BrowserSSHForwardManager.ServiceForwardSnapshot(serviceName: "web", remotePort: 32001, localPort: 41001)])

        #expect(texts == ["32001:41001", "32002"])
    }

    @Test func forwardedServicePortsForUnknownWorkspaceIsEmpty() {
        #expect(BrowserSSHForwardManager().forwardedServicePorts(deviceID: "remote", workspaceID: "workspace-1").isEmpty)
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

    @Test func coldTerminalOverviewLookupRunsOffMainThread() async {
        let recorder = ThreadRecorder()
        let device = SpacesPairedDeviceRecord(
            id: "local", name: "Mac", platform: "macos", host: "127.0.0.1", port: 19000, certificateFingerprint: "fingerprint",
            createdAt: "2026-06-01T00:00:00Z", updatedAt: "2026-06-01T00:00:00Z")
        let clientApp = SpacesDeviceClientApp(
            installationID: "install", bundleID: "com.example.Spaces", platform: "macos", deviceName: "Mac", appVersion: "1.0")
        let summary = SpacesDeviceTerminalSessionSummary(
            id: "session-cold", title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 123, childPID: nil, workspaceID: nil, workspaceTitle: nil, projectID: nil, projectName: nil,
            createdAt: "2026-06-01T00:00:00Z", updatedAt: "2026-06-01T00:00:01Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot())

        let match = await AppKitController.resolveSessionSummaryMatchOffMain(
            sessionID: "session-cold", device: device, clientApp: clientApp,
            resolveOverview: { device, _ in
                recorder.record(Thread.isMainThread)
                return SpacesDeviceOverviewResolution(
                    overview: SpacesDeviceOverview(device: device, overview: SpacesDeviceOverviewPayload(workspaces: [], sessions: [summary])),
                    daemonStatus: nil, compatibility: nil)
            })

        #expect(match == AppKitController.TerminalSessionSummaryMatch(device: device, summary: summary))
        #expect(recorder.values == [false])
    }

    @Test func attachControlRefreshesSessionStateWhenResponseOmitsIt() throws {
        // The Device API does not echo session state for attach/detach controls, so the
        // control helper must fetch the post-control state and apply the new ownership
        // immediately instead of waiting for the live subscription to redeliver it.
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
            sessionID: "session-1", reason: "attachment_state", emittedAt: "2026-06-22T12:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: attachmentSnapshot, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil)
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
        private(set) var issuedStateFetch = false

        init(stateResponseSnapshot: GhosttyRemoteSessionStatePayload?) { self.stateResponseSnapshot = stateResponseSnapshot }

        var send: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse {
            { [self] request in
                switch request.command {
                case .control:
                    return TerminalServiceResponse(
                        ok: true, message: "", sessionState: nil, controlResponse: TerminalControlResponse(ok: true, message: ""))
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
}
