import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {

    // Running a single configured process (the ⌘-number "run process" shortcut → runConfiguredProcess)
    // on a stopped workspace must release the placeholder port reservation, just as full-workspace launch
    // does. Otherwise PortReserver keeps the assigned port and the launched server dies with EADDRINUSE.
    func testRunConfiguredProcessReleasesPortReservationSoServerCanBind() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "web")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$SPACES_WEB_PORT npm run dev")]
        }
        // The workspace is stopped, so saving settings reserved its assigned port via PortReserver.
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))

        try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "web")

        XCTAssertFalse(
            PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id),
            "Running a configured process must release the reservation so the server can bind its port.")
        XCTAssertTrue(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).count, 1)

        PortReserver.shared.releasePorts(workspaceID: workspace.id)
    }

    // If a single-process launch fails after its placeholder reservation was released, the reservation
    // must be restored — otherwise the stopped workspace leaves its pinned port unheld and another
    // process could grab it before the next launch. Mirrors the full-workspace launch restore path.
    func testRunConfiguredProcessRestoresPortReservationWhenLaunchFails() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalSessionLauncher: { _ in throw TerminalLaunchFailure() })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "web")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$SPACES_WEB_PORT npm run dev")]
        }
        // Saving settings for a stopped workspace reserves its assigned port via PortReserver.
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))

        XCTAssertThrowsError(try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "web"))

        XCTAssertFalse(
            try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning, "A failed single-process launch must leave the workspace stopped.")
        XCTAssertTrue(
            PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id),
            "A failed single-process launch must restore the placeholder port reservation it released.")

        PortReserver.shared.releasePorts(workspaceID: workspace.id)
    }

    // If a workspace is already running because of an ad-hoc terminal, a failed configured-process
    // launch must not restore placeholder reservations. Running workspaces intentionally leave service
    // ports unreserved; users resolve conflicts manually if another process claims one.
    func testRunConfiguredProcessDoesNotRestorePortReservationWhenAlreadyRunningLaunchFails() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalSessionLauncher: { _ in throw TerminalLaunchFailure() })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "web")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$SPACES_WEB_PORT npm run dev")]
        }
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-07-01T00:00:00Z")

        XCTAssertThrowsError(try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "web"))

        XCTAssertTrue(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertFalse(
            PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id),
            "A failed launch from an already-running workspace must leave service ports unreserved.")

        PortReserver.shared.releasePorts(workspaceID: workspace.id)
    }

    func testValidateProcessTemplateAcceptsShellVariableSyntax() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        XCTAssertNoThrow(try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: "PORT=${FRONTEND_PORT:-3000} npm run dev")))
    }

    func testValidateProcessTemplateAcceptsCompositeShellCommand() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        XCTAssertNoThrow(try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: "cd app && npm run dev | tee log.txt")))
    }

    func testValidateProcessTemplateRejectsBlankCommand() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

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
        let orchestrator = makeTestOrchestrator(store: store)

        XCTAssertNoThrow(
            try orchestrator.validateProcessTemplate(ProcessTemplate(name: "web", command: "PORT=$FRONTEND_PORT npm run dev | tee log.txt")))
    }

    // Tests check and update process statuses marks dead process as exited by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesMarksDeadProcessAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        // Create a process with a PID that doesn't exist
        let deadProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
            terminalTrackingID: "workspace-session", pid: 99999, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: deadProcess)
        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        XCTAssertTrue(didUpdate)
        let updated = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .exited)
        XCTAssertNotNil(updated?.exitedAt)
    }

    // The exit reconcile runs on its own store connection and takes no workspace lifecycle lock, so a
    // stop can delete the process row after the reconcile snapshotted it. Marking the snapshot exited
    // must not re-create the row: a resurrected row reports the configured process as "exited" forever,
    // where the deleted row correctly reports it as not started.
    func testStopDuringProcessReconcileDoesNotResurrectDeletedProcess() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let interleave = ReconcileInterleave()
        let orchestrator = makeTestOrchestrator(store: store, currentDate: { interleave.runOnce() })

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
            terminalTrackingID: "session-old", pid: 99999, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: process)

        // refreshProcessStatuses reads its snapshot immediately before it reads the clock, so deleting
        // here lands the stop between the snapshot and the exited write.
        interleave.action = { try? store.deleteRunningProcess(id: process.id) }
        let didUpdate = try orchestrator.refreshProcessStatuses(workspaceID: workspace.id)

        XCTAssertTrue(
            try store.runningProcesses(workspaceID: workspace.id).isEmpty,
            "A process stopped mid-reconcile must stay deleted instead of reappearing as exited.")
        XCTAssertFalse(didUpdate, "The reconcile wrote nothing, so it must not report a change.")
    }

    // Mirror image of the stop race: a restart replaces the row's terminal session while the reconcile
    // holds a snapshot of the old one. The stale exited write must not strand the live process's row as
    // exited, nor rebind it to the terminated session.
    func testRestartDuringProcessReconcileKeepsRestartedProcessRunning() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let interleave = ReconcileInterleave()
        let orchestrator = makeTestOrchestrator(store: store, currentDate: { interleave.runOnce() })

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
            terminalTrackingID: "session-old", pid: 99999, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: process)

        interleave.action = {
            let restarted = RunningProcessRecord(
                id: process.id, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
                terminalTrackingID: "session-new", pid: Int(getpid()), status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: ISO8601DateFormatter().string(from: Date()), exitedAt: nil)
            try? store.upsert(runningProcess: restarted)
        }
        _ = try orchestrator.refreshProcessStatuses(workspaceID: workspace.id)

        let reconciled = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(reconciled.status, .running, "A process restarted mid-reconcile must not be marked exited from the stale snapshot.")
        XCTAssertEqual(reconciled.terminalTrackingID, "session-new", "The restarted row must keep its new terminal session.")
        XCTAssertNil(reconciled.exitedAt)
    }

    // Tests check and update process statuses skips newly started processes by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesSkipsNewlyStartedProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        // Create a process that just started (within grace period)
        let newProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
            terminalTrackingID: "workspace-session", pid: 99999, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)), exitedAt: nil)
        try store.upsert(runningProcess: newProcess)
        _ = try orchestrator.checkAndUpdateProcessStatuses()
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .running)
        XCTAssertNil(unchanged?.exitedAt)
    }

    // Tests that a process which dies inside the startup grace window is still
    // reconciled when grace is ignored — the path the DispatchSourceProcess exit
    // observer uses, since the kernel has authoritatively reported the exit.
    func testCheckAndUpdateProcessStatusesMarksRecentDeadProcessWhenIgnoringGrace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let recentDeadProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
            terminalTrackingID: "workspace-session", pid: 99999, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)), exitedAt: nil)
        try store.upsert(runningProcess: recentDeadProcess)

        XCTAssertTrue(try orchestrator.checkAndUpdateProcessStatuses(ignoreStartupGracePeriod: true))
        let updated = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .exited)
        XCTAssertNotNil(updated?.exitedAt)
    }

    // A Spaces terminal-backed process can be recorded running before its child PID is persisted
    // (the launch returns once the session is ready; the child PID lands in terminal runtime state
    // slightly later). The exit monitor must still see such a process, so runningOwnedProcessPIDs
    // resolves the PID through runtime state when the DB pid is missing.
    func testRunningOwnedProcessPIDsResolvesPIDFromRuntimeStateWhenDatabasePIDMissing() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try withEnv(name: SpacesProfile.runtimeDirectoryEnvironmentVariable, value: runtimeDir.path) {
            let sessionID = "session-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try seedTerminalSessionRow(sessionID: sessionID, paths: paths)
            // childPID is a live pid (this test process); the DB record carries no pid yet.
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: Int32(getpid()), state: .running,
                    updatedAt: "2026-05-09T17:00:00Z"), paths: paths)
            let process = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: ISO8601DateFormatter().string(from: Date()), exitedAt: nil)
            try store.upsert(runningProcess: process)

            XCTAssertTrue(try orchestrator.runningOwnedProcessPIDs().contains(Int(getpid())))
        }
    }

    // Without a resolvable runtime PID, a pid-less running record contributes nothing — the monitor
    // has nothing to observe — rather than inserting a bogus zero/negative pid.
    func testRunningOwnedProcessPIDsSkipsRecordWithNoResolvablePID() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
            terminalTrackingID: "session-without-runtime-state", pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date()), exitedAt: nil)
        try store.upsert(runningProcess: process)

        try withEnv(name: SpacesProfile.runtimeDirectoryEnvironmentVariable, value: runtimeDir.path) {
            XCTAssertTrue(try orchestrator.runningOwnedProcessPIDs().isEmpty)
        }
    }

    func testCheckAndUpdateProcessStatusesTreatsZombiePIDAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

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
            # Write to a sibling temp file and rename onto the final path so readers
            # polling for file existence never observe a truncated/empty file.
            tmp = path.with_suffix(".tmp")
            tmp.write_text(str(pid))
            os.replace(tmp, path)
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
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
            terminalTrackingID: "workspace-session", pid: zombiePID, status: .running, logPath: nil, lastOutputAt: nil,
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
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        // Create a process without a PID (still starting up)
        let noPidProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
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
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        // Create an already-exited process
        let exitedProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
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
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }

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
        let orchestrator = makeTestOrchestrator(
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

        try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: "api")

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
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: workspace.id, templateName: "api", command: "zsh", terminalApp: TerminalHost.spaces.appName,
                terminalTrackingID: "session-456", pid: 1234, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2026-05-10T18:05:00Z",
                exitedAt: nil))

        XCTAssertEqual(try orchestrator.workspaceIDForTerminalSession("session-456"), workspace.id)
    }

    func testRefreshWorkspaceWindowsKeepsBuiltInProcessTerminalWindowAfterOwnerCloses() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        _ = project

        let sessionID = "spaces-process-session"
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "window-process-api", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            try seedTerminalSessionRow(sessionID: sessionID, paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 4321,
                    state: .running, updatedAt: "now"), paths: paths)

            _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.map(\.id), ["process-api"])
    }

    // Tests restarting a process recreates a tracked terminal window row even if the stale window row was already pruned.
    func testRestartWorkspaceProcessUsesConfiguredSpacesHostEvenWhenStoredProcessHostDiffers() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
                if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                    try? paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
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
                terminalTrackingID: "session-old", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: "process-api")
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
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
                if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                    try? paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
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
                terminalTrackingID: "old-spaces-session", pid: 999_999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "old-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api", targetURL: nil,
                terminalTrackingID: "old-spaces-session", role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try withEnv(name: "SPACES_TEST_KILL_LOG", value: killLog) {
                try withMockCommands(["kill": killMock]) {
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

    // Tests configured-but-missing processes can be recovered directly without restarting unrelated running processes.
    func testRecoverMissingConfiguredProcessMarksStoppedWorkspaceRunning() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "npm run api")])

        try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: "api")

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.templateName), ["api"])
    }

    func testRecoverMissingConfiguredProcessUsesBuiltInSpacesSessionHost() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
                if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                    try? paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
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
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        var returnedProcess: RunningProcessRecord?
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            returnedProcess = try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: "api")
        }

        XCTAssertEqual(capture.modes, [.owner])
        XCTAssertEqual(capture.sessionIDs.count, 1)
        XCTAssertEqual(returnedProcess?.terminalTrackingID, capture.sessionIDs.first)

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(Set(processes.map(\.templateName)), ["api", "web"])
        let recoveredProcess = try XCTUnwrap(processes.first(where: { $0.templateName == "api" }))
        XCTAssertEqual(recoveredProcess.command, "npm run api")
        XCTAssertEqual(recoveredProcess.status, .running)
        XCTAssertEqual(recoveredProcess.terminalApp, TerminalHost.spaces.appName)
        XCTAssertEqual(recoveredProcess.terminalTrackingID, capture.sessionIDs.first)
        XCTAssertEqual(recoveredProcess.pid, 4321)
        XCTAssertNotNil(recoveredProcess.logPath)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    func testRecoverMissingConfiguredProcessUsesBuiltInSpacesSessionHostWhenNoPriorRuntimeExists() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
                if let paths = try? TerminalSessionPaths.forSession(id: sessionID) {
                    try? paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
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

        var returnedProcess: RunningProcessRecord?
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            returnedProcess = try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: "api")
        }

        XCTAssertEqual(capture.modes, [.owner])
        XCTAssertEqual(capture.sessionIDs.count, 1)
        XCTAssertEqual(returnedProcess?.terminalTrackingID, capture.sessionIDs.first)
        let recoveredProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
        XCTAssertEqual(recoveredProcess.terminalApp, TerminalHost.spaces.appName)
        XCTAssertEqual(recoveredProcess.terminalTrackingID, capture.sessionIDs.first)
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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.templateName, "web")
    }

    func testUpdateWorkspaceSettingsWhileRunningDoesNotReconcileProcessesAndSyncsPorts() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "web", command: "npm run web")])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [24000], names: ["api"])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "worker", command: "npm run worker")]
            settings.ports = [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")]
        }

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.templateName, "web")

        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(namedPorts.map(\.port), [24000, 20000])
        XCTAssertEqual(namedPorts.map(\.name), ["api", "web"])
        // A settings sync persists port assignments but must not re-bind the reservation sockets while
        // the workspace runs: its server processes already own those ports, and re-grabbing one would
        // race the real server for it (EADDRINUSE).
        XCTAssertFalse(PortReserver.shared.reservedWorkspaceIDs().contains(workspace.id))

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 1)
        XCTAssertEqual(runtimeStatus.runtimeHealth, .healthy)
        XCTAssertNil(runtimeStatus.warningSummary)
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
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: processID, workspaceID: workspace.id, app: "Spaces", name: "web", detail: "npm run web", terminalTrackingID: "session-web",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.updateRunningWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(id: process.id, name: "frontend", command: "npm run web:v2", onExit: .notify)],
            restartChangedCommands: true)

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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces",
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
                id: processID, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "LegacyTerminal",
                terminalTrackingID: "session-web", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try orchestrator.updateRunningWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [
                ProcessTemplate(id: process.id, name: "web", command: "cd $SPACES_WORKSPACE_DIR && npm run web | tee log.txt", onExit: .none)
            ], restartChangedCommands: true)

        let running = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(running.map(\.templateName), ["web"])
        XCTAssertEqual(running.first?.command, "cd $SPACES_WORKSPACE_DIR && npm run web | tee log.txt")
        XCTAssertEqual(running.first?.terminalApp, TerminalHost.spaces.appName)
        XCTAssertNotEqual(running.first?.terminalTrackingID, "session-web")
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
                id: "running-web", workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 1111, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "running-worker", workspaceID: workspace.id, templateName: "worker", command: "npm run worker", terminalApp: "Spaces",
                terminalTrackingID: "session-worker", pid: 2222, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "window-web", workspaceID: workspace.id, app: "Spaces", name: "web", detail: "npm run web", terminalTrackingID: "session-web",
                role: "terminal", orderIndex: 100, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: "window-worker", workspaceID: workspace.id, app: "Spaces", name: "worker", detail: "npm run worker",
                terminalTrackingID: "session-worker", role: "terminal", orderIndex: 101, lastSeenAt: "now"))

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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "later"))

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
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

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
                terminalApp: "Spaces", terminalTarget: nil, pid: 999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))

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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces",
                terminalTarget: nil, pid: 999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "Spaces",
                terminalTarget: nil, pid: 999, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

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
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "shell", role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependency: Spaces cleanup via `osascript`.
        // Why: verify cleanup semantics without touching real windows/processes.
        // Remaining risk: real process/window teardown can fail or race differently than this mocked path.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) { try orchestrator.stopWorkspace(workspaceID: workspace.id) }
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
        let orchestrator = makeTestOrchestrator(
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
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "frontend",
                terminalTrackingID: "spaces-frontend", role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "backend",
                terminalTrackingID: "spaces-backend", role: "terminal", orderIndex: 201, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "frontend", command: "npm run dev",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "spaces-frontend", pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "backend", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "spaces-backend", pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(closeCapture.sessionIDs, ["spaces-frontend", "spaces-backend"])
        XCTAssertEqual(terminateCapture.sessionIDs, ["spaces-frontend", "spaces-backend"])
    }

    func testStopWorkspaceClosesBuiltInTerminalSession() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
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
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "tracked-window-spaces", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    func testStopWorkspaceIsVetoedByDaemonHandoffAndPreservesRows() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        // During a daemon handoff the terminator no-ops, so stopping must not delete the workspace's rows;
        // otherwise the replacement daemon adopts a still-live terminal whose records were erased.
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) },
            daemonHandoffInProgress: { true })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        _ = project

        let sessionID = "spaces-session-handoff-veto"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "running-process-handoff", workspaceID: workspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "tracked-window-handoff", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        XCTAssertThrowsError(try orchestrator.stopWorkspace(workspaceID: workspace.id)) { error in
            guard case WorkspaceError.daemonHandoffInProgress = error else { return XCTFail("expected daemonHandoffInProgress, got \(error)") }
        }

        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty, "no terminal should be terminated while a handoff is vetoing the stop")
        XCTAssertFalse(try store.runningProcesses(workspaceID: workspace.id).isEmpty, "running process rows must survive the vetoed stop")
        XCTAssertFalse(try store.windows(workspaceID: workspace.id).isEmpty, "window rows must survive the vetoed stop")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true, "workspace must remain running after a vetoed stop")
    }

    func testStopWorkspaceTerminatesAdHocBuiltInTerminalSession() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
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
                targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    func testStopWorkspaceCompletesWhenAdHocTerminalCatalogCannotBeEnumerated() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "spaces-session-stop-catalog-unavailable"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "running-process-spaces-catalog-unavailable", workspaceID: workspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "now", exitedAt: nil))

        let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
        let unavailableDatabasePath = root.appendingPathComponent("catalog-db-unavailable", isDirectory: true)
        try FileManager.default.createDirectory(at: unavailableDatabasePath, withIntermediateDirectories: true)
        setenv(SpacesProfile.databasePathEnvironmentVariable, unavailableDatabasePath.path, 1)
        defer {
            if let originalDatabasePath {
                setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
            } else {
                unsetenv(SpacesProfile.databasePathEnvironmentVariable)
            }
        }

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    func testUserClosedBuiltInTerminalSessionLeavesOwningProcessRunning() throws {
        let store = try makeTemporaryStore()
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
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
                terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "process-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        XCTAssertFalse(try orchestrator.stopBuiltInTerminalSessionClosedByUser(sessionID: sessionID))

        XCTAssertTrue(closeCapture.sessionIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.id), ["process-1"])
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).map(\.terminalTrackingID), [sessionID])
    }

    // Tests launch workspace without processes does not require terminal runtime.
    func testLaunchWorkspaceWithoutProcessesDoesNotRequireTerminalRuntime() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    // Tests restart workspace stops then launches by arranging representative inputs and asserting the expected result.
    func testRestartWorkspaceStopsThenLaunches() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "shell", role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) { try orchestrator.restartWorkspace(workspaceID: workspace.id) }

        let running = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertTrue(running.isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    // Tests up workspace launches when stopped by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceLaunchesWhenStopped() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.upWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests up workspace launches multiple configured processes in one Spaces window using separate tabs.

    // Tests up workspace does nothing to running processes when runtime indicators exist and restart is disabled by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceDoesNothingWhenRuntimeIndicatorsExistByDefault() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.upWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).count, 1)
    }

    // Tests up workspace restarts exited processes when workspace is running by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceRestartsExitedProcessesWhenRunning() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "echo web", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "now"))

        try orchestrator.upWorkspace(workspaceID: workspace.id)

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
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
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
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "api", terminalTrackingID: "workspace-session",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: processID, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces",
                terminalTrackingID: "workspace-session", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        )

        try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: processID)

        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try store.workspace(id: workspace.id)?.isRunning ?? true)
    }

    func testStopWorkspaceProcessTerminatesBuiltInSession() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
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
                terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "api", detail: "npm run api",
                targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: processID)

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try store.workspace(id: workspace.id)?.isRunning ?? true)
    }

    // MARK: - stopWorkspace

    // Tests stopWorkspace with running processes clears all runtime state by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClearsAllRuntimeState() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "api", role: "terminal", orderIndex: 0, lastSeenAt: "now"))
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
        let orchestrator = makeTestOrchestrator(store: store)
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
        let orchestrator = makeTestOrchestrator(store: store)

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
        let orchestrator = makeTestOrchestrator(store: store)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Mark workspace as running with a tracked process.
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Why: exercise the restartIfRunning=true branch which calls stop then launch.
        try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)

        // After restart, process list is cleared and workspace re-launched.
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests upWorkspace allocates ports when port definitions exist but no ports are allocated by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceAllocatesPortsWhenDefinitionsExistButNoPortsAllocated() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Add port definitions so that portDefinitions.count > 0 with no ports allocated yet.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "web"), ServiceDefinition(name: "api")]
        }

        try orchestrator.upWorkspace(workspaceID: workspace.id)

        // Ports should now be allocated.
        let allocatedPorts = try store.workspacePorts(workspaceID: workspace.id)
        XCTAssertEqual(allocatedPorts.count, 2)
    }

    // Tests stopWorkspace skips stop script when workspace directory is missing by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceSkipsStopScriptWhenWorkspaceDirMissing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
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
            branch: workspace.branch, baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isHidden: workspace.isHidden, isRunning: true,
            lastLaunchedAt: nil, notes: nil)
        try store.upsert(workspace: runningWorkspace)

        // Stop should succeed (skip script because dir is missing) rather than throw.
        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        XCTAssertTrue(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
    }

    // Tests stopWorkspace removes non-Spaces tracked window records by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClosesNonSpacesTrackedWindows() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Insert a tracked "editor" window (non-browser, non-Spaces) so lines 702-705 are reached.
        let editorWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Cursor", title: "editor", role: "editor", orderIndex: 100,
            lastSeenAt: "2024-01-01T00:00:00Z")
        try store.upsert(window: editorWindow)

        // Mark workspace as running.
        let runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, dir: projectDir.path, dirname: workspace.dirname, branch: workspace.branch,
            baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isHidden: workspace.isHidden, isRunning: true, lastLaunchedAt: nil,
            notes: nil)
        try store.upsert(workspace: runningWorkspace)

        // Stop workspace: removes the tracked editor window record.
        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

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
        let orchestrator = makeTestOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Insert a process with a dead PID but very recent startedAt (within 10-second grace)
        let recentStart = ISO8601DateFormatter().string(from: Date())
        let proc = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "sleep 1", terminalApp: "Terminal",
            terminalTrackingID: nil, pid: 2_000_000, status: .running, logPath: nil, lastOutputAt: nil, startedAt: recentStart, exitedAt: nil)
        try store.upsert(runningProcess: proc)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        XCTAssertFalse(didUpdate)
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.first?.status, .running)
    }

    func testCheckAndUpdateProcessStatusesTreatsZombieProcessAsExited() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
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
            # Write to a sibling temp file and rename onto the final path so readers
            # polling for file existence never observe a truncated/empty file.
            tmp_file = pid_file + ".tmp"
            with open(tmp_file, "w", encoding="utf-8") as fh:
                fh.write(str(child_pid))
            os.replace(tmp_file, pid_file)
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
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "sleep 1", terminalApp: "Terminal",
            terminalTrackingID: nil, pid: zombiePID, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2020-01-01T00:00:00Z",
            exitedAt: nil)
        try store.upsert(runningProcess: process)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()

        XCTAssertTrue(didUpdate)
        let updated = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .exited)
        XCTAssertNotNil(updated?.exitedAt)
    }

    /// Archiving removes the record, so `upWorkspace` has nothing to bring up.
    func testUpWorkspaceThrowsAfterArchive() throws {
        let repo = try makeTempGitRepo(name: "up-after-archive")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertNil(try store.workspace(id: workspace.id))
        XCTAssertThrowsError(try orchestrator.upWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace not found"))
        }
    }
}

/// Runs a one-shot mutation from an injected orchestrator closure, so a concurrent stop, restart, or
/// reconcile write can be interleaved at an exact point of a real product code path without adding a
/// test-only seam. `runOnce()` is the clock form: `refreshProcessStatuses` reads the clock immediately
/// after it snapshots the running processes.
final class ReconcileInterleave: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingAction: (() throws -> Void)?
    private var caughtError: (any Error)?

    var action: (() throws -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return pendingAction
        }
        set {
            lock.lock()
            pendingAction = newValue
            lock.unlock()
        }
    }

    var thrownError: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return caughtError
    }

    func run() {
        lock.lock()
        let pending = pendingAction
        pendingAction = nil
        lock.unlock()
        guard let pending else { return }
        do { try pending() } catch {
            lock.lock()
            caughtError = error
            lock.unlock()
        }
    }

    func runOnce() -> Date {
        run()
        return Date()
    }
}
