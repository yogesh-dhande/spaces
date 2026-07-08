import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {
    // Tests workspace window refresh interval is positive by arranging representative inputs and asserting the expected result.
    func testWorkspaceWindowRefreshIntervalIsPositive() { XCTAssertGreaterThan(PollingConstants.workspaceWindowRefreshInterval, 0) }

    func testUpdateProjectConfigAcceptsShellVariableSyntaxAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)

        try orchestrator.updateProjectConfig(projectID: project.id) { project in
            project.ports = [ServiceDefinition(name: "frontend")]
            project.processes = [ProcessTemplate(name: "web", command: "PORT=${TYPO_PORT:-3000} npm run dev | tee log.txt")]
        }

        let updated = try XCTUnwrap(try store.project(id: project.id))
        XCTAssertEqual(updated.processes.first?.command, "PORT=${TYPO_PORT:-3000} npm run dev | tee log.txt")
    }

    func testUpdateWorkspaceSettingsAcceptsShellVariableSyntaxAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "frontend")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$TYPO_PORT npm run dev")]
        }

        let settings = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id))
        XCTAssertEqual(settings.processes.first?.command, "PORT=$TYPO_PORT npm run dev")
    }

    // Tests next window order index uses role offset and max by arranging representative inputs and asserting the expected result.
    func testNextWindowOrderIndexUsesRoleOffsetAndMax() {
        let windows = [
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "Chrome", title: "Browser", role: "browser", orderIndex: 0, lastSeenAt: "now"),
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "Spaces", title: "Term 1", role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "Spaces", title: "Term 2", role: "terminal", orderIndex: 205, lastSeenAt: "now"),
        ]

        let nextTerminal = WorkspaceOrchestrator.nextWindowOrderIndex(existing: windows, role: "terminal", orderOffset: 200)
        XCTAssertEqual(nextTerminal, 206)

        let nextEditor = WorkspaceOrchestrator.nextWindowOrderIndex(existing: windows, role: "editor", orderOffset: 100)
        XCTAssertEqual(nextEditor, 100)
    }

    func testPendingSetupBlocksManagedRuntimeLaunchesButAllowsWorkspaceTerminalReservation() throws {
        let repo = try makeTempGitRepo(name: "pending-setup-blocks")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo setup"
            config.processes = [ProcessTemplate(name: "web", command: "echo web")]
            config.agentLaunchers = [AgentLauncher(name: "Codex", command: "echo codex")]
            config.browserSessions = [BrowserSession(name: "App", url: "http://localhost:3000")]
        }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature", runSetupScript: false)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)

        func assertSetupBlocked(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try operation(), file: file, line: line) { error in
                XCTAssertTrue(error.localizedDescription.contains("Workspace setup has not run"), file: file, line: line)
            }
        }

        assertSetupBlocked { try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "web") }
        assertSetupBlocked { _ = try orchestrator.launchAgentLauncher(workspaceID: workspace.id, name: "Codex") }

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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let reservation = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspace.id)
        let paths = try TerminalSessionPaths.forSession(id: reservation.sessionID)

        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).state, .starting)
        XCTAssertThrowsError(try orchestrator.finishReservedWorkspaceTerminalLaunch(reservation))

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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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

    // Tests open workspace terminal creates a dedicated workspace terminal and tracks the new built-in terminal shell window.

    // Tests that opening a terminal for a not-running workspace marks it as running so the UI shows Restart instead of Launch.
    func testRefreshWorkspaceWindowsPreservesGeneratedAdHocTerminalName() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let dbPath = root.appendingPathComponent("spaces-test.db").path
        let sessionID = "session-1"
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "shell-1", terminalTrackingID: sessionID, role: "terminal",
                orderIndex: 200, lastSeenAt: "now"))

        try withSpacesProfileEnvironment(dbPath: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running, updatedAt: "now",
                    title: "shell-1", workingDirectory: workspace.dir))
            try markBuiltInSessionLive(sessionID: sessionID)
            _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
        }

        let terminalWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(terminalWindow.title, "shell-1")
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }

        let terminalWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(terminalWindow.app, TerminalHost.spaces.appName)
        XCTAssertEqual(terminalWindow.terminalTrackingID, terminalWindow.terminalNativeID)
    }

    func testCreateWorkspaceTerminalSessionCreatesAdHocWorkspaceTerminalRowAndStopsWithWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let launchCapture = TerminalLaunchConfigurationCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionLauncher: { configuration in
                launchCapture.append(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123,
                    childPID: 456, controlSocketPath: "/tmp/control-\(configuration.sessionID)",
                    outputPath: "/tmp/output-\(configuration.sessionID)", launchConfiguration: configuration)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        let session = try orchestrator.createWorkspaceTerminalSession(workspaceID: workspace.id, title: nil, command: "echo hello")

        let launchConfiguration = try XCTUnwrap(launchCapture.snapshot().first)
        XCTAssertEqual(launchConfiguration.sessionID, session.id)
        XCTAssertEqual(launchConfiguration.workspaceID, workspace.id)
        XCTAssertEqual(launchConfiguration.kind, .shell)
        XCTAssertEqual(launchConfiguration.title, "shell-1")
        XCTAssertTrue(launchConfiguration.command?.contains("echo hello") == true)
        let terminalWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first)
        XCTAssertEqual(terminalWindow.app, TerminalHost.spaces.appName)
        XCTAssertEqual(terminalWindow.name, "shell-1")
        XCTAssertEqual(terminalWindow.role, "terminal")
        XCTAssertEqual(terminalWindow.terminalTrackingID, session.id)
        XCTAssertEqual(terminalWindow.terminalNativeID, session.id)
        XCTAssertTrue(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)

        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(terminateCapture.sessionIDs, [session.id])
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
    }

    func testStopWorkspaceTerminatesLaunchOwnedAdHocTerminalSessionWithoutWindowRow() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalSessionTerminator: { sessionID in
                terminateCapture.sessionIDs.append(sessionID)
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
                    let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
                else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    TerminalSessionRuntimeState(
                        sessionID: sessionID, backend: runtimeState.backend, servicePID: runtimeState.servicePID,
                        childPID: runtimeState.childPID, state: .exited, updatedAt: "2026-06-06T00:00:01Z",
                        exitedAt: "2026-06-06T00:00:01Z", title: runtimeState.title, workingDirectory: runtimeState.workingDirectory,
                        columns: runtimeState.columns, rows: runtimeState.rows, foregroundPID: runtimeState.foregroundPID,
                        foregroundExecutablePath: runtimeState.foregroundExecutablePath,
                        foregroundExecutableName: runtimeState.foregroundExecutableName, foregroundArgv: runtimeState.foregroundArgv,
                        foregroundDetectedAgentKind: runtimeState.foregroundDetectedAgentKind,
                        foregroundDisplayLabel: runtimeState.foregroundDisplayLabel,
                        foregroundDisplayCommand: runtimeState.foregroundDisplayCommand),
                    paths: paths)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "launch-owned-shell"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-06-06T00:00:00Z")
        try writeTerminalSessionFixture(
            sessionID: sessionID, workspace: workspace, kind: .shell,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 456,
                state: .running, updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir))

        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
    }

    func testWorkspaceIDForTerminalSessionUsesTrackedBuiltInSessionID() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try store.upsert(
            window: WindowRecord(
                id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                terminalTrackingID: "session-123", terminalNativeID: "session-123", role: "terminal", orderIndex: 200,
                lastSeenAt: "2026-05-10T18:00:00Z"))

        XCTAssertEqual(try orchestrator.workspaceIDForTerminalSession("session-123"), workspace.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }

        let sessionID = try XCTUnwrap(store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" })?.terminalTrackingID)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)

        XCTAssertTrue(try orchestrator.removeAdHocBuiltInTerminalSession(sessionID: sessionID))
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    func testWorkspaceFocusableWindowNamesIncludeConfiguredNames() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "API", command: "npm run api")])
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])

        let names = try orchestrator.workspaceFocusableWindowNames(workspaceID: workspace.id)

        XCTAssertEqual(names, ["Frontend", "API"])
    }

    func testRefreshWorkspaceWindowsPreservesAdHocBuiltInTerminalWindowWhileSessionIsLive() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        _ = project

        let sessionID = "spaces-ad-hoc-session"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, title: "shell-1", workingDirectory: projectDir.path, shell: "/bin/zsh", command: nil, createdAt: "now",
                    workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now"), paths: paths)
            try TerminalSessionPersistence.attachClient(
                sessionID: sessionID,
                client: TerminalClient(
                    id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
                    connectedAt: "now"), mode: .owner, paths: paths, attachedAt: "now")

            _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        _ = project

        let sessionID = "spaces-ad-hoc-session-stale-remote"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, title: "shell-1", workingDirectory: projectDir.path, shell: "/bin/zsh", command: nil, createdAt: "now",
                    workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now"), paths: paths)
            try TerminalSessionPersistence.attachClient(
                sessionID: sessionID,
                client: TerminalClient(
                    id: "remote-client", kind: .remoteViewer, identity: .init(label: "iPhone", hostName: "phone", deviceName: "Remote Client"),
                    connectedAt: "2000-01-01T00:00:00Z"), mode: .viewer, paths: paths, attachedAt: "2000-01-01T00:00:00Z")

            _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.filter { $0.role == "terminal" }.map(\.id), ["window-spaces-shell-1"])
        XCTAssertEqual(windows.first?.name, "shell-1")
    }

    func testRefreshWorkspaceWindowsPrunesAdHocBuiltInTerminalWindowAfterOwnerCloses() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        _ = project

        let sessionID = "spaces-ad-hoc-session-closed"
        try store.upsert(
            window: WindowRecord(
                id: "window-spaces-shell-1", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil,
                targetURL: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, title: "shell-1", workingDirectory: projectDir.path, shell: "/bin/zsh", command: nil, createdAt: timestamp,
                    workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: timestamp), paths: paths)
            let ownerClient = TerminalClient(
                id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
                connectedAt: timestamp)
            try TerminalSessionPersistence.attachClient(sessionID: sessionID, client: ownerClient, mode: .owner, paths: paths, attachedAt: timestamp)
            try TerminalSessionPersistence.detachClient(id: ownerClient.id, paths: paths, detachedAt: timestamp)

            _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
        }

        XCTAssertTrue(try orchestrator.windows(workspaceID: workspace.id).isEmpty)
    }

    // Tests launch workspace reuses existing browser matches and tracks all matching tabs by arranging representative inputs and asserting the expected result.

    // Tests launch workspace opens missing browser sessions as tabs in one Chrome window by arranging representative inputs and asserting the expected result.

    // Tests launch workspace leaves configured browser sessions unopened so they behave like lazy bookmarks.
    func testLaunchWorkspaceLeavesBrowserSessionsUnopenedUntilFocused() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let chromeOpenLog = root.appendingPathComponent("chrome-open.log")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])

        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_OPEN_LOG_FILE", value: chromeOpenLog.path) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
        }

        XCTAssertTrue(try store.windows(workspaceID: workspace.id).filter { $0.role == "browser" }.isEmpty)
        XCTAssertFalse(try store.workspaceBrowserSessions(workspaceID: workspace.id).isEmpty)
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
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "stale", role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        // Why: verify refresh prunes missing/stale tracked windows without implicitly changing lifecycle state.
        // Remaining risk: rapid concurrent open/close events can still race with a single refresh snapshot.
        var didMutate = false
        didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)

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
        didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)

        XCTAssertFalse(didMutate)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    // Tests refresh workspace windows leaves tracked browser rows alone until the user focuses them on demand.
    func testRefreshWorkspaceWindowsDoesNotPruneMissingBrowserRows() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                role: "browser", orderIndex: 0, lastSeenAt: "now"))

        var didMutate = true
        didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)

        XCTAssertFalse(didMutate)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).filter { $0.role == "browser" }.count, 1)
    }

    // Tests updating settings does not promote stopped workspaces to running just because tracked runtime leftovers exist.
    func testUpdateWorkspaceSettingsDoesNotPromoteStoppedWorkspaceWithTrackedRuntimeLeftovers() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "job", command: "echo job", terminalApp: nil, terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "job", command: "echo job")]
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
        let repo = try makeTempGitRepo(name: "refresh-skip-archived")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let defaultWorkspace = try XCTUnwrap(
            try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false).first(where: { $0.isDefault }))
        let activeWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "archived")
        _ = try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: defaultWorkspace.id, app: "Spaces", title: "default-stale", role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: activeWorkspace.id, app: "Spaces", title: "active-stale", role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: archivedWorkspace.id, app: "Spaces", title: "archived-stale", role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))

        // Why: confirm bulk refresh reconciles active workspaces only and leaves archived workspace rows unchanged.
        // Remaining risk: archived rows are intentionally left untouched until explicit archive/cleanup paths run.
        var result: WorkspaceOrchestrator.RefreshResult?
        result = try orchestrator.refreshAllWorkspaceWindows()

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

    // Tests update workspace settings leaves stopped workspaces stopped when only stale runtime leftovers exist.
    func testUpdateWorkspaceSettingsLeavesStoppedWorkspaceStoppedWhenRuntimeIndicatorsExist() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: nil, terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Why: isolate store-state transition coverage from real window manager availability.
        // Remaining risk: reconciliation against rapidly changing real windows remains untested here.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }

        let updated = try store.workspace(id: workspace.id)
        XCTAssertEqual(updated?.isRunning, false)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).count, 1)
        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.lifecycleState, .stopped)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .partial)
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

    func testUpdateProjectConfigWithWorkspaceSyncAppliesReviewedSettingsToWorkspaces() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        let updatedProject = try orchestrator.updateProjectConfig(projectID: project.id, updateAllWorkspaces: true) { config in
            config.stopScript = "echo reviewed-stop"
            config.ports = [ServiceDefinition(name: "api")]
            config.processes = [ProcessTemplate(name: "api", command: "npm run api")]
        }

        XCTAssertEqual(updatedProject.stopScript, "echo reviewed-stop")
        let settings = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id))
        XCTAssertEqual(settings.stopScript, "echo reviewed-stop")
        XCTAssertEqual(settings.ports.map(\.name), ["api"])
        XCTAssertEqual(settings.processes.first?.name, "api")
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-live-session"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "shell-1", workingDirectory: workspace.dir,
                    shell: "/bin/zsh", command: nil, createdAt: "now", workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now", title: "shell-1", workingDirectory: workspace.dir), paths: paths)

            XCTAssertTrue(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID))
        }

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
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
        let parentWorkspace = makeWorkspaceRecord(projectID: project.id, dir: parentDir.path)
        let childWorkspace = makeWorkspaceRecord(projectID: project.id, dir: childDir.path)
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

    // Guards the P2 leak this was fixed for: before every terminal session was workspace-owned,
    // a `spaces terminal command` session with no window/process/agent row and no stamped
    // workspace resolved to no workspace at all, so `stopAdHocBuiltInTerminalSession(sessionID:)`
    // returned false without ever asking the daemon to stop the shell — the pane closed but the
    // process kept running. With every launch configuration always carrying a workspace id, the
    // self-resolving stop path must now terminate that same shape of session.
    func testStopAdHocBuiltInTerminalSessionTerminatesWorkspaceOwnedSessionWithNoOwnerRow() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "terminal-command-session"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "shell", workingDirectory: workspace.dir,
                    shell: "/bin/zsh", command: nil, createdAt: "now", workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now", title: "shell", workingDirectory: workspace.dir), paths: paths)

            XCTAssertTrue(try orchestrator.stopAdHocBuiltInTerminalSession(sessionID: sessionID))
        }

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
    }

    func testResolveWorkspaceIDForTerminalCommandPrefersExplicitID() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        let resolved = try orchestrator.resolveWorkspaceIDForTerminalCommand(explicitWorkspaceID: workspace.id, cwd: "/somewhere/else")

        XCTAssertEqual(resolved, workspace.id)
    }

    func testResolveWorkspaceIDForTerminalCommandMatchesDeepestContainingWorkspace() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let parentDir = root.appendingPathComponent("project", isDirectory: true)
        let childDir = parentDir.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        let project = makeProjectRecord(dir: parentDir.path)
        let parentWorkspace = makeWorkspaceRecord(projectID: project.id, dir: parentDir.path)
        let childWorkspace = makeWorkspaceRecord(projectID: project.id, dir: childDir.path)
        try store.upsert(project: project)
        try store.upsert(workspace: parentWorkspace)
        try store.upsert(workspace: childWorkspace)

        let resolved = try orchestrator.resolveWorkspaceIDForTerminalCommand(
            explicitWorkspaceID: nil, cwd: childDir.appendingPathComponent("src").path)

        XCTAssertEqual(resolved, childWorkspace.id)
    }

    func testResolveWorkspaceIDForTerminalCommandThrowsOutsideAnyWorkspace() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        _ = try orchestrator.addProject(dir: projectDir.path)

        XCTAssertThrowsError(
            try orchestrator.resolveWorkspaceIDForTerminalCommand(explicitWorkspaceID: nil, cwd: root.appendingPathComponent("outside").path)
        ) { error in XCTAssertTrue(error.localizedDescription.contains("Spaces workspace")) }
    }

    func testRenameAdHocBuiltInTerminalSessionPersistsUserTitleOverRuntimeTitleUpdates() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let otherWorkspace = makeWorkspaceRecord(projectID: project.id, dir: root.appendingPathComponent("other", isDirectory: true).path)
        try store.upsert(workspace: otherWorkspace)
        let sessionID = "ad-hoc-rename-session"
        try store.upsert(
            window: WindowRecord(
                id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            let launchConfiguration = TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "shell-1", workingDirectory: workspace.dir,
                shell: "/bin/zsh", command: nil, createdAt: "now", workspaceID: workspace.id, kind: .shell)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "now", title: "vim main.swift", workingDirectory: workspace.dir), paths: paths)

            XCTAssertThrowsError(try orchestrator.renameAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID, title: "  ")) {
                error in XCTAssertTrue(error.localizedDescription.contains("title"))
            }
            XCTAssertFalse(try orchestrator.renameAdHocBuiltInTerminalSession(workspaceID: otherWorkspace.id, sessionID: sessionID, title: "x"))
            XCTAssertTrue(
                try orchestrator.renameAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID, title: "  build watcher  "))

            let window = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first { $0.id == "terminal-window" })
            XCTAssertEqual(window.name, "build watcher")
            XCTAssertEqual(try TerminalSessionPersistence.readLaunchConfiguration(paths: paths).userTitle, "build watcher")

            // Neither a later Ghostty set_title-driven runtime rewrite nor a relaunch-style
            // launch-configuration rewrite may clobber the manual rename.
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                    state: .running, updatedAt: "later", title: "nvim other.swift", workingDirectory: workspace.dir), paths: paths)
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            let entry = try XCTUnwrap(try TerminalSessionCatalog.listLiveSessions().first { $0.sessionID == sessionID })
            XCTAssertEqual(entry.effectiveTitle, "build watcher")
        }
    }

    func testRenameAdHocBuiltInTerminalSessionRefusesConfiguredProcessSessions() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "process-owned-session"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "api", workingDirectory: workspace.dir,
                    shell: "/bin/zsh", command: nil, createdAt: "now", workspaceID: workspace.id, kind: .process), paths: paths)

            XCTAssertFalse(try orchestrator.renameAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID, title: "renamed"))
        }
    }

    // Tests workspace settings and accessors reflect store state by arranging representative inputs and asserting the expected result.
    func testWorkspaceSettingsAndAccessorsReflectStoreState() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let api = ServiceDefinition(id: "port-api", name: "api")
        let web = ServiceDefinition(id: "port-web", name: "web")
        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: [api, web])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [4100, 4101], names: [api.name, web.name], definitionIDs: [api.id, web.id])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "job", command: "echo job", terminalApp: nil, terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Why: keep this test focused on persisted settings/accessor behavior.
        // Remaining risk: browser-session behavior with real Chrome is intentionally excluded in this unit.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.stopScript = "echo workspace-stop"
            settings.ports = [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")]
            settings.processes = [ProcessTemplate(name: "job", command: "echo job")]
            settings.browserSessions = []
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
        XCTAssertEqual(settings?.stopScript, "echo workspace-stop")
        XCTAssertEqual(settings?.processes.first?.name, "job")
        XCTAssertTrue(settings?.browserSessions.isEmpty ?? false)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id), [4100, 4101])
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).count, 1)
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
            p.ports = [ServiceDefinition(name: "api")]
            p.processes = [ProcessTemplate(name: "api", command: "npm start")]
        }

        let updated = try store.project(id: project.id)
        XCTAssertEqual(updated?.setupScript, "echo setup")
        XCTAssertEqual(updated?.stopScript, "echo stop")
        XCTAssertEqual(updated?.ports.count, 1)
        XCTAssertEqual(updated?.processes.count, 1)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "shell", role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        // Why: verify refreshAllWorkspaceWindows iterates workspaces and returns correct counts.
        var result: WorkspaceOrchestrator.RefreshResult!
        result = try orchestrator.refreshAllWorkspaceWindows()

        XCTAssertTrue(result.didMutateDB)
        XCTAssertEqual(result.trackedWindowCounts[workspace.id], 0)
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

    // Tests workspaceSettings seeds and returns defaults for workspace without explicit settings by arranging representative inputs and asserting the expected result.
    func testWorkspaceSettingsReturnsDefaultsWhenNotExplicitlySet() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: projectDir.path)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir.path)
        try store.upsert(workspace: workspace)

        // workspaceSettings seeds defaults when no settings exist; returns an empty (non-nil) settings object.
        let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
        XCTAssertNotNil(settings)
        XCTAssertNil(settings?.stopScript)
        XCTAssertTrue(settings?.ports.isEmpty ?? false)
        XCTAssertTrue(settings?.processes.isEmpty ?? false)
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
            id: defaultWS.id, projectID: project.id, dir: defaultWS.dir, dirname: defaultWS.dirname, branch: defaultWS.branch, isDefault: true,
            isArchived: true, isRunning: defaultWS.isRunning, lastLaunchedAt: defaultWS.lastLaunchedAt)
        try store.upsert(workspace: archived)
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: defaultWS.id)).isArchived)

        // updateProjectConfig calls ensureDefaultWorkspace, which should revive the archived default workspace.
        try orchestrator.updateProjectConfig(projectID: project.id) { _ in }

        let revived = try XCTUnwrap(store.workspace(id: defaultWS.id))
        XCTAssertFalse(revived.isArchived)
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
            id: workspaceID, projectID: normalizedDir, dir: normalizedDir, dirname: nil, branch: nil, isDefault: true, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)
        XCTAssertFalse(try store.workspaceSettingsExists(workspaceID: workspaceID))

        let orchestrator = WorkspaceOrchestrator(store: store)
        try orchestrator.updateProjectConfig(projectID: normalizedDir) { _ in }

        XCTAssertFalse(try store.workspaceSettingsExists(workspaceID: workspaceID))
    }

    // Tests openWorkspaceTerminal throws invalidArgument when the workspace is archived.
    func testOpenWorkspaceTerminalThrowsForArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Archive the workspace directly via the store.
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)

        XCTAssertThrowsError(try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id)) { error in
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

    // MARK: - resolvedWorkspaceBrowserSessions

    // Tests resolvedWorkspaceBrowserSessions returns sessions with static URLs unchanged.
    func testResolvedWorkspaceBrowserSessionsReturnsStaticURLsUnchanged() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/projects/app")
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

    // Tests passive resolvedWorkspaceBrowserSessions resolves device-local browser display without opening SSH forwards.
    func testResolvedWorkspaceBrowserSessionsPassiveLocalDoesNotOpenForward() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        let workspace = WorkspaceRecord(
            id: "workspace-a", projectID: project.id, dir: "/projects/app", runtimePath: "/projects/app", dirname: nil, branch: "main",
            baseBranch: "main", isDefault: false, isArchived: false, isRunning: true, lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["port"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(name: "App", url: "http://localhost:$SPACES_PORT_PORT")])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.map(\.url), ["http://localhost:3000"])
    }

    // Tests resolvedWorkspaceBrowserSessions deduplicates sessions that resolve to the same URL.
    func testResolvedWorkspaceBrowserSessionsDeduplicatesSameResolvedURL() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["port"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "First", url: "http://localhost:$SPACES_PORT_PORT"),
                BrowserSession(name: "Duplicate", url: "http://localhost:$SPACES_PORT_PORT"),
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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/projects/app")
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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["port"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "App", url: "http://localhost:$SPACES_PORT_PORT"),
                BrowserSession(name: "Admin", url: "http://localhost:$SPACES_PORT_PORT/admin"),
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
}
