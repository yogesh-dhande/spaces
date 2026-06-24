import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesui

@Suite struct AppKitControllerActiveDeviceParityTests {
    @Test func daemonMutationSelectionUsesPairedDeviceWithoutRequiringLoadedOverview() {
        let local = SpacesPairedDeviceRecord(
            id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", host: "127.0.0.1", port: 7443,
            certificateFingerprint: "SHA256:local", createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z",
            lastSelectedAt: "2026-06-17T00:00:00Z")
        let emptyOverview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])

        #expect(AppKitController.daemonStateMutationDevice(activePairedDevice: local, activeDeviceOverview: nil) == local)
        #expect(AppKitController.daemonStateMutationDevice(activePairedDevice: nil, activeDeviceOverview: emptyOverview) == nil)
    }

    @Test func sidebarProjectActionsDoNotDependOnDeviceLocation() {
        let gitProjectActions = AppKitController.sidebarProjectActions(isGitRepo: true)
        #expect(gitProjectActions.showsSettings)
        #expect(gitProjectActions.showsAddWorkspace)

        let folderProjectActions = AppKitController.sidebarProjectActions(isGitRepo: false)
        #expect(folderProjectActions.showsSettings)
        #expect(!folderProjectActions.showsAddWorkspace)
    }

    @Test func remoteWorkspacePathActionsKeepControlsButUseSSHDependentErrorText() {
        let editorMessage = AppKitController.remoteWorkspacePathActionErrorMessage(action: .openEditor, deviceName: "Build Host")
        let revealMessage = AppKitController.remoteWorkspacePathActionErrorMessage(action: .revealInFinder, deviceName: "Build Host")

        #expect(editorMessage.contains("Open editor"))
        #expect(revealMessage.contains("Reveal in Finder"))
        #expect(editorMessage.contains("Build Host"))
        #expect(revealMessage.contains("SSH-capable workflow"))
    }

    @Test func activeDeviceOverviewMappingPreservesProjectWorkspaceAndRuntimeControls() {
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
                    id: "workspace-1", projectID: "project-1", projectName: "Project", title: "Feature", branch: "feature", baseBranch: "main",
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

        let mapped = AppKitController.activeDeviceSidebarData(from: overview, deviceID: "remote-device")

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

    @Test func activeDeviceOverviewBuildsCommandPaletteWorkspaceActions() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", title: "Feature", branch: "feature", baseBranch: "main",
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

        let items = AppKitController.activeDeviceCommandPaletteWorkspaceItems(from: overview)

        #expect(items.contains { $0.kind == .browser && $0.label == "web" && $0.detail == "http://localhost:3000" })
        #expect(items.contains { $0.kind == .process && $0.label == "web" && $0.detail == "npm run dev" })
        #expect(items.contains { $0.kind == .agent && $0.label == "Codex" })
        #expect(items.contains { $0.kind == .window && $0.label == "shell-1" })
    }

    @Test func activeDeviceTerminalRowsRenderThroughWorkspaceRuntimeRows() {
        let terminalRows = [
            SpacesDeviceWorkspaceTerminalRow(
                id: "terminal-shell", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/project-feature",
                sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
        ]

        let windows = AppKitController.activeDeviceTerminalWindows(from: terminalRows)
        let entries = AppKitController.orderedWorkspaceRunProcessEntries(configuredProcesses: [], windows: windows, processes: [], agentWindows: [])
        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: [], processEntries: entries, processesByID: [:], configuredAgentLaunchers: [], agentWindows: [])

        #expect(windows.map(\.terminalTrackingKey) == ["terminal:session-shell"])
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .window)
        #expect(entries.first?.windowListIndex == 0)
        #expect(shortcutTargets.map(\.kind) == [.window])
    }

    @Test func activeDeviceProcessTerminalRowsDoNotDuplicateProcessRuntimeRows() {
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
            configuredProcesses: configuredProcesses, windows: AppKitController.activeDeviceTerminalWindows(from: terminalRows),
            processes: runningProcesses, agentWindows: [])

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "running-web")
    }

    @Test func activeDeviceShortcutResolvesRunningProcessToRemoteTerminalOpen() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", title: "Feature", branch: "feature", baseBranch: "main",
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

        let resolution = AppKitController.activeDeviceWindowShortcutResolution(index: 1, selectedWorkspaceID: "workspace-1", overview: overview)

        #expect(
            resolution
                == .openTerminal(
                    AppKitController.ActiveDeviceTerminalOpenRequest(
                        workspaceID: "workspace-1", sessionID: "session-web", title: "web", workingDirectory: "/device/project-feature",
                        kind: .process)))
    }

    @Test func activeDeviceTerminalControlRequestTranslatesRendererControlPayload() throws {
        let control = TerminalControlRequest(command: "resize", clientID: "mac-client", columns: 120, rows: 40, ownerEpoch: 7, resizeSerial: 3)

        let request = try AppKitController.activeDeviceTerminalControlRequest(sessionID: "session-web", controlRequest: control)

        #expect(request.action == .resize)
        #expect(request.sessionID == "session-web")
        #expect(request.clientID == "mac-client")
        #expect(request.columns == 120)
        #expect(request.rows == 40)
        #expect(request.ownerEpoch == 7)
        #expect(request.resizeSerial == 3)
    }
}
