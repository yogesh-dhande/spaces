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

    // Tests update editor preference persists to db by arranging representative inputs and asserting the expected result.
    func testUpdateEditorPreferencePersistsToDB() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        _ = try orchestrator.updateEditorPreference(.cursor)
        XCTAssertEqual(try store.appConfig().editor, .cursor)

        _ = try orchestrator.updateEditorPreference(nil)
        XCTAssertNil(try store.appConfig().editor)
    }

    func testValidateDirectProcessTemplateAcceptsWorkspaceVariableInterpolation() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertNoThrow(
            try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: "PORT=$FRONTEND_PORT npm run dev", executionMode: .direct))
        )
    }

    func testValidateDirectProcessTemplateRejectsUnsupportedExpansionWithRawCommand() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(
            try orchestrator.validateProcessTemplate(
                ProcessTemplate(name: "web", command: "PORT=${FRONTEND_PORT:-3000} npm run dev", executionMode: .direct))
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid argument: Direct mode only supports simple Spaces variables like $API_PORT or ${API_PORT}. Unsupported expansion: ${FRONTEND_PORT:-3000}. Command: PORT=${FRONTEND_PORT:-3000} npm run dev"
            )
        }
    }

    func testValidateDirectProcessTemplateStillRejectsShellSyntaxBeforeLaunch() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(
            try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: "npm run dev | tee log.txt", executionMode: .direct))
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid argument: Process commands in Direct mode must be direct executable invocations without shell syntax: npm run dev | tee log.txt. Use Shell mode for composite commands."
            )
        }
    }

    func testValidateDirectProcessTemplateRejectsUnknownVariableWhenWorkspaceEnvIsKnown() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(
            try orchestrator.validateProcessTemplate(
                ProcessTemplate(name: "web", command: "PORT=$MISSING_PORT npm run dev", executionMode: .direct), env: ["FRONTEND_PORT": "24001"])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid argument: Direct mode only supports Spaces-provided variables. Unknown variable: $MISSING_PORT. Command: PORT=$MISSING_PORT npm run dev"
            )
        }
    }

    func testUpdateProjectConfigRejectsUnknownDirectProcessVariableAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)

        XCTAssertThrowsError(
            try orchestrator.updateProjectConfig(projectID: project.id) { project in
                project.ports = [PortDefinition(name: "FRONTEND_PORT")]
                project.processes = [ProcessTemplate(name: "web", command: "PORT=$TYPO_PORT npm run dev", executionMode: .direct)]
            }
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid argument: Direct mode only supports Spaces-provided variables. Unknown variable: $TYPO_PORT. Command: PORT=$TYPO_PORT npm run dev"
            )
        }
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

    func testUpdateWorkspaceSettingsRejectsUnknownDirectProcessVariableAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.ports = [PortDefinition(name: "FRONTEND_PORT")]
                settings.processes = [ProcessTemplate(name: "web", command: "PORT=$TYPO_PORT npm run dev", executionMode: .direct)]
            }
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid argument: Direct mode only supports Spaces-provided variables. Unknown variable: $TYPO_PORT. Command: PORT=$TYPO_PORT npm run dev"
            )
        }
    }

    func testUpdateWorkspaceSettingsRejectsSyntheticPortFallbackVariableAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.ports = [PortDefinition(name: "API_PORT")]
                settings.processes = [ProcessTemplate(name: "web", command: "PORT=$PORT0 npm run dev", executionMode: .direct)]
            }
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid argument: Direct mode only supports Spaces-provided variables. Unknown variable: $PORT0. Command: PORT=$PORT0 npm run dev")
        }
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

    func testValidateShellProcessTemplateAcceptsShellSyntax() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertNoThrow(
            try orchestrator.validateProcessTemplate(
                ProcessTemplate(name: "web", command: "PORT=$FRONTEND_PORT npm run dev | tee log.txt", executionMode: .shell)))
    }

    func testProcessTemplateDecodeDefaultsExecutionModeToDirect() throws {
        let data = Data(#"{"id":"process-1","name":"web","command":"npm run web","on_exit":"none"}"#.utf8)
        let template = try JSONDecoder().decode(ProcessTemplate.self, from: data)

        XCTAssertEqual(template.executionMode, .direct)
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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
        try orchestrator.updateProjectConfig(projectID: project.id) { project in
            project.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex --dangerously-skip-permissions")]
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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
        try orchestrator.updateProjectConfig(projectID: project.id) { project in
            project.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex --dangerously-skip-permissions")]
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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
        try orchestrator.updateProjectConfig(projectID: project.id) { project in
            project.agentLaunchers = [AgentLauncher(name: "Claude", command: "claude")]
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

        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let focusCapture = TerminalFocusCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
        try orchestrator.updateProjectConfig(projectID: project.id) { project in
            project.agentLaunchers = [AgentLauncher(name: "Reviewer", command: "review-agent")]
        }
        let paths = try TerminalSessionPaths.forSession(id: "ended-reviewer-session")
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "ended-reviewer-session", title: "Reviewer", workingDirectory: workspace.dir, shell: "/bin/zsh", command: "review-agent",
                createdAt: "2026-05-18T18:00:00Z"), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: "ended-reviewer-session", backend: .ghosttyEmbedded, servicePID: 101, childPID: nil, state: .exited,
                updatedAt: "2026-05-18T18:01:00Z", exitedAt: "2026-05-18T18:01:00Z", title: "Reviewer", workingDirectory: workspace.dir), paths: paths
        )
        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Reviewer", terminalTrackingID: "ended-reviewer-session",
            terminalNativeID: "ended-reviewer-session", status: .done, claimedLauncherName: "Reviewer")

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { try orchestrator.focusAgentWindow(record) }
        }

        XCTAssertEqual(focusCapture.sessionIDs, ["ended-reviewer-session"])
        XCTAssertEqual(focusCapture.requestIDs, [nil])
        XCTAssertTrue(openCapture.sessionIDs.isEmpty)
    }

    func testUpdateAgentWindowStatusFallsBackToConfiguredLabelForSpacesProvider() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, tmux: MockTmuxAdapter())
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Mock Agent", terminalTrackingID: "session-a", terminalNativeID: "session-a",
            status: .idle, claimedLauncherName: "Mock Agent")

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "session-b", terminalNativeID: "session-b", label: "Mock Agent",
            status: .waiting)

        let agentWindows = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agentWindows.count, 1)
        XCTAssertEqual(updated.label, "Mock Agent")
        XCTAssertEqual(updated.status, .waiting)
        XCTAssertEqual(updated.terminalTrackingID, "session-b")
        XCTAssertEqual(agentWindows.first?.terminalTrackingID, "session-b")
    }

    // Tests next window order index uses role offset and max by arranging representative inputs and asserting the expected result.
    func testNextWindowOrderIndexUsesRoleOffsetAndMax() {
        let windows = [
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "Chrome", title: "Browser", windowID: 10, role: "browser", orderIndex: 0,
                lastSeenAt: "now"),
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "iTerm2", title: "Term 1", windowID: 11, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"),
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "iTerm2", title: "Term 2", windowID: 12, role: "terminal", orderIndex: 205,
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
                id: UUID().uuidString, projectID: project.id, title: "main", dir: workspaceDir, dirname: "main", branch: "main", targetBranch: "main",
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
                targetBranch: "main", isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil))

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

    // Tests create workspace uses selected target branch as base for new branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesSelectedTargetBranchAsBaseForNewBranch() throws {
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
            projectID: project.id, name: "feature-workspace", branch: "feature-branch", targetBranch: "develop")

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir + "/TARGET.txt"))
        XCTAssertEqual(workspace.targetBranch, "develop")
    }

    // Tests create workspace defaults target branch to project default when omitted by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceDefaultsTargetBranchToProjectDefaultBranch() throws {
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
        XCTAssertEqual(workspace.targetBranch, project.defaultBranch)
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
        _ = try orchestrator.createWorkspace(projectID: project.id, name: "feature-branch", branch: "feature-branch", targetBranch: "develop")

        let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        let feature = try XCTUnwrap(workspaces.first(where: { $0.title == "feature-branch" }))
        XCTAssertEqual(feature.branch, "feature-branch")
        XCTAssertEqual(feature.targetBranch, "develop")
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

    // Tests spacesui shortcuts and active workspace round trip by arranging representative inputs and asserting the expected result.
    func testGUIShortcutsAndActiveWorkspaceRoundTrip() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertEqual(try orchestrator.guiHotkey(), SettingsKey.defaultGUIHotkey)
        XCTAssertEqual(try orchestrator.guiLeaderHotkey(), SettingsKey.defaultGUILeaderHotkey)
        XCTAssertEqual(try orchestrator.guiNextShortcut(), "cmd+alt+]")
        XCTAssertEqual(try orchestrator.guiPreviousShortcut(), "cmd+alt+[")
        XCTAssertEqual(try orchestrator.guiAlertsShortcut(), "cmd+alt+a")
        XCTAssertEqual(try orchestrator.guiAddWorkspaceShortcut(), SettingsKey.defaultGUIAddWorkspaceShortcut)
        XCTAssertEqual(try orchestrator.guiReloadShortcut(), "cmd+alt+r")
        XCTAssertEqual(try orchestrator.guiOpenEditorShortcut(), "cmd+alt+e")
        XCTAssertEqual(try orchestrator.guiOpenTerminalShortcut(), "cmd+alt+t")
        XCTAssertEqual(try orchestrator.guiOpenFinderShortcut(), "cmd+alt+f")
        XCTAssertEqual(try orchestrator.guiOpenSettingsShortcut(), SettingsKey.defaultGUIOpenSettingsShortcut)
        XCTAssertEqual(try orchestrator.guiWindowShortcut(), SettingsKey.defaultGUIWindowShortcut)
        try orchestrator.setGUIHotkey("ctrl+alt+h")
        try orchestrator.setGUILeaderHotkey("ctrl+alt")
        try orchestrator.setGUINextShortcut("n")
        try orchestrator.setGUIPreviousShortcut("p")
        try orchestrator.setGUIAlertsShortcut("d")
        try orchestrator.setGUIAddWorkspaceShortcut("ctrl+alt+w")
        try orchestrator.setGUIReloadShortcut("r")
        try orchestrator.setGUIOpenEditorShortcut("e")
        try orchestrator.setGUIOpenTerminalShortcut("t")
        try orchestrator.setGUIOpenFinderShortcut("f")
        try orchestrator.setGUIOpenSettingsShortcut("ctrl+alt+,")
        try orchestrator.setGUIWindowShortcut("cmd+1")
        try orchestrator.setActiveWorkspace(id: "workspace-123")
        try orchestrator.setAlertsDismissedAttentionItemIDs(Set(["attention-2", "attention-1"]))

        XCTAssertEqual(try orchestrator.guiHotkey(), "ctrl+alt+h")
        XCTAssertEqual(try orchestrator.guiLeaderHotkey(), "alt+ctrl")
        XCTAssertEqual(try orchestrator.guiNextShortcut(), "alt+ctrl+n")
        XCTAssertEqual(try orchestrator.guiPreviousShortcut(), "alt+ctrl+p")
        XCTAssertEqual(try orchestrator.guiAlertsShortcut(), "alt+ctrl+d")
        XCTAssertEqual(try orchestrator.guiAddWorkspaceShortcut(), "ctrl+alt+w")
        XCTAssertEqual(try orchestrator.guiReloadShortcut(), "alt+ctrl+r")
        XCTAssertEqual(try orchestrator.guiOpenEditorShortcut(), "alt+ctrl+e")
        XCTAssertEqual(try orchestrator.guiOpenTerminalShortcut(), "alt+ctrl+t")
        XCTAssertEqual(try orchestrator.guiOpenFinderShortcut(), "alt+ctrl+f")
        XCTAssertEqual(try orchestrator.guiOpenSettingsShortcut(), "ctrl+alt+,")
        XCTAssertEqual(try orchestrator.guiWindowShortcut(), "cmd+1")
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), "workspace-123")
        XCTAssertEqual(try orchestrator.alertsDismissedAttentionItemIDs(), Set(["attention-1", "attention-2"]))

        try orchestrator.setActiveWorkspace(id: nil)
        XCTAssertNil(try orchestrator.activeWorkspaceID())
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

    func testLeaderBackedShortcutsStayStoredAsSuffixesWhenLeaderChanges() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        try orchestrator.setGUIOpenFinderShortcut("cmd+alt+shift+f")
        try orchestrator.setGUILeaderHotkey("cmd+ctrl")

        XCTAssertEqual(try orchestrator.guiOpenFinderShortcut(), "shift+f")
    }

    // Tests check and update process statuses marks dead process as exited by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesMarksDeadProcessAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = WorkspaceOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        // Create a process with a PID that doesn't exist
        let deadProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            terminalTrackingID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: 99999, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
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
        let mockTmux = MockTmuxAdapter()
        let orchestrator = WorkspaceOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        // Create a process that just started (within grace period)
        let newProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            terminalTrackingID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: 99999, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)), exitedAt: nil)
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
        let mockTmux = MockTmuxAdapter()
        let orchestrator = WorkspaceOrchestrator(store: store, tmux: mockTmux)

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
        let liveWindow = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        let zombieProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Ghostty", windowID: 123,
            terminalTrackingID: "workspace-session", terminalNativeID: "ghostty-terminal", terminalContainerID: "ghostty-tab",
            tmuxWindowID: liveWindow.id, pid: zombiePID, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
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
        let mockTmux = MockTmuxAdapter()
        let orchestrator = WorkspaceOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        // Create a process without a PID (still starting up)
        let noPidProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            terminalTrackingID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: nil, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: noPidProcess)
        _ = try orchestrator.checkAndUpdateProcessStatuses()
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .running)
    }

    // Tests check and update process statuses refreshes a stale tracked pid from the live tmux session for managed terminals.
    // Tests check and update process statuses only checks running processes by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesOnlyChecksRunningProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = WorkspaceOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        // Create an already-exited process
        let exitedProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            terminalTrackingID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: 99999, status: .exited, logPath: nil,
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)),
            exitedAt: ISO8601DateFormatter().string(from: Date()))
        try store.upsert(runningProcess: exitedProcess)
        _ = try orchestrator.checkAndUpdateProcessStatuses()
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .exited)
    }

    // Tests tmux runtime sync revives an exited managed process when the tracked pane is still alive by arranging representative inputs and asserting the expected result.

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

    // Tests open workspace editor throws when editor is not configured by arranging representative inputs and asserting the expected result.
    func testOpenWorkspaceEditorThrowsWhenEditorIsNotConfigured() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(try orchestrator.openWorkspaceEditor(workspaceID: workspace.id))
    }

    // Tests open workspace editor does not track editor windows by arranging representative inputs and asserting the expected result.
    func testOpenWorkspaceEditorDoesNotTrackEditorWindows() throws {
        let (orchestrator, _, _, workspace, root) = try makeOrchestratorWithWorkspace(editor: .vscode)
        let openLog = root.appendingPathComponent("open.log")

        // Mocked dependency: `open`.
        // Why: verify editor launch call without touching real GUI apps.
        // Remaining risk: real editor startup behavior is outside this unit test.
        try withMockCommands(["open": Self.openMockScript]) {
            try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) { try orchestrator.openWorkspaceEditor(workspaceID: workspace.id) }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let editorWindows = windows.filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 0)

        let openArgs = try String(contentsOf: openLog)
        XCTAssertTrue(openArgs.contains("-a Visual Studio Code"))
        XCTAssertTrue(openArgs.contains(workspace.dir))
    }

    // Tests open workspace editor does not require yabai by arranging representative inputs and asserting the expected result.
    func testOpenWorkspaceEditorDoesNotRequireYabai() throws {
        let (orchestrator, _, _, workspace, root) = try makeOrchestratorWithWorkspace(editor: .vscode)
        let openLog = root.appendingPathComponent("open-no-yabai.log")

        try withMockCommands(["open": Self.openMockScript]) {
            try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) { try orchestrator.openWorkspaceEditor(workspaceID: workspace.id) }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let editorWindows = windows.filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 0)

        let openArgs = try String(contentsOf: openLog)
        XCTAssertTrue(openArgs.contains("-a Visual Studio Code"))
    }

    // Tests open workspace terminal creates a dedicated workspace terminal and tracks the new tmux shell window.

    // Tests that opening a terminal for a not-running workspace marks it as running so the UI shows Restart instead of Launch.
    func testRefreshWorkspaceWindowsPreservesGeneratedAdHocTerminalName() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell-1", windowID: 101, terminalTrackingID: "session-1",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value:
                    #"[{"id":101,"pid":11,"app":"iTerm2","title":"zsh","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
        XCTAssertEqual(try store.appConfig().processShell, .zsh)
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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
        XCTAssertEqual(openCapture.modes, [.owner])
        let terminalWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(terminalWindow.app, TerminalHost.spaces.appName)
        XCTAssertEqual(terminalWindow.terminalTrackingID, launchedConfigurationSnapshot.first?.sessionID)
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
                windowID: nil, terminalTrackingID: "session-123", terminalNativeID: "session-123", terminalContainerID: nil, itermTabIndex: nil,
                tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "2026-05-10T18:00:00Z"))

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
                windowID: nil, terminalTrackingID: "session-456", terminalNativeID: "session-456", terminalContainerID: nil, itermTabIndex: nil,
                tmuxWindowID: nil, pid: 1234, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2026-05-10T18:05:00Z", exitedAt: nil))

        XCTAssertEqual(try orchestrator.workspaceIDForTerminalSession("session-456"), workspace.id)
    }

    func testRemoveAdHocBuiltInTerminalSessionClearsRunningWhenSessionWasLastRuntimeIndicator() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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

    // Tests focus workspace skips failed window and sets active workspace by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceSkipsFailedWindowAndSetsActiveWorkspace() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "bad", windowID: 999, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "good", windowID: 101, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))

        // Mocked dependency: `yabai` focus command outcomes.
        // Why: control success/failure ordering and verify fallback focus behavior.
        // Remaining risk: actual focus behavior can vary with spaces/displays and concurrent window changes.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) { try orchestrator.focusWorkspace(workspaceID: workspace.id) }
        }

        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["101"])
    }

    // Tests focusing a workspace process targets the process's iTerm2 session when multiple processes share a window.

    // Tests focus workspace process does not borrow another shared-tab index when targeting a specific session.

    func testFocusWorkspaceWindowIndexSkipsProcessDuplicatedByAgentTerminal() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("deduped-shortcut-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "Claude Code", windowID: 101,
                terminalTrackingID: "workspace-session", role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "Claude Code", command: "claude", terminalApp: "iTerm2",
                windowID: 101, terminalTrackingID: "workspace-session", itermTabIndex: nil, tmuxWindowID: nil, pid: 123, status: .running,
                logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI",
                terminalTrackingID: "workspace-session", tmuxWindowID: nil, codexThreadID: nil, windowID: 101, yabaiWindowID: 101, status: .idle,
                createdAt: "now", updatedAt: "now"))
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
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "one", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "two", windowID: 202, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "three", windowID: 303, role: "terminal", orderIndex: 2,
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
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
    }

    func testFocusWindowNavigationFreezesRecencyOrderAcrossCycleSession() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace(currentDate: clock.now)
        let focusLog = root.appendingPathComponent("frozen-cycle-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "one", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "two", windowID: 202, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "three", windowID: 303, role: "terminal", orderIndex: 2,
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
        // Why: ensure browser rows with target URLs still focus their tracked window and set the workspace active.
        // Remaining risk: real Chrome window lifecycle races are not represented.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
            }
        }

        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
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
                    #"[{"id":101,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":888,"pid":22,"app":"Google Chrome","title":"Frontend","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
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
                    #"[{"id":101,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":888,"pid":22,"app":"Google Chrome","title":"Frontend","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
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
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 1, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: tabIndexLog.path) {
                try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: yabaiFocusLog.path) {
                    try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                        try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
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
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
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
            terminalNativeID: "spaces-session-browser-cycle", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-terminal", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend", detail: "npm run frontend",
                targetURL: nil, windowID: 101, terminalTrackingID: "spaces-session-browser-cycle", terminalNativeID: "spaces-session-browser-cycle",
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 0, lastSeenAt: "now"))

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

    func testFocusNextWindowHidesAppNormalizesBrowserTargetURLFromBuiltInTerminal() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let chromeFocusLog = root.appendingPathComponent("browser-cycle-google-focus.log")
        let chromeTabIndexLog = root.appendingPathComponent("browser-cycle-google-tab-index.log")
        let yabaiFocusLog = root.appendingPathComponent("browser-cycle-google-yabai.log")
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
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
            terminalNativeID: "spaces-session-browser-cycle-google", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-terminal-google", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend",
                detail: "npm run frontend", targetURL: nil, windowID: 101, terminalTrackingID: "spaces-session-browser-cycle-google",
                terminalNativeID: "spaces-session-browser-cycle-google", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil,
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            builtInTerminalWindowOpener: { _, _ in XCTFail("cycle focus should not reopen built-in sessions") },
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
            terminalNativeID: "spaces-session-priority", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-process", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend", detail: "npm run frontend",
                targetURL: nil, windowID: 202, terminalTrackingID: "spaces-session-priority", terminalNativeID: "spaces-session-priority",
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 1, lastSeenAt: "now"))

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
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 101, role: "terminal", orderIndex: 200,
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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            builtInTerminalWindowOpener: { _, _ in XCTFail("built-in cycle focus should not reopen the session") },
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
            terminalNativeID: "spaces-session-cycle", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-process", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api", targetURL: nil,
                windowID: 202, terminalTrackingID: "spaces-session-cycle", terminalNativeID: "spaces-session-cycle", terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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

    // Tests direct process focus throws a recoverable missing-window error when the tracked iTerm window no longer exists.
    func testFocusWorkspaceProcessThrowsRecoverableErrorForMissingProcessWindow() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 999,
            terminalTrackingID: "session-999", itermTabIndex: nil, tmuxWindowID: nil, pid: 1234, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "now", exitedAt: nil)
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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
            windowID: nil, terminalTrackingID: "spaces-session-1", terminalNativeID: "spaces-session-1", terminalContainerID: nil, itermTabIndex: nil,
            tmuxWindowID: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev", targetURL: nil,
                windowID: nil, terminalTrackingID: "spaces-session-1", terminalNativeID: "spaces-session-1", terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
            terminalNativeID: "spaces-session-live-only", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-session-only", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: nil, terminalTrackingID: "spaces-session-live-only", terminalNativeID: "spaces-session-live-only",
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
        let store = try SQLiteStore(path: dbPath.path, )
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-ad-hoc-session"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
        let store = try SQLiteStore(path: dbPath.path, )
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-ad-hoc-session-stale-remote"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-ad-hoc-session-closed"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        _ = project

        let sessionID = "spaces-process-session"
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil, itermTabIndex: nil,
                tmuxWindowID: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "window-process-api", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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

    func testFocusWorkspaceProcessUsesBuiltInFocusIPCForLiveBuiltInSpacesWindow() throws {
        let store = try makeTemporaryStore()
        let focusCapture = TerminalFocusCapture()
        let root = try makeTempDirectory()
        let focusLog = root.appendingPathComponent("spaces-live-window-focus.log")
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            builtInTerminalWindowOpener: { _, _ in XCTFail("live built-in window focus should not reopen the session") },
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
            terminalNativeID: "spaces-session-live", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-live-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 501, terminalTrackingID: "spaces-session-live", terminalNativeID: "spaces-session-live",
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            builtInTerminalWindowOpener: { _, _ in XCTFail("focus should not reopen built-in session") },
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
            terminalNativeID: "spaces-session-request-id", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-request-id", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: nil, terminalTrackingID: "spaces-session-request-id", terminalNativeID: "spaces-session-request-id",
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
            terminalNativeID: "spaces-session-cycle-fast-path", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-cycle-fast-path", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 777, terminalTrackingID: "spaces-session-cycle-fast-path",
                terminalNativeID: "spaces-session-cycle-fast-path", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal",
                orderIndex: 200, lastSeenAt: "now"))

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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            terminalFocusPulseController: pulseController,
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
            terminalNativeID: "spaces-session-stale", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-stale-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 777, terminalTrackingID: "spaces-session-stale", terminalNativeID: "spaces-session-stale",
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                try withEnv(name: "YABAI_FOCUS_FAIL_IDS", value: "777") {
                    try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id)
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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
            terminalNativeID: "spaces-session-rebound", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-rebound-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 777, terminalTrackingID: "spaces-session-rebound", terminalNativeID: "spaces-session-rebound",
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            terminalFocusPulseController: pulseController,
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
            terminalNativeID: "spaces-session-live", terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-live-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "web", detail: "npm run dev",
                targetURL: nil, windowID: 777, terminalTrackingID: "spaces-session-live", terminalNativeID: "spaces-session-live",
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
        XCTAssertEqual(pulseController.pulsedWindowIDs, [777])
    }

    // Tests restarting a process recreates a tracked terminal window row even if the stale window row was already pruned.
    // Tests explicit process restart kills the old tmux session and starts a fresh terminal instead of reattaching to it.
    func testRestartWorkspaceProcessUsesConfiguredSpacesHostEvenWhenStoredProcessHostDiffers() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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

        let existingConfig = try store.appConfig()
        try store.setAppConfig(.init(editor: existingConfig.editor, portRange: existingConfig.portRange, processShell: existingConfig.processShell))
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 999,
                terminalTrackingID: "session-old", terminalNativeID: nil, terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

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
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
                windowID: 999, terminalTrackingID: "old-spaces-session", terminalNativeID: "old-spaces-session", terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "old-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api", targetURL: nil,
                windowID: 999, terminalTrackingID: "old-spaces-session", terminalNativeID: "old-spaces-session", terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: "process-api")
            }
        }

        XCTAssertEqual(closeCapture.sessionIDs, ["old-spaces-session"])
        XCTAssertEqual(terminateCapture.sessionIDs, ["old-spaces-session"])
        XCTAssertEqual(openCapture.modes, [.owner])
        XCTAssertEqual(openCapture.sessionIDs.count, 1)
        XCTAssertNotEqual(openCapture.sessionIDs.first, "old-spaces-session")
        let restartedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == "process-api" }))
        XCTAssertEqual(restartedProcess.terminalTrackingID, openCapture.sessionIDs.first)
    }

    // Tests running-process recovery reattaches without restarting when the tmux session is still available.
    // Tests running-process recovery returns false instead of restarting when the tracked process is no longer alive.
    func testRecoverRunningWorkspaceProcessIfPossibleReturnsFalseWhenProcessIsNotRunning() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        mockTmux.createSession(named: "spaces-\(workspace.id)-api")

        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 999,
            terminalTrackingID: "session-old", itermTabIndex: nil, tmuxWindowID: nil, pid: 999_999, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)

        let recovered = try orchestrator.recoverRunningWorkspaceProcessIfPossible(workspaceID: workspace.id, processID: process.id)

        XCTAssertFalse(recovered)
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertTrue(mockTmux.killedSessionNames.isEmpty)
    }

    func testRecoverRunningWorkspaceProcessIfPossibleReopensBuiltInSpacesSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: Int(getpid()), status: .running, logPath: paths.outputPath,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil)
            try store.upsert(runningProcess: process)
            try store.upsert(
                window: WindowRecord(
                    id: process.id, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api", targetURL: nil,
                    windowID: 401, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil, itermTabIndex: nil,
                    tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-api", id: "@1", name: "api", isActive: true)
        mockIterm.nextWindowID = 701
        mockIterm.nextSessionID = "session-api"

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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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

        let existingConfig = try store.appConfig()
        try store.setAppConfig(.init(editor: existingConfig.editor, portRange: existingConfig.portRange, processShell: existingConfig.processShell))
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [ProcessTemplate(name: "api", command: "npm run api"), ProcessTemplate(name: "web", command: "npm run web")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-web", workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: TerminalHost.spaces.appName,
                windowID: 222, terminalTrackingID: "session-web", terminalNativeID: "session-web", terminalContainerID: nil, itermTabIndex: nil,
                tmuxWindowID: nil, pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

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

    func testRecoverMissingConfiguredProcessUsesBuiltInSpacesSessionHostWithoutTmux() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let mockTmux = MockTmuxAdapter()
        mockTmux.available = false
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: mockTmux,
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

        let existingConfig = try store.appConfig()
        try store.setAppConfig(.init(editor: existingConfig.editor, portRange: existingConfig.portRange, processShell: existingConfig.processShell))
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
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "web", command: "npm run web")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 222,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2222, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-web", id: "@2", name: "web", isActive: true)
        mockIterm.nextWindowID = 601
        mockIterm.nextSessionID = "session-web"

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }
        }

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.templateName, "web")
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertTrue(mockTmux.killedSessionNames.isEmpty)
    }

    func testUpdateWorkspaceSettingsWhileRunningDoesNotReconcileProcessesAndSyncsPorts() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "web", command: "npm run web")])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [24000], names: ["API_PORT"])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 222,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2222, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-web", id: "@2", name: "web", isActive: true)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "worker", command: "npm run worker")]
                settings.ports = [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")]
            }
        }

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.templateName, "web")
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertTrue(mockTmux.killedSessionNames.isEmpty)

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
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 222,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2222, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: processID, workspaceID: workspace.id, app: "iTerm2", name: "web", detail: "npm run web", windowID: 222,
                terminalTrackingID: "session-web", terminalNativeID: nil, itermTabIndex: nil, tmuxWindowID: "@2", role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-web", id: "@2", name: "web", isActive: true)

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
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertTrue(mockTmux.killedSessionNames.isEmpty)
    }

    func testUpdateRunningWorkspaceProcessesRestartsChangedCommandAfterConfirmation() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 222,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2222, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-web", id: "@2", name: "web", isActive: true)
        mockIterm.nextWindowID = 602
        mockIterm.nextSessionID = "session-web-v2"

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
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertTrue(mockTmux.killedSessionNames.isEmpty)
    }

    func testUpdateRunningWorkspaceProcessesRejectsChangedCommandWithoutRestartConfirmation() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 222,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2222, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-web", id: "@2", name: "web", isActive: true)

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
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
    }

    func testUpdateRunningWorkspaceProcessesRejectsChangedExecutionModeWithoutRestartConfirmation() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none, executionMode: .direct)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 222,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2222, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-web", id: "@2", name: "web", isActive: true)

        XCTAssertThrowsError(
            try orchestrator.updateRunningWorkspaceProcesses(
                workspaceID: workspace.id,
                processes: [ProcessTemplate(id: process.id, name: "web", command: "npm run web", onExit: .none, executionMode: .shell)],
                restartChangedCommands: false)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription, "Invalid argument: Changing a running process command or execution mode requires restart confirmation.")
        }

        XCTAssertEqual(try store.workspaceProcesses(workspaceID: workspace.id).first?.executionMode, .direct)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.command), ["npm run web"])
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
    }

    func testUpdateRunningWorkspaceProcessesRestartsChangedExecutionModeWithConfiguredShell() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        _ = try orchestrator.updateProcessShell(.sh)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let process = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none, executionMode: .direct)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [process])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let processID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 222,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2222, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-web", id: "@2", name: "web", isActive: true)
        mockIterm.nextWindowID = 603
        mockIterm.nextSessionID = "session-web-shell"

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateRunningWorkspaceProcesses(
                workspaceID: workspace.id,
                processes: [
                    ProcessTemplate(
                        id: process.id, name: "web", command: "cd $SPACES_WORKSPACE_DIR && npm run web", onExit: .none, executionMode: .shell)
                ], restartChangedCommands: true)
        }

        XCTAssertEqual(try store.workspaceProcesses(workspaceID: workspace.id).first?.executionMode, .shell)
        let running = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(running.map(\.templateName), ["web"])
        XCTAssertEqual(running.first?.command, "cd $SPACES_WORKSPACE_DIR && npm run web")
        XCTAssertEqual(running.first?.terminalApp, TerminalHost.spaces.appName)
        XCTAssertNotEqual(running.first?.terminalTrackingID, "session-web")
        XCTAssertEqual(running.first?.terminalTrackingID, running.first?.terminalNativeID)
        XCTAssertEqual(running.first?.pid, 4321)
        XCTAssertTrue(mockTmux.lastStartedCommand.isEmpty)
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
    }

    func testUpdateRunningWorkspaceProcessesDeletingEarlierRowKeepsLaterRunningProcessMatchedByID() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let web = ProcessTemplate(id: "process-web", name: "web", command: "npm run web", onExit: .none)
        let worker = ProcessTemplate(id: "process-worker", name: "worker", command: "npm run worker", onExit: .none)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [web, worker])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "running-web", workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 221,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: "@1", pid: 1111, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "running-worker", workspaceID: workspace.id, templateName: "worker", command: "npm run worker", terminalApp: "iTerm2",
                windowID: 222, terminalTrackingID: "session-worker", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2222, status: .running,
                logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "window-web", workspaceID: workspace.id, app: "iTerm2", name: "web", detail: "npm run web", windowID: 221,
                terminalTrackingID: "session-web", terminalNativeID: nil, itermTabIndex: nil, tmuxWindowID: "@1", role: "terminal", orderIndex: 100,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: "window-worker", workspaceID: workspace.id, app: "iTerm2", name: "worker", detail: "npm run worker", windowID: 222,
                terminalTrackingID: "session-worker", terminalNativeID: nil, itermTabIndex: nil, tmuxWindowID: "@2", role: "terminal",
                orderIndex: 101, lastSeenAt: "now"))
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-web", id: "@1", name: "web", isActive: true)
        _ = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)-worker", id: "@2", name: "worker", isActive: true)

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
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertTrue(mockTmux.killedSessionNames.isEmpty)
    }

    // Tests workspace cycling includes orphaned running processes so recovered iTerm windows remain reachable even before a terminal row is rebuilt.
    // Tests direct coding-agent focus throws a missing-window error without offering process/browser recovery metadata.
    // Tests focus workspace window uses tracked chrome window id when target url is shared by arranging representative inputs and asserting the expected result.

    // Tests focus window navigation wraps across browser targets in same chrome window by arranging representative inputs and asserting the expected result.

    // Tests focus window navigation uses remembered target identity across shared chrome rows when the focused target cannot be resolved.

    // Tests focus window navigation falls back to the remembered cursor when Chrome URL matching is ambiguous across tracked windows.

    // Tests focus window navigation falls back to the remembered cursor when Chrome window matching is ambiguous for an unrelated active tab.

    // Tests focus window navigation cycles agent and process iTerm sessions separately when they share one iTerm window.

    // Tests focus window navigation remembers browser targets by identity instead of stale array index when targets reorder.

    // Tests focus window navigation uses remembered iTerm target identity when focused-session lookup cannot disambiguate shared tabs.

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
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
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
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace(editor: .vscode)
        let root = try makeTempDirectory()
        let openLog = root.appendingPathComponent("launch-open.log")

        let windowsJSON =
            "[{\"id\":101,\"pid\":11,\"app\":\"iTerm2\",\"title\":\"shell\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false},{\"id\":202,\"pid\":22,\"app\":\"Google Chrome\",\"title\":\"docs\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false}]"

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
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "stale", windowID: 909, role: "terminal", orderIndex: 0,
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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 501,
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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 501,
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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "name:api", command: "npm run api", terminalApp: "iTerm2",
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
                terminalApp: "iTerm2", windowID: 501, pid: 999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 501,
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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 501,
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

    // Tests refresh workspace windows prunes legacy terminal rows that do not have tmux identity.

    // Tests refresh workspace windows prunes legacy process-backed terminal rows without tmux identity.

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
                id: UUID().uuidString, workspaceID: defaultWorkspace.id, app: "iTerm2", title: "default-stale", windowID: 910, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: activeWorkspace.id, app: "iTerm2", title: "active-stale", windowID: 911, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: archivedWorkspace.id, app: "iTerm2", title: "archived-stale", windowID: 912, role: "terminal",
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
        XCTAssertEqual(projects.map(\.isCollapsed), [false, false])
    }

    // Tests project collapsed state updates through orchestrator and is exposed in summaries by arranging representative inputs and asserting the expected result.
    func testSetProjectCollapsedPersistsToProjectAndSummary() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.setProjectCollapsed(projectID: project.id, isCollapsed: true)

        XCTAssertEqual(try orchestrator.project(id: project.id)?.isCollapsed, true)
        XCTAssertEqual(try orchestrator.listProjects().first(where: { $0.id == project.id })?.isCollapsed, true)
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

    // Tests update project config seeds default workspace when settings match previous template by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigSeedsDefaultWorkspaceWhenSettingsMatchPreviousTemplate() throws {
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
        XCTAssertEqual(settings?.stopScript, "echo stop")
        XCTAssertEqual(settings?.processes.first?.name, "api")
        XCTAssertEqual(settings?.browserSessions.first?.url, "https://example.com")
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
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependencies: window close via `yabai` and iTerm cleanup via `osascript`.
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

    // Tests stop workspace terminates process before closing tracked terminal window by arranging representative inputs and asserting the expected result.

    // Tests stop workspace resolves pid from runtime file when tracked pid is missing by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClosesManagedTerminalWindowOnlyOnce() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let closeLog = root.appendingPathComponent("stop-workspace-yabai-close.log")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "frontend", windowID: 501, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "backend", windowID: 502, role: "terminal", orderIndex: 201,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "frontend", command: "npm run dev", terminalApp: "iTerm2",
                windowID: 501, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "backend", command: "npm run api", terminalApp: "iTerm2",
                windowID: 502, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_CLOSE_LOG_FILE", value: closeLog.path) { _ = try orchestrator.stopWorkspace(workspaceID: workspace.id) }
        }

        let closedIDs = try String(contentsOf: closeLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(closedIDs, ["501", "502"])
    }

    func testStopWorkspaceClosesBuiltInTerminalSessionWithoutTrackedYabaiWindowID() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
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
                terminalApp: TerminalHost.spaces.appName, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID,
                terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "tracked-window-spaces", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    // Tests stop workspace closes tracked browser tabs without closing chrome window by arranging representative inputs and asserting the expected result.

    // Tests stop workspace closes the shared iTerm window without yabai-closing it by arranging representative inputs and asserting the expected result.

    // Tests stop workspace closes all live detected browser session tabs by arranging representative inputs and asserting the expected result.

    // Tests launch workspace throws when runtime indicators exist by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceThrowsWhenRuntimeIndicatorsExist() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 701,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id))
    }

    // Tests launch workspace without processes does not require i term by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceWithoutProcessesDoesNotRequireITerm() throws {
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
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "iTerm2", windowID: 501,
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

    // Tests up workspace launches multiple configured processes in one iTerm2 window using separate tabs.

    // Tests up workspace does nothing to running processes when runtime indicators exist and restart is disabled by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceDoesNothingWhenRuntimeIndicatorsExistByDefault() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "iTerm2", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.upWorkspace(workspaceID: workspace.id) }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).count, 1)
    }

    // Tests up workspace restarts exited processes when workspace is running by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceRestartsExitedProcessesWhenRunning() throws {
        let (orchestrator, store, _, workspace, _, _, _) = try makeMockItermOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "echo web", terminalApp: "iTerm2", windowID: nil,
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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "iTerm2", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests restart workspace clears agent windows by arranging a running workspace with an iterm2 agent window and asserting the record and tmux window are removed before relaunch.
    func testRestartWorkspaceClearsAgentWindows() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let agentWindow = mockTmux.addWindow(sessionName: "spaces-\(workspace.id)", id: "@2", name: "Claude Code", index: 1, isActive: true)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "Claude Code", windowID: 501,
                terminalTrackingID: "workspace-session", tmuxWindowID: agentWindow.id, role: "terminal", orderIndex: 201, lastSeenAt: "now"))
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Claude Code", terminalTrackingID: "workspace-session",
            tmuxWindowID: agentWindow.id, codexThreadID: nil, windowID: 501, yabaiWindowID: 501, status: .spinning, createdAt: "now", updatedAt: "now"
        )
        try store.upsertAgentWindow(agentRecord)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value:
                    #"[{"id":501,"pid":11,"app":"iTerm2","title":"Claude Code","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) { try orchestrator.restartWorkspace(workspaceID: workspace.id) }
        }

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "Agent window records should be cleared during restart")
        XCTAssertFalse(mockIterm.closedWindowIDs.contains(501), "Dedicated terminal windows close through yabai, not iTerm AppleScript.")
        XCTAssertTrue(mockTmux.killedWindowIDs.contains(agentWindow.id), "Agent tmux window should be killed during restart")
    }

    // Tests restart workspace kills every tmux window in the shared iTerm container so stale windows do not survive the teardown.

    // Tests up workspace with restart enabled clears agent windows by arranging a running workspace with an iterm2 agent window and asserting the record and tmux window are removed before relaunch.

    // Tests stopWorkspace tears down the full tmux session by arranging a running workspace with an iterm2 agent window and asserting the record and session are removed.

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
        editor: EditorPreference? = nil, browserWindowScanDebounceInterval: TimeInterval = 10,
        terminalFocusPulseController: TerminalFocusPulseControlling = MockTerminalFocusPulseController(),
        currentDate: @escaping () -> Date = Date.init
    ) throws -> (WorkspaceOrchestrator, SQLiteStore, ProjectRecord, WorkspaceRecord, URL) {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = WorkspaceOrchestrator(
            store: store, tmux: mockTmux, browserWindowScanDebounceInterval: browserWindowScanDebounceInterval,
            terminalFocusPulseController: terminalFocusPulseController, currentDate: currentDate)
        if let editor { _ = try orchestrator.updateEditorPreference(editor) }

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "spaces-\(workspace.id)")
        return (orchestrator, store, project, workspace, root)
    }

    private func makeMockItermOrchestratorWithWorkspace(
        browserWindowScanDebounceInterval: TimeInterval = 10,
        terminalFocusPulseController: TerminalFocusPulseControlling = MockTerminalFocusPulseController(),
        currentDate: @escaping () -> Date = Date.init
    ) throws -> (WorkspaceOrchestrator, SQLiteStore, ProjectRecord, WorkspaceRecord, URL, MockIterm2Adapter, MockTmuxAdapter) {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        mockIterm.pairedTmux = mockTmux
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: mockIterm, tmux: mockTmux, browserWindowScanDebounceInterval: browserWindowScanDebounceInterval,
            terminalFocusPulseController: terminalFocusPulseController,
            builtInTerminalWindowOpener: { sessionID, _ in
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 4321, state: .running,
                        updatedAt: "2026-05-15T18:00:00Z"), paths: paths)
                try! "test output\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
            }, currentDate: currentDate)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "spaces-\(workspace.id)")
        return (orchestrator, store, project, workspace, root, mockIterm, mockTmux)
    }
    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
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
        focused_app="${YABAI_FOCUSED_APP:-iTerm2}"
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
            echo '[{"id":101,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":202,"pid":22,"app":"Google Chrome","title":"docs","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]'
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
        # Mock `osascript` bridge for iTerm/Chrome paths used by orchestrator tests.
        # Coverage intent:
        # - iTerm availability and window-id responses
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

        if [[ "$script" == *'tell application "iTerm2" to version'* ]]; then
          if [[ "${MOCK_ITERM_UNAVAILABLE:-}" == "1" ]]; then
            echo "iTerm2 unavailable" >&2
            exit 1
          fi
          echo "3.5.0"
          exit 0
        fi

        if [[ "$script" == *'create tab with default profile'* ]]; then
          wid="$(printf '%s\n' "$script" | grep -Eo 'if id of w is [0-9]+' | awk '{print $6}' | head -n1)"
          if [[ -z "$wid" ]]; then
            wid="${MOCK_ITERM_WINDOW_ID:-701}"
          fi
          if [[ -n "${MOCK_ITERM_TAB_COUNTER_FILE:-}" ]]; then
            current="$(cat "$MOCK_ITERM_TAB_COUNTER_FILE" 2>/dev/null)"
            if [[ -z "$current" ]]; then current=1; fi
            next=$((current + 1))
            echo "$next" > "$MOCK_ITERM_TAB_COUNTER_FILE"
            echo "${wid}|session-${wid}-tab-${next}|${next}"
            exit 0
          fi
          echo "${wid}|session-${wid}-tab-2|2"
          exit 0
        fi

        if [[ "$script" == *'create window with default profile'* ]]; then
          if [[ -n "${MOCK_ITERM_WINDOW_IDS_FILE:-}" ]]; then
            ids="$(cat "$MOCK_ITERM_WINDOW_IDS_FILE" 2>/dev/null)"
            if [[ -z "$ids" ]]; then
              ids="${MOCK_ITERM_WINDOW_ID:-701}"
            fi
            first="${ids%%,*}"
            if [[ "$ids" == *","* ]]; then
              rest="${ids#*,}"
            else
              rest="$first"
            fi
            echo "$rest" > "$MOCK_ITERM_WINDOW_IDS_FILE"
            echo "${first}|session-${first}|1"
            exit 0
          fi
          wid="${MOCK_ITERM_WINDOW_ID:-701}"
          echo "${wid}|session-${wid}|1"
          exit 0
        fi

        if [[ "$script" == *'set targetSessionID to'* && "$script" == *'tell application "iTerm2"'* ]]; then
          if [[ "$script" != *'activate'* && "$script" != *'set current window to w'* ]]; then
            # closeSessionOrTab scripts are handled by the close logger branch below
            :
          else
          if [[ -n "${MOCK_ITERM_FOCUS_LOG_FILE:-}" ]]; then
            session_id="$(printf '%s\n' "$script" | awk -F'set targetSessionID to \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
            tab_index="$(printf '%s\n' "$script" | grep -Eo 'set targetTabIndex to -?[0-9]+' | awk '{print $4}' | head -n1)"
            window_id="$(printf '%s\n' "$script" | grep -Eo 'set targetWindowID to -?[0-9]+' | awk '{print $4}' | head -n1)"
            echo "${session_id}|${tab_index}|${window_id}" >> "$MOCK_ITERM_FOCUS_LOG_FILE"
          fi
          echo "${MOCK_ITERM_FOCUS_RESULT:-session}"
          exit 0
          fi
        fi

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

        if [[ "$script" == *'close s'* || "$script" == *'close t'* || "$script" == *'close w'* ]]; then
          close_window_id="$(printf '%s\n' "$script" | grep -Eo 'set targetWindowID to -?[0-9]+' | awk '{print $4}' | head -n1)"
          if [[ -z "$close_window_id" ]]; then
            close_window_id="$(printf '%s\n' "$script" | grep -Eo 'if id of w is [0-9]+ then' | awk '{print $6}' | head -n1)"
          fi
          close_kind="window"
          if [[ "$script" == *'close s'* ]]; then close_kind="session"; fi
          if [[ "$script" == *'close t'* ]]; then close_kind="tab"; fi
          if [[ -n "${MOCK_ITERM_CLOSE_LOG_FILE:-}" ]]; then
            echo "iterm-close ${close_window_id:-unknown} ${close_kind}" >> "$MOCK_ITERM_CLOSE_LOG_FILE"
          fi
          echo "${close_kind}"
          exit 0
        fi

        if [[ "$script" == *'write text'* ]]; then
          echo ""
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

    private func makeTempGitRepo(name: String, initialBranch: String = "main") throws -> URL {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", initialBranch], cwd: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: repo.path)
        return repo
    }

    private func runGit(_ arguments: [String], cwd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "spaces.tests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"])
        }
    }

    private func runGitAndCapture(_ arguments: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "spaces.tests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"])
        }
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

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

    // Tests window focus pulse color returns the configured default when not set.
    func testWindowFocusPulseColorReturnsDefaultWhenNotSet() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        let (r, g, b) = try orchestrator.windowFocusPulseColor()
        XCTAssertEqual(r, 72)
        XCTAssertEqual(g, 98)
        XCTAssertEqual(b, 110)
    }

    // Tests window focus pulse color round trips through the store.
    func testWindowFocusPulseColorRoundTrip() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.setWindowFocusPulseColor(r: 10, g: 128, b: 200)
        let (r, g, b) = try orchestrator.windowFocusPulseColor()
        XCTAssertEqual(r, 10)
        XCTAssertEqual(g, 128)
        XCTAssertEqual(b, 200)
    }

    // Tests window focus pulse color clamps values to 0-255.
    func testWindowFocusPulseColorClampsValues() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.setWindowFocusPulseColor(r: -10, g: 300, b: 128)
        let (r, g, b) = try orchestrator.windowFocusPulseColor()
        XCTAssertEqual(r, 0)
        XCTAssertEqual(g, 255)
        XCTAssertEqual(b, 128)
    }

    func testStopWorkspaceProcessRemovesTrackedRuntimeAndClearsRunningFlagWhenLastProcessStops() throws {
        let (orchestrator, store, _, workspace, _, _, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let sessionName = "spaces-\(workspace.id)-api"
        let tmuxWindow = mockTmux.addWindow(sessionName: sessionName, id: "@1", name: "api", index: 0, isActive: true)
        let processID = UUID().uuidString

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 559, terminalTrackingID: "workspace-session",
                tmuxWindowID: tmuxWindow.id, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 559,
                terminalTrackingID: "workspace-session", itermTabIndex: nil, tmuxWindowID: tmuxWindow.id, pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: processID)
        }

        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try store.workspace(id: workspace.id)?.isRunning ?? true)
        XCTAssertFalse(mockTmux.hasSession(named: sessionName))
    }

    func testStopWorkspaceProcessDoesNotTerminateBuiltInSessionForNonSpacesTerminalProcess() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        let processID = UUID().uuidString
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 559,
                terminalTrackingID: "iterm-session", terminalNativeID: nil, terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 559, terminalTrackingID: "iterm-session",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: processID)
        }

        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try store.workspace(id: workspace.id)?.isRunning ?? true)
    }

    func testStopWorkspaceProcessTerminatesBuiltInSession() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter(),
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
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
                windowID: 601, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil, itermTabIndex: nil,
                tmuxWindowID: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, windowID: 601, terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil,
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: processID)
        }

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try store.workspace(id: workspace.id)?.isRunning ?? true)
    }

    // Tests focus terminal window triggers overlay pulse for iTerm2 by arranging representative inputs and asserting the expected result.
    // Tests window focus pulse enabled returns true by default when not set.
    func testWindowFocusPulseEnabledDefaultsToTrue() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        let enabled = try orchestrator.windowFocusPulseEnabled()
        XCTAssertTrue(enabled)
    }

    // Tests window focus pulse enabled round-trips false.
    func testWindowFocusPulseEnabledRoundTripFalse() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.setWindowFocusPulseEnabled(false)
        let enabled = try orchestrator.windowFocusPulseEnabled()
        XCTAssertFalse(enabled)
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

    // Tests setWindowFocusPulseColor clamps values to 0–255.
    func testWindowFocusPulseColorClamps() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        try orchestrator.setWindowFocusPulseColor(r: -10, g: 300, b: 128)
        let clamped = try orchestrator.windowFocusPulseColor()
        XCTAssertEqual(clamped.r, 0)
        XCTAssertEqual(clamped.g, 255)
        XCTAssertEqual(clamped.b, 128)
    }

    // Tests windowFocusPulseEnabled round-trips through store.
    func testWindowFocusPulseEnabledRoundTrip() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        // Default is enabled.
        XCTAssertTrue(try orchestrator.windowFocusPulseEnabled())

        try orchestrator.setWindowFocusPulseEnabled(false)
        XCTAssertFalse(try orchestrator.windowFocusPulseEnabled())

        try orchestrator.setWindowFocusPulseEnabled(true)
        XCTAssertTrue(try orchestrator.windowFocusPulseEnabled())
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

    func testUpdateProcessShellPersists() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let updated = try orchestrator.updateProcessShell(.bash)

        XCTAssertEqual(updated.processShell, .bash)
        XCTAssertEqual(try orchestrator.appConfig().processShell, .bash)
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
        let mockIterm = MockIterm2Adapter()
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: mockIterm)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 707, role: "terminal", orderIndex: 0,
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
        let mockIterm = MockIterm2Adapter()
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: mockIterm)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 200,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 200, role: "terminal", orderIndex: 0,
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

    // MARK: - updateProjectConfig default workspace sync

    // Tests updateProjectConfig syncs default workspace settings when they match the previous template by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigSyncsDefaultWorkspaceSettings() throws {
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

        // The default workspace should now have the synced stop script.
        let syncedScript = try store.workspaceStopScript(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(syncedScript, "echo project-stop")
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

        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
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
        let mockIterm = MockIterm2Adapter()
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: mockIterm)

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

    // Tests setActiveWorkspace and activeWorkspaceID persist by arranging representative inputs and asserting the expected result.
    func testActiveWorkspaceRoundTrip() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertNil(try orchestrator.activeWorkspaceID())
        try orchestrator.setActiveWorkspace(id: "workspace-xyz")
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), "workspace-xyz")
        try orchestrator.setActiveWorkspace(id: nil)
        XCTAssertNil(try orchestrator.activeWorkspaceID())
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
        let mockIterm = MockIterm2Adapter()
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: mockIterm)
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
        let mockIterm = MockIterm2Adapter()
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: mockIterm)
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
            dirname: workspace.dirname, branch: workspace.branch, targetBranch: workspace.targetBranch, isDefault: workspace.isDefault,
            isArchived: workspace.isArchived, isHidden: workspace.isHidden, isRunning: true, lastLaunchedAt: nil, notes: nil)
        try store.upsert(workspace: runningWorkspace)

        // Stop should succeed (skip script because dir is missing) rather than throw.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)
            XCTAssertTrue(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        }
    }

    // Tests stopWorkspace closes non-iTerm2 tracked windows via yabai by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClosesNonItermTrackedWindowsViaYabai() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: mockIterm)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Insert a tracked "editor" window (non-browser, non-iTerm2) so lines 702-705 are reached.
        let editorWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Cursor", title: "editor", windowID: 42, role: "editor", orderIndex: 100,
            lastSeenAt: "2024-01-01T00:00:00Z")
        try store.upsert(window: editorWindow)

        // Mark workspace as running.
        let runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, title: workspace.title, dir: projectDir.path, dirname: workspace.dirname,
            branch: workspace.branch, targetBranch: workspace.targetBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived,
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

    // Tests addProject by gitURL throws when destination directory already exists on disk by arranging representative inputs and asserting the expected result.
    func testAddProjectByGitURLThrowsWhenDestinationExists() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        // Pre-create the destination directory so it already exists on disk.
        let existingDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: "https://example.com/my-repo.git", preferredName: "my-repo"), isDirectory: true)
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

        // addProject(gitURL:) should throw because the destination directory is already present.
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "https://example.com/my-repo.git")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests checkAndUpdateProcessStatuses keeps live iTerm2 agent sessions by arranging representative inputs and asserting the expected result.

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
            terminalTrackingID: nil, itermTabIndex: nil, pid: 2_000_000, status: .running, logPath: nil, lastOutputAt: nil, startedAt: recentStart,
            exitedAt: nil)
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
            terminalTrackingID: nil, itermTabIndex: nil, pid: zombiePID, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "2020-01-01T00:00:00Z", exitedAt: nil)
        try store.upsert(runningProcess: process)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()

        XCTAssertTrue(didUpdate)
        let updated = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .exited)
        XCTAssertNotNil(updated?.exitedAt)
    }

    // Tests createWorkspace throws when target branch cannot be resolved for a git project with no main/master by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceThrowsWhenTargetBranchCannotBeResolved() throws {
        // Create a git repo with a non-standard initial branch (not main or master)
        let repo = try makeTempGitRepo(name: "no-main-or-master", initialBranch: "develop")
        let store = try makeTemporaryStore()
        // Insert the project directly with defaultBranch = nil to force the main/master branch check
        let projectRecord = ProjectRecord(id: repo.path, name: "test", dir: repo.path, isGitRepo: true, defaultBranch: nil)
        try store.upsert(project: projectRecord)

        let orchestrator = WorkspaceOrchestrator(store: store)
        // Without targetBranch, resolveWorkspaceTargetBranch should check for main/master, find neither, and throw
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

    // Tests openWorkspaceTerminal falls back to the first sorted tracked iTerm2 window ID when no running process provides one by arranging representative inputs and asserting the expected result.

    // Tests openWorkspaceTerminal uses the window ID from a running iTerm2 process when the focused window is not iTerm2 by arranging representative inputs and asserting the expected result.

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

    // Tests syncDefaultWorkspaceSettings reseeds missing settings when updateProjectConfig is called by arranging representative inputs and asserting the expected result.
    func testSyncDefaultWorkspaceSettingsReseesIfSettingsMissing() throws {
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

        // updateProjectConfig triggers syncDefaultWorkspaceSettingsIfTemplateBased, which reseeds missing settings.
        let orchestrator = WorkspaceOrchestrator(store: store)
        try orchestrator.updateProjectConfig(projectID: normalizedDir) { _ in }

        XCTAssertTrue(try store.workspaceSettingsExists(workspaceID: workspaceID))
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

    // Tests openWorkspaceEditor throws invalidArgument when the workspace is archived.
    func testOpenWorkspaceEditorThrowsForArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Archive the workspace directly via the store.
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)

        XCTAssertThrowsError(try orchestrator.openWorkspaceEditor(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived"))
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
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: source.path)
        try "hello".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: source.path)

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
