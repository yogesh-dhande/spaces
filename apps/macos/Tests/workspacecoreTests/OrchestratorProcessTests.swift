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
        // The workspace is stopped, so the daemon's reservation pass holds its assigned port.
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        let assignedPorts = try store.workspacePorts(workspaceID: workspace.id)
        addTeardownBlock { clearPortReservationsForTest(assignedPorts) }
        try PortReservationReconciler(store: store).reconcile()
        XCTAssertTrue(PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts))

        try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "web")

        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isDisjoint(with: assignedPorts),
            "Running a configured process must release the reservation so the server can bind its port.")
        XCTAssertTrue(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).count, 1)
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
            store: store, builtInTerminalWindowOpener: { _, _, _ in }, builtInTerminalSessionLauncher: { _ in throw TerminalLaunchFailure() })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "web")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$SPACES_WEB_PORT npm run dev")]
        }
        // The workspace is stopped, so the daemon's reservation pass holds its assigned port.
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        let assignedPorts = try store.workspacePorts(workspaceID: workspace.id)
        addTeardownBlock { clearPortReservationsForTest(assignedPorts) }
        try PortReservationReconciler(store: store).reconcile()
        XCTAssertTrue(PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts))

        XCTAssertThrowsError(try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "web"))

        XCTAssertFalse(
            try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning, "A failed single-process launch must leave the workspace stopped.")
        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts),
            "A failed single-process launch must restore the placeholder port reservation it released.")
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
            store: store, builtInTerminalWindowOpener: { _, _, _ in }, builtInTerminalSessionLauncher: { _ in throw TerminalLaunchFailure() })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "web")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$SPACES_WEB_PORT npm run dev")]
        }
        let assignedPorts = try store.workspacePorts(workspaceID: workspace.id)
        addTeardownBlock { clearPortReservationsForTest(assignedPorts) }
        // Placeholders held from when the workspace was stopped: an ad-hoc terminal marked it running
        // without a reservation pass having run since.
        try PortReservationReconciler(store: store).reconcile()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-07-01T00:00:00Z")

        XCTAssertThrowsError(try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "web"))

        XCTAssertTrue(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isDisjoint(with: assignedPorts),
            "A failed launch from an already-running workspace must leave service ports unreserved.")

        // The failed launch must not leave a runtime-start hold behind: once the workspace stops, the
        // first reconcile pass that sees it stopped has to be able to hold its pinned ports again. A
        // lingering hold makes `sync` skip the bind, and nothing clears it until the workspace runs
        // again or the daemon restarts.
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: nil)
        try PortReservationReconciler(store: store).reconcile()

        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts),
            "Once the workspace stops, its pinned ports must be held again rather than blocked by the failed launch's hold.")
    }

    /// Codex round 4 (P2b) on issue #438: `launchMissingConfiguredProcesses` launches every missing
    /// configured process in one batch under a single `workspace.isRunning == false` snapshot taken
    /// before the batch starts (the workspace is not marked running until after the whole batch
    /// finishes). Without threading batch progress into `launchConfiguredProcess`, a later process
    /// failing would look identical, from that snapshot's point of view, to the single-process case
    /// above where restoring the reservation is correct: `launchConfiguredProcess` cannot tell an
    /// earlier sibling in the same batch already launched and may already be bound to that same
    /// reservation's port. This is the batch counterpart to
    /// `testRunConfiguredProcessDoesNotRestorePortReservationWhenAlreadyRunningLaunchFails`.
    ///
    /// Codex round 5 (P2) extends this with a retry: calling `launchMissingConfiguredProcesses` again
    /// after this same partial failure (A stayed live, B is still missing) filters A out of
    /// `missingTemplates` entirely on the second call, so it never gets a turn in that call's own loop to
    /// mark the batch as having a live launch; the seed has to come from `running` itself.
    func testLaunchMissingConfiguredProcessesDoesNotRestorePortsAfterALaterFailureOnceABatchHasALiveLaunch() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _, _ in },
            builtInTerminalSessionLauncher: { configuration in
                if configuration.title == "B" { throw TerminalLaunchFailure() }
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "web")]
            settings.processes = [ProcessTemplate(name: "A", command: "echo a"), ProcessTemplate(name: "B", command: "npm run dev")]
        }
        // The workspace is stopped, so the daemon's reservation pass holds its assigned port.
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        let assignedPorts = try store.workspacePorts(workspaceID: workspace.id)
        addTeardownBlock { clearPortReservationsForTest(assignedPorts) }
        try PortReservationReconciler(store: store).reconcile()
        XCTAssertTrue(PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts))

        XCTAssertThrowsError(try orchestrator.launchMissingConfiguredProcesses(workspaceID: workspace.id, background: false))

        XCTAssertEqual(
            try orchestrator.runningProcesses(workspaceID: workspace.id).map(\.templateName), ["A"],
            "the first process launches before the second one fails")
        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isDisjoint(with: assignedPorts),
            "a later failure in the same batch must not restore the placeholder reservation over an earlier live launch's port")

        // Retry: B is still the only missing template (A already matches a live row), and B's launcher
        // still throws every time, so the retry fails again the same way.
        XCTAssertThrowsError(try orchestrator.launchMissingConfiguredProcesses(workspaceID: workspace.id, background: false))

        XCTAssertEqual(
            try orchestrator.runningProcesses(workspaceID: workspace.id).map(\.templateName), ["A"],
            "the retry must not disturb the already-live process")
        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isDisjoint(with: assignedPorts),
            "a retry's failure must not restore the placeholder reservation over the still-live process's port either")
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
            builtInTerminalWindowOpener: { sessionID, mode, openIntent in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
                openCapture.openIntents.append(openIntent)
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
        // An ad hoc terminal is opened one at a time by someone about to type in it, so unlike a
        // configured process launch its pane comes forward focused.
        XCTAssertEqual(openCapture.openIntents.map(\.focus), [.focus])
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
            store: store, builtInTerminalWindowOpener: { _, _, _ in },
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
            builtInTerminalWindowOpener: { sessionID, mode, _ in
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
            builtInTerminalWindowOpener: { sessionID, mode, _ in
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
            }, builtInTerminalWindowCloser: { sessionID, _ in closeCapture.sessionIDs.append(sessionID) },
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
            builtInTerminalWindowOpener: { sessionID, mode, _ in
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
            builtInTerminalWindowOpener: { sessionID, mode, _ in
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

    /// Starting a workspace is triggered programmatically (the CLI's `spaces workspace start`, the MCP
    /// tool wrapping it, or a restart of one of its processes), so the panes its configured processes
    /// open must not take the window the user is working in. Each launch still asks for an owner
    /// attachment: only focus is withheld, not ownership.
    func testConfiguredProcessLaunchesAskForNonFocusingPaneOpens() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode, openIntent in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
                capture.openIntents.append(openIntent)
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 9876, state: .running,
                        updatedAt: "2026-05-11T18:00:00Z"), paths: paths)
                try? "process started\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [ProcessTemplate(name: "api", command: "echo api"), ProcessTemplate(name: "web", command: "echo web")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            let api = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
            try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: api.id)
        }

        XCTAssertEqual(capture.openIntents.map(\.focus), [.withoutFocus, .withoutFocus, .withoutFocus])
        XCTAssertEqual(capture.modes, [.owner, .owner, .owner])
    }

    /// `spaces workspace restart` is a full stop and relaunch, so it reaches process launch through
    /// `launchProcesses` rather than the per-process restart above. It carries the same intent: the
    /// relaunched panes must not take the user's window either. The close side is asserted alongside,
    /// because the stop closes every pane before the relaunch opens any, and that teardown is the other
    /// half of what a restart does to the client.
    func testProgrammaticWorkspaceRestartAsksForNonFocusingPaneOpens() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode, openIntent in
                capture.sessionIDs.append(sessionID)
                capture.modes.append(mode)
                capture.openIntents.append(openIntent)
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 9876, state: .running,
                        updatedAt: "2026-05-11T18:00:00Z"), paths: paths)
                try? "process started\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
            },
            builtInTerminalWindowCloser: { sessionID, disposition in
                closes.sessionIDs.append(sessionID)
                closes.dispositions.append(disposition)
            },
            // The stop waits for each terminated session to actually end, so the fake terminator has to
            // record the exit the real one would; otherwise the restart spends the whole wait timeout.
            builtInTerminalSessionTerminator: { sessionID in
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
        }

        XCTAssertEqual(capture.openIntents.map(\.focus), [.withoutFocus, .withoutFocus], "the launch and the relaunch both open without focus")
        XCTAssertEqual(capture.modes, [.owner, .owner])
        XCTAssertEqual(capture.sessionIDs.count, 2)
        let firstSessionID = try XCTUnwrap(capture.sessionIDs.first)
        XCTAssertEqual(closes.sessionIDs, [firstSessionID], "the restart closes the first session's pane before opening the replacement")
        XCTAssertEqual(closes.dispositions, [.awaitReplacement], "that pane is held for the replacement rather than torn down")
        XCTAssertEqual(
            capture.openIntents.map(\.replacesSessionID), [nil, firstSessionID],
            "the cold launch replaces nothing and the relaunch names the session whose pane it takes over")
    }

    /// A restart refused at the stop's daemon-handoff guard has closed nothing, so it must release
    /// nothing. Capturing a session is not the same as holding its pane: the guard rejects before any
    /// close goes out, and the sessions are deliberately left alive to be carried across the exec into
    /// the replacement daemon. Releasing what was merely captured would close live panes on a workspace
    /// the restart never touched.
    func testARestartRefusedAtTheHandoffGuardClosesNoPanes() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let closes = TerminalCloseCapture()
        let handoffInProgress = TerminalLaunchAttemptCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, _, _ in
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 9876, state: .running,
                        updatedAt: "2026-05-11T18:00:00Z"), paths: paths)
            },
            builtInTerminalWindowCloser: { sessionID, disposition in
                closes.sessionIDs.append(sessionID)
                closes.dispositions.append(disposition)
            }, builtInTerminalSessionTerminator: { _ in },
            // Off for the cold launch, on for the restart, so the restart is the call the guard rejects.
            daemonHandoffInProgress: { handoffInProgress.count > 0 })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            handoffInProgress.count = 1
            XCTAssertThrowsError(try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)) { error in
                guard case .daemonHandoffInProgress = error as? WorkspaceError else {
                    XCTFail("expected the handoff guard to refuse the restart, got \(error)")
                    return
                }
            }
        }

        XCTAssertTrue(closes.sessionIDs.isEmpty, "a restart the handoff guard refused leaves every live pane alone")
        XCTAssertEqual(
            try store.runningProcesses(workspaceID: workspace.id).map(\.status), [.running], "and leaves the process it would have restarted running")
    }

    /// A configured process whose command runs a coding agent has both a `running_processes` row and an
    /// `agent_sessions` row naming the same terminal, so the stop's loops overlap on one session id. That
    /// session must be closed exactly once, carrying the hold the restart needs: a second close would
    /// arrive as a plain teardown and the client would honor it, dropping the pane the replacement is
    /// about to claim. The agent row is still finalized either way, since the stop deletes it separately
    /// from closing its terminal.
    func testARestartClosesAProcessSessionThatAlsoHasAnAgentRowExactlyOnce() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, _, openIntent in
                capture.sessionIDs.append(sessionID)
                capture.openIntents.append(openIntent)
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 9876, state: .running,
                        updatedAt: "2026-05-11T18:00:00Z"), paths: paths)
            },
            builtInTerminalWindowCloser: { sessionID, disposition in
                closes.sessionIDs.append(sessionID)
                closes.dispositions.append(disposition)
            },
            builtInTerminalSessionTerminator: { sessionID in
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "agentproc", command: "claude")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            // The configured process's terminal is running a coding agent, so it also carries an agent
            // row pointing at the very same session, which is what makes the stop's loops overlap.
            let launchedSessionID = try XCTUnwrap(capture.sessionIDs.first)
            _ = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "claude", terminalTrackingID: launchedSessionID)
            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
        }

        let launchedSessionID = try XCTUnwrap(capture.sessionIDs.first)
        let closesForSession = zip(closes.sessionIDs, closes.dispositions).filter { $0.0 == launchedSessionID }.map(\.1)
        XCTAssertEqual(closesForSession, [.awaitReplacement], "the shared session is closed once, as the hold the restart needs")
        XCTAssertTrue(
            try store.agentWindows(workspaceID: workspace.id).isEmpty, "the agent row is still finalized even though its close was deduplicated")
        XCTAssertEqual(capture.openIntents.map(\.replacesSessionID), [nil, launchedSessionID], "and the replacement still claims that pane")
    }

    /// The orchestrator shape every client mutation is served on: the Device API injects a window opener
    /// that reaches no client, but leaves the closer at its real IPC-posting default. Starting or
    /// restarting a configured process from the sidebar, from iOS, or from the CLI runs here.
    private func makeDeviceAPIShapedOrchestrator(
        store: SQLiteStore, opens: TerminalOpenCapture, closes: TerminalCloseCapture,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil
    ) -> WorkspaceOrchestrator {
        makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, _, openIntent in
                opens.sessionIDs.append(sessionID)
                opens.openIntents.append(openIntent)
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 9876, state: .running,
                        updatedAt: "2026-05-11T18:00:00Z"), paths: paths)
            }, deliversTerminalWindowOpens: false,
            builtInTerminalWindowCloser: { sessionID, disposition in
                closes.sessionIDs.append(sessionID)
                closes.dispositions.append(disposition)
            },
            builtInTerminalSessionTerminator: { sessionID in
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
            }, builtInTerminalSessionLauncher: builtInTerminalSessionLauncher)
    }

    /// Records the exit of a configured process the way the reconciler does, leaving the row and its
    /// ended session in place so the next start of that process is a restart of an exited run.
    private func markConfiguredProcessExited(store: SQLiteStore, process: RunningProcessRecord) throws {
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: process.id, workspaceID: process.workspaceID, templateID: process.templateID, templateName: process.templateName,
                command: process.command, terminalApp: process.terminalApp, terminalTrackingID: process.terminalTrackingID, pid: nil, status: .exited,
                logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: "2026-05-11T18:05:00Z"))
    }

    /// Starting a configured process whose previous run exited keeps that run's pane for the replacement,
    /// even though the orchestrator serving the start cannot post the replacement's open. Tearing it down
    /// instead is what removed the ended pane the user was reading: the pane vanished and the new run had
    /// none, against the rule that starting a target never removes a pane. The pairing still reaches the
    /// client, in the refreshed overview the mutation returns, because the process row keeps its id and
    /// only the session it names changes.
    func testStartingAnExitedProcessHoldsItsPaneEvenWhenTheOpenCannotBePosted() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let opens = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let orchestrator = makeDeviceAPIShapedOrchestrator(store: store, opens: opens, closes: closes)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            let api = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
            try markConfiguredProcessExited(store: store, process: api)
            try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "api")
        }

        let endedSessionID = try XCTUnwrap(opens.sessionIDs.first)
        let closesForEndedSession = zip(closes.sessionIDs, closes.dispositions).filter { $0.0 == endedSessionID }.map(\.1)
        XCTAssertEqual(closesForEndedSession, [.awaitReplacement], "the ended run's pane is held for the replacement, never torn down")
        XCTAssertEqual(opens.sessionIDs.count, 2, "the start launched a replacement session")
        XCTAssertEqual(
            opens.openIntents.map(\.replacesSessionID), [nil, endedSessionID],
            "and its open names the pane it takes over for a client that can hear it")
        let restarted = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
        XCTAssertEqual(restarted.status, .running)
        XCTAssertEqual(restarted.terminalTrackingID, opens.sessionIDs.last, "the row keeps its id and names the replacement session")
    }

    /// A start whose replacement never launches must not leave the hold behind. Nothing else can settle
    /// it: the process row still names the ended session, so no overview diff pairs it with anything, and
    /// the client would keep a pane waiting for a session that is not coming.
    func testAFailedStartOfAnExitedProcessReleasesTheHoldItPlaced() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let opens = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let launchCount = TerminalLaunchAttemptCapture()
        let orchestrator = makeDeviceAPIShapedOrchestrator(
            store: store, opens: opens, closes: closes,
            // The cold launch succeeds; the relaunch of the exited process throws.
            builtInTerminalSessionLauncher: { configuration in
                launchCount.count += 1
                if launchCount.count > 1 { throw TerminalLaunchFailure() }
                let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
                try paths.ensureDirectories()
                try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: getpid(),
                    childPID: 9876, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            let api = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
            try markConfiguredProcessExited(store: store, process: api)
            XCTAssertThrowsError(try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "api"))
        }

        let endedSessionID = try XCTUnwrap(opens.sessionIDs.first)
        let closesForEndedSession = zip(closes.sessionIDs, closes.dispositions).filter { $0.0 == endedSessionID }.map(\.1)
        XCTAssertEqual(closesForEndedSession, [.awaitReplacement, .teardown], "the hold is placed by the stop and released when the launch fails")
    }

    /// Restarting a running target keeps its pane for the replacement on the same orchestrator, which is
    /// the shape every client's Restart action runs on. The target's row survives the restart naming the
    /// replacement, so the pairing reaches the client in the refreshed overview exactly as a start's does.
    func testRestartingARunningProcessHoldsItsPaneForTheReplacement() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let opens = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let orchestrator = makeDeviceAPIShapedOrchestrator(store: store, opens: opens, closes: closes)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            let api = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
            try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: api.id)
        }

        let previousSessionID = try XCTUnwrap(opens.sessionIDs.first)
        let closesForPreviousSession = zip(closes.sessionIDs, closes.dispositions).filter { $0.0 == previousSessionID }.map(\.1)
        XCTAssertEqual(closesForPreviousSession, [.awaitReplacement], "the running session's pane is held rather than removed")
        XCTAssertEqual(opens.openIntents.map(\.replacesSessionID), [nil, previousSessionID])
    }

    /// Stopping a runtime target removes its pane, so its close stays a plain teardown however the
    /// orchestrator is wired. A hold here would be released by nothing, since a stop has no replacement.
    func testStoppingAProcessTearsDownItsPaneRatherThanHoldingIt() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let opens = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let orchestrator = makeDeviceAPIShapedOrchestrator(store: store, opens: opens, closes: closes)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            let api = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
            try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: api.id)
        }

        XCTAssertFalse(closes.dispositions.isEmpty, "the stop closes the process's pane")
        XCTAssertFalse(closes.dispositions.contains(.awaitReplacement), "and never as a hold, since nothing is coming to claim it")
    }

    /// A workspace restart keeps tearing its panes down on an orchestrator that cannot post the opens.
    /// Its holds are placed by the stop, for every process at once and before it knows which templates it
    /// will relaunch, and only the daemon's own release pass ends the ones no relaunch reached, so that
    /// path still requires a client that will receive the replacements' opens.
    func testAWorkspaceRestartThatCannotOpenPanesNeverAsksAClientToHoldOne() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let opens = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let orchestrator = makeDeviceAPIShapedOrchestrator(store: store, opens: opens, closes: closes)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
        }

        XCTAssertFalse(closes.dispositions.isEmpty, "the restart does close the previous session's pane")
        XCTAssertFalse(closes.dispositions.contains(.awaitReplacement), "but never as a hold this orchestrator could not release")
    }

    /// The hold a restart places on a pane is bounded by the restart, not by a timer, and there are two
    /// ways it ends when the relaunch goes wrong.
    ///
    /// A template whose launch was attempted has already had its open posted, so the client retargeted
    /// the held pane onto the replacement session; that pane is then cleaned up under the *new* session
    /// id by the launch's own failure close. A template the batch never reached has no open at all, and
    /// its pane would be held forever, so the restart releases it under the old session id on its way
    /// out. This exercises the second, which is the one only the daemon can know about: the client has no
    /// way to learn that a replacement stopped being on its way.
    func testFailedRestartReleasesTheHeldPaneOfATemplateItNeverReached() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let launchCount = TerminalLaunchAttemptCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, _, openIntent in
                capture.sessionIDs.append(sessionID)
                capture.openIntents.append(openIntent)
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 9876, state: .running,
                        updatedAt: "2026-05-11T18:00:00Z"), paths: paths)
            },
            builtInTerminalWindowCloser: { sessionID, disposition in
                closes.sessionIDs.append(sessionID)
                closes.dispositions.append(disposition)
            },
            builtInTerminalSessionTerminator: { sessionID in
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
            },
            // Both cold launches succeed; the relaunch throws on the first template, so the batch never
            // reaches the second and that one's pane is left held with no open ever posted for it.
            builtInTerminalSessionLauncher: { configuration in
                launchCount.count += 1
                if launchCount.count > 2 { throw TerminalLaunchFailure() }
                let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
                try paths.ensureDirectories()
                try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: getpid(),
                    childPID: 9876, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [ProcessTemplate(name: "api", command: "echo api"), ProcessTemplate(name: "web", command: "echo web")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            XCTAssertThrowsError(try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true))
        }

        // The cold launch opened api then web, so the second session is the one whose template the failed
        // relaunch never reached.
        XCTAssertEqual(capture.sessionIDs.count, 3, "two cold launches, then the one relaunch that was attempted")
        let unreachedSessionID = try XCTUnwrap(capture.sessionIDs.dropFirst().first)
        let unreachedCloses = zip(closes.sessionIDs, closes.dispositions).filter { $0.0 == unreachedSessionID }.map(\.1)
        XCTAssertEqual(
            unreachedCloses, [.awaitReplacement, .teardown], "the hold is placed by the stop and released when the relaunch never reaches it")
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

    /// Codex round 7 (P1) on issue #438: an exited configured process still has a live-launchable Start
    /// action (`restartExitedProcesses` revives it), so it must count as missing for Start-visibility
    /// purposes even though `exitedProcessCount` separately reports it as exited rather than absent.
    func testWorkspaceRuntimeStatusCountsExitedTrackedProcessAsMissing() throws {
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
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 1, "an exited row is revivable by Start, so it counts as missing")
        XCTAssertEqual(runtimeStatus.warningSummary, "1 exited process")
    }

    /// Codex round 7 (P1/consistency) on issue #438: a stale-templateID live row (round-6 P2a's scenario)
    /// must not satisfy a *different*, newly configured process that reused its old name, in the
    /// Start-visibility count either, matching `matchingConfiguredTemplateForMissingCheck` (the same rule
    /// `launchMissingConfiguredProcesses` uses to decide it must launch the new template).
    func testWorkspaceRuntimeStatusCountsNewlyConfiguredProcessAsMissingWhenAStaleRowReusesItsName() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "stale-old-web", workspaceID: workspace.id, templateID: "old-template-id", templateName: "web", command: "echo old",
                terminalApp: "Spaces", terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(id: "new-template-id", name: "web", command: "echo new")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        let runtimeStatus = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        XCTAssertEqual(runtimeStatus.missingConfiguredProcessCount, 1, "the stale row must not satisfy the newly configured process by name alone")
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
            store: store, builtInTerminalWindowCloser: { sessionID, _ in closeCapture.sessionIDs.append(sessionID) },
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
            store: store, builtInTerminalWindowCloser: { sessionID, _ in closeCapture.sessionIDs.append(sessionID) },
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

    /// A workspace launch starts the runtimes a workspace configures — its processes — and nothing else.
    /// Coding agents are not configurable, so a launch never starts one: an agent row appears only when a
    /// user runs an agent command in a terminal.
    func testLaunchWorkspaceStartsConfiguredProcessesAndNoCodingAgents() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "app", url: "http://localhost:3000")])

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).map(\.templateName), ["api"])
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "a launch must not start a coding agent")
    }

    /// Issue #438: a stopped workspace whose only tracked runtime is an ad hoc terminal (opened before the
    /// workspace's configured processes were ever started) must not refuse Start. Start launches the
    /// configured process and leaves the ad hoc terminal's window record alone.
    func testLaunchWorkspaceWithAdHocTerminalLaunchesConfiguredProcesses() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false, "the workspace itself is stopped before Start")

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).map(\.templateName), ["api"])
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertNotNil(
            try store.windows(workspaceID: workspace.id).first(where: { $0.id == "ad-hoc-window" }), "the ad hoc terminal is left running")
    }

    /// Configured process and browser-session names are required by contract (spec.md): Spaces rejects an
    /// unnamed entry instead of falling back to its command or URL as an identity. A legacy or
    /// directly-written row that predates or bypasses that validation can still carry one, and Start must
    /// refuse it with the same clear error `updateWorkspaceSettings` would have raised at save time, rather
    /// than silently launching a process with no name. Covers the tracked-runtime convergence branch (an ad
    /// hoc terminal routes Start there).
    func testLaunchWorkspaceWithAdHocTerminalRefusesUnnamedConfiguredProcess() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        // Written directly through the store, bypassing `updateRunningWorkspaceProcesses`/
        // `updateWorkspaceSettings`, which reject an unnamed process at save time; this simulates a legacy
        // row that predates that validation.
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: nil, command: "echo unnamed")])
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Process name is required."))
        }
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty, "Start must not launch an unnamed configured process")
    }

    /// The same unnamed-process workspace with no tracked runtime at all, exercising the cold-launch branch
    /// of `upWorkspace` (the one `launchWorkspaceUnlocked` itself handles).
    func testLaunchWorkspaceWithNoTrackedRuntimeRefusesUnnamedConfiguredProcess() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: nil, command: "echo unnamed")])

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Process name is required."))
        }
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty, "Start must not launch an unnamed configured process")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    /// Codex round 4 (P2a) on issue #438: a configured process's live runtime row can carry no `templateID`
    /// (a legacy row from before per-process identity existed, or any row otherwise written without one),
    /// matched only by `template_name`. `launchMissingConfiguredProcesses`'s missing-check has to fall back
    /// to that name match for such a row, or a still-running process looks missing and Start launches a
    /// duplicate of it.
    func testLaunchWorkspaceDoesNotLaunchDuplicateOfLegacyLiveRowWithNoTemplateID() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "web", command: "echo web")])
        // A live row with no templateID, matched by name: the shape a legacy row (or any row written
        // without templateID) has.
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "legacy-live-row", workspaceID: workspace.id, templateName: "web", command: "echo web", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let processes = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.map(\.id), ["legacy-live-row"], "Start must not launch a duplicate of an already-live process")
    }

    /// Codex round 6 (P2a) on issue #438: a configured process is removed while its runtime row remains
    /// (removal never deletes tracked rows, so the row keeps its old, now-unmatched templateID), and a
    /// later edit reuses that same name for a *different*, newly configured process under a fresh id. The
    /// missing-check must not let the stale row's name match satisfy the new template (that fallback is
    /// right for `configuredProcessTemplate`/`restartExitedProcesses`, wrong here; see
    /// `matchingConfiguredTemplateForMissingCheck`'s doc comment): Start has to launch the new template's
    /// command alongside the stale row, which Start never stops or touches.
    func testLaunchWorkspaceLaunchesNewlyConfiguredProcessWhenAStaleRowReusesItsName() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let staleRowID = "stale-old-web"
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: staleRowID, workspaceID: workspace.id, templateID: "old-template-id", templateName: "web", command: "echo old",
                terminalApp: "Spaces", terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))
        // The workspace's current settings no longer configure "old-template-id" at all: a differently
        // configured process now uses the reused name "web" under a fresh id.
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(id: "new-template-id", name: "web", command: "echo new")])
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let processes = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertTrue(
            processes.contains(where: { $0.id == staleRowID && $0.command == "echo old" }),
            "the stale row is left exactly as is; Start never stops runtime")
        XCTAssertTrue(
            processes.contains(where: { $0.templateID == "new-template-id" && $0.command == "echo new" }),
            "Start must launch the newly configured process instead of treating the stale row as already satisfying it")
        XCTAssertEqual(processes.count, 2, "the new process launches alongside the stale one, not in place of it")
    }

    /// Codex round 8 (P2) on issue #438: a follow-on to round 6/7's stale-templateID scenario. The stale
    /// row from that scenario later exits (instead of staying live), and the replacement template already
    /// has its own live row (round 6's own fix launched it separately). `restartExitedProcesses` resolves
    /// the exited stale row via `matchingConfiguredTemplate`'s unconditional name fallback to the
    /// replacement template, the same as before; without checking whether that template already has a live
    /// row elsewhere, it would restart the stale row too, producing a second, duplicate row for a template
    /// meant to have exactly one. Start must be a no-op for this template: the stale row stays exited, the
    /// replacement's own row is untouched, no duplicate.
    func testLaunchWorkspaceLeavesStaleExitedRowAloneWhenReplacementTemplateAlreadyHasALiveRow() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "stale-old-web", workspaceID: workspace.id, templateID: "old-template-id", templateName: "web", command: "echo old",
                terminalApp: "Spaces", terminalTarget: nil, pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: "later"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "replacement-web", workspaceID: workspace.id, templateID: "new-template-id", templateName: "web", command: "echo new",
                terminalApp: "Spaces", terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(id: "new-template-id", name: "web", command: "echo new")])
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let processes = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 2, "no duplicate: exactly the stale row and the replacement's own live row")
        let staleRow = try XCTUnwrap(processes.first(where: { $0.id == "stale-old-web" }))
        XCTAssertEqual(staleRow.status, .exited, "the stale row is left exited, not revived into a duplicate")
        let replacementRow = try XCTUnwrap(processes.first(where: { $0.id == "replacement-web" }))
        XCTAssertEqual(replacementRow.status, .running, "the replacement's own row is untouched")
    }

    /// Companion to the test above: the same stale-templateID exited row, but the replacement template has
    /// no live row anywhere yet. This is round 6/7's documented self-healing case and must still work: the
    /// exited row is the one live-launchable path back to the replacement, so it revives, tagged with the
    /// replacement's own templateID and command.
    func testLaunchWorkspaceRevivesStaleExitedRowAsReplacementTemplateWhenReplacementHasNoLiveRow() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "stale-old-web", workspaceID: workspace.id, templateID: "old-template-id", templateName: "web", command: "echo old",
                terminalApp: "Spaces", terminalTarget: nil, pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: "later"))
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(id: "new-template-id", name: "web", command: "echo new")])
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let processes = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.map(\.id), ["stale-old-web"], "exactly one row: the stale row revived as the replacement, no duplicate")
        let revived = try XCTUnwrap(processes.first)
        XCTAssertEqual(revived.status, .running)
        XCTAssertEqual(revived.templateID, "new-template-id", "the row is now tagged as the replacement template")
        XCTAssertEqual(revived.command, "echo new", "revived using the replacement's command, not the stale one")
    }

    /// Codex-review follow-up to issue #438: the setup recovery screen keeps ad hoc terminal access open
    /// while setup is pending, running, or failed, so a workspace can reach `upWorkspace`'s tracked-runtime
    /// convergence branch (an ad hoc terminal already tracked) with setup never having run. That branch has
    /// to run the same deferred-setup sequence `launchWorkspaceUnlocked` runs, and only launch configured
    /// processes once it succeeds, or Start would launch into a worktree setup never touched.
    func testLaunchWorkspaceWithAdHocTerminalRunsPendingSetupBeforeLaunchingConfiguredProcesses() throws {
        let repo = try makeTempGitRepo(name: "adhoc-pending-setup")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo ready > .spaces-adhoc-setup-marker" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature", runSetupScript: false)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let markerURL = URL(fileURLWithPath: workspace.dir, isDirectory: true).appending(path: ".spaces-adhoc-setup-marker")
        XCTAssertEqual(
            try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .succeeded,
            "Start must run deferred setup even when an ad hoc terminal is already tracked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "the setup script must have actually run before launch")
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).map(\.templateName), ["api"])
    }

    /// Codex-review follow-up to issue #438: with no configured process to launch (or restart), neither
    /// `restartExitedProcesses` nor `launchMissingConfiguredProcesses` ever calls a process launcher, so
    /// neither has a chance to raise the setup-failed error internally (`launchConfiguredProcess` and
    /// `restartProcessInTerminal` each check `requireWorkspaceSetupSucceeded` themselves, but only when
    /// actually invoked). A workspace with a failed setup, a tracked ad hoc terminal, and nothing configured
    /// to launch is exactly the case that would otherwise slip through as a silent no-op success instead of
    /// surfacing the failure; the top-level setup check in `upWorkspace`'s convergence branch is what catches
    /// it.
    func testLaunchWorkspaceWithAdHocTerminalAndNoConfiguredProcessesSurfacesFailedSetupInsteadOfSilentlySucceeding() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "exit 7" }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, runSetupScript: false)

        XCTAssertThrowsError(try orchestrator.runWorkspaceSetup(workspaceID: workspace.id))
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .failed)

        // An ad hoc terminal tracked after setup already failed: the setup recovery screen's own escape
        // hatch, and the scenario that put the tracked-runtime convergence branch in play. No configured
        // process exists, so downstream process-launch code (the only other place setup gets checked) never
        // runs.
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace setup failed"))
        }
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false, "Start must not silently mark the workspace running")
    }

    /// Issue #438: a coding-agent session is not configured runtime either, so its presence alone must not
    /// block Start.
    func testLaunchWorkspaceWithCodingAgentLaunchesConfiguredProcesses() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "agent-session"), status: .idle, createdAt: "now", updatedAt: "now"))

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).map(\.templateName), ["api"])
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), ["agent-codex"], "the coding agent is left running, not stopped")
    }

    /// Issue #438: once every configured process is already running, Start succeeds as a no-op instead of
    /// restarting anything.
    func testLaunchWorkspaceWithEverythingRunningIsANoOp() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "already-running-api", workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.map(\.id), ["already-running-api"], "an already-running configured process is neither relaunched nor restarted")
    }

    /// Codex round 2 (P1) on issue #438: a process removed from workspace settings while it was running
    /// keeps its `.exited` runtime row with no matching template. Start (via the tracked-runtime convergence
    /// branch, reached here because of the ad hoc terminal) must restart only the still-configured process
    /// and leave the removed one's stale row alone, rather than falling back to relaunching it from the row
    /// itself. The explicit per-process restart action on that same row still works, through
    /// `configuredProcessTemplate`'s deliberate ad hoc fallback for a user's direct action on a specific row.
    func testLaunchWorkspaceRestartsOnlyConfiguredProcessesLeavingRemovedProcessAlone() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "A", command: "echo a")])
        let removedProcessID = "removed-process-b"
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: removedProcessID, workspaceID: workspace.id, templateName: "B", command: "echo b", terminalApp: "Spaces", terminalTarget: nil,
                pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let processes = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.filter { $0.templateName == "A" }.map(\.status), [.running], "Start launches the still-configured process")
        let removed = try XCTUnwrap(processes.first(where: { $0.id == removedProcessID }))
        XCTAssertEqual(removed.status, .exited, "Start must not relaunch a process removed from configuration")

        try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: removedProcessID)
        let restarted = try XCTUnwrap(try orchestrator.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == removedProcessID }))
        XCTAssertEqual(restarted.status, .running, "the explicit per-process restart action still relaunches a removed process via the fallback")
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

    /// Restart's semantics are unchanged by Start's convergence (issue #438): unlike Start, restart still
    /// forces a full stop first, which tears down ad hoc terminals and coding-agent sessions too, then
    /// relaunches configured processes fresh rather than leaving the already-running one alone.
    func testRestartWorkspaceStillTearsDownAdHocTerminalAndCodingAgent() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "old-api", workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: "Spaces", terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-window", workspaceID: workspace.id, app: "Spaces", title: "ad hoc shell", terminalTrackingID: "ad-hoc-session",
                role: "terminal", orderIndex: 1, lastSeenAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "agent-session"), status: .idle, createdAt: "now", updatedAt: "now"))

        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) { try orchestrator.restartWorkspace(workspaceID: workspace.id) }

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.map(\.templateName), ["api"])
        XCTAssertNotEqual(processes.first?.id, "old-api", "restart relaunches the configured process fresh instead of leaving it running")
        XCTAssertTrue(
            try store.windows(workspaceID: workspace.id).allSatisfy { $0.id != "ad-hoc-window" }, "restart also tears down ad hoc terminals")
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "restart also ends coding-agent sessions")
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
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "web", command: "echo web")])
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

    /// Codex round 2 (P1): a process removed from workspace settings while it was running keeps its
    /// `.exited` runtime row (removal never deletes tracked rows), with no configured template matching it
    /// anymore. Bulk convergence (Start) must leave that stale row alone rather than falling back to an ad
    /// hoc template built from the row itself, or Start would silently relaunch a command the user removed
    /// from configuration.
    func testUpWorkspaceLeavesExitedProcessRemovedFromSettingsAlone() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "removed-process", workspaceID: workspace.id, templateName: "removed", command: "echo removed", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "now"))

        try orchestrator.upWorkspace(workspaceID: workspace.id)

        let processes = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.map(\.id), ["removed-process"], "the stale row is left in place, not deleted")
        XCTAssertEqual(processes.first?.status, .exited, "Start must not relaunch a process no longer in workspace settings")
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

    /// The process-status reconcile does not classify foreground coding agents. That scan reads every live
    /// session against every workspace's rows, and it has exactly one owner (the daemon's
    /// `TerminalForegroundAgentReconciler`), which observes the same runtime-state notification this
    /// monitor does; running it from here as well would repeat the whole scan on every process event.
    func testCheckAndUpdateProcessStatusesDoesNotClassifyForegroundAgents() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "process-status-foreground-agent"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            try markBuiltInSessionLive(sessionID: sessionID)
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            _ = try orchestrator.checkAndUpdateProcessStatuses()
            XCTAssertTrue(
                try store.agentWindows(workspaceID: workspace.id).isEmpty,
                "the process-status reconcile must leave foreground classification to its own owner")

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).compactMap(\.label), ["Codex"])
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
