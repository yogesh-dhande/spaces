import XCTest
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore

@testable import spacesclientcore

final class SpacesDeviceOverviewViewModelTests: XCTestCase {
    func testDeviceClientUsesLongerTimeoutForLongRunningMutations() {
        XCTAssertEqual(SpacesDeviceClient.requestTimeoutSeconds(for: .overview), SpacesDeviceClient.defaultRequestTimeoutSeconds)
        XCTAssertEqual(
            SpacesDeviceClient.requestTimeoutSeconds(for: .workspaceCreateOptions(.init(projectID: "project-1"))),
            SpacesDeviceClient.defaultRequestTimeoutSeconds)
        XCTAssertEqual(
            SpacesDeviceClient.requestTimeoutSeconds(for: .restartWorkspace(.init(workspaceID: "workspace-1"))),
            SpacesDeviceClient.longRunningMutationTimeoutSeconds)
        XCTAssertEqual(
            SpacesDeviceClient.requestTimeoutSeconds(
                for: .restartWorkspaceProcess(.init(workspaceID: "workspace-1", processID: nil, processKey: "web", processTemplateID: nil))),
            SpacesDeviceClient.longRunningMutationTimeoutSeconds)
        XCTAssertEqual(
            SpacesDeviceClient.requestTimeoutSeconds(
                for: .restartCodingAgent(.init(workspaceID: "workspace-1", agentID: nil, agentName: "Codex", agentLauncherID: nil))),
            SpacesDeviceClient.longRunningMutationTimeoutSeconds)
        XCTAssertEqual(SpacesDeviceClient.requestTimeoutSeconds(for: .agentHooksStatus), SpacesDeviceClient.agentHooksStatusRequestTimeoutSeconds)
        XCTAssertGreaterThan(SpacesDeviceClient.agentHooksStatusRequestTimeoutSeconds, SpacesDeviceClient.defaultRequestTimeoutSeconds)
    }

    func testOverviewRefreshesLocalBootstrapAfterTransientConnectionFailure() throws {
        try withClientSecretDirectory { root in
            let database = try SpacesClientDatabase(path: root.appendingPathComponent("Client/spaces-client.db").path)
            let clientApp = SpacesDeviceClient.macOSClientApp(installationID: "client-test", deviceName: "Test Mac")
            let probe = DeviceOverviewRetryProbe()
            let bootstrap: SpacesDeviceClient.LocalBootstrapProvider = { _, _ in
                probe.bootstrapCount += 1
                return Self.localBootstrapResponse(port: probe.bootstrapCount == 1 ? 11_111 : 22_222)
            }
            let requestProvider: SpacesDeviceClient.DeviceRequestProvider = { _, device, _, _ in
                probe.requestedPorts.append(device.port)
                guard probe.requestedPorts.count > 1 else { throw POSIXError(.ECONNREFUSED) }
                return Self.emptyOverviewResponse()
            }

            let overview = try SpacesDeviceClient.localOverview(
                database: database, clientApp: clientApp, bootstrap: bootstrap, requestProvider: requestProvider)

            XCTAssertEqual(probe.bootstrapCount, 2)
            XCTAssertEqual(probe.requestedPorts, [11_111, 22_222])
            XCTAssertEqual(overview.device.id, SpacesPairedDeviceRecord.localDeviceID)
            XCTAssertEqual(overview.device.port, 22_222)
            XCTAssertEqual(try database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID)?.port, 22_222)
        }
    }

    func testProjectActionsDoNotDependOnDeviceLocation() {
        XCTAssertEqual(SpacesDeviceProjectActions(isGitRepo: true), .init(isGitRepo: true))
        XCTAssertTrue(SpacesDeviceProjectActions(isGitRepo: true).showsSettings)
        XCTAssertTrue(SpacesDeviceProjectActions(isGitRepo: true).showsAddWorkspace)
        XCTAssertTrue(SpacesDeviceProjectActions(isGitRepo: false).showsSettings)
        XCTAssertFalse(SpacesDeviceProjectActions(isGitRepo: false).showsAddWorkspace)
    }

    func testOverviewViewModelPreservesWorkspaceRowsAndRuntimeIndicators() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-visible", projectID: "project-1", projectName: "Project", branch: "feature/visible", baseBranch: "main",
                    dir: "/device/project-visible", isRunning: true, isArchived: false, isHidden: false, isDefault: false, notes: "Visible notes",
                    sessionCount: 2,
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "process-web", workspaceID: "workspace-visible", name: "web", command: "npm run dev", processID: "running-web",
                            sessionID: "session-web", runState: .running, canRun: false, canStop: true, canRestart: true)
                    ],
                    codingAgentRows: [
                        SpacesDeviceWorkspaceCodingAgentRow(
                            id: "agent-codex", workspaceID: "workspace-visible", name: "Codex", command: "codex", agentID: "running-agent",
                            sessionID: "session-agent", isConfigured: true, runState: .running, activityState: .waiting, canRun: false, canStop: true,
                            canRestart: true)
                    ],
                    terminalRows: [
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "terminal-shell", workspaceID: "workspace-visible", title: "shell", workingDirectory: "/device/project-visible",
                            sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
                    ]),
                SpacesDeviceWorkspaceSummary(
                    id: "workspace-hidden", projectID: "project-1", projectName: "Project", branch: "feature/hidden", baseBranch: "main",
                    dir: "/device/project-hidden", isRunning: false, isArchived: false, isHidden: true, isDefault: false, sessionCount: 0),
            ], sessions: [], daemonStatus: Self.status())

        let model = SpacesDeviceOverviewViewModel(overview: overview)

        XCTAssertEqual(model.projects.map(\.id), ["project-1"])
        XCTAssertEqual(model.projects.first?.actions.showsSettings, true)
        XCTAssertEqual(model.projects.first?.actions.showsAddWorkspace, true)
        XCTAssertEqual(model.workspacesByProject["project-1"]?.map(\.id), ["workspace-hidden", "workspace-visible"])
        XCTAssertEqual(model.workspacesByProject["project-1"]?.first?.isHidden, true)

        let runtime = model.workspaceRuntimeStatusByID["workspace-visible"]
        XCTAssertEqual(runtime?.lifecycleState, .running)
        XCTAssertEqual(runtime?.hasTrackedRuntimeIndicators, true)
        XCTAssertEqual(runtime?.runningProcessCount, 2)
        XCTAssertEqual(runtime?.exitedProcessCount, 0)
        XCTAssertEqual(runtime?.waitingAgentWindowCount, 1)
    }

    func testProjectSettingsViewModelPreservesFullConfigSurface() {
        let project = SpacesDeviceProjectSummary(
            id: "project-1", name: "Project", dir: "/device/project", isGitRepo: true, defaultBranch: "main",
            config: SpacesDeviceProjectConfig(
                setupScript: "make setup", stopScript: "make stop", ports: [SpacesDeviceServiceDefinition(id: "port-web", name: "WEB")],
                processes: [SpacesDeviceProcessTemplate(id: "process-web", name: "web", command: "npm run dev", onExit: "restart")],
                browserSessions: [SpacesDeviceBrowserSession(name: "web", url: "http://localhost:$WEB")],
                agentLaunchers: [SpacesDeviceAgentLauncher(id: "agent-codex", name: "Codex", command: "codex")]))

        let model = SpacesDeviceProjectSettingsViewModel(project: project)

        XCTAssertEqual(model.id, "project-1")
        XCTAssertEqual(model.config.setupScript, "make setup")
        XCTAssertEqual(model.config.stopScript, "make stop")
        XCTAssertEqual(model.config.ports.map(\.name), ["WEB"])
        XCTAssertEqual(model.config.processes.map(\.command), ["npm run dev"])
        XCTAssertEqual(model.config.browserSessions.compactMap(\.url), ["http://localhost:$WEB"])
        XCTAssertEqual(model.config.agentLaunchers.map(\.name), ["Codex"])
        XCTAssertTrue(model.actions.showsSettings)
        XCTAssertTrue(model.actions.showsAddWorkspace)
    }

    func testWorkspaceDetailViewModelPreservesFullWorkspaceContents() {
        let workspace = fullWorkspaceSummary(dir: "/device/project-feature")

        let model = SpacesDeviceWorkspaceDetailViewModel(workspace: workspace)

        XCTAssertEqual(model.id, "workspace-1")
        XCTAssertEqual(model.notes, "Workspace notes")
        XCTAssertEqual(model.setupState?.status, .failed)
        XCTAssertEqual(model.setupState?.errorMessage, "setup failed")
        XCTAssertEqual(model.assignedPorts, [SpacesDeviceAssignedPort(name: "WEB", port: 3000)])
        XCTAssertEqual(model.config.ports.map(\.name), ["WEB"])
        XCTAssertEqual(model.config.processes.map(\.name), ["web"])
        XCTAssertEqual(model.config.browserSessions.compactMap(\.name), ["web"])
        XCTAssertEqual(model.config.resolvedBrowserSessions.compactMap(\.url), ["http://localhost:3000"])
        XCTAssertEqual(model.config.agentLaunchers.map(\.name), ["Codex"])
        XCTAssertEqual(model.processRows.map(\.id), ["process-web"])
        XCTAssertEqual(model.codingAgentRows.map(\.id), ["agent-codex"])
        XCTAssertEqual(model.terminalRows.map(\.sessionID), ["session-shell"])
    }

    func testWorkspaceDetailContentsDoNotDependOnDeviceLocation() {
        let local = SpacesDeviceWorkspaceDetailViewModel(workspace: fullWorkspaceSummary(dir: "/Users/me/project-feature"))
        let remote = SpacesDeviceWorkspaceDetailViewModel(workspace: fullWorkspaceSummary(dir: "/home/me/project-feature"))

        XCTAssertEqual(local.config, remote.config)
        XCTAssertEqual(local.assignedPorts, remote.assignedPorts)
        XCTAssertEqual(local.processRows, remote.processRows)
        XCTAssertEqual(local.codingAgentRows, remote.codingAgentRows)
        XCTAssertEqual(local.terminalRows.map(\.id), remote.terminalRows.map(\.id))
        XCTAssertEqual(local.terminalRows.map(\.sessionID), remote.terminalRows.map(\.sessionID))
        XCTAssertEqual(local.terminalRows.map(\.runState), remote.terminalRows.map(\.runState))
    }

    private func fullWorkspaceSummary(dir: String) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: dir, isRunning: true,
            isArchived: false, isHidden: false, isDefault: false, notes: "Workspace notes", sessionCount: 3,
            assignedPorts: [SpacesDeviceAssignedPort(name: "WEB", port: 3000)],
            setupState: SpacesDeviceWorkspaceSetupState(
                status: .failed, errorMessage: "setup failed", startedAt: "2026-06-18T00:00:00Z", finishedAt: "2026-06-18T00:00:05Z"),
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
                    id: "terminal-shell", workspaceID: "workspace-1", title: "shell", workingDirectory: dir, sessionID: "session-shell",
                    runState: .running, canOpenTerminal: true, canStop: true)
            ])
    }

    func testEnsureLocalDeviceCredentialsBootstrapsWhenMissingAndSkipsWhenPresent() throws {
        try withClientSecretDirectory { root in
            let database = try SpacesClientDatabase(path: root.appendingPathComponent("Client/spaces-client.db").path)
            let clientApp = SpacesDeviceClient.macOSClientApp(installationID: "client-test", deviceName: "Test Mac")
            let probe = DeviceOverviewRetryProbe()
            let bootstrap: SpacesDeviceClient.LocalBootstrapProvider = { _, _ in
                probe.bootstrapCount += 1
                return Self.localBootstrapResponse(port: 12_345)
            }
            let local = SpacesPairedDeviceRecord.localDeviceID

            // Missing local credentials self-heal by re-bootstrapping and persisting them.
            XCTAssertFalse(try SpacesDeviceCredentialStore.hasToken(deviceID: local))
            XCTAssertNotNil(try SpacesDeviceClient.ensureLocalDeviceCredentials(database: database, clientApp: clientApp, bootstrap: bootstrap))
            XCTAssertEqual(probe.bootstrapCount, 1)
            XCTAssertTrue(try SpacesDeviceCredentialStore.hasToken(deviceID: local))

            // Present credentials cost no daemon round-trip.
            XCTAssertNil(try SpacesDeviceClient.ensureLocalDeviceCredentials(database: database, clientApp: clientApp, bootstrap: bootstrap))
            XCTAssertEqual(probe.bootstrapCount, 1)

            // A token deleted later also re-bootstraps, so a local request is not left sending an
            // unauthenticated (401) call.
            try SpacesDeviceCredentialStore.deleteToken(deviceID: local)
            XCTAssertFalse(try SpacesDeviceCredentialStore.hasToken(deviceID: local))
            XCTAssertNotNil(try SpacesDeviceClient.ensureLocalDeviceCredentials(database: database, clientApp: clientApp, bootstrap: bootstrap))
            XCTAssertEqual(probe.bootstrapCount, 2)
            XCTAssertTrue(try SpacesDeviceCredentialStore.hasToken(deviceID: local))
        }
    }

    private func withClientSecretDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secretDirectory = root.appendingPathComponent("Client/Secrets", isDirectory: true)
        let originalSecretDirectory = currentEnvironmentValue(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
        setenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable, secretDirectory.path, 1)
        defer {
            restoreEnvironmentValue(originalSecretDirectory, name: SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    private func currentEnvironmentValue(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }

    private func restoreEnvironmentValue(_ value: String?, name: String) { if let value { setenv(name, value, 1) } else { unsetenv(name) } }

    private static func localBootstrapResponse(port: Int) -> SpacesDeviceAPIControlResponse {
        SpacesDeviceAPIControlResponse(
            ok: true, message: "ok",
            result: .localClientBootstrap(
                SpacesDeviceAPILocalClientBootstrap(
                    deviceID: SpacesPairedDeviceRecord.localDeviceID, name: "Local Mac", platform: "macos", host: "127.0.0.1", port: port,
                    certificateFingerprint: "local-fingerprint", authToken: "token-\(port)")))
    }

    private static func emptyOverviewResponse() -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(
            ok: true, message: "ok", result: .overview(SpacesDeviceOverviewPayload(workspaces: [], sessions: [], daemonStatus: status())))
    }

    private static func status() -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: SpacesWireProtocol.version)
    }
}

private final class DeviceOverviewRetryProbe: @unchecked Sendable {
    var bootstrapCount = 0
    var requestedPorts: [Int] = []
}
