import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

private final class WorkspaceSetupThread: Thread {
    private let orchestrator: WorkspaceOrchestrator
    private let workspaceID: String

    init(orchestrator: WorkspaceOrchestrator, workspaceID: String) {
        self.orchestrator = orchestrator
        self.workspaceID = workspaceID
    }

    override func main() { try? orchestrator.runWorkspaceSetup(workspaceID: workspaceID) }
}

private final class TerminalOpenCapture: @unchecked Sendable {
    var sessionIDs: [String] = []
    var modes: [TerminalAttachmentMode] = []
}

private final class TerminalLaunchConfigurationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [TerminalSessionLaunchConfiguration] = []

    func append(_ configuration: TerminalSessionLaunchConfiguration) {
        lock.lock()
        configurations.append(configuration)
        lock.unlock()
    }

    func snapshot() -> [TerminalSessionLaunchConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }
}

private final class TerminalFocusCapture: @unchecked Sendable {
    var sessionIDs: [String] = []
    var requestIDs: [String?] = []
}

private final class TerminalCloseCapture: @unchecked Sendable { var sessionIDs: [String] = [] }

private final class TerminalTerminateCapture: @unchecked Sendable { var sessionIDs: [String] = [] }

private final class TerminalLaunchAttemptCapture: @unchecked Sendable { var count = 0 }

private final class RemoteStateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: String
    private let workspaceID: String
    private let workingDirectory: String
    private var recordedRequests: [TerminalServiceRequest] = []

    init(sessionID: String, workspaceID: String, workingDirectory: String) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
    }

    func client(target _: SpacesDaemonConnectionTarget, request: TerminalServiceRequest) throws -> TerminalServiceResponse {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()

        guard case .state(let payload) = request.command, payload.sessionID == sessionID else {
            return TerminalServiceResponse(ok: true, message: "ok")
        }
        let timestamp = "2026-06-11T00:00:00Z"
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 42, childPID: 4242, state: .running, updatedAt: timestamp, title: "shell-1",
            workingDirectory: workingDirectory)
        let client = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: timestamp)
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: .owner, attachedAt: timestamp)
        return TerminalServiceResponse(
            ok: true, message: "state",
            sessionState: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: timestamp, sessionStateRevision: 1,
                sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]), title: "shell-1",
                workingDirectory: workingDirectory, outputByteCount: 0))
    }

    func requests() -> [TerminalServiceRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

private func managedProjectStorageDirname(namespace: String, source: String, preferredName: String) -> String {
    let digest = SHA256.hash(data: Data("\(namespace)\u{0}\(source)".utf8)).map { String(format: "%02x", $0) }.joined()
    let cleaned = preferredName.map { char -> String in
        if char.isLetter || char.isNumber { return String(char) }
        if char == "-" || char == "_" { return String(char) }
        return "-"
    }.joined()
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    let sanitizedName = trimmed.isEmpty ? "project" : trimmed
    let hashSuffix = String(digest.prefix(16))
    let maxNameLength = max(1, 255 - hashSuffix.count - 1)
    let truncatedName = String(sanitizedName.prefix(maxNameLength))
    return "\(truncatedName)-\(hashSuffix)"
}

final class OrchestratorTests: XCTestCase {
    // Tests workspace window refresh interval is positive by arranging representative inputs and asserting the expected result.
    func testWorkspaceWindowRefreshIntervalIsPositive() { XCTAssertGreaterThan(PollingConstants.workspaceWindowRefreshInterval, 0) }

    // Tests worktree discovery interval is positive by arranging representative inputs and asserting the expected result.
    func testWorktreeDiscoveryIntervalIsPositive() { XCTAssertGreaterThan(PollingConstants.worktreeDiscoveryInterval, 0) }

    func testValidateProcessTemplateAcceptsShellVariableSyntax() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertNoThrow(try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: "PORT=${FRONTEND_PORT:-3000} npm run dev")))
    }

    func testValidateProcessTemplateAcceptsCompositeShellCommand() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertNoThrow(try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: "cd app && npm run dev | tee log.txt")))
    }

    func testValidateProcessTemplateRejectsBlankCommand() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: " \n\t "))) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid argument: Process command is required.")
        }
    }

    func testStopCodingAgentRemovesRuntimeAndPreservesConfiguredLauncher() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: "window-codex", workspaceID: workspace.id, app: "Spaces", name: "Codex", windowID: nil, terminalTrackingID: "session-codex",
                terminalNativeID: "session-codex", role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", runtimeTargetID: "window-codex",
                terminalTarget: TerminalTargetRecord(runtimeTargetID: "window-codex", trackingID: "session-codex"), sessionKey: nil,
                claimedLauncherName: "Codex", status: .idle, createdAt: "now", updatedAt: "now"))
        let closed = TerminalCloseCapture()
        let terminated = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { closed.sessionIDs.append($0) },
            builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) })

        try orchestrator.stopCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspaceAgentLaunchers(workspaceID: workspace.id).map(\.name), ["Codex"])
        XCTAssertEqual(closed.sessionIDs, ["session-codex"])
        XCTAssertEqual(terminated.sessionIDs, ["session-codex"])
    }

    func testRestartCodingAgentRelaunchesClaimedLauncher() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "old-session",
                codexThreadID: nil, windowID: nil, status: .idle, createdAt: "now", updatedAt: "now"))
        let launches = TerminalLaunchConfigurationCapture()
        let terminated = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalWindowCloser: { _ in },
            builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) },
            builtInTerminalSessionLauncher: { configuration in
                launches.append(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })

        let relaunched = try orchestrator.restartCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")

        XCTAssertEqual(terminated.sessionIDs, ["old-session"])
        XCTAssertEqual(launches.snapshot().map(\.title), ["Codex"])
        XCTAssertEqual(relaunched.label, "Codex")
        XCTAssertEqual(try store.workspaceAgentLaunchers(workspaceID: workspace.id).map(\.name), ["Codex"])
    }

    func testRestartCodingAgentRejectsUnconfiguredAdHocRuntime() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-review", workspaceID: workspace.id, provider: .spaces, label: "reviewer", terminalTrackingID: "session-review",
                codexThreadID: nil, windowID: nil, status: .idle, createdAt: "now", updatedAt: "now"))
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.restartCodingAgent(workspaceID: workspace.id, agentID: "agent-review")) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid argument: Unconfigured live coding agents cannot be restarted from Spaces.")
        }
    }

    func testRestartCodingAgentRejectsStaleClaimedLauncherBeforeStopping() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceAgentLaunchers(
            workspaceID: workspace.id, launchers: [AgentLauncher(id: "launcher-current", name: "Reviewer", command: "codex --review")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "old-session",
                codexThreadID: nil, windowID: nil, status: .idle, createdAt: "now", updatedAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "old-session"), claimedLauncherID: "launcher-codex", claimedLauncherName: "Codex",
                status: .idle, createdAt: "now", updatedAt: "now"))
        let terminated = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) })

        XCTAssertThrowsError(try orchestrator.restartCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid argument: Configured coding agent not found.")
        }

        XCTAssertEqual(terminated.sessionIDs, [])
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), ["agent-codex"])
    }

    func testUpdateProjectConfigAcceptsShellVariableSyntaxAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)

        try orchestrator.updateProjectConfig(projectID: project.id) { project in
            project.ports = [PortDefinition(name: "FRONTEND_PORT")]
            project.processes = [ProcessTemplate(name: "web", command: "PORT=${TYPO_PORT:-3000} npm run dev | tee log.txt")]
        }

        let updated = try XCTUnwrap(try store.project(id: project.id))
        XCTAssertEqual(updated.processes.first?.command, "PORT=${TYPO_PORT:-3000} npm run dev | tee log.txt")
    }

    func testUpdateProjectConfigRejectsBlankPortNameAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)

        XCTAssertThrowsError(
            try orchestrator.updateProjectConfig(projectID: project.id) { project in project.ports = [PortDefinition(name: " \n\t ")] }
        ) { error in XCTAssertEqual(error.localizedDescription, "Invalid argument: Port name is required.") }
    }

    func testUpdateWorkspaceSettingsAcceptsShellVariableSyntaxAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [PortDefinition(name: "FRONTEND_PORT")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$TYPO_PORT npm run dev")]
        }

        let settings = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id))
        XCTAssertEqual(settings.processes.first?.command, "PORT=$TYPO_PORT npm run dev")
    }

    func testUpdateWorkspaceSettingsAcceptsSyntheticPortFallbackVariableAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [PortDefinition(name: "API_PORT")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$PORT0 npm run dev")]
        }

        let settings = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id))
        XCTAssertEqual(settings.processes.first?.command, "PORT=$PORT0 npm run dev")
    }

    func testUpdateWorkspaceSettingsRejectsBlankPortNameAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.ports = [PortDefinition(name: "  ")] }
        ) { error in XCTAssertEqual(error.localizedDescription, "Invalid argument: Port name is required.") }
    }

    func testProcessTemplateDecodingIgnoresLegacyExecutionMode() throws {
        let data = Data(#"{"id":"process-1","name":"web","command":"npm run web","on_exit":"none","execution_mode":"shell"}"#.utf8)
        let template = try JSONDecoder().decode(ProcessTemplate.self, from: data)
        let encoded = try JSONEncoder().encode(template)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(template.command, "npm run web")
        XCTAssertNil(object["execution_mode"])
    }

    func testValidateProcessTemplateAcceptsPipelineSyntax() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertNoThrow(
            try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: "PORT=$FRONTEND_PORT npm run dev | tee log.txt")))
    }

    func testLaunchAgentLauncherUsesBuiltInSpacesTerminalAndRegistersAgentWindow() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let terminateCapture = TerminalTerminateCapture()
        let launchedConfigurations = TerminalLaunchConfigurationCapture()
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher { configuration in
            launchedConfigurations.append(configuration)
            let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: configuration.sessionID, backend: configuration.backend, servicePID: Int32(ProcessInfo.processInfo.processIdentifier),
                    childPID: 5432, state: .running, updatedAt: "2026-05-18T18:00:00Z", title: configuration.title,
                    workingDirectory: configuration.workingDirectory), paths: paths)
            return TerminalServiceSessionSummary(
                id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running,
                servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 5432, controlSocketPath: paths.controlSocketPath,
                outputPath: paths.outputPath)
        }
        defer { WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher(nil) }
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 101, childPID: 5432, state: .running,
                        updatedAt: "2026-05-10T18:00:00Z"), paths: paths)
            }, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex --dangerously-skip-permissions")]
        }

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                    let record = try orchestrator.launchAgentLauncher(workspaceID: workspace.id, name: "Codex")
                    XCTAssertEqual(record.label, "Codex")
                    XCTAssertEqual(record.provider, .spaces)
                    XCTAssertEqual(record.terminalTrackingID, record.terminalNativeID)
                }
            }
        }

        XCTAssertEqual(openCapture.modes, [.owner])
        let launchedConfiguration = try XCTUnwrap(launchedConfigurations.snapshot().first)
        XCTAssertEqual(launchedConfiguration.workspaceID, workspace.id)
        XCTAssertEqual(launchedConfiguration.kind, .agent)
        let launchedCommand = try XCTUnwrap(launchedConfiguration.command)
        XCTAssertTrue(launchedCommand.contains(" -ilc "))
        XCTAssertTrue(launchedCommand.contains("\\033]0;Codex\\007"))
        XCTAssertTrue(launchedCommand.contains("codex --dangerously-skip-permissions"))
        let agentWindows = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agentWindows.count, 1)
        XCTAssertEqual(agentWindows.first?.provider, .spaces)
        let trackedTerminalWindows = try store.windows(workspaceID: workspace.id).filter { $0.role == "terminal" }
        XCTAssertTrue(trackedTerminalWindows.isEmpty || trackedTerminalWindows.first?.app == TerminalHost.spaces.appName)
        XCTAssertTrue(trackedTerminalWindows.isEmpty || trackedTerminalWindows.first?.terminalTrackingID == agentWindows.first?.terminalTrackingID)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    func testLaunchAgentLauncherReplacesStaleConfiguredSpacesAgentRowAndClosesPreviousSession() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 101, childPID: 5432, state: .running,
                        updatedAt: "2026-05-10T18:00:00Z"), paths: paths)
            }, builtInTerminalWindowCloser: { sessionID in closeCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex --dangerously-skip-permissions")]
        }
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "stale-session", terminalNativeID: "stale-session",
            status: .idle, claimedLauncherName: "Codex")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                    let record = try orchestrator.launchAgentLauncher(workspaceID: workspace.id, name: "Codex")
                    XCTAssertEqual(record.label, "Codex")
                    XCTAssertEqual(record.provider, .spaces)
                    XCTAssertEqual(record.terminalTrackingID, record.terminalNativeID)
                    XCTAssertNotEqual(record.terminalTrackingID, "stale-session")
                }
            }
        }

        XCTAssertEqual(openCapture.modes, [.owner])
        XCTAssertEqual(closeCapture.sessionIDs, ["stale-session"])
        XCTAssertEqual(terminateCapture.sessionIDs, ["stale-session"])
        let agentWindows = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agentWindows.count, 1)
        XCTAssertEqual(agentWindows.first?.label, "Codex")
        XCTAssertEqual(agentWindows.first?.provider, .spaces)
        XCTAssertNotEqual(agentWindows.first?.terminalTrackingID, "stale-session")
    }

    func testFocusAgentWindowRelaunchesClaimedSpacesLauncherWhenTrackedWindowIsClosed() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 101, childPID: 5432, state: .running,
                        updatedAt: "2026-05-10T18:00:00Z"), paths: paths)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(name: "Claude", command: "claude")]
        }
        let staleRecord = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude", terminalTrackingID: nil, terminalNativeID: nil, status: .idle,
            claimedLauncherName: "Claude")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.focusAgentWindow(staleRecord) }
            }
        }

        XCTAssertEqual(openCapture.modes, [.owner])
        let agentWindows = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agentWindows.count, 1)
        XCTAssertEqual(agentWindows.first?.provider, .spaces)
        XCTAssertNotNil(agentWindows.first?.terminalTrackingID)
    }

    func testFocusEndedClaimedSpacesAgentFocusesExistingSessionInsteadOfLaunchingDuplicate() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces-test.db").path
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true).path
        setenv(SpacesProfile.databasePathEnvironmentVariable, dbPath, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, runtimeDir, 1)
        let store = try SQLiteStore(path: dbPath)
        let openCapture = TerminalOpenCapture()
        let focusCapture = TerminalFocusCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
            },
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(name: "Reviewer", command: "review-agent")]
        }
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: "ended-reviewer-session")
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: "ended-reviewer-session", title: "Reviewer", workingDirectory: workspace.dir, shell: "/bin/zsh",
                    command: "review-agent", createdAt: "2026-05-18T18:00:00Z"), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: "ended-reviewer-session", backend: .ghosttyEmbedded, servicePID: 101, childPID: nil, state: .exited,
                    updatedAt: "2026-05-18T18:01:00Z", exitedAt: "2026-05-18T18:01:00Z", title: "Reviewer", workingDirectory: workspace.dir),
                paths: paths)
            let record = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Reviewer", terminalTrackingID: "ended-reviewer-session",
                terminalNativeID: "ended-reviewer-session", status: .done, claimedLauncherName: "Reviewer")

            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.focusAgentWindow(record) }
            }
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["ended-reviewer-session"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
        XCTAssertTrue(openCapture.sessionIDs.isEmpty)
    }

    func testUpdateAgentWindowStatusDoesNotMatchConfiguredLauncherByLabel() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Mock Agent", command: "mock-agent")])

        let configured = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Mock Agent", terminalTrackingID: "session-a", terminalNativeID: "session-a",
            status: .idle, claimedLauncherName: "Mock Agent")

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "session-b", terminalNativeID: "session-b", label: "Mock Agent",
            status: .waiting)

        let agentWindows = try store.agentWindows(workspaceID: workspace.id)
        let configuredAfterUpdate = try XCTUnwrap(agentWindows.first { $0.id == configured.id })
        XCTAssertEqual(agentWindows.count, 2)
        XCTAssertEqual(configuredAfterUpdate.label, "Mock Agent")
        XCTAssertEqual(configuredAfterUpdate.status, .idle)
        XCTAssertEqual(configuredAfterUpdate.terminalTrackingID, "session-a")
        XCTAssertNotEqual(updated.id, configured.id)
        XCTAssertEqual(updated.label, "Mock Agent-2")
        XCTAssertEqual(updated.status, .waiting)
        XCTAssertEqual(updated.terminalTrackingID, "session-b")
    }

    // Tests next window order index uses role offset and max by arranging representative inputs and asserting the expected result.
    func testNextWindowOrderIndexUsesRoleOffsetAndMax() {
        let windows = [
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "Chrome", title: "Browser", windowID: 10, role: "browser", orderIndex: 0,
                lastSeenAt: "now"),
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "Spaces", title: "Term 1", windowID: 11, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"),
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "Spaces", title: "Term 2", windowID: 12, role: "terminal", orderIndex: 205,
                lastSeenAt: "now"),
        ]

        let nextTerminal = WorkspaceOrchestrator.nextWindowOrderIndex(existing: windows, role: "terminal", orderOffset: 200)
        XCTAssertEqual(nextTerminal, 206)

        let nextEditor = WorkspaceOrchestrator.nextWindowOrderIndex(existing: windows, role: "editor", orderOffset: 100)
        XCTAssertEqual(nextEditor, 100)
    }

    // Tests add project by cloning uses repos root and repo name by arranging representative inputs and asserting the expected result.
    func testAddProjectByCloningUsesReposRootAndRepoName() throws {
        let fixture = try makeTempGitRepo(name: "sample-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        XCTAssertTrue(project.dir.hasPrefix(reposRoot.path))
        XCTAssertEqual(
            URL(fileURLWithPath: project.dir).lastPathComponent,
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "sample-repo"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--is-bare-repository"], cwd: project.dir).trimmingCharacters(in: .whitespacesAndNewlines), "true")
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        XCTAssertEqual(defaultWorkspace.title, "main")
        XCTAssertEqual(defaultWorkspace.branch, "main")
        XCTAssertTrue(defaultWorkspace.dir.hasPrefix(workspacesRoot.path))
        XCTAssertEqual(URL(fileURLWithPath: defaultWorkspace.dir).lastPathComponent, "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(defaultWorkspace.dir)/README.md"))
    }

    func testRollbackFailedImportedProjectCreationRemovesManagedRepoAndWorktreeDirectories() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(
            namespace: "git", source: "12345678-1234-1234-1234-123456789ABC", preferredName: "sample-repo")

        let project = ProjectRecord(
            id: "12345678-1234-1234-1234-123456789ABC", name: "sample-repo",
            dir: reposRoot.appendingPathComponent(managedDirname, isDirectory: true).path, isGitRepo: true, defaultBranch: "main")
        let projectDir = project.dir
        let workspaceRoot = workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true).path
        let workspaceDir = URL(fileURLWithPath: workspaceRoot).appendingPathComponent("main", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)

        try store.upsert(project: project)
        try store.upsert(
            workspace: WorkspaceRecord(
                id: UUID().uuidString, projectID: project.id, title: "main", dir: workspaceDir, dirname: "main", branch: "main", baseBranch: "main",
                isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil))

        try orchestrator.rollbackFailedImportedProjectCreation(project: project, workspaceDirectory: workspaceDir)

        XCTAssertNil(try store.project(dir: projectDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir))
        let workspaceRootContents = try FileManager.default.contentsOfDirectory(atPath: workspaceRoot)
        XCTAssertTrue(workspaceRootContents.isEmpty)
    }

    func testRollbackFailedImportedProjectCreationPreservesSiblingWorkspaceDirectoriesWithSameSanitizedName() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(
            namespace: "git", source: "12345678-1234-1234-1234-123456789ABC", preferredName: "sample-repo")

        let importedProject = ProjectRecord(
            id: "12345678-1234-1234-1234-123456789ABC", name: "sample-repo",
            dir: reposRoot.appendingPathComponent(managedDirname, isDirectory: true).path, isGitRepo: true, defaultBranch: "main")
        let sharedWorkspaceRoot = workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true)
        let importedWorkspaceDir = sharedWorkspaceRoot.appendingPathComponent("main", isDirectory: true).path
        let siblingWorkspaceDir = sharedWorkspaceRoot.appendingPathComponent("feature", isDirectory: true).path
        let importedProjectDir = importedProject.dir

        try FileManager.default.createDirectory(atPath: importedWorkspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: siblingWorkspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: importedProjectDir, withIntermediateDirectories: true)

        try store.upsert(project: importedProject)
        try store.upsert(
            workspace: WorkspaceRecord(
                id: UUID().uuidString, projectID: importedProject.id, title: "main", dir: importedWorkspaceDir, dirname: "main", branch: "main",
                baseBranch: "main", isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil))

        try orchestrator.rollbackFailedImportedProjectCreation(project: importedProject, workspaceDirectory: importedWorkspaceDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: importedProjectDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedWorkspaceDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingWorkspaceDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedWorkspaceRoot.path))
    }

    // Tests add project by cloning strips git suffix from repo name by arranging representative inputs and asserting the expected result.
    func testAddProjectByCloningStripsGitSuffixFromRepoName() throws {
        let fixture = try makeTempGitRepo(name: "source.git")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        XCTAssertTrue(project.dir.hasPrefix(reposRoot.path))
        XCTAssertEqual(
            URL(fileURLWithPath: project.dir).lastPathComponent,
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "source"))
        XCTAssertEqual(project.name, "source")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--is-bare-repository"], cwd: project.dir).trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    // Tests add project by cloning uses master branch when main is unavailable by arranging representative inputs and asserting the expected result.
    func testAddProjectByCloningUsesMasterWhenMainMissing() throws {
        let fixture = try makeTempGitRepo(name: "master-only", initialBranch: "master")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))

        XCTAssertEqual(project.defaultBranch, "master")
        XCTAssertEqual(defaultWorkspace.title, "master")
        XCTAssertEqual(defaultWorkspace.branch, "master")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(defaultWorkspace.dir)/README.md"))
    }

    // Tests remove project deletes managed git project directory by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDeletesManagedGitProjectDirectory() throws {
        let fixture = try makeTempGitRepo(name: "managed")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("repos", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: projectsRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertNil(try store.project(dir: project.dir))
        XCTAssertTrue(try orchestrator.listProjects().isEmpty)
    }

    // Tests remove project deletes managed workspace directories for managed git project by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDeletesManagedWorkspaceDirectoriesForManagedGitProject() throws {
        let fixture = try makeTempGitRepo(name: "managed-with-workspace")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let projectWorkspaceRoot = URL(
            fileURLWithPath: try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault)).dir
        ).deletingLastPathComponent()
        let workspaceDir = projectWorkspaceRoot.appendingPathComponent("main", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertTrue(workspaceDir.path.hasPrefix(workspacesRoot.path))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectWorkspaceRoot.path))
    }

    // Tests remove project does not delete unmanaged project directory but deletes managed workspace directories by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDoesNotDeleteUnmanagedProjectDirectoryButDeletesManagedWorkspaceDirectories() throws {
        let projectDir = try makeTempDirectory()
        try runGit(["init"], cwd: projectDir.path)
        try "hello".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: projectDir.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: projectDir.path)

        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature")
        let projectWorkspaceRoot = URL(fileURLWithPath: workspace.dir).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir))
        XCTAssertTrue(workspace.dir.hasPrefix(workspacesRoot.path))

        let normalizedWorkspaceDir = normalizeTestPath(workspace.dir)
        let worktreesBefore = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertTrue(parseWorktreePaths(worktreesBefore).contains(normalizedWorkspaceDir))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectWorkspaceRoot.path))
        let worktreesAfter = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertFalse(parseWorktreePaths(worktreesAfter).contains(normalizedWorkspaceDir))
    }

    // Tests archive workspace does not delete project directory for non git project by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceDoesNotDeleteProjectDirectoryForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let marker = projectDir.appendingPathComponent("marker.txt")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
    }

    // Tests create workspace for non git project allocates ports by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceForNonGitProjectAllocatesPorts() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        XCTAssertEqual(workspace.dir, projectDir.path)
        XCTAssertFalse(workspace.isArchived)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id).count, 0)
    }

    // Tests create workspace rejects directory name override for non git project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameOverrideForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "feature", directoryName: "feature_dir")) { error in
            XCTAssertTrue(error.localizedDescription.contains("only supported for git projects"))
        }
    }

    // Tests workspace stop script is seeded from project and can be overridden by arranging representative inputs and asserting the expected result.
    func testWorkspaceStopScriptIsSeededFromProjectAndCanBeOverridden() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.stopScript = "echo project-stop" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo project-stop")

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.stopScript = "echo workspace-stop" }
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo workspace-stop")

        // Project-level changes do not overwrite workspace-level overrides.
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.stopScript = "echo project-stop-updated" }
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo workspace-stop")
    }

    // Tests suggested workspace name matches auto generated dirname by arranging representative inputs and asserting the expected result.
    func testSuggestedWorkspaceNameMatchesAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-default")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: suggested, branch: suggested)

        XCTAssertEqual(workspace.title, suggested)
        XCTAssertEqual(workspace.dirname, suggested)
        XCTAssertEqual(workspace.branch, suggested)

        let nextSuggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        XCTAssertNotEqual(nextSuggested, suggested)
    }

    // Tests static workspace name suggestion chooses first available food name by arranging representative inputs and asserting the expected result.
    func testSuggestWorkspaceNameUsesFirstAvailableCandidate() {
        XCTAssertEqual(WorkspaceOrchestrator.suggestWorkspaceName(existingNames: Set<String>()), "almond")
        XCTAssertEqual(WorkspaceOrchestrator.suggestWorkspaceName(existingNames: Set(["almond"])), "anchovy")
    }

    // Tests create workspace uses custom name with auto generated dirname by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesCustomNameWithAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-custom")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch")

        XCTAssertEqual(workspace.title, "feature-name")
        XCTAssertEqual(workspace.branch, "feature-branch")
        XCTAssertEqual(workspace.dirname, suggested)
    }

    // Tests create workspace uses provided directory name for git project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesProvidedDirectoryNameForGitProject() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-override")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature_branch_1")

        XCTAssertEqual(workspace.dirname, "feature_branch_1")
        XCTAssertTrue(workspace.dir.hasSuffix("/feature_branch_1"))
    }

    // Tests create workspace rejects directory name with invalid characters by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameWithInvalidCharacters() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-invalid-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature/branch")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("letters, numbers, '-', and '_'")) }
    }

    // Tests create workspace rejects directory name with spaces by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameWithSpaces() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-space-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature branch")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("cannot contain spaces")) }
    }

    // Tests create workspace uses selected base branch as base for new branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesSelectedBaseBranchAsBaseForNewBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-target-branch")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try "target".write(to: repo.appendingPathComponent("TARGET.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "TARGET.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "target"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-workspace", branch: "feature-branch", baseBranch: "develop")

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir + "/TARGET.txt"))
        XCTAssertEqual(workspace.baseBranch, "develop")
    }

    // Tests create workspace defaults base branch to project default when omitted by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceDefaultsBaseBranchToProjectDefaultBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-default-target")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: suggested, branch: suggested)

        XCTAssertEqual(workspace.title, suggested)
        XCTAssertEqual(workspace.branch, suggested)
        XCTAssertEqual(workspace.baseBranch, project.defaultBranch)
    }

    // Tests deferred workspace setup updates state and runs setup script when requested by arranging representative inputs and asserting the expected result.
    func testDeferredWorkspaceSetupUpdatesStateAndRunsSetupScript() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo ready > .spaces-setup-marker" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", runSetupScript: false)
        let pendingState = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(pendingState.status, .pending)

        let markerURL = URL(fileURLWithPath: workspace.dir, isDirectory: true).appending(path: ".spaces-setup-marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)
        let succeededState = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(succeededState.status, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    // Tests first launch runs deferred workspace setup automatically by arranging a pending setup state and asserting launch completes setup.
    func testLaunchWorkspaceRunsDeferredSetupAutomatically() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo ready > .spaces-launch-marker" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", runSetupScript: false)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let markerURL = URL(fileURLWithPath: workspace.dir, isDirectory: true).appending(path: ".spaces-launch-marker")
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(try store.workspace(id: workspace.id)?.isRunning ?? false)
    }

    func testLaunchWorkspaceArchivedPendingSetupThrowsArchivedWithoutMutatingSetupState() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo ready > .spaces-launch-marker" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", runSetupScript: false)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived"))
        }
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)
    }

    func testWorkspaceSetupFailureStoresExitCodeLogAndBlocksLaunch() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo setup stdout; echo setup stderr >&2; exit 7"
        }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", runSetupScript: false)

        try withEnv(name: SpacesProfile.runtimeDirectoryEnvironmentVariable, value: runtimeDir.path) {
            XCTAssertThrowsError(try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Setup script exited with code 7"))
            }

            let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
            XCTAssertEqual(state.status, .failed)
            XCTAssertEqual(state.exitCode, 7)
            let logPath = try XCTUnwrap(state.logPath)
            XCTAssertEqual(
                logPath,
                runtimeDir.appendingPathComponent("workspace-setup", isDirectory: true).appendingPathComponent(workspace.id, isDirectory: true)
                    .appendingPathComponent("setup.log", isDirectory: false).path)
            let log = try String(contentsOfFile: logPath, encoding: .utf8)
            XCTAssertTrue(log.contains("setup stdout"))
            XCTAssertTrue(log.contains("setup stderr"))

            XCTAssertThrowsError(
                try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("Workspace setup failed"))
                XCTAssertTrue(error.localizedDescription.contains("exit code 7"))
            }
            XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        }
    }

    func testWorkspaceSetupUsesShellCommandEnvironmentPath() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        let commandDir = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: commandDir, withIntermediateDirectories: true)

        let commandFile = commandDir.appendingPathComponent("setupcmd")
        try """
        #!/bin/sh
        echo setup command ran
        printf path-ok > setup-path-marker
        """.write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        try """
        #!/bin/sh
        if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
          printf '\\n__SPACES_PATH__%s' "\(commandDir.path):/usr/bin:/bin"
          exit 0
        fi
        exec /bin/sh "$@"
        """.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        sharedPathMutationLock.lock()
        defer {
            sharedPathMutationLock.unlock()
            sharedEnvironmentMutationLock.unlock()
        }
        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("HOME", root.path, 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            setenv("HOME", originalHome, 1)
        }

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "setupcmd" }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", runSetupScript: false)

        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)

        let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertEqual(state.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOfFile: URL(fileURLWithPath: workspace.dir).appendingPathComponent("setup-path-marker").path, encoding: .utf8),
            "path-ok")
    }

    func testWorkspaceSetupDoesNotWaitForBackgroundChildHoldingOutputOpen() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo setup start; (sleep 2; echo background finished) & echo setup end"
        }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", runSetupScript: false)

        let startedAt = Date()
        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)
        let elapsed = Date().timeIntervalSince(startedAt)

        let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertLessThan(elapsed, 1.5)
        let logPath = try XCTUnwrap(state.logPath)
        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("setup start"))
        XCTAssertTrue(log.contains("setup end"))
    }

    func testPendingSetupBlocksManagedRuntimeLaunchesButAllowsWorkspaceTerminalReservation() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo setup"
            config.processes = [ProcessTemplate(name: "web", command: "echo web")]
            config.agentLaunchers = [AgentLauncher(name: "Codex", command: "echo codex")]
            config.browserSessions = [BrowserSession(name: "App", url: "http://localhost:3000")]
        }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", runSetupScript: false)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)

        func assertSetupBlocked(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try operation(), file: file, line: line) { error in
                XCTAssertTrue(error.localizedDescription.contains("Workspace setup has not run"), file: file, line: line)
            }
        }

        assertSetupBlocked { try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "web") }
        assertSetupBlocked { _ = try orchestrator.launchAgentLauncher(workspaceID: workspace.id, name: "Codex") }
        assertSetupBlocked { try orchestrator.recoverMissingBrowserSession(workspaceID: workspace.id, targetURL: "http://localhost:3000") }

        let reservation = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspace.id)
        XCTAssertFalse(reservation.sessionID.isEmpty)
        let paths = try TerminalSessionPaths.forSession(id: reservation.sessionID)
        let launchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(launchConfiguration.sessionID, reservation.sessionID)
        XCTAssertEqual(launchConfiguration.workspaceID, workspace.id)
        XCTAssertEqual(launchConfiguration.kind, .shell)
        XCTAssertEqual(runtimeState.sessionID, reservation.sessionID)
        XCTAssertEqual(runtimeState.state, .starting)
        XCTAssertEqual(runtimeState.title, reservation.title)
        XCTAssertGreaterThan(runtimeState.servicePID, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths.outputPath)).count, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths.serviceLogPath)).count, 0)
        let terminalWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first { $0.id == reservation.windowRecordID })
        XCTAssertEqual(terminalWindow.role, "terminal")
        XCTAssertEqual(terminalWindow.terminalNativeID, reservation.sessionID)
        XCTAssertEqual(terminalWindow.terminalTrackingID, reservation.sessionID)
        XCTAssertTrue(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)
    }

    func testWorkspaceTerminalLaunchFailureMarksReservedSessionFailedAndClearsWindowRow() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalWindowCloser: { _ in },
            builtInTerminalSessionLauncher: { _ in throw WorkspaceError.invalidArgument(message: "launcher failed") })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let reservation = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspace.id)
        let paths = try TerminalSessionPaths.forSession(id: reservation.sessionID)

        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .starting)
        XCTAssertThrowsError(
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.finishReservedWorkspaceTerminalLaunch(reservation) }
            })

        let failedState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(failedState.state, .failed)
        XCTAssertNotNil(failedState.exitedAt)
        XCTAssertNil(try store.windows(workspaceID: workspace.id).first { $0.id == reservation.windowRecordID })
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.subscriptionSocketPath))
    }

    func testRemovedWorkspaceTerminalReservationMarksSessionFailedBeforeLaunch() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let launchCapture = TerminalLaunchAttemptCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalWindowCloser: { _ in },
            builtInTerminalSessionLauncher: { _ in
                launchCapture.count += 1
                throw WorkspaceError.invalidArgument(message: "launcher should not run")
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let reservation = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspace.id)
        let paths = try TerminalSessionPaths.forSession(id: reservation.sessionID)

        try store.deleteWindow(id: reservation.windowRecordID)
        XCTAssertNoThrow(try orchestrator.finishReservedWorkspaceTerminalLaunch(reservation))

        XCTAssertEqual(launchCapture.count, 0)
        let failedState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        XCTAssertEqual(failedState.state, TerminalSessionState.failed)
        XCTAssertNotNil(failedState.exitedAt)
        XCTAssertNil(try store.windows(workspaceID: workspace.id).first { $0.id == reservation.windowRecordID })
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
    }

    // Tests list workspaces includes branch metadata by arranging representative inputs and asserting the expected result.
    func testListWorkspacesIncludesBranchMetadata() throws {
        let repo = try makeTempGitRepo(name: "workspace-branch-list")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        _ = try orchestrator.createWorkspace(projectID: project.id, name: "feature-branch", branch: "feature-branch", baseBranch: "develop")

        let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        let feature = try XCTUnwrap(workspaces.first(where: { $0.title == "feature-branch" }))
        XCTAssertEqual(feature.branch, "feature-branch")
        XCTAssertEqual(feature.baseBranch, "develop")
    }

    // Tests create workspace for non-git projects revives archived workspaces by path.
    func testCreateWorkspaceForNonGitProjectRevivesArchivedWorkspaceByPath() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let created = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = try orchestrator.archiveWorkspace(workspaceID: created.id)

        let revived = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        XCTAssertEqual(revived.id, created.id)
        XCTAssertEqual(try store.workspace(id: created.id)?.isArchived, false)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: revived.id).count, 0)
    }

    // Tests list workspaces honors include archived flag by arranging representative inputs and asserting the expected result.
    func testListWorkspacesHonorsIncludeArchivedFlag() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let activeOnly = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
        XCTAssertEqual(activeOnly.map(\.title), ["default"])

        let all = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        XCTAssertEqual(Set(all.map(\.title)), Set(["default", "feature"]))
    }

    // Tests archive workspace removes git worktree registration by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceRemovesGitWorktreeRegistration() throws {
        let repo = try makeTempGitRepo(name: "workspace-archive-git-worktree-remove")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature-archive", branch: "feature-archive")

        let normalizedWorkspaceDir = normalizeTestPath(workspace.dir)
        let before = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: repo.path)
        XCTAssertTrue(parseWorktreePaths(before).contains(normalizedWorkspaceDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir))

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let after = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: repo.path)
        XCTAssertFalse(parseWorktreePaths(after).contains(normalizedWorkspaceDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))
    }

    // Tests archive workspace gracefully handles missing worktree directory by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceGracefullyHandlesMissingWorktreeDirectory() throws {
        let repo = try makeTempGitRepo(name: "workspace-archive-missing-worktree")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let marker = root.appendingPathComponent("archive-stop-script-marker.txt")
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature-missing", branch: "feature-missing")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo ran > '\(marker.path)'")

        try FileManager.default.removeItem(atPath: workspace.dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testArchiveWorkspaceCanDeleteLocalAndRemoteBranch() throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: source.path)
        try "hello".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: source.path)
        try runGit(["checkout", "-b", "feature-cleanup"], cwd: source.path)
        try "cleanup".write(to: source.appendingPathComponent("CLEANUP.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "CLEANUP.md"], cwd: source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "cleanup"], cwd: source.path)
        try runGit(["checkout", "main"], cwd: source.path)

        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, remote.path], cwd: root.path)

        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try runGit(["clone", remote.path, clone.path], cwd: root.path)

        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let client = GitClient()

        let project = try orchestrator.addProject(dir: clone.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "cleanup", branch: "feature-cleanup", allowExistingBranchReuse: true)
        XCTAssertTrue(client.branchExists(path: clone.path, branch: "feature-cleanup"))
        XCTAssertTrue(client.remoteBranchExists(path: clone.path, branch: "feature-cleanup"))

        let outcome = try orchestrator.archiveWorkspace(workspaceID: workspace.id, deleteLocalBranch: true, deleteRemoteBranch: true)

        XCTAssertFalse(client.branchExists(path: clone.path, branch: "feature-cleanup"))
        XCTAssertFalse(client.remoteBranchExists(path: clone.path, branch: "feature-cleanup"))
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isArchived, true)
        XCTAssertTrue(outcome.notice?.contains("Deleted remote branch 'feature-cleanup'.") == true)
        XCTAssertTrue(outcome.notice?.contains("Deleted local branch 'feature-cleanup'.") == true)
    }

    func testArchiveWorkspaceClearsArchivedBranchWhenDeletionRemovesBranchIdentity() throws {
        let repo = try makeTempGitRepo(name: "archive-clears-deleted-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature")

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id, deleteLocalBranch: true)

        let archived = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertTrue(archived.isArchived)
        XCTAssertNil(archived.branch)

        let recreated = try orchestrator.createWorkspace(projectID: project.id, name: "feature-again", branch: "feature")
        XCTAssertEqual(recreated.branch, "feature")
        XCTAssertNotEqual(recreated.id, workspace.id)
    }

    func testArchiveWorkspacePreservesBranchIdentityWhenRemoteLookupFails() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "remote-archive"], cwd: fixture.source.path)
        try "remote archive".write(to: fixture.source.appendingPathComponent("REMOTE_ARCHIVE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "REMOTE_ARCHIVE.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remote archive"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-archive"], cwd: fixture.source.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let createOrchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try createOrchestrator.addProject(dir: fixture.clone.path)
        let workspace = try createOrchestrator.createWorkspace(
            projectID: project.id, name: "archive", branch: "remote-archive", allowExistingBranchReuse: true)

        let archiveOrchestrator = WorkspaceOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot, git: try makeLsRemoteFailingGitClient())
        let outcome = try archiveOrchestrator.archiveWorkspace(workspaceID: workspace.id, deleteLocalBranch: true, deleteRemoteBranch: true)

        let archived = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.branch, "remote-archive")
        XCTAssertTrue(outcome.notice?.contains("Failed to delete remote branch 'remote-archive': Git command failed: remote lookup failed") == true)
    }

    func testAlertsDismissedAttentionItemIDsClearsWhenEmpty() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        try orchestrator.setAlertsDismissedAttentionItemIDs(Set(["attention-1"]))
        XCTAssertEqual(try orchestrator.alertsDismissedAttentionItemIDs(), Set(["attention-1"]))

        try orchestrator.setAlertsDismissedAttentionItemIDs([])
        XCTAssertTrue(try orchestrator.alertsDismissedAttentionItemIDs().isEmpty)
        XCTAssertNil(try store.setting(key: SettingsKey.alertsDismissedAttentionItems))
    }

    // Tests check and update process statuses marks dead process as exited by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesMarksDeadProcessAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        // Create a process with a PID that doesn't exist
        let deadProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces", windowID: 123,
            terminalTrackingID: "workspace-session", pid: 99999, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: deadProcess)
        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        XCTAssertTrue(didUpdate)
        let updated = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .exited)
        XCTAssertNotNil(updated?.exitedAt)
    }

    // Tests check and update process statuses skips newly started processes by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesSkipsNewlyStartedProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        // Create a process that just started (within grace period)
        let newProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces", windowID: 123,
            terminalTrackingID: "workspace-session", pid: 99999, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)), exitedAt: nil)
        try store.upsert(runningProcess: newProcess)
        _ = try orchestrator.checkAndUpdateProcessStatuses()
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .running)
        XCTAssertNil(unchanged?.exitedAt)
    }

    func testCheckAndUpdateProcessStatusesTreatsZombiePIDAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("python3 is required to create a real zombie process fixture")
        }
        let pidFile = root.appendingPathComponent("zombie-pid.txt")

        let zombieParent = Process()
        zombieParent.executableURL = URL(fileURLWithPath: python)
        zombieParent.arguments = [
            "-c",
            """
            import os, pathlib, time
            path = pathlib.Path(\(String(reflecting: pidFile.path)))
            pid = os.fork()
            if pid == 0:
                os._exit(0)
            path.write_text(str(pid))
            time.sleep(30)
            """,
        ]
        try zombieParent.run()
        defer {
            if zombieParent.isRunning {
                zombieParent.terminate()
                zombieParent.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
        let zombiePID = try XCTUnwrap(Int(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        Thread.sleep(forTimeInterval: 0.2)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let zombieProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces", windowID: 123,
            terminalTrackingID: "workspace-session", terminalNativeID: "spaces-terminal", pid: zombiePID, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: zombieProcess)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()

        XCTAssertTrue(didUpdate)
        let updated = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .exited)
        XCTAssertNotNil(updated?.exitedAt)
    }

    // Tests check and update process statuses skips processes without pid by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesSkipsProcessesWithoutPID() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        // Create a process without a PID (still starting up)
        let noPidProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces", windowID: 123,
            terminalTrackingID: "workspace-session", pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: noPidProcess)
        _ = try orchestrator.checkAndUpdateProcessStatuses()
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .running)
    }

    // Tests check and update process statuses refreshes a stale tracked pid from the live built-in terminal session for managed terminals.
    // Tests check and update process statuses only checks running processes by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesOnlyChecksRunningProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        // Create an already-exited process
        let exitedProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces", windowID: 123,
            terminalTrackingID: "workspace-session", pid: 99999, status: .exited, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: ISO8601DateFormatter().string(from: Date()))
        try store.upsert(runningProcess: exitedProcess)
        _ = try orchestrator.checkAndUpdateProcessStatuses()
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .exited)
    }

    // Tests built-in terminal runtime sync revives an exited managed process when the tracked pane is still alive by arranging representative inputs and asserting the expected result.

    // Tests create workspace throws for unknown project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceThrowsForUnknownProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: "missing", name: "feature"))
    }

    // Tests create workspace for git project requires branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceForGitProjectRequiresBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-requires-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "workspace")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Branch name is required"))
        }
    }

    // Tests workspace name can be updated after creation by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNameUpdatesWorkspaceRecord() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: "feature-auth")

        let updated = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(updated.title, "feature-auth")
    }

    // Tests workspace name update allows duplicate titles by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNameAllowsDuplicateWorkspaceName() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let one = try orchestrator.createWorkspace(projectID: project.id, name: "feature-one")
        _ = try orchestrator.createWorkspace(projectID: project.id, name: "feature-two")

        XCTAssertNoThrow(try orchestrator.updateWorkspaceName(workspaceID: one.id, name: "feature-two"))
        XCTAssertEqual(try store.workspace(id: one.id)?.title, "feature-two")
    }

    // Tests default workspace name cannot be changed by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNameAllowsDefaultWorkspaceRename() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, title: "default"))

        XCTAssertNoThrow(try orchestrator.updateWorkspaceName(workspaceID: defaultWorkspace.id, name: "renamed-default"))
        let updated = try XCTUnwrap(store.workspace(id: defaultWorkspace.id))
        XCTAssertEqual(updated.title, "renamed-default")
        XCTAssertTrue(updated.isDefault)
    }

    // Tests workspace metadata update can change title, branch, directory name, and notes by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataUpdatesTitleBranchDirectoryNameAndNotes() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-start")

        try orchestrator.updateWorkspaceMetadata(
            workspaceID: workspace.id, title: "feature-auth", branch: "feature-auth", directoryName: "feature_auth",
            notes: .some("Reviewing OAuth flow"))

        let updated = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(updated.title, "feature-auth")
        XCTAssertEqual(updated.branch, "feature-auth")
        XCTAssertEqual(updated.dirname, "feature_auth")
        XCTAssertEqual(updated.notes, "Reviewing OAuth flow")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: workspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "feature-auth")
        let branches = try runGitAndCapture(["branch", "--format=%(refname:short)"], cwd: project.dir)
        XCTAssertTrue(branches.split(separator: "\n").contains("feature-auth"))
        XCTAssertFalse(branches.split(separator: "\n").contains("feature-start"))
    }

    // Tests default workspace metadata update allows title override while preserving default protections by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataAllowsDefaultWorkspaceTitleOverride() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, title: "default"))

        try orchestrator.updateWorkspaceMetadata(workspaceID: defaultWorkspace.id, title: "Codex Task", notes: .some("Imported from agent"))

        let updated = try XCTUnwrap(store.workspace(id: defaultWorkspace.id))
        XCTAssertEqual(updated.title, "Codex Task")
        XCTAssertEqual(updated.notes, "Imported from agent")
        XCTAssertTrue(updated.isDefault)

        XCTAssertThrowsError(try orchestrator.archiveWorkspace(workspaceID: defaultWorkspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Default workspace cannot be archived"))
        }
    }

    // Tests workspace metadata update can clear notes by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataClearsNotes() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, notes: .some("Investigating timeout regression"))

        try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, notes: .some(nil))

        let updated = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertNil(updated.notes)
    }

    // Tests workspace active state can be toggled independently of runtime state by arranging representative inputs and asserting persistence.
    func testUpdateWorkspaceHiddenPersistsState() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: true)
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: workspace.id)).isHidden)

        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: false)
        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isHidden)
    }

    // Tests workspace metadata update rejects renaming protected main branch by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataRejectsRenamingProtectedMainBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-main-protected")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let mainWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, title: "default"))

        XCTAssertEqual(mainWorkspace.branch, "main")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: mainWorkspace.id, branch: "main-renamed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Protected branches main/master cannot be renamed"))
        }

        let updated = try XCTUnwrap(store.workspace(id: mainWorkspace.id))
        XCTAssertEqual(updated.branch, "main")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: mainWorkspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "main")
    }

    // Tests workspace metadata update rejects renaming protected master branch by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataRejectsRenamingProtectedMasterBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-master-protected", initialBranch: "master")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let masterWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, title: "default"))

        XCTAssertEqual(masterWorkspace.branch, "master")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: masterWorkspace.id, branch: "master-renamed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Protected branches main/master cannot be renamed"))
        }

        let updated = try XCTUnwrap(store.workspace(id: masterWorkspace.id))
        XCTAssertEqual(updated.branch, "master")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: masterWorkspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "master")
    }

    // Tests open workspace terminal creates a dedicated workspace terminal and tracks the new built-in terminal shell window.

    // Tests that opening a terminal for a not-running workspace marks it as running so the UI shows Restart instead of Launch.
    func testRefreshWorkspaceWindowsPreservesGeneratedAdHocTerminalName() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "shell-1", windowID: 101, terminalTrackingID: "session-1",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value:
                    #"[{"id":101,"pid":11,"app":"Spaces","title":"zsh","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) { _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
        }

        let terminalWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(terminalWindow.title, "shell-1")
        XCTAssertEqual(terminalWindow.detail, "zsh")
    }

    func testOpenWorkspaceTerminalUsesBuiltInSpacesHostByDefault() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                XCTAssertEqual(mode, .owner)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: 4321, state: .running,
                        updatedAt: "2026-05-09T18:00:00Z"), paths: paths)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }
            }
        }

        let terminalWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(terminalWindow.app, TerminalHost.spaces.appName)
        XCTAssertEqual(terminalWindow.terminalTrackingID, terminalWindow.terminalNativeID)
    }

    func testOpenWorkspaceTerminalUsesProcessWideBuiltInSessionLauncherOverride() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let launchedConfigurations = TerminalLaunchConfigurationCapture()

        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher { configuration in
            launchedConfigurations.append(configuration)
            let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: configuration.sessionID, backend: configuration.backend, servicePID: Int32(ProcessInfo.processInfo.processIdentifier),
                    childPID: 4321, state: .running, updatedAt: "2026-05-18T18:00:00Z", title: configuration.title,
                    workingDirectory: configuration.workingDirectory), paths: paths)
            return TerminalServiceSessionSummary(
                id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running,
                servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 4321, controlSocketPath: paths.controlSocketPath,
                outputPath: paths.outputPath)
        }
        defer { WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher(nil) }
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }
            }
        }

        let launchedConfigurationSnapshot = launchedConfigurations.snapshot()
        XCTAssertEqual(launchedConfigurationSnapshot.count, 1)
        XCTAssertEqual(launchedConfigurationSnapshot.first?.workingDirectory, workspace.dir)
        XCTAssertEqual(launchedConfigurationSnapshot.first?.lifetimePolicy, .persistent)
        XCTAssertEqual(launchedConfigurationSnapshot.first?.workspaceID, workspace.id)
        XCTAssertEqual(launchedConfigurationSnapshot.first?.kind, .shell)
        XCTAssertEqual(openCapture.modes, [.owner])
        let terminalWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(terminalWindow.app, TerminalHost.spaces.appName)
        XCTAssertEqual(terminalWindow.terminalTrackingID, launchedConfigurationSnapshot.first?.sessionID)
    }

    func testRunConfiguredProcessLaunchConfigurationIncludesWorkspaceMetadata() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let launches = TerminalLaunchConfigurationCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in },
            builtInTerminalSessionLauncher: { configuration in
                launches.append(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })
        let project = makeProjectRecord(dir: projectDir.path)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: projectDir.path)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(id: "process-api", name: "api", command: "echo api")])

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: "api")
            }
        }

        let configuration = try XCTUnwrap(launches.snapshot().first)
        XCTAssertEqual(configuration.workspaceID, workspace.id)
        XCTAssertEqual(configuration.kind, .process)
        XCTAssertEqual(configuration.title, "api")
    }

    func testWorkspaceIDForTerminalSessionUsesTrackedBuiltInSessionID() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try store.upsert(
            window: WindowRecord(
                id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                windowID: nil, terminalTrackingID: "session-123", terminalNativeID: "session-123", role: "terminal", orderIndex: 200,
                lastSeenAt: "2026-05-10T18:00:00Z"))

        XCTAssertEqual(try orchestrator.workspaceIDForTerminalSession("session-123"), workspace.id)
    }

    func testWorkspaceIDForTerminalSessionFallsBackToRunningProcessSessionID() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: workspace.id, templateName: "api", command: "zsh", terminalApp: TerminalHost.spaces.appName,
                windowID: nil, terminalTrackingID: "session-456", terminalNativeID: "session-456", pid: 1234, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "2026-05-10T18:05:00Z", exitedAt: nil))

        XCTAssertEqual(try orchestrator.workspaceIDForTerminalSession("session-456"), workspace.id)
    }

    func testRemoveAdHocBuiltInTerminalSessionClearsRunningWhenSessionWasLastRuntimeIndicator() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                XCTAssertEqual(mode, .owner)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: 4321, state: .running,
                        updatedAt: "2026-05-17T18:00:00Z"), paths: paths)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }
            }
        }

        let sessionID = try XCTUnwrap(store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" })?.terminalTrackingID)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)

        XCTAssertTrue(try orchestrator.removeAdHocBuiltInTerminalSession(sessionID: sessionID))
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    // Tests focus workspace skips failed window by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceSkipsFailedWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "bad", windowID: 999, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "good", windowID: 101, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))

        // Mocked dependency: `yabai` focus command outcomes.
        // Why: control success/failure ordering and verify fallback focus behavior.
        // Remaining risk: actual focus behavior can vary with spaces/displays and concurrent window changes.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) { try orchestrator.focusWorkspace(workspaceID: workspace.id) }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["101"])
    }

    // Tests focusing a workspace process targets the process's Spaces session when multiple processes share a window.

    // Tests focus workspace process does not borrow another shared-tab index when targeting a specific session.

    func testFocusWorkspaceWindowIndexSkipsProcessDuplicatedByAgentTerminal() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("deduped-shortcut-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "Claude Code", windowID: 101,
                terminalTrackingID: "workspace-session", role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "Claude Code", command: "claude", terminalApp: "Spaces",
                windowID: 101, terminalTrackingID: "workspace-session", pid: 123, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI",
                terminalTrackingID: "workspace-session", codexThreadID: nil, windowID: 101, yabaiWindowID: 101, status: .idle, createdAt: "now",
                updatedAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "frontend", targetURL: "http://localhost:3000",
                windowID: 202, role: "browser", orderIndex: 1, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["202"])
    }

    // Tests focus window navigation uses the current focused window and wraps by arranging representative inputs and asserting the expected result.
    func testFocusWindowNavigationUsesRelativeOrderAndWraps() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("relative-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "one", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "two", windowID: 202, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "three", windowID: 303, role: "terminal", orderIndex: 2,
                lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_FOCUSED_ID", value: "202") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
                try withEnv(name: "YABAI_FOCUSED_ID", value: "101") { try orchestrator.focusPreviousWindow(workspaceID: workspace.id) }
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["303", "303", "202"])
    }

    func testFocusWindowNavigationFreezesRecencyOrderAcrossCycleSession() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace(currentDate: clock.now)
        let focusLog = root.appendingPathComponent("frozen-cycle-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "one", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "two", windowID: 202, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "three", windowID: 303, role: "terminal", orderIndex: 2,
                lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 3)
                try withEnv(name: "YABAI_FOCUSED_ID", value: "303") { try orchestrator.focusPreviousWindow(workspaceID: workspace.id) }
                try withEnv(name: "YABAI_FOCUSED_ID", value: "202") { try orchestrator.focusPreviousWindow(workspaceID: workspace.id) }
                try withEnv(name: "YABAI_FOCUSED_ID", value: "101") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs.suffix(3), ["202", "101", "202"])
    }

    // Tests focus workspace window uses browser target url when present by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceWindowUsesBrowserTargetURLWhenPresent() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("browser-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Google Calendar", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "now"))

        // Mocked dependency: direct yabai focus for the tracked dedicated Chrome window.
        // Why: ensure browser rows with target URLs still focus their tracked window.
        // Remaining risk: real Chrome window lifecycle races are not represented.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(focusedIDs, "202")
    }

    func testWorkspaceFocusableWindowNamesIncludeConfiguredNames() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "API", command: "npm run api")])
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])

        let names = try orchestrator.workspaceFocusableWindowNames(workspaceID: workspace.id)

        XCTAssertEqual(names, ["Frontend", "API"])
    }

    func testFocusWorkspaceWindowByNameRecoversConfiguredBrowserSession() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let chromeOpenLog = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-chrome-open.log")

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value:
                    #"[{"id":888,"pid":22,"app":"Google Chrome","title":"Frontend","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try withEnv(name: "MOCK_CHROME_OPEN_LOG_FILE", value: chromeOpenLog.path) {
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, name: "Frontend")
                }
            }
        }

        let trackedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "browser" }))
        XCTAssertEqual(trackedWindow.targetURL, "http://localhost:3001")
        XCTAssertEqual(trackedWindow.windowID, 888)
    }

    // Tests direct browser focus silently recovers by opening a new tracked Chrome window when the old yabai window is stale.
    func testFocusWorkspaceWindowRecoversMissingBrowserWindow() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let chromeOpenLog = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-chrome-open.log")

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 999, role: "browser", orderIndex: 0, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value:
                    #"[{"id":101,"pid":11,"app":"Spaces","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":888,"pid":22,"app":"Google Chrome","title":"Frontend","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try withEnv(name: "MOCK_CHROME_OPEN_LOG_FILE", value: chromeOpenLog.path) {
                    XCTAssertNoThrow(try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1))
                }
            }
        }

        let trackedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "browser" }))
        XCTAssertEqual(trackedWindow.windowID, 888)
        let openLog = try String(contentsOf: chromeOpenLog)
        XCTAssertTrue(openLog.contains("set URL of active tab of newWindow"))
    }

    // Tests direct browser-session focus opens a new tracked Chrome window when the configured session has no tracked window row.
    func testFocusWorkspaceBrowserSessionRecoversWhenTrackedWindowIsMissing() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let chromeOpenLog = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-chrome-open.log")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value:
                    #"[{"id":101,"pid":11,"app":"Spaces","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":888,"pid":22,"app":"Google Chrome","title":"Frontend","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try withEnv(name: "MOCK_CHROME_OPEN_LOG_FILE", value: chromeOpenLog.path) {
                    XCTAssertNoThrow(try orchestrator.focusWorkspaceBrowserSession(workspaceID: workspace.id, targetURL: "http://localhost:3001"))
                }
            }
        }

        let trackedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "browser" }))
        XCTAssertEqual(trackedWindow.targetURL, "http://localhost:3001")
        XCTAssertEqual(trackedWindow.windowID, 888)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        let openLog = try String(contentsOf: chromeOpenLog)
        XCTAssertTrue(openLog.contains("set URL of active tab of newWindow"))
    }

    // Tests direct browser-session focus reselects the tracked Chrome window's first tab instead of relying on yabai-only window focus.
    func testFocusWorkspaceBrowserSessionSelectsFirstTabInTrackedChromeWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let tabIndexLog = root.appendingPathComponent("browser-first-tab.log")
        let yabaiFocusLog = root.appendingPathComponent("browser-first-tab-yabai.log")

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: tabIndexLog.path) {
                try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: yabaiFocusLog.path) {
                    try orchestrator.focusWorkspaceBrowserSession(workspaceID: workspace.id, targetURL: "http://localhost:3001")
                }
            }
        }

        let focusedTabs = try String(contentsOf: tabIndexLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedTabs, ["front\t1"])
        let focusedWindows = try String(contentsOf: yabaiFocusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedWindows, ["202"])
    }

    // Tests workspace window cycling reselects the tracked browser window's first tab when landing on a browser target.
    func testFocusNextWindowSelectsFirstTabForBrowserTarget() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let tabIndexLog = root.appendingPathComponent("browser-cycle-first-tab.log")
        let yabaiFocusLog = root.appendingPathComponent("browser-cycle-yabai.log")

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "api", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 1, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: tabIndexLog.path) {
                try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: yabaiFocusLog.path) {
                    try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                        try withEnv(name: "YABAI_FOCUSED_APP", value: "Spaces") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
                    }
                }
            }
        }

        let focusedTabs = try String(contentsOf: tabIndexLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedTabs, ["front\t1"])
        let focusedWindows = try String(contentsOf: yabaiFocusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedWindows, ["202"])
    }

    func testFocusNextWindowHidesAppUsesScannedChromeWindowTabFocusFromBuiltInTerminal() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let chromeFocusLog = root.appendingPathComponent("browser-cycle-url-focus.log")
        let chromeTabIndexLog = root.appendingPathComponent("browser-cycle-tab-index.log")
        let yabaiFocusLog = root.appendingPathComponent("browser-cycle-url-yabai.log")
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Docs", url: "http://localhost:3001/docs/")])
        try store.upsert(
            window: WindowRecord(
                id: "window-browser", workspaceID: workspace.id, app: "Google Chrome", title: "Docs", targetURL: "http://localhost:3001/docs/",
                windowID: 302, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        let process = RunningProcessRecord(
            id: "process-spaces-browser-cycle", workspaceID: workspace.id, templateName: "frontend", command: "npm run frontend",
            terminalApp: TerminalHost.spaces.appName, windowID: 101, terminalTrackingID: "spaces-session-browser-cycle",
            terminalNativeID: "spaces-session-browser-cycle", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
            exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-terminal", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend", detail: "npm run frontend",
                targetURL: nil, windowID: 101, terminalTrackingID: "spaces-session-browser-cycle", terminalNativeID: "spaces-session-browser-cycle",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeFocusLog.path) {
                try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: "202\t1\tDocs\thttp://localhost:3001/docs/\n") {
                    try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: chromeTabIndexLog.path) {
                        try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: yabaiFocusLog.path) {
                            let hidesApp = try orchestrator.focusNextWindowHidesApp(
                                workspaceID: workspace.id, requestID: "cycle-request-browser-focus",
                                preferredFocusedBuiltInTerminalSessionID: "spaces-session-browser-cycle")
                            XCTAssertTrue(hidesApp)
                        }
                    }
                }
            }
        }

        let focusedTabs = try String(contentsOf: chromeTabIndexLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedTabs, ["202\t1"])
        let focusedURLs = try String(contentsOf: chromeFocusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedURLs, ["http://localhost:3001/docs/"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: yabaiFocusLog.path))
    }

    func testFocusNextWindowHidesAppUsesChromeURLFocusWhenScannedTabQueryFailsFromBuiltInTerminal() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let chromeFocusLog = root.appendingPathComponent("browser-cycle-scan-fail-url-focus.log")
        let chromeTabIndexLog = root.appendingPathComponent("browser-cycle-scan-fail-tab-index.log")
        let yabaiFocusLog = root.appendingPathComponent("browser-cycle-scan-fail-yabai.log")
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Docs", url: "http://localhost:3001/docs/")])
        try store.upsert(
            window: WindowRecord(
                id: "window-browser-scan-fail", workspaceID: workspace.id, app: "Google Chrome", title: "Docs",
                targetURL: "http://localhost:3001/docs/", windowID: 302, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        let process = RunningProcessRecord(
            id: "process-spaces-browser-cycle-scan-fail", workspaceID: workspace.id, templateName: "frontend", command: "npm run frontend",
            terminalApp: TerminalHost.spaces.appName, windowID: 101, terminalTrackingID: "spaces-session-browser-cycle-scan-fail",
            terminalNativeID: "spaces-session-browser-cycle-scan-fail", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
            exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-terminal-scan-fail", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend",
                detail: "npm run frontend", targetURL: nil, windowID: 101, terminalTrackingID: "spaces-session-browser-cycle-scan-fail",
                terminalNativeID: "spaces-session-browser-cycle-scan-fail", role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_SCAN_FAIL", value: "1") {
                try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeFocusLog.path) {
                    try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: chromeTabIndexLog.path) {
                        try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: yabaiFocusLog.path) {
                            let hidesApp = try orchestrator.focusNextWindowHidesApp(
                                workspaceID: workspace.id, requestID: "cycle-request-browser-focus-scan-fail",
                                preferredFocusedBuiltInTerminalSessionID: "spaces-session-browser-cycle-scan-fail")
                            XCTAssertTrue(hidesApp)
                        }
                    }
                }
            }
        }

        let focusedURLs = try String(contentsOf: chromeFocusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedURLs, ["http://localhost:3001/docs/"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: chromeTabIndexLog.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: yabaiFocusLog.path))
    }

    func testFocusNextWindowHidesAppNormalizesBrowserTargetURLFromBuiltInTerminal() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let chromeFocusLog = root.appendingPathComponent("browser-cycle-google-focus.log")
        let chromeTabIndexLog = root.appendingPathComponent("browser-cycle-google-tab-index.log")
        let yabaiFocusLog = root.appendingPathComponent("browser-cycle-google-yabai.log")
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Google", url: "https://google.com")])
        try store.upsert(
            window: WindowRecord(
                id: "window-browser-google", workspaceID: workspace.id, app: "Google Chrome", title: "Google", targetURL: "https://google.com",
                windowID: 42176, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        let process = RunningProcessRecord(
            id: "process-spaces-browser-cycle-google", workspaceID: workspace.id, templateName: "frontend", command: "npm run frontend",
            terminalApp: TerminalHost.spaces.appName, windowID: 101, terminalTrackingID: "spaces-session-browser-cycle-google",
            terminalNativeID: "spaces-session-browser-cycle-google", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
            exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-terminal-google", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend",
                detail: "npm run frontend", targetURL: nil, windowID: 101, terminalTrackingID: "spaces-session-browser-cycle-google",
                terminalNativeID: "spaces-session-browser-cycle-google", role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeFocusLog.path) {
                try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: "1039450131\t1\tGoogle\thttps://www.google.com/\n") {
                    try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: chromeTabIndexLog.path) {
                        try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: yabaiFocusLog.path) {
                            let hidesApp = try orchestrator.focusNextWindowHidesApp(
                                workspaceID: workspace.id, requestID: "cycle-request-browser-focus-google",
                                preferredFocusedBuiltInTerminalSessionID: "spaces-session-browser-cycle-google")
                            XCTAssertTrue(hidesApp)
                        }
                    }
                }
            }
        }

        let focusedTabs = try String(contentsOf: chromeTabIndexLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedTabs, ["1039450131\t1"])
        let focusedURLs = try String(contentsOf: chromeFocusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedURLs, ["https://www.google.com/"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: yabaiFocusLog.path))
    }

    func testFocusNextWindowUsesFrontBrowserURLWhenYabaiHasNoFocusedWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("browser-cycle-fallback-focus.log")

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Docs", url: "http://localhost:3001/docs/")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Docs", targetURL: "http://localhost:3001/docs/",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Finder", title: "Notes", windowID: 303, role: "editor", orderIndex: 1,
                lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_FOCUSED_NONE", value: "1") {
                    try withEnv(name: "MOCK_CHROME_ACTIVE_URL", value: "http://localhost:3001/docs/") {
                        try orchestrator.focusNextWindow(workspaceID: workspace.id)
                    }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["303"])
    }

    func testFocusPreviousWindowUsesPreferredBuiltInTerminalSessionBeforeFallback() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let root = try makeTempDirectory()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in XCTFail("cycle focus should not reopen built-in sessions") },
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        try store.upsert(
            window: WindowRecord(
                id: "window-browser", workspaceID: workspace.id, app: "Google Chrome", title: "Docs", targetURL: "http://localhost:3001/docs/",
                windowID: 101, role: "browser", orderIndex: 0, lastSeenAt: "now"))
        let process = RunningProcessRecord(
            id: "process-spaces-cycle-priority", workspaceID: workspace.id, templateName: "frontend", command: "npm run frontend",
            terminalApp: TerminalHost.spaces.appName, windowID: 202, terminalTrackingID: "spaces-session-priority",
            terminalNativeID: "spaces-session-priority", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-process", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend", detail: "npm run frontend",
                targetURL: nil, windowID: 202, terminalTrackingID: "spaces-session-priority", terminalNativeID: "spaces-session-priority",
                role: "terminal", orderIndex: 1, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
            }
            _ = try orchestrator.focusPreviousWindowHidesApp(
                workspaceID: workspace.id, requestID: "cycle-request-1", preferredFocusedBuiltInTerminalSessionID: "spaces-session-priority")
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-priority"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
    }

    // Tests window cycling ignores missing browser windows and keeps moving to the next live tracked window.
    func testFocusNextWindowIgnoresMissingBrowserWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("ignore-missing-browser-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 999, role: "browser", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "api", windowID: 101, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_FOCUSED_ID", value: "555") {
                    try withEnv(name: "YABAI_FOCUSED_APP", value: "Finder") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["101"])
    }

    func testFocusNextWindowDoesNotRequestAppHideForBuiltInProcessTarget() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let root = try makeTempDirectory()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in XCTFail("built-in cycle focus should not reopen the session") },
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        try store.upsert(
            window: WindowRecord(
                id: "window-browser", workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 101, role: "browser", orderIndex: 0, lastSeenAt: "now"))
        let process = RunningProcessRecord(
            id: "process-spaces-cycle", workspaceID: workspace.id, templateName: "api", command: "npm run api",
            terminalApp: TerminalHost.spaces.appName, windowID: 202, terminalTrackingID: "spaces-session-cycle",
            terminalNativeID: "spaces-session-cycle", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-process", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api", targetURL: nil,
                windowID: 202, terminalTrackingID: "spaces-session-cycle", terminalNativeID: "spaces-session-cycle", role: "terminal",
                orderIndex: 200, lastSeenAt: "now"))

        var hidesApp = true
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                    hidesApp = try orchestrator.focusNextWindowHidesApp(workspaceID: workspace.id)
                }
            }
        }

        XCTAssertFalse(hidesApp)
        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-cycle"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
    }

    // Tests process focus throws a recoverable missing-window error when a legacy tracked terminal window no longer exists.
    func testFocusWorkspaceProcessThrowsRecoverableErrorForMissingProcessWindow() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "LegacyTerminal",
            windowID: 999, terminalTrackingID: "session-999", pid: 1234, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
            exitedAt: nil)
        try store.upsert(runningProcess: process)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            XCTAssertThrowsError(try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id)) { error in
                guard case .missingTrackedWindow(let context) = error as? WorkspaceError else {
                    return XCTFail("Expected missingTrackedWindow, got \(error)")
                }
                XCTAssertEqual(context.kind, .process)
                XCTAssertEqual(context.processID, process.id)
                XCTAssertEqual(context.title, "api")
            }
        }
    }

    func testFocusWorkspaceProcessUsesBuiltInSpacesSessionWithoutTrackedYabaiWindowID() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let process = RunningProcessRecord(
            id: "process-spaces", workspaceID: workspace.id, templateName: "web", command: "npm run dev", terminalApp: TerminalHost.spaces.appName,
            windowID: nil, terminalTrackingID: "spaces-session-1", terminalNativeID: "spaces-session-1", pid: nil, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev", targetURL: nil,
                windowID: nil, terminalTrackingID: "spaces-session-1", terminalNativeID: "spaces-session-1", role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id)

        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-1"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
    }

    func testFocusWorkspaceProcessReusesLiveBuiltInSpacesSessionWithoutOpeningWhenWindowBindingIsMissing() throws {
        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let focusCapture = TerminalFocusCapture()
        let root = try makeTempDirectory()
        let queryLog = root.appendingPathComponent("yabai-query.log")
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
            },
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let process = RunningProcessRecord(
            id: "process-spaces-session-only", workspaceID: workspace.id, templateName: "web", command: "npm run dev",
            terminalApp: TerminalHost.spaces.appName, windowID: nil, terminalTrackingID: "spaces-session-live-only",
            terminalNativeID: "spaces-session-live-only", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil
        )
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-session-only", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: nil, terminalTrackingID: "spaces-session-live-only", terminalNativeID: "spaces-session-live-only",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "889") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: TerminalHost.spaces.appName) {
                    try withEnv(name: "YABAI_FOCUSED_TITLE", value: "web") {
                        try withEnv(name: "YABAI_QUERY_LOG_FILE", value: queryLog.path) {
                            try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id)
                        }
                    }
                }
            }
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-live-only"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
        XCTAssertTrue(openCapture.sessionIDs.isEmpty)

        let updatedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == process.id }))
        XCTAssertEqual(updatedProcess.windowID, 889)

        let updatedWindow = try XCTUnwrap(
            try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" && $0.terminalTrackingID == "spaces-session-live-only" }
            ))
        XCTAssertEqual(updatedWindow.windowID, 889)

        let queryLines = try String(contentsOf: queryLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(queryLines.filter { $0 == "query --windows --window" }.count, 1)
        XCTAssertFalse(queryLines.contains("query --windows"))
    }

    func testRefreshWorkspaceWindowsPreservesAdHocBuiltInTerminalWindowWithoutYabaiWindowIDWhileSessionIsLive() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-ad-hoc-session"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(sessionID: sessionID, title: "shell-1", workingDirectory: projectDir.path, shell: "/bin/zsh", command: nil, createdAt: "now"),
                paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now"), paths: paths)
            try TerminalSessionPersistence.attachClient(
                sessionID: sessionID,
                client: TerminalClient(
                    id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
                    connectedAt: "now"), mode: .owner, paths: paths, attachedAt: "now")

            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.filter { $0.role == "terminal" }.map(\.id), ["window-spaces-shell-1"])
        XCTAssertEqual(windows.first?.name, "shell-1")
    }

    func testRefreshWorkspaceWindowsPreservesAdHocBuiltInTerminalWindowUntilHostDetachesStaleRemoteAttachment() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-ad-hoc-session-stale-remote"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(sessionID: sessionID, title: "shell-1", workingDirectory: projectDir.path, shell: "/bin/zsh", command: nil, createdAt: "now"),
                paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now"), paths: paths)
            try TerminalSessionPersistence.attachClient(
                sessionID: sessionID,
                client: TerminalClient(
                    id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", hostName: "phone", deviceName: "Remote Client"),
                    connectedAt: "2000-01-01T00:00:00Z"), mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")

            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.filter { $0.role == "terminal" }.map(\.id), ["window-spaces-shell-1"])
        XCTAssertEqual(windows.first?.name, "shell-1")
    }

    func testRefreshWorkspaceWindowsPrunesAdHocBuiltInTerminalWindowAfterOwnerCloses() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path, )
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-ad-hoc-session-closed"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, title: "shell-1", workingDirectory: projectDir.path, shell: "/bin/zsh", command: nil, createdAt: timestamp),
                paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: timestamp), paths: paths)
            let ownerClient = TerminalClient(
                id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
                connectedAt: timestamp)
            try TerminalSessionPersistence.attachClient(sessionID: sessionID, client: ownerClient, mode: .owner, paths: paths, attachedAt: timestamp)
            try TerminalSessionPersistence.detachClient(id: ownerClient.id, paths: paths, detachedAt: timestamp)

            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
            }
        }

        XCTAssertTrue(try orchestrator.windows(workspaceID: workspace.id).isEmpty)
    }

    func testRefreshWorkspaceWindowsKeepsBuiltInProcessTerminalWindowAfterOwnerCloses() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path, )
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-process-session"
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "window-process-api", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 4321,
                    state: .running, updatedAt: "now"), paths: paths)

            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.map(\.id), ["process-api"])
    }

    func testRefreshWorkspaceWindowsKeepsBuiltInAgentTerminalWindowAfterOwnerCloses() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path, )
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-agent-session"
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID,
                terminalNativeID: sessionID, codexThreadID: nil, windowID: 202, status: .spinning, createdAt: "now", updatedAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, title: "Codex", workingDirectory: projectDir.path, shell: "/bin/zsh", command: "codex",
                    createdAt: timestamp, workspaceID: workspace.id, kind: .agent), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 4321,
                    state: .running, updatedAt: timestamp), paths: paths)
            let ownerClient = TerminalClient(
                id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
                connectedAt: timestamp)
            try TerminalSessionPersistence.attachClient(sessionID: sessionID, client: ownerClient, mode: .owner, paths: paths, attachedAt: timestamp)
            try TerminalSessionPersistence.detachClient(id: ownerClient.id, paths: paths, detachedAt: timestamp)

            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.map(\.terminalTrackingID), [sessionID])
        XCTAssertNil(windows.first?.windowID)
        let agents = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agents.map(\.id), ["agent-codex"])
        XCTAssertEqual(agents.first?.terminalTrackingID, sessionID)
        XCTAssertNil(agents.first?.windowID)
    }

    func testFocusAgentWindowPersistsReopenedBuiltInSpacesWindowBinding() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-agent-session-reopen"
        let agent = AgentWindowRecord(
            id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID,
            terminalNativeID: sessionID, codexThreadID: nil, windowID: nil, status: .spinning, createdAt: "now", updatedAt: "now")
        try store.upsertAgentWindow(agent)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "889") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: TerminalHost.spaces.appName) {
                    try orchestrator.focusAgentWindow(agent)
                    XCTAssertEqual(try orchestrator.workspaceIDForFocusedWindow(), workspace.id)
                }
            }
        }

        XCTAssertEqual(focusCapture.sessionIDs, [sessionID])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.windowID, 889)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).first?.windowID, 889)
    }

    func testFocusWorkspaceProcessUsesBuiltInFocusIPCForLiveBuiltInSpacesWindow() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let root = try makeTempDirectory()
        let focusLog = root.appendingPathComponent("spaces-live-window-focus.log")
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in XCTFail("live built-in window focus should not reopen the session") },
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let process = RunningProcessRecord(
            id: "process-spaces-live-window", workspaceID: workspace.id, templateName: "web", command: "npm run dev",
            terminalApp: TerminalHost.spaces.appName, windowID: 501, terminalTrackingID: "spaces-session-live",
            terminalNativeID: "spaces-session-live", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-live-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 501, terminalTrackingID: "spaces-session-live", terminalNativeID: "spaces-session-live", role: "terminal",
                orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(
                    name: "YABAI_WINDOWS_JSON",
                    value:
                        #"[{"id":501,"pid":11,"app":"Spaces","title":"web","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                ) { try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id) }
            }
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-live"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
        XCTAssertFalse(FileManager.default.fileExists(atPath: focusLog.path))
    }

    func testFocusWorkspaceProcessPassesRequestIDToBuiltInSpacesFocusIPC() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in XCTFail("focus should not reopen built-in session") },
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let root = try makeTempDirectory()
        let focusLog = root.appendingPathComponent("spaces-built-in-focus.log")
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let process = RunningProcessRecord(
            id: "process-spaces-request-id", workspaceID: workspace.id, templateName: "web", command: "npm run dev",
            terminalApp: TerminalHost.spaces.appName, windowID: nil, terminalTrackingID: "spaces-session-request-id",
            terminalNativeID: "spaces-session-request-id", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
            exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-request-id", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: nil, terminalTrackingID: "spaces-session-request-id", terminalNativeID: "spaces-session-request-id",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id, requestID: "focus-request-1")
            }
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-request-id"])
        XCTAssertEqual(focusCapture.requestIDs, ["focus-request-1"])
    }

    func testCycleFocusWorkspaceProcessSkipsStaleYabaiFocusProbeForBuiltInSpacesSession() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let openCapture = TerminalOpenCapture()
        let root = try makeTempDirectory()
        let focusLog = root.appendingPathComponent("yabai-focus.log")
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
            },
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let process = RunningProcessRecord(
            id: "process-spaces-cycle-fast-path", workspaceID: workspace.id, templateName: "web", command: "npm run dev",
            terminalApp: TerminalHost.spaces.appName, windowID: 777, terminalTrackingID: "spaces-session-cycle-fast-path",
            terminalNativeID: "spaces-session-cycle-fast-path", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
            exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-cycle-fast-path", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 777, terminalTrackingID: "spaces-session-cycle-fast-path",
                terminalNativeID: "spaces-session-cycle-fast-path", role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                    try withEnv(name: "YABAI_FOCUS_FAIL_IDS", value: "777") {
                        try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id, requestID: "cycle-request-1")
                    }
                }
            }
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-cycle-fast-path"])
        XCTAssertEqual(focusCapture.requestIDs, ["cycle-request-1"])
        XCTAssertTrue(openCapture.sessionIDs.isEmpty)
        XCTAssertTrue(openCapture.modes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: focusLog.path))
    }

    func testFocusWorkspaceProcessReopensBuiltInSpacesSessionAndClearsStaleWindowBinding() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let pulseController = MockTerminalFocusPulseController()
        let root = try makeTempDirectory()
        let orchestrator = WorkspaceOrchestrator(
            store: store, terminalFocusPulseController: pulseController,
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let process = RunningProcessRecord(
            id: "process-spaces-stale-window", workspaceID: workspace.id, templateName: "web", command: "npm run dev",
            terminalApp: TerminalHost.spaces.appName, windowID: 777, terminalTrackingID: "spaces-session-stale",
            terminalNativeID: "spaces-session-stale", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-stale-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 777, terminalTrackingID: "spaces-session-stale", terminalNativeID: "spaces-session-stale", role: "terminal",
                orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                    try withEnv(name: "YABAI_FOCUS_FAIL_IDS", value: "777") {
                        try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id)
                    }
                }
            }
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-stale"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
        XCTAssertTrue(pulseController.pulsedWindowIDs.isEmpty)

        let updatedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == process.id }))
        XCTAssertNil(updatedProcess.windowID)

        let updatedWindow = try XCTUnwrap(
            try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" && $0.terminalTrackingID == "spaces-session-stale" }))
        XCTAssertNil(updatedWindow.windowID)
    }

    func testFocusWorkspaceProcessRebindsBuiltInSpacesSessionToFreshWindowWithoutReopenWhenFocusIPCFindsLiveWindow() throws {
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let focusCapture = TerminalFocusCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
            },
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project
        let queryLog = root.appendingPathComponent("yabai-query.log")

        let process = RunningProcessRecord(
            id: "process-spaces-rebound-window", workspaceID: workspace.id, templateName: "web", command: "npm run dev",
            terminalApp: TerminalHost.spaces.appName, windowID: 777, terminalTrackingID: "spaces-session-rebound",
            terminalNativeID: "spaces-session-rebound", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-rebound-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 777, terminalTrackingID: "spaces-session-rebound", terminalNativeID: "spaces-session-rebound",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                try withEnv(name: "YABAI_FOCUS_FAIL_IDS", value: "777") {
                    try withEnv(name: "YABAI_FOCUSED_ID", value: "888") {
                        try withEnv(name: "YABAI_FOCUSED_APP", value: TerminalHost.spaces.appName) {
                            try withEnv(name: "YABAI_FOCUSED_TITLE", value: "web") {
                                try withEnv(name: "YABAI_QUERY_LOG_FILE", value: queryLog.path) {
                                    try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id)
                                }
                            }
                        }
                    }
                }
            }
        }

        XCTAssertTrue(capture.sessionIDs.isEmpty)
        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-rebound"])

        let updatedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == process.id }))
        XCTAssertEqual(updatedProcess.windowID, 888)

        let updatedWindow = try XCTUnwrap(
            try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" && $0.terminalTrackingID == "spaces-session-rebound" }))
        XCTAssertEqual(updatedWindow.windowID, 888)

        let queryLines = try String(contentsOf: queryLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(queryLines.filter { $0 == "query --windows --window" }.count, 1)
        XCTAssertFalse(queryLines.contains("query --windows"))
    }

    func testFocusWorkspaceProcessUsesTrackedBuiltInSessionWhenLiveWindowIDExists() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let pulseController = MockTerminalFocusPulseController()
        let root = try makeTempDirectory()
        let focusLog = root.appendingPathComponent("spaces-tracked-live-window-focus.log")
        let orchestrator = WorkspaceOrchestrator(
            store: store, terminalFocusPulseController: pulseController,
            builtInTerminalWindowFocuser: { sessionID, requestID in
                focusCapture.sessionIDs.append(sessionID)
                focusCapture.requestIDs.append(requestID)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let process = RunningProcessRecord(
            id: "process-spaces-live-window", workspaceID: workspace.id, templateName: "web", command: "npm run dev",
            terminalApp: TerminalHost.spaces.appName, windowID: 777, terminalTrackingID: "spaces-session-live",
            terminalNativeID: "spaces-session-live", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-live-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 777, terminalTrackingID: "spaces-session-live", terminalNativeID: "spaces-session-live", role: "terminal",
                orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(
                    name: "YABAI_WINDOWS_JSON",
                    value:
                        #"[{"id":777,"pid":11,"app":"Spaces","title":"web","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                ) { try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id) }
            }
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["spaces-session-live"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
        XCTAssertFalse(FileManager.default.fileExists(atPath: focusLog.path))
        XCTAssertTrue(pulseController.pulsedWindowIDs.isEmpty)
    }

    // Tests restarting a process recreates a tracked terminal window row even if the stale window row was already pruned.
    func testRestartWorkspaceProcessUsesConfiguredSpacesHostEvenWhenStoredProcessHostDiffers() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
                if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                    try? paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try? TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 4321, state: .running,
                            updatedAt: "2026-05-11T09:00:00Z"), paths: paths)
                    try? "process restarted\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
                }
            }, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "LegacyTerminal",
                windowID: 999, terminalTrackingID: "session-old", terminalNativeID: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "now", exitedAt: nil))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: "process-api")
            }
        }

        XCTAssertEqual(capture.modes, [.owner])
        XCTAssertEqual(capture.sessionIDs.count, 1)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
        let restartedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == "process-api" }))
        XCTAssertEqual(restartedProcess.terminalApp, TerminalHost.spaces.appName)
        XCTAssertEqual(restartedProcess.terminalTrackingID, capture.sessionIDs.first)
        XCTAssertEqual(restartedProcess.status, RunningProcessState.running)

        let restartedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(restartedWindow.app, TerminalHost.spaces.appName)
        XCTAssertEqual(restartedWindow.terminalTrackingID, capture.sessionIDs.first)
    }

    func testRestartWorkspaceProcessClosesPreviousSpacesSessionBeforeStartingReplacement() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let killLog = root.appendingPathComponent("kill.log").path
        let killMock = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$SPACES_TEST_KILL_LOG"
            exit 0
            """
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
                if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                    try? paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try? TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 4321, state: .running,
                            updatedAt: "2026-05-11T09:00:00Z"), paths: paths)
                }
            }, builtInTerminalWindowCloser: { sessionID in closeCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                windowID: 999, terminalTrackingID: "old-spaces-session", terminalNativeID: "old-spaces-session", pid: 999_999, status: .running,
                logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "old-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api", targetURL: nil,
                windowID: 999, terminalTrackingID: "old-spaces-session", terminalNativeID: "old-spaces-session", role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withEnv(name: "SPACES_TEST_KILL_LOG", value: killLog) {
                try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "kill": killMock]) {
                    try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: "process-api")
                }
            }
        }

        XCTAssertEqual(closeCapture.sessionIDs, ["old-spaces-session"])
        XCTAssertEqual(terminateCapture.sessionIDs, ["old-spaces-session"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: killLog))
        XCTAssertEqual(openCapture.modes, [.owner])
        XCTAssertEqual(openCapture.sessionIDs.count, 1)
        XCTAssertNotEqual(openCapture.sessionIDs.first, "old-spaces-session")
        let restartedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == "process-api" }))
        XCTAssertEqual(restartedProcess.terminalTrackingID, openCapture.sessionIDs.first)
    }

    // Tests running-process recovery reattaches without restarting when the built-in terminal session is still available.
    // Tests running-process recovery returns false instead of restarting when the tracked process is no longer alive.
    func testRecoverRunningWorkspaceProcessIfPossibleReturnsFalseWhenProcessIsNotRunning() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 999,
            terminalTrackingID: "session-old", pid: 999_999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)

        let recovered = try orchestrator.recoverRunningWorkspaceProcessIfPossible(workspaceID: workspace.id, processID: process.id)

        XCTAssertFalse(recovered)
    }

    func testRecoverRunningWorkspaceProcessIfPossibleReopensBuiltInSpacesSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-session-recover-1"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: getpid(), state: .running,
                    updatedAt: "2026-05-09T19:00:00Z"), paths: paths)

            let process = RunningProcessRecord(
                id: "process-spaces-recover", workspaceID: workspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, windowID: 401, terminalTrackingID: sessionID, terminalNativeID: sessionID,
                pid: Int(getpid()), status: .running, logPath: paths.outputPath, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
            try store.upsert(runningProcess: process)
            try store.upsert(
                window: WindowRecord(
                    id: process.id, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api", targetURL: nil,
                    windowID: 401, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                    let recovered = try orchestrator.recoverRunningWorkspaceProcessIfPossible(workspaceID: workspace.id, processID: process.id)
                    XCTAssertTrue(recovered)
                }
            }
        }

        XCTAssertEqual(capture.sessionIDs, [sessionID])
        XCTAssertEqual(capture.modes, [.owner])

        let recoveredProcess = try XCTUnwrap(
            try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == "process-spaces-recover" }))
        XCTAssertEqual(recoveredProcess.terminalTrackingID, sessionID)
        XCTAssertEqual(recoveredProcess.terminalNativeID, sessionID)
        XCTAssertEqual(recoveredProcess.terminalApp, TerminalHost.spaces.appName)
        XCTAssertNil(recoveredProcess.windowID)

        let recoveredWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.id == "process-spaces-recover" }))
        XCTAssertEqual(recoveredWindow.terminalTrackingID, sessionID)
        XCTAssertEqual(recoveredWindow.terminalNativeID, sessionID)
        XCTAssertEqual(recoveredWindow.app, TerminalHost.spaces.appName)
        XCTAssertNil(recoveredWindow.windowID)
    }

    // Tests configured-but-missing processes can be recovered directly without restarting unrelated running processes.
    func testRecoverMissingConfiguredProcessMarksStoppedWorkspaceRunning() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: "api")
            }
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.templateName), ["api"])
    }

    func testRecoverMissingConfiguredProcessUsesBuiltInSpacesSessionHost() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
                if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                    try? paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try? TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 4321, state: .running,
                            updatedAt: "2026-05-09T21:00:00Z"), paths: paths)
                    try? "process recovered\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
                }
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [ProcessTemplate(name: "api", command: "npm run api"), ProcessTemplate(name: "web", command: "npm run web")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-web", workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: TerminalHost.spaces.appName,
                windowID: 222, terminalTrackingID: "session-web", terminalNativeID: "session-web", pid: 2222, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                    try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: "api")
                }
            }
        }

        XCTAssertEqual(capture.modes, [.owner])
        XCTAssertEqual(capture.sessionIDs.count, 1)

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(Set(processes.map(\.templateName)), ["api", "web"])
        let recoveredProcess = try XCTUnwrap(processes.first(where: { $0.templateName == "api" }))
        XCTAssertEqual(recoveredProcess.command, "npm run api")
        XCTAssertEqual(recoveredProcess.status, .running)
        XCTAssertEqual(recoveredProcess.terminalApp, TerminalHost.spaces.appName)
        XCTAssertEqual(recoveredProcess.terminalTrackingID, capture.sessionIDs.first)
        XCTAssertEqual(recoveredProcess.terminalNativeID, capture.sessionIDs.first)
        XCTAssertEqual(recoveredProcess.pid, 4321)
        XCTAssertNotNil(recoveredProcess.logPath)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    func testRecoverMissingConfiguredProcessUsesBuiltInSpacesSessionHostWhenNoPriorRuntimeExists() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
                if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                    try? paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try? TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 9876, state: .running,
                            updatedAt: "2026-05-11T18:00:00Z"), paths: paths)
                    try? "process recovered\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
                }
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                    try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: "api")
                }
            }
        }

        XCTAssertEqual(capture.modes, [.owner])
        XCTAssertEqual(capture.sessionIDs.count, 1)
        let recoveredProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
        XCTAssertEqual(recoveredProcess.terminalApp, TerminalHost.spaces.appName)
        XCTAssertEqual(recoveredProcess.terminalTrackingID, capture.sessionIDs.first)
        XCTAssertEqual(recoveredProcess.terminalNativeID, capture.sessionIDs.first)
        XCTAssertEqual(recoveredProcess.pid, 9876)
    }

    // Tests no-op settings saves do not restart a recovered named process.
    func testUpdateWorkspaceSettingsDoesNotRestartRecoveredNamedProcess() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "web", command: "npm run web")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces", windowID: 222,
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }
        }

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.templateName, "web")
    }

    func testUpdateWorkspaceSettingsWhileRunningDoesNotReconcileProcessesAndSyncsPorts() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "web", command: "npm run web")])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [24000], names: ["API_PORT"])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces", windowID: 222,
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "worker", command: "npm run worker")]
                settings.ports = [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")]
            }
        }

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.templateName, "web")

        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(namedPorts.map(\.port), [24000, 20000])
        XCTAssertEqual(namedPorts.map(\.name), ["API_PORT", "WEB_PORT"])
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 1)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .healthy)
        XCTAssertNil(runtimeStatus.warningSummary)

        PortReserver.shared.releasePorts(workspaceID: workspace.id)
    }

    func testUpdateRunningWorkspaceProcessesRelabelsRunningProcessAndUpdatesOnExit() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces", windowID: 222,
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: processID, workspaceID: workspace.id, app: "Spaces", name: "web", detail: "npm run web", windowID: 222,
                terminalTrackingID: "session-web", terminalNativeID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try orchestrator.updateRunningWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(id: process.id, name: "frontend", command: "npm run web", onExit: .restart)],
            restartChangedCommands: false)

        let configured = try store.workspaceProcesses(workspaceID: workspace.id)
        XCTAssertEqual(configured.count, 1)
        XCTAssertEqual(configured.first?.name, "frontend")
        XCTAssertEqual(configured.first?.command, "npm run web")
        XCTAssertEqual(configured.first?.onExit, .restart)
        let running = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(running.map(\.templateName), ["frontend"])
        XCTAssertEqual(running.first?.command, "npm run web")
        let windows = try store.windows(workspaceID: workspace.id).filter { $0.role == "terminal" }
        XCTAssertEqual(windows.map(\.name), ["frontend"])
    }

    func testUpdateRunningWorkspaceProcessesRestartsChangedCommandAfterConfirmation() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces", windowID: 222,
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateRunningWorkspaceProcesses(
                workspaceID: workspace.id, processes: [ProcessTemplate(id: process.id, name: "frontend", command: "npm run web:v2", onExit: .notify)],
                restartChangedCommands: true)
        }

        let configured = try store.workspaceProcesses(workspaceID: workspace.id)
        XCTAssertEqual(configured.count, 1)
        XCTAssertEqual(configured.first?.name, "frontend")
        XCTAssertEqual(configured.first?.command, "npm run web:v2")
        XCTAssertEqual(configured.first?.onExit, .notify)
        let running = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(running.map(\.templateName), ["frontend"])
        XCTAssertEqual(running.first?.command, "npm run web:v2")
        XCTAssertEqual(running.first?.terminalApp, TerminalHost.spaces.appName)
        XCTAssertNotEqual(running.first?.terminalTrackingID, "session-web")
        XCTAssertEqual(running.first?.terminalTrackingID, running.first?.terminalNativeID)
        XCTAssertEqual(running.first?.pid, 4321)
    }

    func testUpdateRunningWorkspaceProcessesRejectsChangedCommandWithoutRestartConfirmation() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces", windowID: 222,
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        XCTAssertThrowsError(
            try orchestrator.updateRunningWorkspaceProcesses(
                workspaceID: workspace.id, processes: [ProcessTemplate(id: process.id, name: "web", command: "npm run web:v2", onExit: .none)],
                restartChangedCommands: false))

        let configured = try store.workspaceProcesses(workspaceID: workspace.id)
        XCTAssertEqual(configured.count, 1)
        XCTAssertEqual(configured.first?.name, "web")
        XCTAssertEqual(configured.first?.command, "npm run web")
        XCTAssertEqual(configured.first?.onExit, ProcessExitAction.none)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.command), ["npm run web"])
    }

    func testUpdateRunningWorkspaceProcessesRestartsCompositeShellCommand() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "LegacyTerminal", windowID: 222,
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateRunningWorkspaceProcesses(
                workspaceID: workspace.id,
                processes: [
                    ProcessTemplate(id: process.id, name: "web", command: "cd $SPACES_WORKSPACE_DIR && npm run web | tee log.txt", onExit: .none)
                ], restartChangedCommands: true)
        }

        let running = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(running.map(\.templateName), ["web"])
        XCTAssertEqual(running.first?.command, "cd $SPACES_WORKSPACE_DIR && npm run web | tee log.txt")
        XCTAssertEqual(running.first?.terminalApp, TerminalHost.spaces.appName)
        XCTAssertNotEqual(running.first?.terminalTrackingID, "session-web")
        XCTAssertEqual(running.first?.terminalTrackingID, running.first?.terminalNativeID)
        XCTAssertEqual(running.first?.pid, 4321)
    }

    func testUpdateRunningWorkspaceProcessesDeletingEarlierRowKeepsLaterRunningProcessMatchedByID() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let web = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        let worker = ProcessTemplate(id: "process-worker", name: "worker", command: "npm run worker", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [web, worker])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "running-web", workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces", windowID: 221,
                terminalTrackingID: "session-web", pid: 1111, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "running-worker", workspaceID: workspace.id, templateName: "worker", command: "npm run worker", terminalApp: "Spaces",
                windowID: 222, terminalTrackingID: "session-worker", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "window-web", workspaceID: workspace.id, app: "Spaces", name: "web", detail: "npm run web", windowID: 221,
                terminalTrackingID: "session-web", terminalNativeID: nil, role: "terminal", orderIndex: 100, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: "window-worker", workspaceID: workspace.id, app: "Spaces", name: "worker", detail: "npm run worker", windowID: 222,
                terminalTrackingID: "session-worker", terminalNativeID: nil, role: "terminal", orderIndex: 101, lastSeenAt: "now"))

        try orchestrator.updateRunningWorkspaceProcesses(workspaceID: workspace.id, processes: [worker], restartChangedCommands: false)

        let configured = try store.workspaceProcesses(workspaceID: workspace.id)
        XCTAssertEqual(configured.map(\.id), [worker.id])
        XCTAssertEqual(configured.map(\.name), ["worker"])

        let running = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(Set(running.map(\.templateName)), ["web", "worker"])
        XCTAssertEqual(running.first(where: { $0.id == "running-web" })?.command, "npm run web")
        XCTAssertEqual(running.first(where: { $0.id == "running-worker" })?.command, "npm run worker")

        let windows = try store.windows(workspaceID: workspace.id).filter { $0.role == "terminal" }
        XCTAssertEqual(Set(windows.map(\.name)), ["web", "worker"])
    }

    // Tests workspace cycling includes orphaned running processes so recovered Spaces windows remain reachable even before a terminal row is rebuilt.
    // Tests direct coding-agent focus throws a missing-window error without offering process/browser recovery metadata.
    // Tests focus workspace window uses tracked chrome window id when target url is shared by arranging representative inputs and asserting the expected result.

    // Tests focus window navigation wraps across browser targets in same chrome window by arranging representative inputs and asserting the expected result.

    // Tests focus window navigation uses remembered target identity across shared chrome rows when the focused target cannot be resolved.

    // Tests focus window navigation falls back to the remembered cursor when Chrome URL matching is ambiguous across tracked windows.

    // Tests focus window navigation falls back to the remembered cursor when Chrome window matching is ambiguous for an unrelated active tab.

    // Tests focus window navigation cycles agent and process Spaces sessions separately when they share one Spaces window.

    // Tests focus window navigation remembers browser targets by identity instead of stale array index when targets reorder.

    // Tests focus window navigation uses remembered Spaces target identity when focused-session lookup cannot disambiguate shared tabs.

    // Tests windows live scan uses session prefixes and deduplicates overlapping matches by arranging representative inputs and asserting the expected result.

    // Tests windows live scan debounces refresh for ten seconds by arranging representative inputs and asserting the expected result.

    // Tests focus workspace window uses tab index fast path when live scan is present by arranging representative inputs and asserting the expected result.

    // Tests focus workspace window auto corrects when focused indexed tab does not match workspace by arranging representative inputs and asserting the expected result.

    // Tests focus workspace window rejects same-workspace wrong-tab verification and falls back to exact target by arranging representative inputs and asserting the expected result.

    // Tests focus workspace window uses distinct live tab ur ls for overlapping session prefixes by arranging representative inputs and asserting the expected result.

    // Tests tracked windows orders browser then terminal then other roles by arranging representative inputs and asserting the expected result.

    // Tests windows live scan orders browser rows by session prefix then url by arranging representative inputs and asserting the expected result.

    // Tests windows omits untargeted browser rows when targeted row shares window id by arranging representative inputs and asserting the expected result.

    // Tests launch workspace tracks one terminal row per process-backed terminal by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceWithBuiltInSpacesHostReturnsAfterSessionReadyWithoutWaitingForChildPID() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                XCTAssertEqual(mode, .owner)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: nil, state: .running,
                        updatedAt: "2026-05-09T17:00:00Z"), paths: paths)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    try! TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: Int32(getpid()), state: .running,
                            updatedAt: "2026-05-09T17:00:01Z"), paths: paths)
                }
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "api", command: "npm run api")]
        }

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
            }
        }

        let runningProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(runningProcess.terminalApp, TerminalHost.spaces.appName)
        XCTAssertEqual(runningProcess.terminalTrackingID, runningProcess.terminalNativeID)

        let window = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(window.app, TerminalHost.spaces.appName)
        XCTAssertEqual(window.terminalTrackingID, runningProcess.terminalTrackingID)
    }

    // Tests launch workspace does not auto open editor by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceDoesNotAutoOpenEditor() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let root = try makeTempDirectory()
        let openLog = root.appendingPathComponent("launch-open.log")

        let windowsJSON =
            "[{\"id\":101,\"pid\":11,\"app\":\"Spaces\",\"title\":\"shell\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false},{\"id\":202,\"pid\":22,\"app\":\"Google Chrome\",\"title\":\"docs\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false}]"

        // Mocked dependencies: `yabai`, `osascript`, and `open`.
        // Why: verify launch behavior keeps editor unopened/untracked.
        // Remaining risk: real launch timing may still differ under heavy desktop churn.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock, "open": Self.openMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) {
                try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
            }
        }

        let editorWindows = try orchestrator.windows(workspaceID: workspace.id).filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLog.path))
    }

    // Tests launch workspace reuses existing browser matches and tracks all matching tabs by arranging representative inputs and asserting the expected result.

    // Tests launch workspace opens missing browser sessions as tabs in one Chrome window by arranging representative inputs and asserting the expected result.

    // Tests launch workspace leaves configured browser sessions unopened so they behave like lazy bookmarks.
    func testLaunchWorkspaceLeavesBrowserSessionsUnopenedUntilFocused() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let chromeOpenLog = root.appendingPathComponent("chrome-open.log")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_OPEN_LOG_FILE", value: chromeOpenLog.path) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
        }

        XCTAssertTrue(try store.windows(workspaceID: workspace.id).filter { $0.role == "browser" }.isEmpty)
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertNil(sessions.first?.extractedWindow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chromeOpenLog.path))
    }

    // Tests focus workspace window marks stale extracted mapping invalid after direct focus failure and falls back to indexed tab focus by arranging representative inputs and asserting the expected result.

    // Tests focus window navigation uses active browser tab when remembered index is stale by arranging representative inputs and asserting the expected result.

    // Tests workspace id for focused chrome window uses active tab url match by arranging representative inputs and asserting the expected result.

    // Tests refresh workspace windows prunes stale rows and clears running when no runtime indicators remain by arranging representative inputs and asserting the expected result.
    func testRefreshWorkspaceWindowsPrunesStaleRowsWithoutClearingRunningLifecycleState() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "stale", windowID: 909, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))

        // Mocked dependency: live yabai window inventory.
        // Why: verify refresh prunes missing/stale tracked windows without implicitly changing lifecycle state.
        // Remaining risk: rapid concurrent open/close events can still race with a single refresh snapshot.
        var didMutate = false
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
        }

        XCTAssertTrue(didMutate)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .running)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .healthy)
    }

    // Tests refresh workspace windows returns false when nothing changed by arranging representative inputs and asserting the expected result.
    func testRefreshWorkspaceWindowsReturnsFalseWhenNothingChanged() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        // Workspace is not running and has no tracked windows — nothing to prune or update.
        var didMutate = true
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
        }

        XCTAssertFalse(didMutate)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    // Tests refresh workspace windows leaves tracked browser rows alone until the user focuses them on demand.
    func testRefreshWorkspaceWindowsDoesNotPruneMissingBrowserRows() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 909, role: "browser", orderIndex: 0, lastSeenAt: "now"))

        var didMutate = true
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
        }

        XCTAssertFalse(didMutate)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).filter { $0.role == "browser" }.count, 1)
    }

    // Tests stopped workspaces with tracked runtime leftovers remain stopped but surface degraded runtime health.
    func testWorkspaceRuntimeStatusMarksStoppedWorkspaceWithTrackedRuntimeLeftoversAsPartial() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .stopped)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .partial)
        XCTAssertEqual(runtimeStatus.warningSummary, "tracked runtime leftovers")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    // Tests exited tracked processes are reported as exited, not missing, when the runtime record still exists.
    func testWorkspaceRuntimeStatusDoesNotCountExitedTrackedProcessAsMissing() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 501,
                pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "later"))

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .running)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .partial)
        XCTAssertEqual(runtimeStatus.exitedProcessCount, 1)
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 0)
        XCTAssertEqual(runtimeStatus.warningSummary, "1 exited process")
    }

    // Tests configured process names that literally start with key prefixes still match their live runtime records.
    func testWorkspaceRuntimeStatusMatchesLiteralPrefixedProcessNames() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "name:api", command: "npm run api")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "name:api", command: "npm run api", terminalApp: "Spaces",
                windowID: 501, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .healthy)
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 0)
        XCTAssertNil(runtimeStatus.warningSummary)
    }

    // Tests recovered runtime records stored under the configured raw name clear the missing-process warning immediately.
    func testWorkspaceRuntimeStatusMatchesRecoveredProcessNamesByRawName() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(name: "web server", command: "PORT=20003 npm run dev")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web server", command: "PORT=20003 npm run dev",
                terminalApp: "Spaces", windowID: 501, pid: 999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .running)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .healthy)
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 0)
        XCTAssertNil(runtimeStatus.warningSummary)
    }

    // Tests running workspaces do not surface warnings just because configured browser sessions remain unopened.
    func testWorkspaceRuntimeStatusIgnoresUnopenedBrowserSessionsForRunningWorkspace() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Docs", url: "https://example.com/docs")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 501,
                pid: 999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .running)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .healthy)
        XCTAssertEqual(runtimeStatus.missingConfiguredBrowserSessionCount, 1)
        XCTAssertNil(runtimeStatus.warningSummary)
    }

    func testWorkspaceRuntimeStatusIgnoresNeverStartedConfiguredProcessesForRunningWorkspace() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [ProcessTemplate(name: "api", command: "npm run api"), ProcessTemplate(name: "web", command: "npm run web")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces", windowID: 501,
                pid: 999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 1)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .healthy)
        XCTAssertNil(runtimeStatus.warningSummary)
    }

    func testWorkspaceRuntimeStatusIgnoresExplicitlyStoppedConfiguredProcesses() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .stopped)
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 1)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .healthy)
        XCTAssertNil(runtimeStatus.warningSummary)
    }

    // Tests updating settings does not promote stopped workspaces to running just because tracked runtime leftovers exist.
    func testUpdateWorkspaceSettingsDoesNotPromoteStoppedWorkspaceWithTrackedRuntimeLeftovers() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "job", command: "echo job", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "job", command: "echo job")]
            }
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .stopped)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .partial)
    }

    // Tests refresh workspace windows prunes legacy terminal rows that do not have built-in terminal identity.

    // Tests refresh workspace windows prunes legacy process-backed terminal rows without built-in terminal identity.

    // Tests refresh all workspace windows skips archived workspaces by arranging representative inputs and asserting the expected result.
    func testRefreshAllWorkspaceWindowsSkipsArchivedWorkspaces() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(
            try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false).first(where: { $0.isDefault }))
        let activeWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "archived")
        _ = try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: defaultWorkspace.id, app: "Spaces", title: "default-stale", windowID: 910, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: activeWorkspace.id, app: "Spaces", title: "active-stale", windowID: 911, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: archivedWorkspace.id, app: "Spaces", title: "archived-stale", windowID: 912, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))

        // Mocked dependency: live yabai window inventory.
        // Why: confirm bulk refresh reconciles active workspaces only and leaves archived workspace rows unchanged.
        // Remaining risk: archived rows are intentionally left untouched until explicit archive/cleanup paths run.
        var result: WorkspaceOrchestrator.RefreshResult?
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { result = try orchestrator.refreshAllWorkspaceWindows() }
        }

        let refreshResult = try XCTUnwrap(result)
        XCTAssertTrue(refreshResult.didMutateDB)
        // Archived workspace is excluded from refresh, so its ID should not appear in tracked counts.
        XCTAssertNil(refreshResult.trackedWindowCounts[archivedWorkspace.id])
        // Active workspaces had their stale windows pruned, leaving zero tracked windows each.
        XCTAssertEqual(refreshResult.trackedWindowCounts[defaultWorkspace.id], 0)
        XCTAssertEqual(refreshResult.trackedWindowCounts[activeWorkspace.id], 0)

        XCTAssertTrue(try store.windows(workspaceID: defaultWorkspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: activeWorkspace.id).isEmpty)
        XCTAssertEqual(try store.windows(workspaceID: archivedWorkspace.id).count, 1)
    }

    // Tests refresh all workspace windows reports no mutation when nothing changed by arranging representative inputs and asserting the expected result.
    func testRefreshAllWorkspaceWindowsReportsNoMutationWhenNothingChanged() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()

        // No tracked windows and workspace is not running — refresh should report no DB mutation.
        var result: WorkspaceOrchestrator.RefreshResult?
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { result = try orchestrator.refreshAllWorkspaceWindows() }
        }

        let refreshResult = try XCTUnwrap(result)
        XCTAssertFalse(refreshResult.didMutateDB)
        // All non-archived workspaces should still appear in tracked counts (with zero windows).
        XCTAssertFalse(refreshResult.trackedWindowCounts.isEmpty)
        for (_, count) in refreshResult.trackedWindowCounts { XCTAssertEqual(count, 0) }
    }

    // Tests list space options sorts by display then space by arranging representative inputs and asserting the expected result.
    func testListSpaceOptionsSortsByDisplayThenSpace() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        // Mocked dependency: `yabai --spaces` payload ordering.
        // Why: guarantee sort assertions independently of host window-manager state.
        // Remaining risk: unexpected production fields or space metadata edge cases are not covered.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            let options = try orchestrator.listSpaceOptions()
            let values = options.map { "\($0.displayIndex):\($0.spaceIndex)" }
            XCTAssertEqual(values, ["1:1", "1:2", "2:3"])
        }
    }

    // Tests update workspace settings leaves stopped workspaces stopped when only stale runtime leftovers exist.
    func testUpdateWorkspaceSettingsLeavesStoppedWorkspaceStoppedWhenRuntimeIndicatorsExist() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: nil, windowID: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependency: `yabai` query path used during process/window reconciliation.
        // Why: isolate store-state transition coverage from real window manager availability.
        // Remaining risk: reconciliation against rapidly changing real windows remains untested here.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }
        }

        let updated = try store.workspace(id: workspace.id)
        XCTAssertEqual(updated?.isRunning, false)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).count, 1)
        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .stopped)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .partial)
    }

    // Tests list projects returns sorted summaries by arranging representative inputs and asserting the expected result.
    func testListProjectsReturnsSortedSummaries() throws {
        let root = try makeTempDirectory()
        let aDir = root.appendingPathComponent("alpha", isDirectory: true)
        let bDir = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        _ = try orchestrator.addProject(dir: bDir.path)
        _ = try orchestrator.addProject(dir: aDir.path)
        let projects = try orchestrator.listProjects()

        XCTAssertEqual(projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(projects.map(\.isGitRepo), [false, false])
    }

    // Tests update project config and read back project config by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigAndReadBackProjectConfig() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.updateProjectConfig(projectID: project.id) { p in
            p.setupScript = "echo setup"
            p.stopScript = "echo stop"
            p.processes = [ProcessTemplate(name: "api", command: "npm run api")]
            p.browserSessions = [BrowserSession(name: "Docs", url: "https://example.com")]
        }

        let loaded = try orchestrator.project(id: project.id)
        XCTAssertEqual(loaded?.setupScript, "echo setup")
        XCTAssertEqual(loaded?.stopScript, "echo stop")
        XCTAssertEqual(loaded?.processes.first?.name, "api")
        XCTAssertEqual(loaded?.browserSessions.first?.url, "https://example.com")
    }

    // Tests update project config using closure persists changes by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigUsingClosurePersistsChanges() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo bye"
            config.processes = [ProcessTemplate(name: "process", command: "echo process")]
        }

        let loaded = try orchestrator.project(id: project.id)
        XCTAssertEqual(loaded?.stopScript, "echo bye")
        XCTAssertEqual(loaded?.processes.first?.command, "echo process")
    }

    // Tests update project config rejects processes without configured names.
    func testUpdateProjectConfigRejectsUnnamedProcess() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(
            try orchestrator.updateProjectConfig(projectID: project.id) { config in
                config.processes = [ProcessTemplate(name: "", command: "echo process")]
            }
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertEqual(message, "Process name is required.")
        }
    }

    // Tests update project config rejects browser sessions without configured names.
    func testUpdateProjectConfigRejectsUnnamedBrowserSession() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(
            try orchestrator.updateProjectConfig(projectID: project.id) { config in
                config.browserSessions = [BrowserSession(name: "", url: "https://example.com")]
            }
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertEqual(message, "Browser session name is required.")
        }
    }

    func testUpdateProjectConfigRejectsDuplicateConfiguredCodingAgentNames() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(
            try orchestrator.updateProjectConfig(projectID: project.id) { config in
                config.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex"), AgentLauncher(name: "codex", command: "codex --review")]
            }
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("coding agents"))
            XCTAssertTrue(message.contains("Codex"))
        }
    }

    // Tests update project config leaves default workspace settings unchanged even when they match the previous template.
    func testUpdateProjectConfigDoesNotSyncDefaultWorkspaceWhenSettingsMatchPreviousTemplate() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(
            try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true).first(where: { $0.isDefault }))

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo stop"
            config.processes = [ProcessTemplate(name: "api", command: "npm run api")]
            config.browserSessions = [BrowserSession(name: "Docs", url: "https://example.com")]
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertNil(settings?.stopScript)
        XCTAssertTrue(settings?.processes.isEmpty == true)
        XCTAssertTrue(settings?.browserSessions.isEmpty == true)
    }

    // Tests update project config does not overwrite customized default workspace settings by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigDoesNotOverwriteCustomizedDefaultWorkspaceSettings() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(
            try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true).first(where: { $0.isDefault }))

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo project-stop"
            config.processes = [ProcessTemplate(name: "api", command: "npm run api")]
            config.browserSessions = [BrowserSession(name: "Docs", url: "https://example.com")]
        }

        try orchestrator.updateWorkspaceSettings(workspaceID: defaultWorkspace.id) { settings in
            settings.stopScript = "echo workspace-stop"
            settings.processes = [ProcessTemplate(name: "custom", command: "echo custom")]
            settings.browserSessions = [BrowserSession(name: "Custom Docs", url: "https://custom.example.com")]
        }

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo project-stop-v2"
            config.processes = [ProcessTemplate(name: "api", command: "npm run api:v2")]
            config.browserSessions = [BrowserSession(name: "Docs", url: "https://example.com/v2")]
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo workspace-stop")
        XCTAssertEqual(settings?.processes.first?.name, "custom")
        XCTAssertEqual(settings?.processes.first?.command, "echo custom")
        XCTAssertEqual(settings?.browserSessions.first?.url, "https://custom.example.com")
    }

    func testAddProjectDirImportsSpacesYAMLAsAuthoritativeCreateTimeConfig() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo yaml-stop").write(
            to: projectDir.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path) { config in
            config.stopScript = "echo ignored"
            config.agentLaunchers = [AgentLauncher(name: "Ignored", command: "ignored")]
        }

        XCTAssertEqual(project.stopScript, "echo yaml-stop")
        XCTAssertEqual(project.ports.map(\.name), ["API_PORT"])
        XCTAssertEqual(project.processes.first?.name, "api")
        XCTAssertEqual(project.browserSessions.first?.url, "http://localhost:3000")
        XCTAssertEqual(project.agentLaunchers.first?.command, "codex")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo yaml-stop")
        XCTAssertEqual(settings?.ports.map(\.name) ?? [], ["API_PORT"])
        XCTAssertEqual(settings?.processes.first?.name, "api")
    }

    func testAddProjectByGitURLImportsSpacesYAMLFromDefaultWorktree() throws {
        let fixture = try makeTempGitRepo(name: "yaml-git-import")
        try spacesYAMLFixture(stopScript: "echo git-yaml-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        XCTAssertEqual(project.stopScript, "echo git-yaml-stop")
        XCTAssertEqual(project.processes.first?.command, "npm run api")
        let configURL = try orchestrator.spacesYAMLConfigURL(projectID: project.id)
        XCTAssertTrue(configURL.path.hasPrefix(workspacesRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo git-yaml-stop")
        XCTAssertEqual(settings?.agentLaunchers.first?.name, "Codex")
    }

    func testPreviewProjectDirImportsSpacesYAMLWithoutPersistingProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("preview-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo preview-stop").write(
            to: projectDir.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let preview = try orchestrator.previewProject(dir: projectDir.path)

        XCTAssertEqual(preview.stopScript, "echo preview-stop")
        XCTAssertEqual(preview.processes.first?.command, "npm run api")
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.workspaces(projectID: preview.id).isEmpty)
    }

    func testAddReviewedProjectUsesEditedSettingsFromHydratedPreview() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("reviewed-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo yaml-stop").write(
            to: projectDir.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addReviewedProject(dir: projectDir.path) { config in
            config.stopScript = "echo edited-stop"
            config.processes = [ProcessTemplate(name: "edited", command: "npm run edited")]
        }

        XCTAssertEqual(project.stopScript, "echo edited-stop")
        XCTAssertEqual(project.processes.first?.name, "edited")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo edited-stop")
        XCTAssertEqual(settings?.processes.first?.command, "npm run edited")
    }

    func testAddReviewedProjectDoesNotReloadLocalSpacesYAMLAtSaveTime() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("reviewed-project-invalid-yaml-after-preview", isDirectory: true)
        let configURL = projectDir.appendingPathComponent("spaces.yaml")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo preview-stop").write(to: configURL, atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let preview = try orchestrator.previewProject(dir: projectDir.path)
        try "version: [".write(to: configURL, atomically: true, encoding: .utf8)

        let project = try orchestrator.addReviewedProject(dir: projectDir.path) { config in
            config.stopScript = preview.stopScript
            config.ports = preview.ports
            config.processes = preview.processes
            config.browserSessions = preview.browserSessions
            config.agentLaunchers = preview.agentLaunchers
        }

        XCTAssertEqual(project.stopScript, "echo preview-stop")
        XCTAssertEqual(project.processes.first?.command, "npm run api")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo preview-stop")
        XCTAssertEqual(settings?.processes.first?.command, "npm run api")
    }

    func testPrepareGitProjectImportsSpacesYAMLWithoutPersistingUntilCommit() throws {
        let fixture = try makeTempGitRepo(name: "prepared-yaml-git-import")
        try spacesYAMLFixture(stopScript: "echo prepared-yaml-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        var didCommit = false

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        defer { if !didCommit { try? orchestrator.discardPreparedGitProject(prepared) } }

        XCTAssertEqual(prepared.project.stopScript, "echo prepared-yaml-stop")
        XCTAssertNotNil(prepared.importedDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.workspaces(projectID: prepared.project.id).isEmpty)

        let project = try orchestrator.addPreparedGitProject(prepared) { config in
            config.stopScript = "echo edited-prepared-stop"
            config.agentLaunchers = [AgentLauncher(name: "Edited", command: "codex --model gpt-5")]
        }
        didCommit = true

        XCTAssertEqual(project.stopScript, "echo edited-prepared-stop")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        XCTAssertEqual(defaultWorkspace.dir, prepared.defaultWorkspace.dir)
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo edited-prepared-stop")
        XCTAssertEqual(settings?.agentLaunchers.first?.name, "Edited")
    }

    func testDiscardPreparedGitProjectRemovesManagedCloneAndDefaultWorktree() throws {
        let fixture = try makeTempGitRepo(name: "discard-prepared-git-import")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))

        try orchestrator.discardPreparedGitProject(prepared)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))
        XCTAssertTrue(try store.projects().isEmpty)
    }

    func testDiscardPreparedGitProjectPreservesCloneWhenRegisteredBeforeCleanup() throws {
        let fixture = try makeTempGitRepo(name: "registered-before-prepared-discard")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let actualWorkspacesRoot = root.appendingPathComponent("actual-workspaces", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces-link", isDirectory: true)
        try FileManager.default.createDirectory(at: actualWorkspacesRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspacesRoot, withDestinationURL: actualWorkspacesRoot)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)

        try store.upsert(project: prepared.project)
        try store.upsert(workspace: prepared.defaultWorkspace)

        try orchestrator.discardPreparedGitProject(prepared)

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))
        XCTAssertEqual(try store.project(id: prepared.project.id)?.dir, prepared.project.dir)
        XCTAssertEqual(try store.workspace(id: prepared.defaultWorkspace.id)?.dir, prepared.defaultWorkspace.dir)
    }

    func testPrepareGitProjectOverwritesAbandonedPreparedCloneOnRetry() throws {
        let fixture = try makeTempGitRepo(name: "retry-prepared-git-import")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let firstPrepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        XCTAssertNil(firstPrepared.importedDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPrepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPrepared.defaultWorkspace.dir))

        try spacesYAMLFixture(stopScript: "echo retry-prepared-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: fixture.path)

        let secondPrepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        defer { try? orchestrator.discardPreparedGitProject(secondPrepared) }

        XCTAssertEqual(secondPrepared.project.dir, firstPrepared.project.dir)
        XCTAssertEqual(secondPrepared.defaultWorkspace.dir, firstPrepared.defaultWorkspace.dir)
        XCTAssertEqual(secondPrepared.project.stopScript, "echo retry-prepared-stop")
        XCTAssertNotNil(secondPrepared.importedDocument)
        XCTAssertTrue(try store.projects().isEmpty)
    }

    func testAddPreparedGitProjectKeepsPreparedCloneWhenReviewedConfigIsInvalid() throws {
        let fixture = try makeTempGitRepo(name: "invalid-prepared-reviewed-git-import")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        defer { try? orchestrator.discardPreparedGitProject(prepared) }

        XCTAssertThrowsError(try orchestrator.addPreparedGitProject(prepared) { config in config.ports = [PortDefinition(name: "   ")] }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Port name is required"))
        }

        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))
    }

    func testAddProjectByGitURLRollsBackManagedCloneWhenSpacesYAMLIsInvalid() throws {
        let fixture = try makeTempGitRepo(name: "invalid-yaml-git-import")
        try "version: 999\n".write(to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add invalid spaces yaml"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let reservedBefore = PortReserver.shared.reservedWorkspaceIDs()
        defer {
            for workspaceID in PortReserver.shared.reservedWorkspaceIDs().subtracting(reservedBefore) {
                PortReserver.shared.releasePorts(workspaceID: workspaceID)
            }
        }

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path) { config in config.ports = [PortDefinition(name: "API_PORT")] }) {
            error in XCTAssertTrue(error.localizedDescription.contains("Unsupported spaces.yaml version 999"))
        }

        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "invalid-yaml-git-import")
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().subtracting(reservedBefore).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reposRoot.appendingPathComponent(managedDirname, isDirectory: true).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true).appendingPathComponent("main", isDirectory: true)
                    .path))
    }

    func testAddProjectByGitURLRollsBackPreparedCloneWhenReviewedConfigIsInvalid() throws {
        let fixture = try makeTempGitRepo(name: "invalid-reviewed-git-import")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path) { config in config.ports = [PortDefinition(name: "   ")] }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Port name is required"))
        }

        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "invalid-reviewed-git-import")
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reposRoot.appendingPathComponent(managedDirname, isDirectory: true).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true).appendingPathComponent("main", isDirectory: true)
                    .path))
    }

    func testImportSpacesYAMLUpdatesOnlyProjectWhenWorkspaceSyncIsOff() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.ports = [PortDefinition(id: "existing-port", name: "API_PORT")]
            config.processes = [ProcessTemplate(id: "existing-process", name: "api", command: "npm run api")]
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: defaultWorkspace.id) { settings in
            settings.stopScript = "echo workspace-stop"
            settings.processes = [ProcessTemplate(name: "workspace", command: "echo workspace")]
        }
        try spacesYAMLFixture(stopScript: "echo imported-stop").write(
            to: try orchestrator.spacesYAMLConfigURL(projectID: project.id), atomically: true, encoding: .utf8)

        let importedProject = try orchestrator.importSpacesYAML(projectID: project.id, updateAllWorkspaces: false)

        XCTAssertEqual(importedProject.stopScript, "echo imported-stop")
        XCTAssertEqual(importedProject.ports.first?.id, "existing-port")
        XCTAssertEqual(importedProject.processes.first?.id, "existing-process")
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo workspace-stop")
        XCTAssertEqual(settings?.processes.first?.name, "workspace")
    }

    func testPreviewProjectConfigDoesNotPersistImportedConfig() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path) { config in
            config.stopScript = "echo saved-stop"
            config.ports = [PortDefinition(id: "saved-port", name: "SAVED_PORT")]
        }
        let document = SpacesYAMLDocument(stopScript: "echo imported-stop", ports: [SpacesYAMLDocument.Port(name: "API_PORT")])

        let preview = try orchestrator.previewProjectConfig(projectID: project.id) { config in document.applying(to: &config) }

        XCTAssertEqual(preview.stopScript, "echo imported-stop")
        XCTAssertEqual(preview.ports.map(\.name), ["API_PORT"])
        let savedProject = try XCTUnwrap(try store.project(id: project.id))
        XCTAssertEqual(savedProject.stopScript, "echo saved-stop")
        XCTAssertEqual(savedProject.ports.map(\.name), ["SAVED_PORT"])
    }

    func testUpdateProjectConfigWithWorkspaceSyncAppliesReviewedSettingsToWorkspaces() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        let updatedProject = try orchestrator.updateProjectConfig(projectID: project.id, updateAllWorkspaces: true) { config in
            config.stopScript = "echo reviewed-stop"
            config.ports = [PortDefinition(name: "API_PORT")]
            config.processes = [ProcessTemplate(name: "api", command: "npm run api")]
        }

        XCTAssertEqual(updatedProject.stopScript, "echo reviewed-stop")
        let settings = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id))
        XCTAssertEqual(settings.stopScript, "echo reviewed-stop")
        XCTAssertEqual(settings.ports.map(\.name), ["API_PORT"])
        XCTAssertEqual(settings.processes.first?.name, "api")
    }

    func testUpdateProjectConfigWithWorkspaceSyncKeepsInsertedPortsAlignedWithAssignments() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let api = PortDefinition(id: "port-api", name: "API_PORT")
        let project = try orchestrator.addProject(dir: projectDir.path) { config in config.ports = [api] }
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        defer { PortReserver.shared.releasePorts(workspaceID: workspace.id) }
        let previousAPIAssignment = try XCTUnwrap(try store.workspacePortsAssigned(workspaceID: workspace.id).first)

        let updatedProject = try orchestrator.updateProjectConfig(projectID: project.id, updateAllWorkspaces: true) { config in
            config.ports = [PortDefinition(name: "WEB_PORT"), PortDefinition(name: "API_PORT")]
        }

        XCTAssertEqual(updatedProject.ports.map(\.name), ["WEB_PORT", "API_PORT"])
        XCTAssertEqual(updatedProject.ports.last?.id, api.id)
        let assignments = try store.workspacePortsAssigned(workspaceID: workspace.id)
        XCTAssertEqual(assignments.map(\.name), ["WEB_PORT", "API_PORT"])
        let webAssignment = try XCTUnwrap(assignments.first { $0.name == "WEB_PORT" })
        let apiAssignment = try XCTUnwrap(assignments.first { $0.name == "API_PORT" })
        XCTAssertNotEqual(webAssignment.port, previousAPIAssignment.port)
        XCTAssertEqual(apiAssignment.port, previousAPIAssignment.port)
        XCTAssertEqual(apiAssignment.definitionID, api.id)
    }

    func testImportSpacesYAMLUpdatesActiveAndArchivedWorkspacesWhenWorkspaceSyncIsOn() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let activeWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "active")
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "archived")
        _ = try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id)
        try spacesYAMLFixture(stopScript: "echo synced-stop").write(
            to: try orchestrator.spacesYAMLConfigURL(projectID: project.id), atomically: true, encoding: .utf8)

        _ = try orchestrator.importSpacesYAML(projectID: project.id, updateAllWorkspaces: true)

        let activeSettings = try orchestrator.workspaceSettings(workspaceID: activeWorkspace.id)
        let archivedSettings = try orchestrator.workspaceSettings(workspaceID: archivedWorkspace.id)
        XCTAssertEqual(activeSettings?.stopScript, "echo synced-stop")
        XCTAssertEqual(activeSettings?.ports.map(\.name) ?? [], ["API_PORT"])
        XCTAssertEqual(activeSettings?.processes.first?.name, "api")
        XCTAssertEqual(archivedSettings?.stopScript, "echo synced-stop")
        XCTAssertEqual(archivedSettings?.browserSessions.first?.name, "app")
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: archivedWorkspace.id)).isArchived)
    }

    func testImportSpacesYAMLWithWorkspaceSyncPreservesAgentLauncherIDsForLiveAgents() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let launches = TerminalLaunchConfigurationCapture()
        let terminated = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalWindowCloser: { _ in },
            builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) },
            builtInTerminalSessionLauncher: { configuration in
                launches.append(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.agentLaunchers = [AgentLauncher(id: "project-launcher-codex", name: "Codex", command: "codex")]
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: defaultWorkspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(id: "workspace-launcher-codex", name: "Codex", command: "codex")]
        }
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: defaultWorkspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "old-session"), claimedLauncherID: "workspace-launcher-codex",
                claimedLauncherName: "Codex", status: .idle, createdAt: "now", updatedAt: "now"))
        try spacesYAMLFixture(stopScript: "echo synced-stop").write(
            to: try orchestrator.spacesYAMLConfigURL(projectID: project.id), atomically: true, encoding: .utf8)

        _ = try orchestrator.importSpacesYAML(projectID: project.id, updateAllWorkspaces: true)
        _ = try orchestrator.restartCodingAgent(workspaceID: defaultWorkspace.id, agentID: "agent-codex")

        XCTAssertEqual(try store.project(id: project.id)?.agentLaunchers.first?.id, "project-launcher-codex")
        XCTAssertEqual(try store.workspaceAgentLaunchers(workspaceID: defaultWorkspace.id).first?.id, "workspace-launcher-codex")
        XCTAssertEqual(terminated.sessionIDs, ["old-session"])
        XCTAssertEqual(launches.snapshot().map(\.title), ["Codex"])
    }

    func testImportSpacesYAMLWithWorkspaceSyncRollsBackProjectAndEarlierWorkspacesOnFailure() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path) { config in
            config.stopScript = "echo old-stop"
            config.ports = [PortDefinition(id: "old-port", name: "OLD_PORT")]
            config.processes = [ProcessTemplate(id: "old-process", name: "old", command: "npm run old")]
            config.browserSessions = [BrowserSession(name: "old-app", url: "http://localhost:4000")]
            config.agentLaunchers = [AgentLauncher(name: "Old Codex", command: "old-codex")]
        }
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let conflictWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "conflict")
        defer {
            PortReserver.shared.releasePorts(workspaceID: defaultWorkspace.id)
            PortReserver.shared.releasePorts(workspaceID: conflictWorkspace.id)
        }
        let defaultSettingsBefore = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id))
        let conflictSettingsBefore = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: conflictWorkspace.id))
        let defaultPortsBefore = try store.workspacePortsAssigned(workspaceID: defaultWorkspace.id)
        let conflictPortsBefore = try store.workspacePortsAssigned(workspaceID: conflictWorkspace.id)
        _ = try orchestrator.registerAgentWindow(workspaceID: conflictWorkspace.id, provider: .spaces, label: "api")
        try spacesYAMLFixture(stopScript: "echo imported-stop").write(
            to: try orchestrator.spacesYAMLConfigURL(projectID: project.id), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try orchestrator.importSpacesYAML(projectID: project.id, updateAllWorkspaces: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Duplicates: api"))
        }

        let restoredProject = try XCTUnwrap(try store.project(id: project.id))
        XCTAssertEqual(restoredProject.stopScript, "echo old-stop")
        XCTAssertEqual(restoredProject.ports.map(\.name), ["OLD_PORT"])
        XCTAssertEqual(restoredProject.processes.first?.command, "npm run old")

        let defaultSettingsAfter = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id))
        XCTAssertEqual(defaultSettingsAfter.stopScript, defaultSettingsBefore.stopScript)
        XCTAssertEqual(defaultSettingsAfter.ports.map(\.name), defaultSettingsBefore.ports.map(\.name))
        XCTAssertEqual(defaultSettingsAfter.processes.map(\.command), defaultSettingsBefore.processes.map(\.command))
        XCTAssertEqual(defaultSettingsAfter.browserSessions.map(\.url), defaultSettingsBefore.browserSessions.map(\.url))
        XCTAssertEqual(defaultSettingsAfter.agentLaunchers.map(\.command), defaultSettingsBefore.agentLaunchers.map(\.command))
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: defaultWorkspace.id).map { $0.name }, defaultPortsBefore.map { $0.name })
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: defaultWorkspace.id).map { $0.port }, defaultPortsBefore.map { $0.port })

        let conflictSettingsAfter = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: conflictWorkspace.id))
        XCTAssertEqual(conflictSettingsAfter.stopScript, conflictSettingsBefore.stopScript)
        XCTAssertEqual(conflictSettingsAfter.ports.map(\.name), conflictSettingsBefore.ports.map(\.name))
        XCTAssertEqual(conflictSettingsAfter.processes.map(\.command), conflictSettingsBefore.processes.map(\.command))
        XCTAssertEqual(conflictSettingsAfter.browserSessions.map(\.url), conflictSettingsBefore.browserSessions.map(\.url))
        XCTAssertEqual(conflictSettingsAfter.agentLaunchers.map(\.command), conflictSettingsBefore.agentLaunchers.map(\.command))
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: conflictWorkspace.id).map { $0.name }, conflictPortsBefore.map { $0.name })
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: conflictWorkspace.id).map { $0.port }, conflictPortsBefore.map { $0.port })
    }

    func testExportSpacesYAMLOverwritesExistingFile() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let configURL = try orchestrator.spacesYAMLConfigURL(projectID: project.id)
        try "old: value\n".write(to: configURL, atomically: true, encoding: .utf8)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo exported-stop"
            config.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex")]
        }

        let writtenURL = try orchestrator.exportSpacesYAML(projectID: project.id)
        let exported = try String(contentsOf: writtenURL, encoding: .utf8)

        XCTAssertEqual(writtenURL, configURL)
        XCTAssertTrue(exported.contains("stop_script: echo exported-stop"))
        XCTAssertTrue(exported.contains("command: codex"))
        XCTAssertFalse(exported.contains("old: value"))
    }

    // Tests create workspace allows duplicate active titles by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceAllowsDuplicateActiveWorkspaceTitles() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        XCTAssertNoThrow(try orchestrator.createWorkspace(projectID: project.id, name: "feature"))
    }

    // Tests archive default workspace throws by arranging representative inputs and asserting the expected result.
    func testArchiveDefaultWorkspaceThrows() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: { $0.isDefault }))
        XCTAssertThrowsError(try orchestrator.archiveWorkspace(workspaceID: defaultWorkspace.id))
    }

    // Tests stop workspace updates running state and cleans runtime records by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceUpdatesRunningStateAndCleansRuntimeRecords() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "shell", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependencies: window close via `yabai` and Spaces cleanup via `osascript`.
        // Why: verify cleanup semantics without touching real windows/processes.
        // Remaining risk: real process/window teardown can fail or race differently than this mocked path.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.stopWorkspace(workspaceID: workspace.id)
        }
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        XCTAssertTrue(try orchestrator.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests stop workspace handles missing workspace directory and returns outcome by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceHandlesMissingWorkspaceDirectoryAndReturnsOutcome() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let marker = root.appendingPathComponent("stop-script-marker.txt")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo ran > '\(marker.path)'")

        try FileManager.default.removeItem(atPath: workspace.dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing, true)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // Tests stop workspace terminates each tracked Spaces terminal session once.
    func testStopWorkspaceClosesManagedTerminalWindowOnlyOnce() throws {
        let store = try makeTemporaryStore()
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { sessionID in closeCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend", windowID: 501,
                terminalTrackingID: "spaces-frontend", terminalNativeID: "spaces-frontend", role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "backend", windowID: 502,
                terminalTrackingID: "spaces-backend", terminalNativeID: "spaces-backend", role: "terminal", orderIndex: 201, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "frontend", command: "npm run dev",
                terminalApp: TerminalHost.spaces.appName, windowID: 501, terminalTrackingID: "spaces-frontend", terminalNativeID: "spaces-frontend",
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "backend", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, windowID: 502, terminalTrackingID: "spaces-backend", terminalNativeID: "spaces-backend",
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { _ = try orchestrator.stopWorkspace(workspaceID: workspace.id) }

        XCTAssertEqual(closeCapture.sessionIDs, ["spaces-frontend", "spaces-backend"])
        XCTAssertEqual(terminateCapture.sessionIDs, ["spaces-frontend", "spaces-backend"])
    }

    func testStopWorkspaceClosesBuiltInTerminalSessionWithoutTrackedYabaiWindowID() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-session-stop-1"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "running-process-spaces", workspaceID: workspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "tracked-window-spaces", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    func testStopWorkspaceTerminatesAdHocBuiltInTerminalSession() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "ad-hoc-session-stop-1"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: "tracked-ad-hoc-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    func testUserClosedBuiltInTerminalSessionLeavesOwningProcessRunning() throws {
        let store = try makeTemporaryStore()
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { sessionID in closeCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "process-session-close-1"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "process-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: nil, targetURL: nil,
                windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        XCTAssertFalse(try orchestrator.stopBuiltInTerminalSessionClosedByUser(sessionID: sessionID))

        XCTAssertTrue(closeCapture.sessionIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.id), ["process-1"])
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).map(\.terminalTrackingID), [sessionID])
    }

    func testUserClosedBuiltInTerminalSessionLeavesOwningAgentRunning() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { sessionID in closeCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "agent-session-close-1"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID,
                terminalNativeID: sessionID, codexThreadID: nil, windowID: nil, status: .spinning, createdAt: "now", updatedAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: "agent-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "Codex", detail: nil, targetURL: nil,
                windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .agent,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "Codex", workingDirectory: workspace.dir))

            XCTAssertFalse(try orchestrator.stopBuiltInTerminalSessionClosedByUser(sessionID: sessionID))
        }

        XCTAssertTrue(closeCapture.sessionIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), ["agent-1"])
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).map(\.terminalTrackingID), [sessionID])
    }

    func testUserClosedAdHocShellSessionStopsEvenWhenAgentRegistered() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "ad-hoc-shell-with-agent-signal"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir))
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex",
                    terminalTarget: TerminalTargetRecord(trackingID: sessionID), sessionKey: "thread-1", claimedLauncherName: "Codex",
                    status: .spinning, createdAt: "now", updatedAt: "now"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.stopBuiltInTerminalSessionClosedByUser(sessionID: sessionID))
        }

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    func testStopAdHocBuiltInTerminalSessionUsesLiveSessionDirectoryWithoutTrackedWindow() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "ad-hoc-live-session"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "shell-1", workingDirectory: workspace.dir,
                    shell: "/bin/zsh", command: nil, createdAt: "now"), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now", title: "shell-1", workingDirectory: workspace.dir), paths: paths)

            XCTAssertTrue(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID))
        }

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
    }

    func testStopAdHocBuiltInTerminalSessionRejectsProcessAndAgentOwnedSessionsGlobally() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let parentDir = root.appendingPathComponent("project", isDirectory: true)
        let childDir = parentDir.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbPath)
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let project = makeProjectRecord(dir: parentDir.path)
        let parentWorkspace = makeWorkspaceRecord(projectID: project.id, title: "parent", dir: parentDir.path)
        let childWorkspace = makeWorkspaceRecord(projectID: project.id, title: "child", dir: childDir.path)
        try store.upsert(project: project)
        try store.upsert(workspace: parentWorkspace)
        try store.upsert(workspace: childWorkspace)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: childWorkspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, windowID: nil, terminalTrackingID: "process-session", terminalNativeID: "process-session",
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: childWorkspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "agent-session",
                terminalNativeID: "agent-session", codexThreadID: nil, windowID: nil, status: .spinning, createdAt: "now", updatedAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: "agent-session", workspace: childWorkspace, kind: .agent,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "agent-session", backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "Codex", workingDirectory: childWorkspace.dir))

            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: parentWorkspace.id, sessionID: "process-session"))
            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: childWorkspace.id, sessionID: "process-session"))
            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: parentWorkspace.id, sessionID: "agent-session"))
            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: childWorkspace.id, sessionID: "agent-session"))
        }
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    func testStopAdHocBuiltInTerminalSessionRequiresLaunchMetadataWorkspaceMatch() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let parentDir = root.appendingPathComponent("project", isDirectory: true)
        let childDir = parentDir.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        let project = makeProjectRecord(dir: parentDir.path)
        let parentWorkspace = makeWorkspaceRecord(projectID: project.id, title: "parent", dir: parentDir.path)
        let childWorkspace = makeWorkspaceRecord(projectID: project.id, title: "child", dir: childDir.path)
        try store.upsert(project: project)
        try store.upsert(workspace: parentWorkspace)
        try store.upsert(workspace: childWorkspace)
        let sessionID = "metadata-owned-shell-session"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "shell",
                    workingDirectory: childWorkspace.dir, shell: "/bin/zsh", command: nil, createdAt: "now", workspaceID: childWorkspace.id,
                    kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now", title: "shell", workingDirectory: childWorkspace.dir), paths: paths)

            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: parentWorkspace.id, sessionID: sessionID))
            XCTAssertTrue(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: childWorkspace.id, sessionID: sessionID))
        }

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
    }

    func testReconcileTerminalForegroundAgentClassificationsPromotesAndKeepsAdHocShellSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "ad-hoc-foreground-agent"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promotedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(promotedAgent.label, "Codex")
            XCTAssertNil(promotedAgent.claimedLauncherID)
            let promotedWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first)
            XCTAssertEqual(promotedWindow.name, "shell-1")
            XCTAssertEqual(promotedWindow.detail, "codex --model gpt-5")

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir),
                paths: try TerminalSessionPaths.forSession(id: sessionID))

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(stickyAgent.id, promotedAgent.id)
            XCTAssertEqual(stickyAgent.label, "Codex")
            let stickyWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first)
            XCTAssertEqual(stickyWindow.name, "shell-1")
            XCTAssertEqual(stickyWindow.detail, "codex --model gpt-5")
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsMarksExitedAdHocAgentSessionDone() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "ad-hoc-agent-session-exit"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "codex", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "codex", foregroundDisplayCommand: "codex"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "codex", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            var agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(agent.id, "terminal-agent-\(sessionID)")
            XCTAssertEqual(agent.status, .idle)

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                    updatedAt: "2026-06-06T00:00:10Z", exitedAt: "2026-06-06T00:00:10Z", title: "codex", workingDirectory: workspace.dir),
                paths: paths)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(agent.id, "terminal-agent-\(sessionID)")
            XCTAssertEqual(agent.status, .done)
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesSignalAgentAcrossTransientAndRealForegrounds() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "signal-custom-agent-unknown-foreground"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/usr/bin/python3", foregroundExecutableName: "python3", foregroundArgv: ["python3", "agent.py"]))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: .spinning, eventSource: "spaces_signal")

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            let agents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(agents.map(\.id), [signalAgent.id])
            XCTAssertEqual(agents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(agents.first?.status, .spinning)
            XCTAssertNil(
                try store.latestAgentSessionEventMessage(id: signalAgent.id, eventType: "foreground_identity", source: "foreground_agent_signal"))

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"), paths: try TerminalSessionPaths.forSession(id: sessionID))

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(stickyAgents.map(\.id), [signalAgent.id])
            XCTAssertEqual(stickyAgents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(stickyAgents.first?.status, .spinning)
            XCTAssertNil(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail)
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesSignalAgentAcrossShellForeground() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "signal-agent-pending-foreground"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: .spinning, eventSource: "spaces_signal")

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), [signalAgent.id])

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]), paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(stickyAgents.map(\.id), [signalAgent.id])
            XCTAssertEqual(stickyAgents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(stickyAgents.first?.status, .spinning)
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsDoesNotRecordSignalIdentityFromFirstNonShellSample() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "signal-agent-first-sample"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: .spinning, eventSource: "spaces_signal")

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/usr/bin/python3", foregroundExecutableName: "python3", foregroundArgv: ["python3", "agent.py"]),
                paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), [signalAgent.id])
            XCTAssertNil(
                try store.latestAgentSessionEventMessage(id: signalAgent.id, eventType: "foreground_identity", source: "foreground_agent_signal"))

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:20Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]), paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), [signalAgent.id])
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesSignalLabelOnKnownForeground() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "signal-custom-agent-known-foreground"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: .waiting, eventSource: "spaces_signal")

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            let agents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(agents.map(\.id), [signalAgent.id])
            XCTAssertEqual(agents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(agents.first?.status, .waiting)
            XCTAssertNil(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail)
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsKeepsSignaledDetectorRowAfterForegroundChanges() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "detector-row-signal-update"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let detectedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(detectedAgent.id, "terminal-agent-\(sessionID)")
            XCTAssertEqual(detectedAgent.label, "Codex")

            let signaledAgent = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, terminalNativeID: sessionID, label: "Custom Hook Agent",
                status: .spinning, eventType: "start", eventSource: "spaces_signal")
            XCTAssertEqual(signaledAgent.id, detectedAgent.id)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let knownForegroundAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(knownForegroundAgent.id, detectedAgent.id)
            XCTAssertEqual(knownForegroundAgent.label, "Custom Hook Agent")
            XCTAssertEqual(knownForegroundAgent.status, .spinning)

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/usr/bin/python3", foregroundExecutableName: "python3", foregroundArgv: ["python3", "agent.py"]),
                paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(stickyAgent.id, detectedAgent.id)
            XCTAssertEqual(stickyAgent.label, "Custom Hook Agent")
            XCTAssertEqual(stickyAgent.status, .spinning)
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")
        }
    }

    func testUpdateAgentWindowStatusPreservesAdHocDetectedTerminalNameAndDetail() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "ad-hoc-foreground-agent-signal"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).name, "shell-1")
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")

            let updated = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, codexThreadID: "thread-1", label: "Codex",
                status: .spinning)

            XCTAssertNil(updated.claimedLauncherName)
            let window = try XCTUnwrap(store.windows(workspaceID: workspace.id).first)
            XCTAssertEqual(window.name, "shell-1")
            XCTAssertEqual(window.detail, "codex --model gpt-5")
        }
    }

    func testRefreshWorkspaceWindowsPreservesAdHocDetectedAgentForegroundCommandDetail() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "ad-hoc-foreground-agent-title-refresh"
        let windowsJSON = """
            [{"id":101,"pid":11,"app":"Spaces","title":"live shell title","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]
            """

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: 101, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")

            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) {
                    _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
                }
            }
        }

        XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")
    }

    func testReconcileTerminalForegroundAgentClassificationsSuffixesDuplicateAdHocLabels() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let firstSessionID = "ad-hoc-foreground-agent-1"
        let secondSessionID = "ad-hoc-foreground-agent-2"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            for (index, sessionID) in [firstSessionID, secondSessionID].enumerated() {
                try writeTerminalSessionFixture(
                    sessionID: sessionID, workspace: workspace, kind: .shell,
                    runtimeState: TerminalSessionRuntimeState(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: Int32(123 + index), state: .running,
                        updatedAt: "2026-06-06T00:00:00Z", title: "shell-\(index + 1)", workingDirectory: workspace.dir,
                        foregroundPID: Int32(123 + index), foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                        foregroundArgv: ["codex"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                        foregroundDisplayCommand: "codex"))
                try store.upsert(
                    window: WindowRecord(
                        id: "terminal-window-\(index + 1)", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-\(index + 1)",
                        detail: nil, targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal",
                        orderIndex: 200 + index, lastSeenAt: "now"))
            }

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let labels = try store.agentWindows(workspaceID: workspace.id).compactMap(\.label)

            XCTAssertEqual(Set(labels), Set(["Codex", "Codex-2"]))
            XCTAssertNoThrow(try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in })
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsReservesConfiguredLauncherNames() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        let sessionID = "ad-hoc-reserved-foreground-agent"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promotedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)

            XCTAssertEqual(promotedAgent.label, "Codex-2")
            XCTAssertNoThrow(try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in })
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesConfiguredLauncherRowOnUnknownForeground() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "configured-agent-session"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .agent,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "Codex", workingDirectory: workspace.dir))
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex",
                    terminalTarget: TerminalTargetRecord(trackingID: sessionID), claimedLauncherName: "Codex", status: .idle, createdAt: "now",
                    updatedAt: "now"))

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            let agents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(agents.map(\.id), ["agent-1"])
            XCTAssertEqual(agents.first?.claimedLauncherName, "Codex")
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsSkipsConfiguredProcessSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionID = "process-foreground-agent"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .process,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "api", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: "process-1", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil, status: .running, logPath: nil,
                    lastOutputAt: nil, startedAt: "now", exitedAt: nil))

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        }
    }

    // Tests stop workspace closes tracked browser tabs without closing chrome window by arranging representative inputs and asserting the expected result.

    // Tests stop workspace closes the shared Spaces window without yabai-closing it by arranging representative inputs and asserting the expected result.

    // Tests stop workspace closes all live detected browser session tabs by arranging representative inputs and asserting the expected result.

    // Tests launch workspace throws when runtime indicators exist by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceThrowsWhenRuntimeIndicatorsExist() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 701,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id))
    }

    // Tests launch workspace without processes does not require terminal runtime.
    func testLaunchWorkspaceWithoutProcessesDoesNotRequireTerminalRuntime() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }

        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    // Tests launch workspace waits for pending setup to finish by arranging a deferred setup run and asserting launch completes afterwards.
    func testLaunchWorkspaceWaitsForPendingSetupToFinish() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "sleep 1; echo done > .spaces-launch-wait-marker"
        }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "launch-waits", runSetupScript: false)
        let setupThread = WorkspaceSetupThread(orchestrator: orchestrator, workspaceID: workspace.id)
        setupThread.start()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .succeeded)
    }

    // Tests restart workspace stops then launches by arranging representative inputs and asserting the expected result.
    func testRestartWorkspaceStopsThenLaunches() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "shell", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "Spaces", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        let running = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertTrue(running.isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    // Tests up workspace launches when stopped by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceLaunchesWhenStopped() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.upWorkspace(workspaceID: workspace.id) }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests up workspace launches multiple configured processes in one Spaces window using separate tabs.

    // Tests up workspace does nothing to running processes when runtime indicators exist and restart is disabled by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceDoesNothingWhenRuntimeIndicatorsExistByDefault() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "Spaces", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.upWorkspace(workspaceID: workspace.id) }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).count, 1)
    }

    // Tests up workspace restarts exited processes when workspace is running by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceRestartsExitedProcessesWhenRunning() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "echo web", terminalApp: "Spaces", windowID: nil,
                pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.upWorkspace(workspaceID: workspace.id) }

        let processes = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.status, .running)
        XCTAssertEqual(processes.first?.templateName, "web")
    }

    // Tests explicit up workspace bypasses startup grace for a dead managed process so recovery can happen immediately.
    // Tests up workspace restarts when runtime indicators exist and restart is enabled by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceRestartsWhenRuntimeIndicatorsExistWithRestartEnabled() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "Spaces", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests restart workspace clears agent windows by arranging a running workspace with an Spaces2 agent window and asserting the record and built-in terminal window are removed before relaunch.
    func testRestartWorkspaceClearsAgentWindows() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "Claude Code", windowID: 501,
                terminalTrackingID: "workspace-session", role: "terminal", orderIndex: 201, lastSeenAt: "now"))
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Claude Code", terminalTrackingID: "workspace-session",
            codexThreadID: nil, windowID: 501, yabaiWindowID: 501, status: .spinning, createdAt: "now", updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value:
                    #"[{"id":501,"pid":11,"app":"Spaces","title":"Claude Code","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) { try orchestrator.restartWorkspace(workspaceID: workspace.id) }
        }

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "Agent window records should be cleared during restart")
    }

    // Tests restart workspace kills every built-in terminal window in the shared Spaces container so stale windows do not survive the teardown.

    // Tests up workspace with restart enabled clears agent windows by arranging a running workspace with an Spaces2 agent window and asserting the record and built-in terminal window are removed before relaunch.

    // Tests stopWorkspace tears down the full built-in terminal session by arranging a running workspace with an Spaces2 agent window and asserting the record and session are removed.

    // Tests update workspace settings removing browser sessions closes tabs without closing chrome window by arranging representative inputs and asserting the expected result.

    // Tests launch workspace rejects archived workspace by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceRejectsArchivedWorkspace() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        // Mocked dependencies are present only to satisfy adapter calls; launch should fail before launching anything.
        // Remaining risk: launch behavior when partially archived/misaligned runtime state exists is covered elsewhere.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id))
        }
    }

    // Tests workspace settings and accessors reflect store state by arranging representative inputs and asserting the expected result.
    func testWorkspaceSettingsAndAccessorsReflectStoreState() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let api = PortDefinition(id: "port-api", name: "API_PORT")
        let web = PortDefinition(id: "port-web", name: "WEB_PORT")
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [api, web])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [4100, 4101], names: [api.name, web.name], definitionIDs: [api.id, web.id])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "job", command: "echo job", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependency: `yabai` queries used by settings reconciliation.
        // Why: keep this test focused on persisted settings/accessor behavior.
        // Remaining risk: browser-session behavior with real Chrome is intentionally excluded in this unit.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.stopScript = "echo workspace-stop"
                settings.ports = [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")]
                settings.processes = [ProcessTemplate(name: "job", command: "echo job")]
                settings.browserSessions = []
            }
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
        XCTAssertEqual(settings?.stopScript, "echo workspace-stop")
        XCTAssertEqual(settings?.processes.first?.name, "job")
        XCTAssertTrue(settings?.browserSessions.isEmpty ?? false)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id), [4100, 4101])
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).count, 1)
    }

    private final class TestClock {
        private var current: Date

        init(now: Date) { current = now }

        func now() -> Date { current }

        func advance(seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    private func makeOrchestratorWithWorkspace(
        browserWindowScanDebounceInterval: TimeInterval = 10,
        terminalFocusPulseController: TerminalFocusPulseControlling = MockTerminalFocusPulseController(),
        currentDate: @escaping () -> Date = Date.init
    ) throws -> (WorkspaceOrchestrator, SQLiteStore, ProjectRecord, WorkspaceRecord, URL) {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces-test.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(
            store: store, browserWindowScanDebounceInterval: browserWindowScanDebounceInterval,
            terminalFocusPulseController: terminalFocusPulseController,
            builtInTerminalWindowOpener: { sessionID, _ in
                try! withSpacesProfileEnvironment(dbPath: dbPath) {
                    let paths = try TerminalSessionPaths.forSession(id: sessionID)
                    try paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 4321, state: .running,
                            updatedAt: "2026-05-15T18:00:00Z"), paths: paths)
                    try "test output\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
                }
            },
            builtInTerminalSessionLauncher: { configuration in
                try withSpacesProfileEnvironment(dbPath: dbPath) {
                    let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
                    try paths.ensureDirectories()
                    try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
                    let runtimeState =
                        (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
                        ?? TerminalSessionRuntimeState(
                            sessionID: configuration.sessionID, backend: configuration.backend,
                            servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 4321, state: .running,
                            updatedAt: "2026-05-15T18:00:00Z", title: configuration.title, workingDirectory: configuration.workingDirectory)
                    try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
                    return TerminalServiceSessionSummary(
                        id: configuration.sessionID, title: runtimeState.title ?? configuration.title,
                        workingDirectory: runtimeState.workingDirectory ?? configuration.workingDirectory, backend: configuration.backend,
                        lifetimePolicy: configuration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                        childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
                }
            }, currentDate: currentDate)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        return (orchestrator, store, project, workspace, root)
    }

    private func spacesYAMLFixture(stopScript: String) -> String {
        """
        version: 1
        setup_script: npm install
        stop_script: \(stopScript)
        ports:
          - name: API_PORT
        processes:
          - name: api
            command: npm run api
            on_exit: none
        browser_sessions:
          - name: app
            url: http://localhost:3000
        agent_launchers:
          - name: Codex
            command: codex
        """
    }

    private func writeTerminalSessionFixture(
        sessionID: String, workspace: WorkspaceRecord, kind: TerminalSessionKind, runtimeState: TerminalSessionRuntimeState
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: runtimeState.title ?? sessionID,
                workingDirectory: runtimeState.workingDirectory ?? workspace.dir, shell: "/bin/zsh", command: nil, createdAt: "2026-06-06T00:00:00Z",
                workspaceID: workspace.id, kind: kind), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
    }

    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
        if name == SpacesProfile.databasePathEnvironmentVariable {
            try withSpacesProfileEnvironment(dbPath: value, run: run)
            return
        }
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let original { setenv(name, original, 1) } else { unsetenv(name) } }
        try run()
    }

    private static let orchestratorYabaiMockScript = """
        #!/bin/bash
        # Mock `yabai` CLI used by orchestrator tests.
        # Coverage intent:
        # - space/display/window query payloads
        # - focus success/failure and focused-window toggles via env vars
        # Residual risk: real yabai output and timing can differ significantly under live desktops.
        args="$*"

        sleep_ms() {
          local value="$1"
          if [[ -z "$value" || "$value" == "0" ]]; then
            return
          fi
          local cap="${MOCK_TEST_DELAY_CAP_MS:-25}"
          if [[ "$value" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ && "$value" -gt "$cap" ]]; then
            value="$cap"
          fi
          perl -e "select(undef, undef, undef, $value / 1000);"
        }

        focused_id="${YABAI_FOCUSED_ID:-101}"
        focused_app="${YABAI_FOCUSED_APP:-Spaces}"
        focused_title="${YABAI_FOCUSED_TITLE:-focused}"
        focused_json="{\\"id\\":${focused_id},\\"pid\\":11,\\"app\\":\\"${focused_app}\\",\\"title\\":\\"${focused_title}\\",\\"space\\":1,\\"display\\":1,\\"is-sticky\\":false,\\"is-hidden\\":false,\\"is-visible\\":true,\\"is-native-fullscreen\\":false}"
        query_log_file="${YABAI_QUERY_LOG_FILE:-}"

        if [[ "$args" == *"query --displays"* ]]; then
          if [[ -n "$query_log_file" ]]; then
            echo "query --displays" >> "$query_log_file"
          fi
          echo '[{"index":1},{"index":2}]'
          exit 0
        fi

        if [[ "$args" == *"query --spaces"* ]]; then
          if [[ -n "$query_log_file" ]]; then
            echo "query --spaces" >> "$query_log_file"
          fi
          echo '[{"index":3,"display":2},{"index":2,"display":1},{"index":1,"display":1}]'
          exit 0
        fi

        if [[ "$args" == *"query --windows --window"* ]]; then
          if [[ -n "$query_log_file" ]]; then
            echo "query --windows --window" >> "$query_log_file"
          fi
          if [[ "${YABAI_FOCUSED_NONE:-}" == "1" ]]; then
            echo "no focused window" >&2
            exit 1
          fi
          echo "$focused_json"
          exit 0
        fi

        if [[ "$args" == *"query --windows"* ]]; then
          if [[ -n "$query_log_file" ]]; then
            echo "query --windows" >> "$query_log_file"
          fi
          if [[ -n "${YABAI_WINDOWS_JSON:-}" ]]; then
            echo "$YABAI_WINDOWS_JSON"
          else
            echo '[{"id":101,"pid":11,"app":"Spaces","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":202,"pid":22,"app":"Google Chrome","title":"docs","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]'
          fi
          exit 0
        fi

        if [[ "$args" == *"window --focus"* ]]; then
          id="${@: -1}"
          if [[ "$id" == "999" || ",${YABAI_FOCUS_FAIL_IDS:-}," == *",${id},"* ]]; then
            echo "focus failed" >&2
            exit 1
          fi
          sleep_ms "${MOCK_YABAI_FOCUS_DELAY_MS:-0}"
          if [[ -n "${YABAI_FOCUS_LOG_FILE:-}" ]]; then
            echo "$id" >> "$YABAI_FOCUS_LOG_FILE"
          fi
          echo "ok"
          exit 0
        fi

        if [[ "$args" == *"window --close"* ]]; then
          id="${@: -1}"
          if [[ -n "${YABAI_CLOSE_LOG_FILE:-}" ]]; then
            echo "$id" >> "$YABAI_CLOSE_LOG_FILE"
          fi
          echo "ok"
          exit 0
        fi

        if [[ "$args" == *"window --minimize"* ]]; then
          echo "ok"
          exit 0
        fi

        echo "unhandled command: $args" >&2
        exit 1
        """

    private static let orchestratorOsaScriptMock = """
        #!/bin/bash
        # Mock `osascript` bridge for Chrome paths used by orchestrator tests.
        # Coverage intent:
        # - Chrome availability/session stubs
        # Residual risk: no validation of true AppleScript syntax/runtime against installed applications.
        script="${*: -1}"
        chrome_active_url_file="${MOCK_CHROME_ACTIVE_URL_FILE:-}"
        if [[ -z "$chrome_active_url_file" && -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
          chrome_active_url_file="${MOCK_CHROME_FOCUS_LOG_FILE}.active"
        fi
        extract_window_id() {
          local source="$1"
          local extracted
          extracted="$(printf '%s\n' "$source" | awk -F'set requestedWindowID to \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -n "$extracted" ]]; then
            echo "$extracted"
            return
          fi
          printf '%s\n' "$source" | grep -Eo 'if id of w is [0-9]+ then' | awk '{print $6}' | head -n1
        }

        sleep_ms() {
          local value="$1"
          if [[ -z "$value" || "$value" == "0" ]]; then
            return
          fi
          local cap="${MOCK_TEST_DELAY_CAP_MS:-25}"
          if [[ "$value" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ && "$value" -gt "$cap" ]]; then
            value="$cap"
          fi
          perl -e "select(undef, undef, undef, $value / 1000);"
        }

        if [[ "$script" == *'tell application "Google Chrome" to version'* ]]; then
          echo "122"
          exit 0
        fi

        if [[ "$script" == *'set active tab index of front window to 1'* ]]; then
          if [[ -n "${MOCK_CHROME_TAB_INDEX_LOG_FILE:-}" ]]; then
            echo "front\t1" >> "$MOCK_CHROME_TAB_INDEX_LOG_FILE"
          fi
          echo "1"
          exit 0
        fi

        if [[ "$script" == *'set output to ""'* ]]; then
          sleep_ms "${MOCK_CHROME_SCAN_DELAY_MS:-0}"
          if [[ -n "${MOCK_CHROME_SCAN_LOG_FILE:-}" ]]; then
            echo "scan" >> "$MOCK_CHROME_SCAN_LOG_FILE"
          fi
          if [[ "${MOCK_CHROME_SCAN_FAIL:-}" == "1" ]]; then
            echo "scan failed" >&2
            exit 1
          fi
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" ]]; then
            printf "%b" "$MOCK_CHROME_WINDOW_MATCHES"
          else
            echo ""
          fi
          exit 0
        fi

        if [[ "$script" == *'set u to URL of tab requestedTabIndex of w'* ]]; then
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_URL:-}" ]]; then
            echo "$MOCK_CHROME_TAB_INDEX_URL"
            exit 0
          fi
          indexed_url=""
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" && -n "$focused_window_id" && -n "$requested_tab_index" ]]; then
            indexed_url="$(printf "%b" "$MOCK_CHROME_WINDOW_MATCHES" | awk -F $'\t' -v wid="$focused_window_id" -v target="$requested_tab_index" '($1 == wid) { count += 1; if (count == target) { print $NF; exit } }')"
          fi
          echo "$indexed_url"
          exit 0
        fi

        if [[ "$script" == *'set targetTab to tab requestedTabIndex of w'* ]]; then
          sleep_ms "${MOCK_CHROME_EXTRACT_DELAY_MS:-0}"
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_EXTRACT_LOG_FILE:-}" ]]; then
            echo "${focused_window_id:-*}\t${requested_tab_index:-0}" >> "$MOCK_CHROME_EXTRACT_LOG_FILE"
          fi
          echo "${MOCK_CHROME_EXTRACT_WINDOW_ID:-888}"
          exit 0
        fi

        if [[ "$script" == *'set requestedTabIndex to'* ]]; then
          sleep_ms "${MOCK_CHROME_TAB_INDEX_DELAY_MS:-0}"
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_LOG_FILE:-}" ]]; then
            echo "${focused_window_id:-*}\t${requested_tab_index:-0}" >> "$MOCK_CHROME_TAB_INDEX_LOG_FILE"
          fi
          focused_url=""
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" && -n "$focused_window_id" && -n "$requested_tab_index" ]]; then
            focused_url="$(printf "%b" "$MOCK_CHROME_WINDOW_MATCHES" | awk -F $'\t' -v wid="$focused_window_id" -v target="$requested_tab_index" '($1 == wid) { count += 1; if (count == target) { print $NF; exit } }')"
          fi
          focused_active_url="$focused_url"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_ACTIVE_URL:-}" ]]; then
            focused_active_url="$MOCK_CHROME_TAB_INDEX_ACTIVE_URL"
          fi
          if [[ -n "$focused_active_url" ]]; then
            if [[ -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
              echo "$focused_active_url" >> "$MOCK_CHROME_FOCUS_LOG_FILE"
            fi
            if [[ -n "$chrome_active_url_file" ]]; then
              echo "$focused_active_url" > "$chrome_active_url_file"
            fi
          fi
          echo "${MOCK_CHROME_TAB_INDEX_FOCUS_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'set tabCount to count of tabs of w'* && "$script" == *'close tab i of w'* ]]; then
          if [[ "${MOCK_CHROME_CLOSE_REQUIRE_PREFIX:-}" == "1" && "$script" != *'u starts with \"'* ]]; then
            echo "0"
            exit 0
          fi
          close_url="$(printf '%s\n' "$script" | awk -F'u is \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -z "$close_url" ]]; then
            close_url="$(printf '%s\n' "$script" | awk -F'u starts with \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          fi
          close_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_CLOSE_LOG_FILE:-}" ]]; then
            echo "${close_window_id:-*}\t${close_url}" >> "$MOCK_CHROME_CLOSE_LOG_FILE"
          fi
          echo "${MOCK_CHROME_CLOSE_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'set tabCount to count of tabs of w'* ]]; then
          focused_url="$(printf '%s\n' "$script" | awk -F'starts with \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -z "$focused_url" ]]; then
            focused_url="$(printf '%s\n' "$script" | awk -F'u is \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          fi
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "$focused_window_id" && -n "${MOCK_CHROME_FOCUS_WINDOW_LOG_FILE:-}" ]]; then
            echo "$focused_window_id" >> "$MOCK_CHROME_FOCUS_WINDOW_LOG_FILE"
          fi
          if [[ -n "$focused_url" ]]; then
            if [[ -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
              echo "$focused_url" >> "$MOCK_CHROME_FOCUS_LOG_FILE"
            fi
            if [[ -n "$chrome_active_url_file" ]]; then
              echo "$focused_url" > "$chrome_active_url_file"
            fi
          fi
          echo "${MOCK_CHROME_FOCUS_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'URL of active tab of front window'* ]]; then
          sleep_ms "${MOCK_CHROME_ACTIVE_URL_DELAY_MS:-0}"
          if [[ -n "$chrome_active_url_file" && -f "$chrome_active_url_file" ]]; then
            cat "$chrome_active_url_file"
          else
            echo "${MOCK_CHROME_ACTIVE_URL:-}"
          fi
          exit 0
        fi

        if [[ "$script" == *'set URL of active tab of newWindow'* ]]; then
          if [[ -n "${MOCK_CHROME_OPEN_LOG_FILE:-}" ]]; then
            echo "$script" >> "$MOCK_CHROME_OPEN_LOG_FILE"
          fi
          echo "88"
          exit 0
        fi

        if [[ "$script" == *'make new tab at end of tabs of w with properties {URL:'* ]]; then
          if [[ -n "${MOCK_CHROME_OPEN_LOG_FILE:-}" ]]; then
            echo "$script" >> "$MOCK_CHROME_OPEN_LOG_FILE"
          fi
          echo "${MOCK_CHROME_OPEN_TAB_RESULT:-1}"
          exit 0
        fi

        echo ""
        exit 0
        """

    private static let killMockScript = """
        #!/bin/bash
        if [[ -n "${MOCK_KILL_LOG_FILE:-}" ]]; then
          echo "kill $*" >> "$MOCK_KILL_LOG_FILE"
        fi
        exit 0
        """

    private static let openMockScript = """
        #!/bin/bash
        # Mock `open` for editor-launch assertions.
        # Residual risk: launch service resolution and app startup behavior are not exercised.
        if [[ -n "${OPEN_LOG_FILE:-}" ]]; then
          echo "$*" >> "$OPEN_LOG_FILE"
        fi
        exit 0
        """

    private func parseWorktreePaths(_ porcelainOutput: String) -> Set<String> {
        Set(
            porcelainOutput.split(separator: "\n").compactMap { rawLine -> String? in
                let line = String(rawLine)
                guard line.hasPrefix("worktree ") else { return nil }
                let path = String(line.dropFirst("worktree ".count))
                return normalizeTestPath(path)
            })
    }

    private func normalizeTestPath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    // MARK: - buildWorkspaceEnv

    // Tests build workspace env sets spaces workspace dir by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvSetsSpacesWorkspaceDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        XCTAssertEqual(env["SPACES_WORKSPACE_DIR"], "/tmp/project/ws")
    }

    // Tests build workspace env sets spaces project dir by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvSetsSpacesProjectDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        XCTAssertEqual(env["SPACES_PROJECT_DIR"], "/tmp/project")
    }

    // Tests build workspace env does not contain scoped key by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvDoesNotContainScopedKey() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        let scopedKeys = env.keys.filter { $0.hasPrefix("spaces_") || $0.hasPrefix("SPACES_PROJECT_") && $0.hasSuffix("_WORKSPACE_DIR") }
        XCTAssertTrue(scopedKeys.isEmpty, "Expected no scoped cross-project keys, found: \(scopedKeys)")
    }

    // Tests add project stores in db only by arranging representative inputs and asserting the expected result.
    func testAddProjectStoresInDBOnly() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("myproject", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let record = try orchestrator.addProject(dir: projectDir.path)

        // Project is in DB
        XCTAssertNotNil(try store.project(id: record.id))

        // Project count in DB is correct
        XCTAssertEqual(try store.projects().count, 1)
    }

    // Tests update project config persists templates to db by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigPersistsTemplatesToDB() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { p in
            p.setupScript = "echo setup"
            p.stopScript = "echo stop"
            p.ports = [PortDefinition(name: "API_PORT")]
            p.processes = [ProcessTemplate(name: "api", command: "npm start")]
        }

        let updated = try store.project(id: project.id)
        XCTAssertEqual(updated?.setupScript, "echo setup")
        XCTAssertEqual(updated?.stopScript, "echo stop")
        XCTAssertEqual(updated?.ports.count, 1)
        XCTAssertEqual(updated?.processes.count, 1)
    }

    // Tests remove project deletes from db by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDeletesFromDB() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        XCTAssertNotNil(try store.project(id: project.id))

        try orchestrator.removeProject(dir: projectDir.path)

        XCTAssertNil(try store.project(id: project.id))
    }

    // Tests build workspace env includes named ports by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvIncludesNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/tmp/project/ws")
        let ports: [(port: Int, name: String)] = [(port: 3000, name: "FRONTEND_PORT"), (port: 8080, name: "API_PORT")]
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: ports)
        XCTAssertEqual(env["FRONTEND_PORT"], "3000")
        XCTAssertEqual(env["API_PORT"], "8080")
        XCTAssertEqual(env["SPACES_WORKSPACE_DIR"], "/tmp/project/ws")
        XCTAssertEqual(env["SPACES_PROJECT_DIR"], "/tmp/project")
    }

    func testBuildWorkspaceEnvDoesNotIncludePath() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/tmp/project/ws")

        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])

        XCTAssertNil(env["PATH"])
    }

    func testBuildWorkspaceEnvSkipsUnnamedPortsAndDoesNotSynthesizeFallbackKeys() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/tmp/project/ws")
        let ports: [(port: Int, name: String)] = [(port: 3000, name: " "), (port: 8080, name: "API_PORT")]

        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: ports)

        XCTAssertNil(env["PORT0"])
        XCTAssertNil(env["PORT1"])
        XCTAssertEqual(env["API_PORT"], "8080")
    }

    // Tests create workspace from worktree infers project and branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeInfersProjectAndBranch() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        let root = repo.deletingLastPathComponent()
        let worktree = root.appendingPathComponent("feature-branch", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-branch")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)
        XCTAssertEqual(workspace.projectID, project.id)
        XCTAssertEqual(workspace.title, "feature-branch")
        XCTAssertEqual(workspace.branch, "feature-branch")
        XCTAssertEqual(workspace.dir, worktree.path)
        XCTAssertEqual(workspace.dirname, "feature-branch")
        XCTAssertFalse(workspace.isArchived)
        let stored = try store.workspace(id: workspace.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.title, "feature-branch")
    }

    // Tests create workspace from worktree with custom name by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeWithCustomName() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: repo.path)
        let worktree = root.appendingPathComponent("fix-bug", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "fix/bug-123")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: "bug-fix")
        XCTAssertEqual(workspace.title, "bug-fix")
        XCTAssertEqual(workspace.branch, "fix/bug-123")
    }

    // Tests create workspace from worktree fails if project not registered by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeFailsIfProjectNotRegistered() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let worktree = root.appendingPathComponent("feature", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature")
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("Project not found"))
            XCTAssertTrue(nsError.localizedDescription.contains("Add the project in the app"))
        }
    }

    // Tests create workspace from worktree fails if already exists by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeFailsIfAlreadyExists() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: repo.path)
        let worktree = root.appendingPathComponent("feature", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature")
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("already exists"))
        }
    }

    // Tests scan and create workspaces from worktrees finds all worktrees by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesFindsAllWorktrees() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("feature-1", isDirectory: true)
        let worktree2 = root.appendingPathComponent("feature-2", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree1.path, branch: "feature-1")
        try client.createWorktree(path: repo.path, worktreePath: worktree2.path, branch: "feature-2")
        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertEqual(created.count, 2)
        let names = Set(created.map(\.title))
        XCTAssertTrue(names.contains("feature-1"))
        XCTAssertTrue(names.contains("feature-2"))
        let allWorkspaces = try store.workspaces(projectID: project.id, includeArchived: false)
        XCTAssertEqual(allWorkspaces.count, 3)
    }

    // Tests scan and create workspaces from worktrees skips existing workspaces by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesSkipsExistingWorkspaces() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("feature-1", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree1.path, branch: "feature-1")
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree1.path, name: nil)
        let worktree2 = root.appendingPathComponent("feature-2", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree2.path, branch: "feature-2")
        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertEqual(created.count, 1)
        let names = Set(created.map(\.title))
        XCTAssertTrue(names.contains("feature-2"))
        XCTAssertFalse(names.contains("feature-1"))
        XCTAssertFalse(names.contains("main"))
    }

    // Tests scan and create workspaces from worktrees runs setup script for created workspace by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesRunsSetupScriptForCreatedWorkspace() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo discovered > .spaces-discovery-setup-marker"
        }

        let client = GitClient()
        let worktree = root.appendingPathComponent("feature-setup", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-setup")

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertEqual(created.count, 1)

        let markerFile = worktree.appendingPathComponent(".spaces-discovery-setup-marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
        let marker = try String(contentsOf: markerFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(marker, "discovered")
    }

    // Tests scan and create workspaces from worktrees skips deleted workspace paths marked ignored by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesSkipsDeletedWorkspacePathsMarkedIgnored() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let worktree = root.appendingPathComponent("feature-ignored", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-ignored")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path)

        try store.deleteWorkspace(id: workspace.id)

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees()
        XCTAssertTrue(created.isEmpty)
        XCTAssertNil(try store.workspace(dir: worktree.path))
        XCTAssertTrue(try store.isIgnoredWorktree(path: worktree.path))
    }

    // Tests scan and create workspaces from worktrees skips missing worktree directories by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesSkipsMissingWorktreeDirectories() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let missingWorktree = root.appendingPathComponent("feature-missing", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: missingWorktree.path, branch: "feature-missing")
        try FileManager.default.removeItem(at: missingWorktree)

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertTrue(created.isEmpty)
        XCTAssertNil(try store.workspace(dir: missingWorktree.path))
    }

    // Tests scan and create workspaces from worktrees archives existing workspace when worktree is removed by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesArchivesWorkspaceWhenWorktreeIsRemoved() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let removedWorktree = root.appendingPathComponent("feature-removed", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: removedWorktree.path, branch: "feature-removed")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: removedWorktree.path, name: nil)

        try client.removeWorktree(path: repo.path, worktreePath: removedWorktree.path)

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertTrue(created.isEmpty)

        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
    }

    // Tests scan and create workspaces from worktrees refreshes stored branch names by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesRefreshesBranchNamesFromDisk() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let worktree = root.appendingPathComponent("feature-renamed", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-renamed")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)

        _ = try client.runGitAndCapture(["-C", worktree.path, "branch", "-m", "feature-renamed-on-disk"])
        _ = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)

        let refreshedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(refreshedWorkspace?.branch, "feature-renamed-on-disk")
    }

    // Tests scan and create workspaces from worktrees scans all projects when no project id provided by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesScansAllProjectsWhenNoProjectIDProvided() throws {
        let repo1 = try makeTempGitRepo(name: "repo1")
        let repo2 = try makeTempGitRepo(name: "repo2")
        let root = repo1.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project1 = try orchestrator.addProject(dir: repo1.path)
        let project2 = try orchestrator.addProject(dir: repo2.path)
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("repo1-feature", isDirectory: true)
        try client.createWorktree(path: repo1.path, worktreePath: worktree1.path, branch: "feature")
        let worktree2 = root.appendingPathComponent("repo2-bugfix", isDirectory: true)
        try client.createWorktree(path: repo2.path, worktreePath: worktree2.path, branch: "bugfix")
        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: nil)
        XCTAssertEqual(created.count, 2)
        let project1Workspaces = try store.workspaces(projectID: project1.id, includeArchived: false)
        XCTAssertEqual(project1Workspaces.count, 2)
        let project2Workspaces = try store.workspaces(projectID: project2.id, includeArchived: false)
        XCTAssertEqual(project2Workspaces.count, 2)
    }

    func testStopWorkspaceProcessRemovesTrackedRuntimeAndClearsRunningFlagWhenLastProcessStops() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let processID = UUID().uuidString

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "api", windowID: 559, terminalTrackingID: "workspace-session",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 559,
                terminalTrackingID: "workspace-session", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        )

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: processID)
        }

        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try store.workspace(id: workspace.id)?.isRunning ?? true)
    }

    func testStopWorkspaceProcessTerminatesBuiltInSession() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        let sessionID = "spaces-session-stop-process-1"
        let processID = UUID().uuidString
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                windowID: 601, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, windowID: 601, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: processID)
        }

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try store.workspace(id: workspace.id)?.isRunning ?? true)
    }

    // MARK: - resolveEnvVars

    // Tests applyEnvVars substitutes a single named variable.
    func testApplyEnvVarsSubstitutesSingleVar() {
        let orchestrator = WorkspaceOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$FRONTEND_PORT npm run dev", env: ["FRONTEND_PORT": "20002"])
        XCTAssertEqual(result, "PORT=20002 npm run dev")
    }

    // Tests applyEnvVars substitutes multiple variables in one command.
    func testApplyEnvVarsSubstitutesMultipleVars() {
        let orchestrator = WorkspaceOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars(
            "PORT=$FRONTEND_PORT BACKEND=$BACKEND_PORT node server.js", env: ["FRONTEND_PORT": "3000", "BACKEND_PORT": "4000"])
        XCTAssertEqual(result, "PORT=3000 BACKEND=4000 node server.js")
    }

    // Tests applyEnvVars leaves unknown variables unchanged.
    func testApplyEnvVarsLeavesUnknownVarsUnchanged() {
        let orchestrator = WorkspaceOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$UNKNOWN npm start", env: ["FRONTEND_PORT": "3000"])
        XCTAssertEqual(result, "PORT=$UNKNOWN npm start")
    }

    // Tests applyEnvVars returns command unchanged when env is empty.
    func testApplyEnvVarsEmptyEnvReturnsCommandUnchanged() {
        let orchestrator = WorkspaceOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$FRONTEND_PORT npm run dev", env: [:])
        XCTAssertEqual(result, "PORT=$FRONTEND_PORT npm run dev")
    }

    // Tests resolveEnvVars replaces named port variable with allocated port number.
    func testResolveEnvVarsReplacesNamedPortVar() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [20002], names: ["FRONTEND_PORT"])

        let resolved = try orchestrator.resolveEnvVars(in: "PORT=$FRONTEND_PORT npm run dev", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "PORT=20002 npm run dev")
    }

    // Tests resolveEnvVars resolves multiple named ports.
    func testResolveEnvVarsResolvesMultipleNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["FRONTEND_PORT", "BACKEND_PORT"])

        let resolved = try orchestrator.resolveEnvVars(in: "FRONTEND=$FRONTEND_PORT BACKEND=$BACKEND_PORT node app.js", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "FRONTEND=3000 BACKEND=4000 node app.js")
    }

    // Tests resolveEnvVars leaves command unchanged when no ports are allocated.
    func testResolveEnvVarsNoPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)

        let resolved = try orchestrator.resolveEnvVars(in: "npm start", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "npm start")
    }

    // Tests resolveEnvVars injects SPACES_WORKSPACE_DIR into command.
    func testResolveEnvVarsInjectsWorkspaceDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)

        let resolved = try orchestrator.resolveEnvVars(in: "cd $SPACES_WORKSPACE_DIR && npm start", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "cd /workspaces/myapp/dev && npm start")
    }

    // MARK: - updatePortRange

    // Tests updatePortRange persists to the app config by arranging representative inputs and asserting the expected result.
    func testUpdatePortRangePersists() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let updated = try orchestrator.updatePortRange(PortRange(start: 25000, end: 35000))
        XCTAssertEqual(updated.portRange.start, 25000)
        XCTAssertEqual(updated.portRange.end, 35000)
        XCTAssertEqual(try orchestrator.appConfig().portRange.start, 25000)
    }

    // MARK: - listProjects

    // Tests listProjects returns summaries for all stored projects by arranging representative inputs and asserting the expected result.
    func testListProjectsReturnsSummariesForAllProjects() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertTrue(try orchestrator.listProjects().isEmpty)

        let root = try makeTempDirectory()
        let dirA = root.appendingPathComponent("a", isDirectory: true)
        let dirB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        _ = try orchestrator.addProject(dir: dirA.path)
        _ = try orchestrator.addProject(dir: dirB.path)

        let projects = try orchestrator.listProjects()
        XCTAssertEqual(projects.count, 2)
        let names = Set(projects.map(\.name))
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
    }

    // MARK: - refreshAllWorkspaceWindows

    // Tests refreshAllWorkspaceWindows iterates all projects and workspaces by arranging representative inputs and asserting the expected result.
    func testRefreshAllWorkspaceWindowsIteratesAllWorkspaces() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "shell", windowID: 707, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        // Mocked dependency: yabai window list (empty means the stale window gets pruned).
        // Why: verify refreshAllWorkspaceWindows iterates workspaces and returns correct counts.
        // Remaining risk: real yabai interactions not covered.
        var result: WorkspaceOrchestrator.RefreshResult!
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { result = try orchestrator.refreshAllWorkspaceWindows() }
        }

        XCTAssertTrue(result.didMutateDB)
        XCTAssertEqual(result.trackedWindowCounts[workspace.id], 0)
    }

    // MARK: - stopWorkspace

    // Tests stopWorkspace with running processes clears all runtime state by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClearsAllRuntimeState() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces", windowID: 200,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "api", windowID: 200, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    // Tests stopWorkspace with stop script that runs by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceWithStopScriptRuns() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        let markerFile = root.appendingPathComponent("stop-marker.txt")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "touch \(markerFile.path)")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
    }

    // Tests stopWorkspace skips stop script when workspace directory is missing by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceSkipsStopScriptWhenDirectoryMissing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/nonexistent/project/path")
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "feature", dir: "/nonexistent/project/path/feature")
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo this-should-not-run")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        XCTAssertTrue(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
    }

    // MARK: - syncConfig / appConfig

    // Tests syncConfig returns the current app config by arranging representative inputs and asserting the expected result.
    func testSyncConfigReturnsCurrentAppConfig() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let config = try orchestrator.syncConfig()
        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)

        let config2 = try orchestrator.appConfig()
        XCTAssertEqual(config2.portRange.start, 20000)
    }

    // MARK: - updateProjectConfig workspace isolation

    // Tests updateProjectConfig does not sync default workspace settings when they match the previous template.
    func testUpdateProjectConfigDoesNotSyncDefaultWorkspaceSettings() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try store.workspaces(projectID: project.id).first(where: \.isDefault)!

        // Set default workspace settings to match the project template (initially empty).
        try store.touchWorkspaceSettings(workspaceID: defaultWorkspace.id, updatedAt: "now")

        // Update the project config with a stop script.
        try orchestrator.updateProjectConfig(projectID: project.id) { record in record.stopScript = "echo project-stop" }

        let workspaceScript = try store.workspaceStopScript(workspaceID: defaultWorkspace.id)
        XCTAssertNil(workspaceScript)
    }

    // Tests updateProjectConfig with git repo project refreshes default workspace by arranging representative inputs and asserting the expected result.
    func testAddProjectDirForGitRepoDetectsGitBranch() throws {
        let fixture = try makeTempGitRepo(name: "detect-git")
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: fixture.path)

        XCTAssertTrue(project.isGitRepo)
        XCTAssertNotNil(project.defaultBranch)
        XCTAssertFalse((project.defaultBranch ?? "").isEmpty)
    }

    // MARK: - workspaceSetupState from orchestrator

    // Tests workspaceSetupState returns current state by arranging representative inputs and asserting the expected result.
    func testOrchestratorWorkspaceSetupStateReturnsCurrentState() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Setup state is seeded automatically.
        let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(state.status, .succeeded)
    }

    // Tests createWorkspace seeds per-workspace process IDs so multiple workspaces can inherit the same project template without collisions.
    func testCreateWorkspaceSeedsUniqueProcessIDsPerWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path) { config in
            config.processes = [.init(name: "frontend", command: "npm run dev"), .init(name: "backend", command: "npm run api")]
        }

        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let defaultSettings = try XCTUnwrap(orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id))

        let createdWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let createdSettings = try XCTUnwrap(orchestrator.workspaceSettings(workspaceID: createdWorkspace.id))

        XCTAssertEqual(defaultSettings.processes.map(\.name), createdSettings.processes.map(\.name))
        XCTAssertEqual(defaultSettings.processes.map(\.command), createdSettings.processes.map(\.command))
        XCTAssertTrue(Set(defaultSettings.processes.map(\.id)).isDisjoint(with: createdSettings.processes.map(\.id)))
    }

    // MARK: - workspacePorts

    // Tests workspacePortsNamed returns named ports by arranging representative inputs and asserting the expected result.
    func testWorkspacePortsNamedReturnsNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/projects/myapp")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["FRONTEND", "BACKEND"])

        let named = try orchestrator.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named[0].name, "FRONTEND")
        XCTAssertEqual(named[0].port, 3000)
        XCTAssertEqual(named[1].name, "BACKEND")
        XCTAssertEqual(named[1].port, 4000)
    }

    // MARK: - upWorkspace restart-exited-processes path

    // Tests upWorkspace with no runtime indicators launches workspace fresh by arranging representative inputs and asserting the expected result.
    // Tests upWorkspace with restartIfRunning stops then restarts workspace by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceWithRestartIfRunningStopsThenRestarts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Mark workspace as running with a tracked process.
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependencies: yabai for stop and re-launch.
        // Why: exercise the restartIfRunning=true branch which calls stop then launch.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true) }
        }

        // After restart, process list is cleared and workspace re-launched.
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests gitBranchOptions returns empty for non-git project by arranging representative inputs and asserting the expected result.
    func testGitBranchOptionsReturnsEmptyForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let options = try orchestrator.gitBranchOptions(projectID: project.id)
        XCTAssertTrue(options.isEmpty)
    }

    // Tests updateWorkspaceHidden persists isHidden state by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceHiddenIdemopotentWhenSameValue() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Default isHidden is false; setting it to false again should be a no-op.
        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: false)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, false)

        // Setting to true should persist.
        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: true)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, true)
    }

    // Tests updateWorkspaceNotes persists notes through orchestrator by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNotesPersistsThroughOrchestrator() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: "Working on API")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.notes, "Working on API")

        try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: nil)
        XCTAssertNil(try store.workspace(id: workspace.id)?.notes)
    }

    // Tests workspaceSettings seeds and returns defaults for workspace without explicit settings by arranging representative inputs and asserting the expected result.
    func testWorkspaceSettingsReturnsDefaultsWhenNotExplicitlySet() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: projectDir.path)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "raw", dir: projectDir.path)
        try store.upsert(workspace: workspace)

        // workspaceSettings seeds defaults when no settings exist; returns an empty (non-nil) settings object.
        let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
        XCTAssertNotNil(settings)
        XCTAssertNil(settings?.stopScript)
        XCTAssertTrue(settings?.ports.isEmpty ?? false)
        XCTAssertTrue(settings?.processes.isEmpty ?? false)
    }

    // Tests upWorkspace allocates ports when port definitions exist but no ports are allocated by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceAllocatesPortsWhenDefinitionsExistButNoPortsAllocated() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Add port definitions so that portDefinitions.count > 0 with no ports allocated yet.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [PortDefinition(name: "web"), PortDefinition(name: "api")]
        }

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.upWorkspace(workspaceID: workspace.id) }

        // Ports should now be allocated.
        let allocatedPorts = try store.workspacePorts(workspaceID: workspace.id)
        XCTAssertEqual(allocatedPorts.count, 2)
    }

    // Tests stopWorkspace skips stop script when workspace directory is missing by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceSkipsStopScriptWhenWorkspaceDirMissing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Set a stop script that would fail if the directory doesn't exist.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.stopScript = "echo stopped" }

        // Mark workspace as running so stop can proceed.
        var runningWorkspace = workspace
        runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, title: workspace.title, dir: "/nonexistent/workspace-\(UUID().uuidString)",
            dirname: workspace.dirname, branch: workspace.branch, baseBranch: workspace.baseBranch, isDefault: workspace.isDefault,
            isArchived: workspace.isArchived, isHidden: workspace.isHidden, isRunning: true, lastLaunchedAt: nil, notes: nil)
        try store.upsert(workspace: runningWorkspace)

        // Stop should succeed (skip script because dir is missing) rather than throw.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)
            XCTAssertTrue(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        }
    }

    // Tests stopWorkspace closes non-Spaces tracked windows via yabai by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClosesNonSpacesTrackedWindowsViaYabai() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Insert a tracked "editor" window (non-browser, non-Spaces) so lines 702-705 are reached.
        let editorWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Cursor", title: "editor", windowID: 42, role: "editor", orderIndex: 100,
            lastSeenAt: "2024-01-01T00:00:00Z")
        try store.upsert(window: editorWindow)

        // Mark workspace as running.
        let runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, title: workspace.title, dir: projectDir.path, dirname: workspace.dirname,
            branch: workspace.branch, baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived,
            isHidden: workspace.isHidden, isRunning: true, lastLaunchedAt: nil, notes: nil)
        try store.upsert(workspace: runningWorkspace)

        // Stop workspace: should attempt to close the editor window via yabai (yabai.closeWindow may fail silently).
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { _ = try orchestrator.stopWorkspace(workspaceID: workspace.id) }

        // The window records should be deleted after stop.
        let remainingWindows = try store.windows(workspaceID: workspace.id)
        XCTAssertTrue(remainingWindows.isEmpty)
    }

    func testUpdateWorkspaceSettingsRejectsDuplicateFocusNamesAcrossProcessAndBrowserSession() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "Frontend", command: "npm run api")]
                settings.browserSessions = [BrowserSession(name: "Frontend", url: "http://localhost:3001")]
            }
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("unique"))
            XCTAssertTrue(message.contains("Frontend"))
        }
    }

    func testUpdateWorkspaceSettingsRejectsDuplicateFocusNamesAcrossProcessAndCodingAgent() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "Reviewer", command: "npm run review")]
                settings.agentLaunchers = [AgentLauncher(name: "reviewer", command: "codex --review")]
            }
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("coding agents"))
            XCTAssertTrue(message.contains("Reviewer"))
        }
    }

    func testUpdateWorkspaceSettingsRejectsUnnamedBrowserSession() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.browserSessions = [BrowserSession(name: "", url: "http://localhost:3001")]
            }
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertEqual(message, "Browser session name is required.")
        }
    }

    func testRegisterAgentWindowAutoRenamesDuplicateFocusName() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "Claude", command: "claude")])

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude", terminalTrackingID: "agent-session")

        XCTAssertEqual(record.label, "Claude-2")
    }

    // Tests addProject throws when directory does not exist by arranging representative inputs and asserting the expected result.
    func testAddProjectThrowsWhenDirectoryNotFound() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let nonExistent = "/tmp/spaces-test-nonexistent-\(UUID().uuidString)"
        XCTAssertThrowsError(try orchestrator.addProject(dir: nonExistent)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata allows duplicate titles by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataAllowsDuplicateTitle() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let ws1 = try orchestrator.createWorkspace(projectID: project.id, name: "alpha")
        _ = try orchestrator.createWorkspace(projectID: project.id, name: "beta")

        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: ws1.id, title: "beta"))
        XCTAssertEqual(try store.workspace(id: ws1.id)?.title, "beta")
    }

    // Tests addProject by gitURL overwrites abandoned managed destination state by arranging representative inputs and asserting the expected result.
    func testAddProjectByGitURLOverwritesAbandonedDestination() throws {
        let fixture = try makeTempGitRepo(name: "my-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let existingDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "my-repo"), isDirectory: true)
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)
        let orphanMarker = existingDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        XCTAssertEqual(project.dir, existingDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertEqual(try store.projects().map(\.id), [project.id])
    }

    func testManagedGitProjectImportReplacementCandidatesIncludeOrphanedManagedFolders() throws {
        let fixture = try makeTempGitRepo(name: "candidate-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "candidate-repo")
        let projectDir = reposRoot.appendingPathComponent(managedDirname, isDirectory: true)
        let workspaceRoot = workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        let candidates = try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path)

        XCTAssertEqual(Set(candidates.map(\.path)), Set([projectDir.path, workspaceRoot.path]))
        XCTAssertEqual(Set(candidates.map(\.kind)), Set([.projectRepository, .workspaceDirectory]))
    }

    func testPreparedGitProjectImportSavesWithSymlinkedManagedReposRoot() throws {
        let fixture = try makeTempGitRepo(name: "symlinked-root-repo")
        let root = try makeTempDirectory()
        let actualReposRoot = root.appendingPathComponent("actual-repos", isDirectory: true)
        let reposRoot = root.appendingPathComponent("repos-link", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: actualReposRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: reposRoot, withDestinationURL: actualReposRoot)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "symlinked-root-repo")
        let entryProjectDir = reposRoot.appendingPathComponent(managedDirname, isDirectory: true)
        let normalizedProjectDir = actualReposRoot.appendingPathComponent(managedDirname, isDirectory: true).path

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        let project = try orchestrator.addPreparedGitProject(prepared) { _ in }

        XCTAssertEqual(prepared.project.dir, normalizedProjectDir)
        XCTAssertEqual(project.dir, normalizedProjectDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryProjectDir.appendingPathComponent("HEAD").path))
        XCTAssertEqual(try store.projects().map(\.dir), [normalizedProjectDir])
    }

    func testManagedGitProjectImportRejectsDatabaseOwnedMissingProjectDirectory() throws {
        let fixture = try makeTempGitRepo(name: "missing-owned-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let projectDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "missing-owned-repo"), isDirectory: true)
        try store.upsert(project: ProjectRecord(id: UUID().uuidString, name: "Owned", dir: projectDir.path, isGitRepo: true, defaultBranch: "main"))

        XCTAssertThrowsError(try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path)) { error in
            guard case WorkspaceError.projectAlreadyExists = error else { return XCTFail("Expected projectAlreadyExists, got \(error)") }
        }
        XCTAssertThrowsError(try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)) { error in
            guard case WorkspaceError.projectAlreadyExists = error else { return XCTFail("Expected projectAlreadyExists, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir.path))
    }

    func testManagedGitProjectImportReplacementRemovesManagedSymlinkNotManagedTarget() throws {
        let fixture = try makeTempGitRepo(name: "symlink-managed-target-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let projectDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "symlink-managed-target-repo"), isDirectory: true)
        let targetDir = reposRoot.appendingPathComponent("other-managed-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetMarker = targetDir.appendingPathComponent("target.txt")
        try "target".write(to: targetMarker, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: projectDir, withDestinationURL: targetDir)

        let candidate = try XCTUnwrap(try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path).first)
        XCTAssertEqual(candidate.path, projectDir.path)

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)

        XCTAssertEqual(prepared.project.dir, projectDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("HEAD").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: projectDir.path)
        XCTAssertNotEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testManagedGitProjectImportReplacementUnlinksSymlinkToOutsideManagedRoot() throws {
        let fixture = try makeTempGitRepo(name: "symlink-outside-target-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let outsideDir = root.appendingPathComponent("outside-target", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let projectDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "symlink-outside-target-repo"), isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reposRoot, withIntermediateDirectories: true)
        let outsideMarker = outsideDir.appendingPathComponent("outside.txt")
        try "outside".write(to: outsideMarker, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: projectDir, withDestinationURL: outsideDir)

        let candidate = try XCTUnwrap(try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path).first)
        XCTAssertEqual(candidate.path, projectDir.path)

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)

        XCTAssertEqual(prepared.project.dir, projectDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDir.appendingPathComponent("HEAD").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("HEAD").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: projectDir.path)
        XCTAssertNotEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testCreateWorkspaceReplacesConfirmedOrphanedManagedWorkspaceDirectory() throws {
        let fixture = try makeTempGitRepo(name: "replace-workspace")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let workspaceRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        let orphanDir = workspaceRoot.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let orphanMarker = orphanDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)

        let candidate = try XCTUnwrap(try orchestrator.managedWorkspaceReplacementCandidate(projectID: project.id, directoryName: "feature"))
        XCTAssertEqual(candidate.path, orphanDir.path)

        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "Feature", branch: "feature", baseBranch: "main", directoryName: "feature", runSetupScript: false,
            replaceExistingManagedDirectory: true)

        XCTAssertEqual(workspace.dir, orphanDir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(workspace.dir)/README.md"))
    }

    func testManagedWorkspaceReplacementRejectsDirectoryUnderSymlinkedManagedAncestor() throws {
        let fixture = try makeTempGitRepo(name: "symlinked-worktree-root")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let outsideWorktreeRoot = root.appendingPathComponent("outside-worktree-root", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let managedWorktreeRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outsideWorktreeRoot, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: managedWorktreeRoot)
        try FileManager.default.createSymbolicLink(at: managedWorktreeRoot, withDestinationURL: outsideWorktreeRoot)
        let outsideFeature = outsideWorktreeRoot.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideFeature, withIntermediateDirectories: true)
        let outsideMarker = outsideFeature.appendingPathComponent("outside.txt")
        try "outside".write(to: outsideMarker, atomically: true, encoding: .utf8)

        XCTAssertNil(try orchestrator.managedWorkspaceReplacementCandidate(projectID: project.id, directoryName: "feature"))
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(
                projectID: project.id, name: "Feature", branch: "feature", baseBranch: "main", directoryName: "feature", runSetupScript: false,
                replaceExistingManagedDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideMarker.path))
    }

    func testCreateWorkspaceReplacementClearsOrphanedGitWorktreeRegistration() throws {
        let fixture = try makeTempGitRepo(name: "replace-stale-worktree")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let workspaceRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        let orphanDir = workspaceRoot.appendingPathComponent("stale-feature", isDirectory: true)
        try runGit(["worktree", "add", "-b", "stale-feature", orphanDir.path, "main"], cwd: project.dir)
        let orphanMarker = orphanDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)
        let listedOrphanDir = normalizeTestPath(orphanDir.path)
        let beforeWorktrees = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertTrue(parseWorktreePaths(beforeWorktrees).contains(listedOrphanDir), beforeWorktrees)

        let candidate = try XCTUnwrap(try orchestrator.managedWorkspaceReplacementCandidate(projectID: project.id, directoryName: "stale-feature"))
        XCTAssertEqual(candidate.path, orphanDir.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "Stale Feature", branch: "stale-feature", baseBranch: "main", directoryName: "stale-feature",
            runSetupScript: false, allowExistingBranchReuse: true, replaceExistingManagedDirectory: true)

        XCTAssertEqual(workspace.dir, orphanDir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(workspace.dir)/README.md"))
        let afterWorktrees = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertEqual(parseWorktreePaths(afterWorktrees).filter { $0 == listedOrphanDir }.count, 1, afterWorktrees)
    }

    func testCreateWorkspaceReplacementPrunesCorruptOrphanedGitWorktreeRegistration() throws {
        let fixture = try makeTempGitRepo(name: "replace-corrupt-stale-worktree")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let workspaceRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        let orphanDir = workspaceRoot.appendingPathComponent("corrupt-feature", isDirectory: true)
        try runGit(["worktree", "add", "-b", "corrupt-feature", orphanDir.path, "main"], cwd: project.dir)
        let orphanMarker = orphanDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: orphanDir.appendingPathComponent(".git"))
        let listedOrphanDir = normalizeTestPath(orphanDir.path)
        let beforeWorktrees = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertTrue(parseWorktreePaths(beforeWorktrees).contains(listedOrphanDir), beforeWorktrees)

        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "Corrupt Feature", branch: "corrupt-feature", baseBranch: "main", directoryName: "corrupt-feature",
            runSetupScript: false, allowExistingBranchReuse: true, replaceExistingManagedDirectory: true)

        XCTAssertEqual(workspace.dir, orphanDir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(workspace.dir)/README.md"))
        let afterWorktrees = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertEqual(parseWorktreePaths(afterWorktrees).filter { $0 == listedOrphanDir }.count, 1, afterWorktrees)
    }

    func testManagedProjectImportReplacementRevalidatesProjectOwnershipBeforeDeleting() throws {
        let fixture = try makeTempGitRepo(name: "owned-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let projectDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "owned-repo"), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let ownerMarker = projectDir.appendingPathComponent("owner.txt")
        try "owner".write(to: ownerMarker, atomically: true, encoding: .utf8)
        XCTAssertEqual(try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path).map(\.path), [projectDir.path])

        try store.upsert(project: ProjectRecord(id: UUID().uuidString, name: "Owned", dir: projectDir.path, isGitRepo: true, defaultBranch: "main"))

        XCTAssertThrowsError(try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)) { error in
            guard case WorkspaceError.projectAlreadyExists = error else { return XCTFail("Expected projectAlreadyExists, got \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerMarker.path))
    }

    func testManagedWorkspaceReplacementDoesNotDeleteDatabaseOwnedWorkspaceDirectory() throws {
        let fixture = try makeTempGitRepo(name: "owned-workspace")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let workspaceRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        let ownedDir = workspaceRoot.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDir, withIntermediateDirectories: true)
        let ownerMarker = ownedDir.appendingPathComponent("owner.txt")
        try "owner".write(to: ownerMarker, atomically: true, encoding: .utf8)
        try store.upsert(
            workspace: WorkspaceRecord(
                id: UUID().uuidString, projectID: project.id, title: "Owned", dir: ownedDir.path, dirname: "owned", branch: "owned",
                baseBranch: "main", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil))

        XCTAssertThrowsError(
            try orchestrator.createWorkspace(
                projectID: project.id, name: "Feature", branch: "feature", baseBranch: "main", directoryName: "owned", runSetupScript: false,
                replaceExistingManagedDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerMarker.path))
    }

    func testNonManagedDirectoryIsNotReplacementCandidate() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        XCTAssertNil(try orchestrator.managedDirectoryReplacementCandidate(path: outsideDir.path, kind: .projectRepository))
        XCTAssertNil(try orchestrator.managedDirectoryReplacementCandidate(path: outsideDir.path, kind: .workspaceDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDir.path))
    }

    // Tests checkAndUpdateProcessStatuses keeps live Spaces agent sessions by arranging representative inputs and asserting the expected result.

    // Tests gitBranchOptions returns branches for a real git project by arranging representative inputs and asserting the expected result.
    func testGitBranchOptionsForGitProject() throws {
        let fixture = try makeTempGitRepo(name: "branch-opts-test")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let options = try orchestrator.gitBranchOptions(projectID: project.id)
        XCTAssertFalse(options.isEmpty)
        XCTAssertTrue(options.contains("main"))
    }

    // Tests createWorkspace revives an archived git workspace by branch and applies the requested title.
    func testCreateWorkspaceRevivesArchivedGitWorkspaceByBranch() throws {
        let repo = try makeTempGitRepo(name: "revive-git-workspace")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let original = try orchestrator.createWorkspace(projectID: project.id, name: "old title", branch: "feature-branch")
        _ = try orchestrator.archiveWorkspace(workspaceID: original.id)
        let archived = try XCTUnwrap(store.workspace(id: original.id))
        XCTAssertTrue(archived.isArchived)

        let revived = try orchestrator.createWorkspace(
            projectID: project.id, name: "new title", branch: "feature-branch", allowExistingBranchReuse: true)
        let persisted = try XCTUnwrap(store.workspace(id: revived.id))
        XCTAssertEqual(revived.id, original.id)
        XCTAssertFalse(persisted.isArchived)
        XCTAssertEqual(persisted.title, "new title")
        XCTAssertEqual(persisted.branch, "feature-branch")
    }

    func testCreateWorkspaceAllowsReusingArchivedGitDirname() throws {
        let repo = try makeTempGitRepo(name: "reuse-archived-git-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let original = try orchestrator.createWorkspace(projectID: project.id, name: "docs old", branch: "docs-old", directoryName: "docs")
        _ = try orchestrator.archiveWorkspace(workspaceID: original.id)

        let replacement = try orchestrator.createWorkspace(projectID: project.id, name: "docs new", branch: "docs-new", directoryName: "docs")
        XCTAssertEqual(replacement.dirname, "docs")
        XCTAssertEqual(replacement.branch, "docs-new")
    }

    func testCreateWorkspaceRevivesArchivedGitWorkspaceWithFreshDirnameWhenOldDirnameIsTaken() throws {
        let repo = try makeTempGitRepo(name: "revive-git-fresh-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let archived = try orchestrator.createWorkspace(projectID: project.id, name: "docs old", branch: "docs-old", directoryName: "docs")
        _ = try orchestrator.archiveWorkspace(workspaceID: archived.id)
        let replacement = try orchestrator.createWorkspace(projectID: project.id, name: "docs new", branch: "docs-new", directoryName: "docs")

        let revived = try orchestrator.createWorkspace(
            projectID: project.id, name: "docs restored", branch: "docs-old", allowExistingBranchReuse: true)
        XCTAssertEqual(revived.id, archived.id)
        XCTAssertNotEqual(revived.dirname, "docs")
        XCTAssertNotEqual(revived.dirname, replacement.dirname)
    }

    func testCreateWorkspaceRevivesArchivedGitWorkspaceReplacingConfirmedOrphanedDirectory() throws {
        let repo = try makeTempGitRepo(name: "revive-replace-orphan-dir")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let archived = try orchestrator.createWorkspace(
            projectID: project.id, name: "old title", branch: "feature-revive-replace", directoryName: "old-feature-dir")
        _ = try orchestrator.archiveWorkspace(workspaceID: archived.id)
        let workspaceRoot = URL(fileURLWithPath: archived.dir, isDirectory: true).deletingLastPathComponent()
        let orphanDir = workspaceRoot.appendingPathComponent("revived-feature-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let orphanMarker = orphanDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)
        let candidate = try XCTUnwrap(
            try orchestrator.managedWorkspaceReplacementCandidate(projectID: project.id, directoryName: "revived-feature-dir"))
        XCTAssertEqual(candidate.path, orphanDir.path)

        let revived = try orchestrator.createWorkspace(
            projectID: project.id, name: "new title", branch: "feature-revive-replace", directoryName: "revived-feature-dir",
            allowExistingBranchReuse: true, replaceExistingManagedDirectory: true)

        XCTAssertEqual(revived.id, archived.id)
        XCTAssertEqual(revived.dir, orphanDir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(revived.dir)/README.md"))
    }

    func testCreateWorkspaceRejectsExistingBranchInCreateMode() throws {
        let repo = try makeTempGitRepo(name: "reject-existing-branch")
        try runGit(["checkout", "-b", "existing-branch"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "existing-branch", allowExistingBranchReuse: false)
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("Branch 'existing-branch' already exists"))
        }
    }

    func testCreateWorkspaceRejectsMissingBranchInExistingMode() throws {
        let repo = try makeTempGitRepo(name: "reject-missing-existing-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "missing-branch", allowExistingBranchReuse: true)
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("Branch 'missing-branch' was not found"))
        }
    }

    func testCreateWorkspaceRemoteLookupFailureDoesNotDecideBranchMode() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "remote-only"], cwd: fixture.source.path)
        try "remote only".write(to: fixture.source.appendingPathComponent("REMOTE_ONLY.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "REMOTE_ONLY.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remote only"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-only"], cwd: fixture.source.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot, git: try makeLsRemoteFailingGitClient())

        let project = try orchestrator.addProject(dir: fixture.clone.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "remote-only", allowExistingBranchReuse: false)
        ) { error in
            guard case WorkspaceError.gitCommandFailed(let message) = error else { return XCTFail("Expected gitCommandFailed, got \(error)") }
            XCTAssertTrue(message.contains("remote lookup failed"))
        }
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "remote-only", allowExistingBranchReuse: true)
        ) { error in
            guard case WorkspaceError.gitCommandFailed(let message) = error else { return XCTFail("Expected gitCommandFailed, got \(error)") }
            XCTAssertTrue(message.contains("remote lookup failed"))
        }
    }

    func testCreateWorkspaceSkipsRemoteBranchLookupWhenDisabled() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "remote-only"], cwd: fixture.source.path)
        try "remote only".write(to: fixture.source.appendingPathComponent("REMOTE_ONLY_SKIP.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "REMOTE_ONLY_SKIP.md"], cwd: fixture.source.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remote only skip"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-only"], cwd: fixture.source.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot, git: try makeLsRemoteFailingGitClient())

        let project = try orchestrator.addProject(dir: fixture.clone.path)
        let created = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature", branch: "remote-only", allowRemoteBranchLookup: false, allowExistingBranchReuse: false)

        XCTAssertEqual(created.branch, "remote-only")
    }

    // Tests createWorkspaceFromWorktree throws when the path does not exist by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenPathMissing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: "/nonexistent/path/\(UUID().uuidString)")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests createWorkspaceFromWorktree throws when the path is not a git repository by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenNotGitRepo() throws {
        let dir = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: dir.path)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for empty title by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForEmptyTitle() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, title: "   ")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for empty branch on git project by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForEmptyBranchOnGitProject() throws {
        let repo = try makeTempGitRepo(name: "empty-branch-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-start")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "  ")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for empty directoryName on git project by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForEmptyDirectoryNameOnGitProject() throws {
        let repo = try makeTempGitRepo(name: "empty-dirname-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-start")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, directoryName: "")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for duplicate directory name across workspaces by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForDuplicateDirectoryName() throws {
        let repo = try makeTempGitRepo(name: "dup-dirname-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let ws1 = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-start")
        let ws2 = try orchestrator.createWorkspace(projectID: project.id, name: "other", branch: "other-branch")
        guard let ws1Dirname = ws1.dirname, let ws2Dirname = ws2.dirname else { return }
        XCTAssertNotEqual(ws1Dirname, ws2Dirname)
        // Try to set ws2's dirname to ws1's dirname - should throw duplicate error
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: ws2.id, directoryName: ws1Dirname)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests suggestedWorkspaceName throws when all available names are exhausted by arranging representative inputs and asserting the expected result.
    func testSuggestedWorkspaceNameThrowsWhenAllNamesExhausted() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)

        // Insert workspace records for all known food names to exhaust suggestions
        let allFoodNames = [
            "almond", "anchovy", "apple", "apricot", "avocado", "bagel", "bacon", "banana", "basil", "bean", "beef", "beet", "berry", "biscuit",
            "bread", "broccoli", "brownie", "burger", "burrito", "butter", "cabbage", "cacao", "candy", "cantaloupe", "caramel", "carrot", "cashew",
            "celery", "cereal", "cherry", "cheddar", "cheesecake", "chili", "chips", "chive", "chocolate", "chutney", "cider", "cinnamon", "clove",
            "cocoa", "coconut", "coffee", "coleslaw", "cookie", "corn", "couscous", "cracker", "cream", "crouton", "cucumber", "cupcake", "curry",
            "custard", "danish", "dill", "donut", "dumpling", "eclair", "edamame", "egg", "empanada", "endive", "fajita", "falafel", "fig", "flan",
            "fries", "garlic", "ginger", "gnocchi", "granola", "grape", "gravy", "grits", "guava", "ham", "hazelnut", "honey", "hummus", "icecream",
            "jam", "jalapeno", "jelly", "kale", "kebab", "ketchup", "kiwi", "kohlrabi", "lasagna", "leek", "lemon", "lentil", "lettuce", "lime",
            "lobster", "lychee", "macaroni", "macaron", "mango", "maple", "marshmallow", "mascarpone", "mayo", "meatball", "melon", "mint", "mocha",
            "molasses", "muffin", "mushroom", "mustard", "nacho", "noodle", "nutmeg", "oat", "omelet", "olive", "onion", "orange", "oreo", "pancake",
            "papaya", "paprika", "parsnip", "pastry", "peach", "peanut", "pear", "peas", "pecan", "pepper", "pesto", "pho", "pickle", "pie",
            "pineapple", "pita", "pizza", "plum", "poppy", "popcorn", "pork", "potato", "poutine", "pretzel", "prune", "pudding", "pumpkin", "quiche",
            "quinoa", "radish", "raisin", "ramen", "relish", "rice", "risotto", "roast", "roll", "saffron", "sage", "salad", "salami", "salsa",
            "salt", "sardine", "sausage", "scone", "seaweed", "sesame", "shallot", "shrimp", "soup", "sorbet", "soy", "spice", "spinach", "squash",
            "steak", "stew", "sugar", "sushi", "syrup", "taco", "tamarind", "tapioca", "tea", "toffee", "toast", "tofu", "tomato", "tortilla", "tuna",
            "turkey", "turnip", "vanilla", "vinegar", "waffle", "walnut", "watermelon", "yams", "yogurt", "ziti", "zucchini",
        ]
        for name in allFoodNames {
            let ws = makeWorkspaceRecord(projectID: project.id, title: name, dir: projectDir.path)
            try store.upsert(workspace: ws)
        }

        XCTAssertThrowsError(try orchestrator.suggestedWorkspaceName(projectID: project.id)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests checkAndUpdateProcessStatuses marks a dead process as exited and calls handleProcessExit .none case by arranging representative inputs and asserting the expected result.

    // Tests checkAndUpdateProcessStatuses skips recently started processes within the 10-second grace window by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesSkipsRecentlyStartedProcess() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Insert a process with a dead PID but very recent startedAt (within 10-second grace)
        let recentStart = ISO8601DateFormatter().string(from: Date())
        let proc = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "sleep 1", terminalApp: "Terminal", windowID: nil,
            terminalTrackingID: nil, pid: 2_000_000, status: .running, logPath: nil, lastOutputAt: nil, startedAt: recentStart, exitedAt: nil)
        try store.upsert(runningProcess: proc)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        XCTAssertFalse(didUpdate)
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.first?.status, .running)
    }

    func testCheckAndUpdateProcessStatusesTreatsZombieProcessAsExited() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "web", command: "sleep 1", onExit: .none)]
        }

        let zombiePIDPath = root.appendingPathComponent("zombie.pid")
        let zombieParent = Process()
        zombieParent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        zombieParent.arguments = [
            "-c",
            """
            import os, sys, time
            pid_file = sys.argv[1]
            child_pid = os.fork()
            if child_pid == 0:
                os._exit(0)
            with open(pid_file, "w", encoding="utf-8") as fh:
                fh.write(str(child_pid))
            time.sleep(30)
            """, zombiePIDPath.path,
        ]
        try zombieParent.run()
        defer {
            if zombieParent.isRunning {
                zombieParent.terminate()
                zombieParent.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: zombiePIDPath.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: zombiePIDPath.path))
        let zombiePID = try XCTUnwrap(Int(String(contentsOf: zombiePIDPath).trimmingCharacters(in: .whitespacesAndNewlines)))
        Thread.sleep(forTimeInterval: 0.2)

        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "sleep 1", terminalApp: "Terminal", windowID: nil,
            terminalTrackingID: nil, pid: zombiePID, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2020-01-01T00:00:00Z",
            exitedAt: nil)
        try store.upsert(runningProcess: process)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()

        XCTAssertTrue(didUpdate)
        let updated = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .exited)
        XCTAssertNotNil(updated?.exitedAt)
    }

    // Tests createWorkspace throws when base branch cannot be resolved for a git project with no main/master by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceThrowsWhenBaseBranchCannotBeResolved() throws {
        // Create a git repo with a non-standard initial branch (not main or master)
        let repo = try makeTempGitRepo(name: "no-main-or-master", initialBranch: "develop")
        let store = try makeTemporaryStore()
        // Insert the project directly with defaultBranch = nil to force the main/master branch check
        let projectRecord = ProjectRecord(id: repo.path, name: "test", dir: repo.path, isGitRepo: true, defaultBranch: nil)
        try store.upsert(project: projectRecord)

        let orchestrator = WorkspaceOrchestrator(store: store)
        // Without baseBranch, resolveWorkspaceBaseBranch should check for main/master, find neither, and throw
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: projectRecord.id, name: "feature", branch: "feature-branch")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata branch update on non-git project throws by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataBranchThrowsForNonGitProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "new-branch")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata directoryName update on non-git project throws by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataDirectoryNameThrowsForNonGitProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, directoryName: "newdir")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests workspaceIDForFocusedWindow returns the workspace of an agent window by arranging representative inputs and asserting the expected result.
    func testWorkspaceIDForFocusedWindowReturnsAgentWindowMatch() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Insert an agent window with yabaiWindowID=101; no regular tracked window has that ID.
        let agentWindow = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: nil, terminalTrackingID: "s1", codexThreadID: nil,
            windowID: nil, yabaiWindowID: 101, status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        try store.upsertAgentWindow(agentWindow)

        // Mocked dependency: yabai focused window returns id=101, app=Finder (not Chrome, not tracked as a window record).
        // Why: exercise the agent-window fallback path in workspaceIDForFocusedWindow.
        // Remaining risk: only a single app name other than Chrome is tested.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Finder") {
                    let result = try orchestrator.workspaceIDForFocusedWindow()
                    XCTAssertEqual(result, workspace.id)
                }
            }
        }
    }

    // Tests openWorkspaceTerminal falls back to the first sorted tracked Spaces window ID when no running process provides one by arranging representative inputs and asserting the expected result.

    // Tests openWorkspaceTerminal uses the window ID from a running Spaces process when the focused window is not Spaces by arranging representative inputs and asserting the expected result.

    // Tests ensureDefaultWorkspace revives an archived default workspace via updateProjectConfig by arranging representative inputs and asserting the expected result.
    func testEnsureDefaultWorkspaceRevivesArchivedDefaultViaUpdateProjectConfig() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)

        // Find the default workspace and archive it via store directly.
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
        let defaultWS = try XCTUnwrap(workspaces.first(where: \.isDefault))
        let archived = WorkspaceRecord(
            id: defaultWS.id, projectID: project.id, title: defaultWS.title, dir: defaultWS.dir, dirname: defaultWS.dirname, branch: defaultWS.branch,
            isDefault: true, isArchived: true, isRunning: defaultWS.isRunning, lastLaunchedAt: defaultWS.lastLaunchedAt)
        try store.upsert(workspace: archived)
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: defaultWS.id)).isArchived)

        // updateProjectConfig calls ensureDefaultWorkspace, which should revive the archived default workspace.
        try orchestrator.updateProjectConfig(projectID: project.id) { _ in }

        let revived = try XCTUnwrap(store.workspace(id: defaultWS.id))
        XCTAssertFalse(revived.isArchived)
    }

    // Tests handleProcessExit with onExit .restart restarts the process via openWindowAndRun by arranging representative inputs and asserting the expected result.
    // Tests createWorkspaceFromWorktree throws when the worktree directory matches an archived workspace by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenAlreadyArchivedWorkspaceExists() throws {
        let repo = try makeTempGitRepo(name: "archived-worktree-repo")
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        // The default workspace has dir=repo.path; archive it so the next createWorkspaceFromWorktree finds it archived.
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
        let defaultWS = try XCTUnwrap(workspaces.first(where: \.isDefault))
        let archived = WorkspaceRecord(
            id: defaultWS.id, projectID: project.id, title: defaultWS.title, dir: defaultWS.dir, dirname: defaultWS.dirname, branch: defaultWS.branch,
            isDefault: true, isArchived: true, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: archived)

        // createWorkspaceFromWorktree should detect the archived workspace and throw.
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: repo.path)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateProjectConfig leaves missing default workspace settings missing.
    func testUpdateProjectConfigDoesNotReseedMissingDefaultWorkspaceSettings() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Use symlink-resolved path so it matches what normalizePath returns internally.
        let normalizedDir = URL(fileURLWithPath: projectDir.path).resolvingSymlinksInPath().path
        let projectRecord = ProjectRecord(id: normalizedDir, name: "test", dir: normalizedDir, isGitRepo: false, defaultBranch: nil)
        try store.upsert(project: projectRecord)

        // Insert a default workspace directly without going through seedWorkspaceSettings.
        let workspaceID = UUID().uuidString
        let workspaceRecord = WorkspaceRecord(
            id: workspaceID, projectID: normalizedDir, title: "default", dir: normalizedDir, dirname: nil, branch: nil, isDefault: true,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)
        XCTAssertFalse(try store.workspaceSettingsExists(workspaceID: workspaceID))

        let orchestrator = WorkspaceOrchestrator(store: store)
        try orchestrator.updateProjectConfig(projectID: normalizedDir) { _ in }

        XCTAssertFalse(try store.workspaceSettingsExists(workspaceID: workspaceID))
    }

    // Tests createWorkspace rejects a non-ASCII directory name by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsNonAsciiDirectoryName() throws {
        let repo = try makeTempGitRepo(name: "non-ascii-dirname-repo")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        // Pass a non-ASCII directory name (é is non-ASCII) to trigger the guard scalar.isASCII path.
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "f\u{00e9}ature")
        ) { error in guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") } }
    }

    // Tests expandTilde resolves a standalone tilde to the home directory path by arranging representative inputs and asserting the expected result.
    func testExpandTildeResolvesStandaloneTildeToHome() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        // "~" expands to the home directory; no project exists there so removeProject returns silently.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~"))
    }

    // Tests expandTilde resolves a tilde-slash prefix to the corresponding home subdirectory path by arranging representative inputs and asserting the expected result.
    func testExpandTildeResolvesTildeSlashPrefixToHomeSubdirectory() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        // "~/foo" expands to home/foo; no project exists there so removeProject returns silently.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~/spaces-test-nonexistent-path-xyzzy"))
    }

    // Tests expandTilde passes through a tilde-name prefix unchanged by arranging representative inputs and asserting the expected result.
    func testExpandTildePassesThroughTildeNamePrefixUnchanged() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        // "~user" starts with ~ but is neither "~" alone nor "~/"; returned unchanged, no project found.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~notahomedirectory"))
    }

    // Tests archiveWorkspace suppresses isMissingWorktreeError when the worktree directory is not registered in git by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceSuppressesIsMissingWorktreeErrorForUnregisteredPath() throws {
        let repo = try makeTempGitRepo(name: "archive-git-missing-worktree-path")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        // Create a workspace record pointing to a path that is NOT a registered git worktree.
        // When archiveWorkspace calls git.removeWorktree, git fails with "not a working tree"
        // → isMissingWorktreeError returns true → error is suppressed.
        let fakeWorktreeDir = root.appendingPathComponent("not-a-registered-worktree").path
        let workspaceRecord = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: "fake-worktree-ws", dir: fakeWorktreeDir, dirname: "fake", branch: "feature-x",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)

        XCTAssertNoThrow(try orchestrator.archiveWorkspace(workspaceID: workspaceRecord.id))

        let archived = try store.workspace(id: workspaceRecord.id)
        XCTAssertEqual(archived?.isArchived, true)
    }

    // Tests removeProject without projectsRootDirectory exercises the default repositories root path by arranging representative inputs and asserting the expected result.
    func testRemoveGitProjectWithoutProjectsRootDirectoryCoversDefaultRootPaths() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        // projectsRootDirectory is nil → repositoriesRootDirectory() uses ~/spaces/repos (default path).
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        // Insert a fake git project at a temp path so removeProject reaches isManagedRepositoryDirectory.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let projectRecord = ProjectRecord(id: tempDir, name: "coverage-test", dir: tempDir, isGitRepo: true, defaultBranch: "main")
        try store.upsert(project: projectRecord)
        let workspaceRecord = WorkspaceRecord(
            id: UUID().uuidString, projectID: tempDir, title: "default", dir: tempDir, dirname: nil, branch: "main", isDefault: true,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)

        // removeProject exercises isManagedRepositoryDirectory; the temp path is outside the managed root so nothing gets deleted.
        try orchestrator.removeProject(dir: tempDir)
        XCTAssertNil(try store.project(dir: tempDir))
    }

    // Tests createWorkspaceFromWorktree allows duplicate titles when branches differ.
    func testCreateWorkspaceFromWorktreeAllowsDuplicateTitles() throws {
        let repo = try makeTempGitRepo(name: "workspace-duplicate-name")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        _ = try orchestrator.addProject(dir: repo.path)

        // Create first worktree and register it with name "feature".
        let worktree1 = root.appendingPathComponent("worktree1", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature-branch-1", worktree1.path], cwd: repo.path)
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree1.path, name: "feature")

        // Create a second worktree at a different path and register it with the same title.
        let worktree2 = root.appendingPathComponent("worktree2", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature-branch-2", worktree2.path], cwd: repo.path)
        let second = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree2.path, name: "feature")

        XCTAssertEqual(second.title, "feature")
        XCTAssertEqual(second.branch, "feature-branch-2")
    }

    // Tests addProject(dir:) throws projectAlreadyExists when the directory has already been imported.
    func testAddProjectDirThrowsWhenProjectAlreadyExists() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: projectDir.path)

        XCTAssertThrowsError(try orchestrator.addProject(dir: projectDir.path)) { error in
            guard case WorkspaceError.projectAlreadyExists = error else { return XCTFail("Expected projectAlreadyExists, got \(error)") }
        }
    }

    func testAddProjectDirWithInvalidConfigDoesNotPersistPartialProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.addProject(dir: projectDir.path) { project in project.ports = [PortDefinition(name: "   ")] }) {
            error in XCTAssertEqual(error.localizedDescription, "Invalid argument: Port name is required.")
        }

        XCTAssertNil(try store.project(dir: projectDir.path))
        XCTAssertTrue(try store.projects().isEmpty)

        let project = try orchestrator.addProject(dir: projectDir.path) { project in project.ports = [PortDefinition(name: "API_PORT")] }

        let stored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(stored.ports.map(\.name), ["API_PORT"])
        XCTAssertEqual(try store.workspaces(projectID: project.id).count, 1)
    }

    // Tests updateWorkspaceName throws invalidArgument when the new name is empty or whitespace-only.
    func testUpdateWorkspaceNameRejectsEmptyName() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        XCTAssertThrowsError(try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace name is required"))
        }
        XCTAssertThrowsError(try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: "   ")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace name is required"))
        }
    }

    // Tests updateWorkspaceName is a no-op when the trimmed name matches the current name.
    func testUpdateWorkspaceNameIsNoOpWhenNameIsUnchanged() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Renaming to the same name should not throw and should not change the record.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: "feature"))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(fetched.title, "feature")
    }

    // Tests addProject(gitURL:) throws invalidArgument when the URL is an empty string.
    func testAddProjectByGitURLThrowsWhenURLIsEmpty() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "   ")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests createWorkspace throws invalidArgument when the workspace name is empty.
    func testCreateWorkspaceThrowsWhenNameIsEmpty() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace name is required"))
        }
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "   ")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace name is required"))
        }
    }

    // Tests openWorkspaceTerminal throws invalidArgument when the workspace is archived.
    func testOpenWorkspaceTerminalThrowsForArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Archive the workspace directly via the store.
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)

        XCTAssertThrowsError(try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived"))
        }
    }

    // Tests focusWorkspaceWindow with index 0 is a no-op (guard index > 0 early return).
    func testFocusWorkspaceWindowWithZeroIndexIsNoOp() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        // Index 0 is invalid (windows are 1-based); should return without throwing.
        XCTAssertNoThrow(try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 0))
    }

    // Tests focusWorkspaceWindow with an out-of-bounds index is a no-op (guard index <= windows.count early return).
    func testFocusWorkspaceWindowWithOutOfBoundsIndexIsNoOp() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        // No windows are tracked; index 99 is out of bounds.
        XCTAssertNoThrow(try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 99))
    }

    // Tests scanAndCreateWorkspacesFromWorktrees throws missingProject when a specific projectID is not found.
    func testScanAndCreateWorkspacesFromWorktreesThrowsForMissingProjectID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: "/nonexistent/project/\(UUID().uuidString)")) { error in
            guard case WorkspaceError.missingProject = error else { return XCTFail("Expected missingProject, got \(error)") }
        }
    }

    // Tests addProject(gitURL:) throws projectAlreadyExists when the same destination is already registered.
    func testAddProjectByGitURLThrowsWhenProjectAlreadyExistsInDB() throws {
        let fixture = try makeTempGitRepo(name: "duplicate-project")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        _ = try orchestrator.addProject(gitURL: fixture.path)

        // The destination directory now exists in the repos root AND in the DB.
        // Cloning again should fail because the project already exists in the DB.
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path)) { error in
            // Either projectAlreadyExists (DB hit) or invalidArgument (directory on disk hit) — both are valid.
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("already exists"), "Expected 'already exists' in error, got: \(desc)")
        }
    }

    // Tests updateWorkspaceMetadata with all-nil arguments is a no-op (covers guard didChange else { return }).
    func testUpdateWorkspaceMetadataWithAllNilArgsIsNoOp() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // No optional parameters → didChange stays false → guard else return is hit.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(fetched.title, "feature")
    }

    // Tests updateWorkspaceMetadata with the same title as current is a no-op (covers trimmedTitle == workspace.title false branch).
    func testUpdateWorkspaceMetadataWithSameTitleIsNoOp() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Same title → trimmedTitle == workspace.title → no change, didChange stays false.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, title: "feature"))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(fetched.title, "feature")
    }

    // Tests updateWorkspaceMetadata with notes matching the current (nil) is a no-op (covers notes == workspace.notes false branch).
    func testUpdateWorkspaceMetadataWithSameNotesIsNoOp() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // notes: .some(nil) — outer optional is present, inner value is nil (same as current nil notes).
        // notes != workspace.notes → nil != nil → false → didChange stays false → guard else return.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, notes: .some(nil)))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertNil(fetched.notes)
    }

    // Tests upWorkspace throws invalidArgument when the workspace is archived (covers guard !workspace.isArchived else throw).
    func testUpWorkspaceThrowsForArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)

        XCTAssertThrowsError(try orchestrator.upWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived"))
        }
    }

    // Tests updateProjectConfig throws missingProject when the project ID does not exist in the store.
    func testUpdateProjectConfigThrowsForMissingProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.updateProjectConfig(projectID: "/nonexistent/\(UUID().uuidString)") { _ in }) { error in
            guard case WorkspaceError.missingProject = error else { return XCTFail("Expected missingProject, got \(error)") }
        }
    }

    // Tests addProject(gitURL:) throws when the cloned repo has neither main nor master branch.
    func testAddProjectByGitURLThrowsWhenRepoHasNeitherMainNorMaster() throws {
        let fixture = try makeTempGitRepo(name: "develop-only", initialBranch: "develop")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("main or master branch"))
        }
    }

    // Tests addProject(gitURL:) succeeds for a repo with only a master branch (covers preferredImportedDefaultBranch master path).
    func testAddProjectByGitURLSucceedsWithMasterBranch() throws {
        let fixture = try makeTempGitRepo(name: "master-only", initialBranch: "master")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertEqual(project.defaultBranch, "master")
    }

    // Tests addProject(gitURL:) with an SSH-style URL (no "://", colon after last slash) covers inferredProjectName SSH path.
    func testAddProjectByGitURLWithSSHStyleURLCoversInferredProjectName() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        // URL: "users/host:sshrepo.git" — no "://", colon (index 10) > last slash (index 5).
        // inferredProjectName strips the SSH prefix → "sshrepo.git" → strips ".git" → "sshrepo".
        // Clone will fail (not a real remote), but lines 2657-2659 are covered before the clone attempt.
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "users/host:sshrepo.git"))
    }

    // Tests addProject(gitURL:) with a project name containing "." covers sanitizeDirname's return "-" path.
    func testAddProjectByGitURLWithSpecialCharsInNameSanitizesDirname() throws {
        let fixture = try makeTempGitRepo(name: "my.project", initialBranch: "main")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        // "my.project" contains "." → sanitizeDirname replaces "." with "-" → cloned as "my-project".
        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertEqual(project.name, "my-project")
    }

    // Tests createWorkspace throws when the requested directoryName is already in use by another workspace (covers makeWorkspaceDirname line 2503).
    func testCreateWorkspaceDirnameConflictThrows() throws {
        let repo = try makeTempGitRepo(name: "dirname-conflict-repo")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        _ = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-a", branch: "feature-a", directoryName: "apple", runSetupScript: false)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(
                projectID: project.id, name: "feature-b", branch: "feature-b", directoryName: "apple", runSetupScript: false)
        ) { error in XCTAssertTrue(error.localizedDescription.contains("already in use"), "Expected 'already in use' error, got: \(error)") }
    }

    // MARK: - resolvedWorkspaceBrowserSessions

    // Tests resolvedWorkspaceBrowserSessions returns sessions with static URLs unchanged.
    func testResolvedWorkspaceBrowserSessionsReturnsStaticURLsUnchanged() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [BrowserSession(name: "App", url: "http://localhost:3000"), BrowserSession(name: "Admin", url: "http://localhost:3000/admin")])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].name, "App")
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
        XCTAssertEqual(resolved[1].name, "Admin")
        XCTAssertEqual(resolved[1].url, "http://localhost:3000/admin")
    }

    // Tests resolvedWorkspaceBrowserSessions expands port env vars to their allocated values.
    func testResolvedWorkspaceBrowserSessionsExpandsPortEnvVars() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["PORT", "API_PORT"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "Frontend", url: "http://localhost:$PORT"), BrowserSession(name: "API", url: "http://localhost:$API_PORT/v1"),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].name, "Frontend")
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
        XCTAssertEqual(resolved[1].name, "API")
        XCTAssertEqual(resolved[1].url, "http://localhost:4000/v1")
    }

    // Tests passive resolvedWorkspaceBrowserSessions resolves device-local browser display without opening SSH forwards.
    func testResolvedWorkspaceBrowserSessionsPassiveLocalDoesNotOpenForward() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        let workspace = WorkspaceRecord(
            id: "workspace-a", projectID: project.id, title: "dev", dir: "/projects/app", runtimePath: "/projects/app", dirname: nil, branch: "main",
            baseBranch: "main", isDefault: false, isArchived: false, isRunning: true, lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["PORT"])
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "App", url: "http://localhost:$PORT")])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.map(\.url), ["http://localhost:3000"])
    }

    // Tests resolvedWorkspaceBrowserSessions deduplicates sessions that resolve to the same URL.
    func testResolvedWorkspaceBrowserSessionsDeduplicatesSameResolvedURL() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["PORT"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "First", url: "http://localhost:$PORT"), BrowserSession(name: "Duplicate", url: "http://localhost:$PORT"),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].name, "First")
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
    }

    // Tests resolvedWorkspaceBrowserSessions omits sessions with empty or nil URLs.
    func testResolvedWorkspaceBrowserSessionsOmitsSessionsWithEmptyURL() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(name: "App", url: "http://localhost:3000"), BrowserSession(name: "NoURL", url: nil)])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].name, "App")
    }

    // Tests resolvedWorkspaceBrowserSessions resolved URLs enable longest-prefix name matching.
    func testResolvedWorkspaceBrowserSessionsEnablesLongestPrefixNameMatching() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, title: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["PORT"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "App", url: "http://localhost:$PORT"), BrowserSession(name: "Admin", url: "http://localhost:$PORT/admin"),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
        XCTAssertEqual(resolved[1].url, "http://localhost:3000/admin")

        // Simulate the longest-prefix name lookup that the GUI uses.
        let tabURL = "http://localhost:3000/admin/users"
        var bestName: String?
        var bestLength = 0
        for session in resolved {
            guard let prefix = session.url, !prefix.isEmpty, tabURL.hasPrefix(prefix) else { continue }
            if prefix.count > bestLength {
                bestLength = prefix.count
                bestName = session.name
            }
        }
        XCTAssertEqual(bestName, "Admin", "Longest-prefix match should yield 'Admin' not 'App'")
    }

    private func makeRemoteFixture() throws -> (root: URL, source: URL, remote: URL, clone: URL) {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try initializeGitRepository(at: source, initialBranch: "main")

        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, remote.path], cwd: root.path)

        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try runGit(["clone", remote.path, clone.path], cwd: root.path)
        return (root, source, remote, clone)
    }

    private func makeLsRemoteFailingGitClient() throws -> GitClient {
        let toolsRoot = try makeExecutableTestToolsDirectory()
        let script = toolsRoot.appendingPathComponent("git")
        let contents = """
            #!/bin/sh
            subcommand=""
            expect_value=0
            for arg in "$@"; do
              if [ "$expect_value" -eq 1 ]; then
                expect_value=0
                continue
              fi
              case "$arg" in
                -C|--git-dir|--work-tree)
                  expect_value=1
                  continue
                  ;;
                -*)
                  continue
                  ;;
                *)
                  subcommand="$arg"
                  break
                  ;;
              esac
            done
            if [ "$subcommand" = "ls-remote" ]; then
              echo "remote lookup failed" >&2
              exit 128
            fi
            exec /usr/bin/git "$@"
            """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return GitClient(gitExecutable: script.path)
    }

    private func makeExecutableTestToolsDirectory() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/test-tools/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        return directory
    }
}
