import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {

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

    // Tests check and update process statuses marks dead process as exited by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesMarksDeadProcessAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir.path)
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

    func testWorkspaceIDForTerminalSessionFallsBackToRunningProcessSessionID() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: workspace.id, templateName: "api", command: "zsh", terminalApp: TerminalHost.spaces.appName,
                windowID: nil, terminalTrackingID: "session-456", terminalNativeID: "session-456", pid: 1234, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "2026-05-10T18:05:00Z", exitedAt: nil))

        XCTAssertEqual(try orchestrator.workspaceIDForTerminalSession("session-456"), workspace.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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

    func testRefreshWorkspaceWindowsKeepsBuiltInProcessTerminalWindowAfterOwnerCloses() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path, )
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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

    // Tests launch workspace without processes does not require terminal runtime.
    func testLaunchWorkspaceWithoutProcessesDoesNotRequireTerminalRuntime() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }

        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

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

    // MARK: - stopWorkspace

    // Tests stopWorkspace with running processes clears all runtime state by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClearsAllRuntimeState() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

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
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/nonexistent/project/path/feature")
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo this-should-not-run")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        XCTAssertTrue(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

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

    // Tests upWorkspace allocates ports when port definitions exist but no ports are allocated by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceAllocatesPortsWhenDefinitionsExistButNoPortsAllocated() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Set a stop script that would fail if the directory doesn't exist.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.stopScript = "echo stopped" }

        // Mark workspace as running so stop can proceed.
        var runningWorkspace = workspace
        runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, dir: "/nonexistent/workspace-\(UUID().uuidString)", dirname: workspace.dirname,
            branch: workspace.branch, baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived,
            isHidden: workspace.isHidden, isRunning: true, lastLaunchedAt: nil, notes: nil)
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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Insert a tracked "editor" window (non-browser, non-Spaces) so lines 702-705 are reached.
        let editorWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Cursor", title: "editor", windowID: 42, role: "editor", orderIndex: 100,
            lastSeenAt: "2024-01-01T00:00:00Z")
        try store.upsert(window: editorWindow)

        // Mark workspace as running.
        let runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, dir: projectDir.path, dirname: workspace.dirname, branch: workspace.branch,
            baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived, isHidden: workspace.isHidden,
            isRunning: true, lastLaunchedAt: nil, notes: nil)
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

    // Tests checkAndUpdateProcessStatuses marks a dead process as exited and calls handleProcessExit .none case by arranging representative inputs and asserting the expected result.

    // Tests checkAndUpdateProcessStatuses skips recently started processes within the 10-second grace window by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesSkipsRecentlyStartedProcess() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

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
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

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

    // Tests upWorkspace throws invalidArgument when the workspace is archived (covers guard !workspace.isArchived else throw).
    func testUpWorkspaceThrowsForArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)

        XCTAssertThrowsError(try orchestrator.upWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived"))
        }
    }
}
