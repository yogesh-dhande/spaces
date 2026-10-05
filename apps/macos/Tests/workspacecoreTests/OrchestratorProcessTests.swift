import CryptoKit
import XCTest
import spacesterminalcore
import spacestestsupport
import systembridge

@testable import workspacecore

extension OrchestratorTests {

    // Running a single configured process (the ⌘-number "run process" shortcut → runConfiguredProcess)
    // on a stopped workspace must release the placeholder port reservation, just as full-workspace launch
    // does. Otherwise PortReserver keeps the assigned port and the launched server dies with EADDRINUSE.
    func testRunConfiguredProcessReleasesPortReservationSoServerCanBind() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        // This fixture's assigned port is really bound as a placeholder below, so it must come from a
        // range this test process has verified bindable rather than `PortRange.default`, which a real
        // daemon on this machine may already hold (issue #533).
        try seedBindablePortRange(in: store)
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
        // This fixture's assigned port is really bound as a placeholder below, so it must come from a
        // range this test process has verified bindable rather than `PortRange.default`, which a real
        // daemon on this machine may already hold (issue #533).
        try seedBindablePortRange(in: store)
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
        // This fixture's assigned port is really bound as a placeholder below, so it must come from a
        // range this test process has verified bindable rather than `PortRange.default`, which a real
        // daemon on this machine may already hold (issue #533).
        try seedBindablePortRange(in: store)
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

    /// Issue #438: `launchMissingConfiguredProcesses` launches every missing
    /// configured process in one batch under a single `workspace.isRunning == false` snapshot taken
    /// before the batch starts (the workspace is not marked running until after the whole batch
    /// finishes). Without threading batch progress into `launchConfiguredProcess`, a later process
    /// failing would look identical, from that snapshot's point of view, to the single-process case
    /// above where restoring the reservation is correct: `launchConfiguredProcess` cannot tell an
    /// earlier sibling in the same batch already launched and may already be bound to that same
    /// reservation's port. This is the batch counterpart to
    /// `testRunConfiguredProcessDoesNotRestorePortReservationWhenAlreadyRunningLaunchFails`.
    ///
    /// A retry extends this: calling `launchMissingConfiguredProcesses` again
    /// after this same partial failure (A stayed live, B is still missing) filters A out of
    /// `missingTemplates` entirely on the second call, so it never gets a turn in that call's own loop to
    /// mark the batch as having a live launch; the seed has to come from `running` itself.
    func testLaunchMissingConfiguredProcessesDoesNotRestorePortsAfterALaterFailureOnceABatchHasALiveLaunch() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        // This fixture's assigned port is really bound as a placeholder below, so it must come from a
        // range this test process has verified bindable rather than `PortRange.default`, which a real
        // daemon on this machine may already hold (issue #533).
        try seedBindablePortRange(in: store)
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

    func testCheckAndUpdateProcessStatusesMarksDeadProcessAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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

    // The DispatchSourceProcess exit observer ignores the startup grace window: the kernel has
    // authoritatively reported the exit, so there is nothing left to debounce.
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

    func testCheckAndUpdateProcessStatusesSkipsProcessesWithoutPID() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let noPidProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "Spaces",
            terminalTrackingID: "workspace-session", pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: noPidProcess)
        _ = try orchestrator.checkAndUpdateProcessStatuses()
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .running)
    }

    func testCheckAndUpdateProcessStatusesOnlyChecksRunningProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
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

    /// A row tracked under some other terminal app (never a built-in Spaces pane at all) has nothing for a
    /// restart to reuse, so it comes back onto Spaces the same pane-less way any process with no pane
    /// does: migrated in the row, posting no open (#799). It is not a fresh pane the way Start's revival of
    /// an exited process gets one, since Start and Restart differ in exactly this: Restart never opens.
    func testRestartWorkspaceProcessMigratesOffALegacyHostWithoutOpeningAPane() throws {
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

        XCTAssertTrue(capture.sessionIDs.isEmpty, "the restart posts no open, so the migrated process starts with no pane at all")
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty, "the old session was never a built-in one, so there is nothing here to terminate")
        let restartedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == "process-api" }))
        XCTAssertEqual(restartedProcess.terminalApp, TerminalHost.spaces.appName, "the row still migrates onto Spaces")
        XCTAssertNotEqual(restartedProcess.terminalTrackingID, "session-old", "and names a fresh Spaces session")
        XCTAssertEqual(restartedProcess.status, RunningProcessState.running)

        let restartedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(restartedWindow.app, TerminalHost.spaces.appName)
        XCTAssertEqual(restartedWindow.terminalTrackingID, restartedProcess.terminalTrackingID)
    }

    /// A single-process restart terminates the old built-in session but posts no close IPC for it and no
    /// open IPC for its replacement (#799): the row keeps its id and only the session it names changes, so
    /// every client retargets its own pane from the next overview diff instead of being told to.
    func testRestartWorkspaceProcessTerminatesThePreviousSpacesSessionWithoutAnyPaneIPC() throws {
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

        XCTAssertTrue(closeCapture.sessionIDs.isEmpty, "the restart posts no close IPC for the session it replaces")
        XCTAssertEqual(terminateCapture.sessionIDs, ["old-spaces-session"], "the old session is still actually ended")
        XCTAssertFalse(FileManager.default.fileExists(atPath: killLog))
        XCTAssertTrue(openCapture.sessionIDs.isEmpty, "the restart posts no open IPC for the replacement either")
        let restartedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == "process-api" }))
        XCTAssertNotEqual(restartedProcess.terminalTrackingID, "old-spaces-session", "the row silently names a fresh session")
    }

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
    /// tool wrapping it), so the panes its configured processes open must not take the window the user is
    /// working in. Each launch still asks for an owner attachment: only focus is withheld, not ownership.
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

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }

        XCTAssertEqual(capture.openIntents.map(\.focus), [.withoutFocus, .withoutFocus])
        XCTAssertEqual(capture.modes, [.owner, .owner])
    }

    /// A workspace restart relaunches each configured process in place through `restartProcessInTerminal`,
    /// which never posts an open or a close for the session it swaps in: the process row keeps its id and
    /// only the session it names changes, so every client retargets its own pane from the next overview
    /// diff instead of being told to (#799). Only the cold launch that started the workspace opens a pane.
    func testProgrammaticWorkspaceRestartNeverAsksAClientToOpenOrCloseAPane() throws {
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
            // The restart waits for each terminated session to actually end, so the fake terminator has to
            // record the exit the real one would; otherwise it spends the whole wait timeout.
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

        XCTAssertEqual(capture.openIntents.map(\.focus), [.withoutFocus], "only the cold launch opens a pane, without focus")
        XCTAssertEqual(capture.sessionIDs.count, 1, "the restart's relaunch opens no pane of its own")
        XCTAssertTrue(closes.sessionIDs.isEmpty, "the restart closes no pane for the session it replaces")
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertNotEqual(processes.first?.terminalTrackingID, capture.sessionIDs.first, "the row now names a fresh session the restart never opened")
    }

    /// A configured process added to settings after the workspace was already running has no tracked row
    /// yet: `restartWorkspaceUnlocked` launches it fresh through `launchConfiguredProcess`, which must open
    /// no pane for it either, exactly as the in-place relaunch of the already-tracked process does not
    /// (#799).
    func testWorkspaceRestartWithAnUntrackedConfiguredProcessOpensAndClosesNoPanes() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let opens = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode, openIntent in
                opens.sessionIDs.append(sessionID)
                opens.modes.append(mode)
                opens.openIntents.append(openIntent)
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
        // "api" keeps the same template id across both settings writes below, so the row the cold launch
        // creates for it still resolves back to its template after "web" is added; a fresh id would read
        // as a removed-and-replaced template and get the row stopped instead of relaunched in place.
        let apiTemplate = ProcessTemplate(id: "api-template", name: "api", command: "echo api")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [apiTemplate])

        var opensBeforeRestart = 0
        var closesBeforeRestart = 0
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            // Adds "web" directly to settings, bypassing the reconciler that would otherwise launch it
            // right away, so it is configured but has no tracked row when the restart below runs.
            try store.setWorkspaceProcesses(
                workspaceID: workspace.id, processes: [apiTemplate, ProcessTemplate(id: "web-template", name: "web", command: "echo web")])
            opensBeforeRestart = opens.sessionIDs.count
            closesBeforeRestart = closes.sessionIDs.count

            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
        }

        XCTAssertEqual(opens.sessionIDs.count, opensBeforeRestart, "neither the in-place relaunch nor the newly-configured process opens a pane")
        XCTAssertEqual(closes.sessionIDs.count, closesBeforeRestart, "the restart closes no pane")

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 2)
        for process in processes {
            XCTAssertEqual(process.status, .running, "\(process.templateName) has a row naming a live session")
            XCTAssertNotNil(process.terminalTrackingID)
        }
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

    /// `restartWorkspace`'s entry check happens once, before the stop script runs; a handoff that begins
    /// after that check (for instance while the stop script itself runs) must still be caught before any
    /// process is touched. Mirrors `stopWorkspaceUnlocked`'s mutation-boundary veto: the terminator no-ops
    /// during a handoff, so proceeding here would relaunch over a session the successor daemon is about to
    /// inherit and mislabel it as exited.
    func testRestartRefusedByHandoffGuardAfterStopScriptLeavesTheProcessRowUntouched() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let opens = TerminalOpenCapture()
        let terminateCapture = TerminalTerminateCapture()
        // The entry check (`restartWorkspace`, before the lifecycle lock) answers "no handoff"; every later
        // check, starting with the one right after the stop script, answers "handoff in progress", modeling
        // a handoff that begins mid-restart.
        let handoffCheckCount = TerminalLaunchAttemptCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, _, _ in
                opens.sessionIDs.append(sessionID)
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try? seedTerminalSessionRow(sessionID: sessionID, paths: paths)
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 9876, state: .running,
                        updatedAt: "2026-05-11T18:00:00Z"), paths: paths)
            }, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) },
            daemonHandoffInProgress: {
                handoffCheckCount.count += 1
                return handoffCheckCount.count > 1
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        var originalSessionID = ""
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            originalSessionID = try XCTUnwrap(opens.sessionIDs.first)
            XCTAssertThrowsError(try orchestrator.restartWorkspace(workspaceID: workspace.id)) { error in
                guard case WorkspaceError.daemonHandoffInProgress = error else {
                    XCTFail("expected the mid-restart handoff guard to refuse the restart, got \(error)")
                    return
                }
            }
        }

        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty, "the terminator is never reached once the handoff guard refuses")
        let process = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(process.status, .running, "the process row is untouched by the refused restart")
        XCTAssertEqual(process.terminalTrackingID, originalSessionID, "and still names its original session")
    }

    /// A handoff can also begin after `restartProcessInTerminal`'s own `.restart` guard already let the
    /// relaunch proceed: the guard only checks on the way in, not across the launch call. If the launch
    /// then fails, the terminator already no-op'd for the handoff, so the old session is still live for
    /// the successor daemon; the failure catch must re-check the handoff and rethrow untouched instead of
    /// writing `.exited` over that still-live row.
    func testHandoffDuringAFailedRelaunchLeavesTheProcessRowUntouched() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let handoffCheckCount = TerminalLaunchAttemptCapture()
        let launchCount = TerminalLaunchAttemptCapture()
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
            }, builtInTerminalWindowCloser: { _, _ in },
            builtInTerminalSessionTerminator: { sessionID in
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
            },
            // The cold launch succeeds; the relaunch throws, exercising the failed-relaunch catch under test.
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
            },
            // False for the restart's entry check, the post-stop-script check, and the per-process
            // `.restart` guard inside `restartProcessInTerminal`; true from the failed launch's catch
            // onward, modeling a handoff that begins only after that per-process guard already passed.
            daemonHandoffInProgress: {
                handoffCheckCount.count += 1
                return handoffCheckCount.count > 3
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        var originalSessionID = ""
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            originalSessionID = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first?.terminalTrackingID)
            XCTAssertThrowsError(try orchestrator.restartWorkspace(workspaceID: workspace.id)) { error in
                guard case WorkspaceError.daemonHandoffInProgress = error else {
                    XCTFail("expected the post-failure handoff re-check to refuse the restart, got \(error)")
                    return
                }
            }
        }

        let process = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(process.status, .running, "a handoff caught in the failure catch must not mark the row exited")
        XCTAssertEqual(process.terminalTrackingID, originalSessionID, "the row still names its original, still-live session")
    }

    /// A configured process whose command runs a coding agent has both a `running_processes` row and an
    /// `agent_sessions` row naming the same terminal, so a stop's loops overlap on one session id. That
    /// session must be closed exactly once: closing it twice would send the client two close messages for
    /// one pane. The agent row is still finalized, separately from closing its terminal.
    func testStopClosesAProcessSessionThatAlsoHasAnAgentRowExactlyOnce() throws {
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
            try orchestrator.stopWorkspace(workspaceID: workspace.id)
        }

        let launchedSessionID = try XCTUnwrap(capture.sessionIDs.first)
        XCTAssertEqual(closes.sessionIDs.filter { $0 == launchedSessionID }.count, 1, "the shared session is closed exactly once")
        XCTAssertTrue(
            try store.agentWindows(workspaceID: workspace.id).isEmpty, "the agent row is still finalized even though its close was deduplicated")
    }

    /// A restart relaunches the configured process in place, but the agent row sharing its old session
    /// must not linger naming a now-dead terminal: the agent ran inside that process, so it ends with it.
    /// The foreground reconciler skips `.process`-kind sessions, so nothing else would ever finalize it.
    func testRestartFinalizesAnAgentRowSharingTheRestartedProcessSession() throws {
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

        var originalSessionID = ""
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            // The configured process's terminal is running a coding agent, so it also carries an agent row
            // pointing at the very same session that the restart below ends.
            originalSessionID = try XCTUnwrap(capture.sessionIDs.first)
            _ = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "claude", terminalTrackingID: originalSessionID)
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        XCTAssertTrue(
            try store.agentWindows(workspaceID: workspace.id).isEmpty,
            "the agent row is finalized once the process session it shared ends, instead of lingering on a dead session")
        let process = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "agentproc" }))
        XCTAssertEqual(process.status, .running)
        XCTAssertNotEqual(process.terminalTrackingID, originalSessionID, "the row now names the restart's fresh session")
    }

    /// A stale row (its configured template removed while it ran) is stopped rather than relaunched by a
    /// restart, through `stopRunningProcess`. That call ends the session and drops its own row but never
    /// touches `agent_sessions`, and process-kind sessions are not finalized by the foreground reconciler
    /// either, so without a finalize of its own a removed process that ran a coding agent leaves a ghost
    /// agent row naming a now-dead terminal.
    func testRestartFinalizesAnAgentRowSharingAStaleProcessSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
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
            // The configured process's terminal is running a coding agent, so it also carries an agent row
            // pointing at its session.
            let staleSessionID = try XCTUnwrap(capture.sessionIDs.first)
            _ = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "claude", terminalTrackingID: staleSessionID)
            // Removes the configured process while it runs: its tracked row now matches no template, so
            // the restart below stops it instead of relaunching it in place.
            try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [])
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        XCTAssertTrue(
            try store.agentWindows(workspaceID: workspace.id).isEmpty,
            "the agent row is finalized once the stale process's session is stopped, instead of lingering on a dead session")
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty, "the stale row itself is dropped, not relaunched")
    }

    /// Terminating a session is asynchronous (SIGHUP, then a TERM/KILL escalation that can take seconds),
    /// so a restart that launches the replacement immediately can race a slow-exiting process still
    /// holding its port. The fake terminator here mirrors that: it returns at once, as the real terminator
    /// does, but the session only stops being interactive later, off a background queue, so if the restart
    /// launched its replacement without waiting, the launcher would be observed running before that flip.
    func testRestartWaitsForTheOldSessionToStopBeingInteractiveBeforeLaunchingTheReplacement() throws {
        final class ExitTiming: @unchecked Sendable {
            var exitedAt: Date?
            var launchInvokedAt: Date?
        }
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let capture = TerminalOpenCapture()
        let timing = ExitTiming()
        let exitDelay: TimeInterval = 0.2
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
            builtInTerminalSessionTerminator: { sessionID in
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                // Both the bulk restart terminate and `restartProcessInTerminal`'s own per-process
                // terminate call this for the same session; the second call must be a no-op once the
                // delayed exit below has already landed, or it would push `exitedAt` out again and make
                // this test fail even when the wait it exercises is implemented correctly.
                if let existing = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !existing.state.isInteractive { return }
                DispatchQueue.global().asyncAfter(deadline: .now() + exitDelay) {
                    // Stamped before the write that ends the session, so a launch released by that write
                    // can never be timestamped earlier than the exit it waited for.
                    timing.exitedAt = Date()
                    try? TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                            updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
                }
            },
            builtInTerminalSessionLauncher: { configuration in
                timing.launchInvokedAt = Date()
                return try TerminalService.createSession(configuration)
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            timing.launchInvokedAt = nil
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        let exitedAt = try XCTUnwrap(timing.exitedAt, "the fake terminator's delayed exit ran")
        let launchInvokedAt = try XCTUnwrap(timing.launchInvokedAt, "the replacement was launched")
        XCTAssertGreaterThanOrEqual(launchInvokedAt, exitedAt, "the replacement launch waits for the old session to stop being interactive first")
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

    /// Restarting one running target through the public single-process API relaunches it through the same
    /// `restartProcessInTerminal(reason: .restart)` a whole-workspace restart uses, so it never asks a
    /// client to open or close a pane either: the row keeps its id and only the session it names changes.
    func testRestartingARunningProcessNeverAsksAClientToOpenOrCloseAPane() throws {
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

        // The cold launch is the only thing that ever opens a pane, so its session is the previous one.
        let previousSessionID = try XCTUnwrap(opens.sessionIDs.first)
        XCTAssertEqual(opens.sessionIDs.count, 1, "only the cold launch opens a pane; the restart opens none")
        XCTAssertTrue(closes.sessionIDs.isEmpty, "the restart closes no pane for the session it replaces")
        let restarted = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == "api" }))
        XCTAssertNotEqual(restarted.terminalTrackingID, previousSessionID, "the row now names a fresh session the restart never opened")
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

    /// A configured process that fails to relaunch does not stop the others: the restart keeps going,
    /// leaves the failed process's row naming its now-ended session and marked exited, and still throws
    /// one error naming it once every process has been tried. The workspace stays running throughout, and
    /// nothing here ever asks a client to open or close a pane, whether the relaunch succeeds or fails.
    func testFailedRestartLeavesItsRowExitedRelaunchesTheOthersAndThrowsNamingIt() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let opens = TerminalOpenCapture()
        let closes = TerminalCloseCapture()
        let launchCount = TerminalLaunchAttemptCapture()
        let orchestrator = makeTestOrchestrator(
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
            // The two cold launches (api, then web) succeed; the restart's relaunch of "api" (the third
            // launch attempt) fails, and the restart's relaunch of "web" (the fourth) still runs.
            builtInTerminalSessionLauncher: { configuration in
                launchCount.count += 1
                if launchCount.count == 3 { throw TerminalLaunchFailure() }
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

        var apiSessionBeforeRestart: String?
        var webSessionBeforeRestart: String?
        var opensFromColdLaunch = 0
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            // The cold launch legitimately opens a pane for each configured process; only the restart that
            // follows is under test below.
            opensFromColdLaunch = opens.sessionIDs.count
            let processes = try store.runningProcesses(workspaceID: workspace.id)
            apiSessionBeforeRestart = processes.first(where: { $0.templateName == "api" })?.terminalTrackingID
            webSessionBeforeRestart = processes.first(where: { $0.templateName == "web" })?.terminalTrackingID
            XCTAssertThrowsError(try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("api"), "the error names the process that failed to relaunch")
            }
        }

        XCTAssertEqual(opens.sessionIDs.count, opensFromColdLaunch, "neither the successful nor the failed relaunch ever asks to open a pane")
        XCTAssertTrue(closes.sessionIDs.isEmpty, "neither the successful nor the failed relaunch ever asks to close a pane")

        let processesAfterRestart = try store.runningProcesses(workspaceID: workspace.id)
        let api = try XCTUnwrap(processesAfterRestart.first(where: { $0.templateName == "api" }))
        XCTAssertEqual(api.terminalTrackingID, apiSessionBeforeRestart, "the failed relaunch leaves its row naming its old, now-ended session")
        XCTAssertEqual(api.status, .exited, "and marks that row exited rather than leaving it reading running with nothing behind it")

        let web = try XCTUnwrap(processesAfterRestart.first(where: { $0.templateName == "web" }))
        XCTAssertNotEqual(web.terminalTrackingID, webSessionBeforeRestart, "the other process still relaunches onto a fresh session")
        XCTAssertEqual(web.status, .running)

        XCTAssertTrue(try store.workspace(id: workspace.id)?.isRunning ?? false, "the workspace stays running despite the failed relaunch")
    }

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
        // The added service is allocated from the range, which probes the machine, so the range must be one
        // this process just found free rather than the default that real daemons hold ports in.
        try seedBindablePortRange(in: store)
        let rangeStart = try store.appConfig().portRange.start
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [rangeStart + 3], names: ["api"])
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
        XCTAssertEqual(namedPorts.map(\.port), [rangeStart + 3, rangeStart])
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

    /// Issue #438: an exited configured process still has a live-launchable Start
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

    /// Issue #438: a stale-templateID live row
    /// (`testLaunchWorkspaceLaunchesNewlyConfiguredProcessWhenAStaleRowReusesItsName`'s scenario)
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

        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) { try orchestrator.stopWorkspace(workspaceID: workspace.id) }
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        XCTAssertTrue(try orchestrator.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

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

    /// Issue #438: a configured process's live runtime row can carry no `templateID`
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

    /// Issue #438: a configured process is removed while its runtime row remains
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

    /// Issue #438: a follow-on to
    /// `testLaunchWorkspaceLaunchesNewlyConfiguredProcessWhenAStaleRowReusesItsName`'s stale-templateID
    /// scenario. The stale row from that scenario later exits (instead of staying live), and the
    /// replacement template already has its own live row, launched separately. `restartExitedProcesses` resolves
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
    /// no live row anywhere yet. This is the documented self-healing case and must still work: the
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

    /// Issue #438: the setup recovery screen keeps ad hoc terminal access open
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

    /// Issue #438: with no configured process to launch (or restart), neither
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

    /// Issue #438: a process removed from workspace settings while it was running
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

    /// A tracked `running_processes` row whose template is no longer in the workspace's configuration (the
    /// workspace here configures none at all) is stopped and its row removed rather than relaunched: the
    /// restart applies the current configuration, not whatever was tracked before it ran.
    func testRestartWorkspaceStopsAndRemovesARowNoLongerConfigured() throws {
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
        XCTAssertTrue(running.isEmpty, "the untracked-by-configuration row is removed rather than relaunched")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true, "the restart still ends running")
    }

    /// A tracked row no longer configured, and a newly configured template with no row yet, land on the
    /// same restart when a process is removed and a differently named one added in its place. The stale
    /// row's stop must run before the replacement launches: it is what frees the port (or, for a built-in
    /// terminal, releases the workspace-mutation boundary) the replacement is about to claim, so restoring
    /// it after the launch instead would race the new process for the same slot.
    func testRestartWorkspaceStopsStaleRowBeforeLaunchingANewlyConfiguredProcess() throws {
        final class OrderedCallCapture: @unchecked Sendable { var events: [String] = [] }
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let order = OrderedCallCapture()
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
            }, builtInTerminalWindowCloser: { _, _ in },
            builtInTerminalSessionTerminator: { sessionID in
                order.events.append("terminate:\(sessionID)")
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
            },
            builtInTerminalSessionLauncher: { configuration in
                order.events.append("launch:\(configuration.sessionID)")
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
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(id: "old-template", name: "old", command: "echo old")])

        var staleSessionID = ""
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            staleSessionID = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first?.terminalTrackingID)
            order.events.removeAll()
            // Removes "old" outright and configures "new" in its place, bypassing the reconciler that
            // would otherwise stop/launch them right away, so the restart below is what has to resolve
            // both: "old"'s row is now stale, and "new" is configured with no row at all.
            try store.setWorkspaceProcesses(
                workspaceID: workspace.id, processes: [ProcessTemplate(id: "new-template", name: "new", command: "echo new")])

            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        let terminateIndex = try XCTUnwrap(order.events.firstIndex(of: "terminate:\(staleSessionID)"))
        let launchIndex = try XCTUnwrap(order.events.firstIndex { $0.hasPrefix("launch:") })
        XCTAssertLessThan(terminateIndex, launchIndex, "the stale row is stopped before the newly configured process launches")

        let running = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(running.map(\.templateName), ["new"], "the stale row is gone and the newly configured process is tracked")
        XCTAssertEqual(running.first?.status, .running)
    }

    /// `restartWorkspaceUnlocked`'s stale-row cleanup runs before the relaunch loop and deletes rows
    /// outright, so it needs its own handoff guard: `stopRunningProcess` carries none of its own. A
    /// handoff that begins right after the post-stop-script check (the guard immediately before this
    /// cleanup) must be caught there, leaving the stale row exactly as it was rather than deleted out from
    /// under a session the successor daemon is about to inherit.
    func testHandoffDuringTheStaleRowCleanupLeavesTheStaleRowInPlace() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let handoffCheckCount = TerminalLaunchAttemptCapture()
        let terminateCapture = TerminalTerminateCapture()
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
            }, builtInTerminalWindowCloser: { _, _ in },
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) },
            // False for the restart's entry check and the post-stop-script check; true from the stale-row
            // cleanup's own handoff guard onward, modeling a handoff that begins only after the stop
            // script's check already passed.
            daemonHandoffInProgress: {
                handoffCheckCount.count += 1
                return handoffCheckCount.count > 2
            })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        var staleSessionID = ""
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            staleSessionID = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first?.terminalTrackingID)
            // Removes "api" from settings entirely, bypassing the reconciler that would otherwise stop it
            // right away, so the cold launch's row is stale by the time the restart below runs.
            try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [])

            XCTAssertThrowsError(try orchestrator.restartWorkspace(workspaceID: workspace.id)) { error in
                guard case WorkspaceError.daemonHandoffInProgress = error else {
                    XCTFail("expected the stale-row cleanup's handoff guard to refuse the restart, got \(error)")
                    return
                }
            }
        }

        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty, "the handoff guard fires before the stale row's session is ever terminated")
        let process = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(process.status, .running, "the stale row is left exactly as it was")
        XCTAssertEqual(process.terminalTrackingID, staleSessionID)
    }

    /// Every client (Mac, iOS, CLI, MCP) reads a workspace's running state off this flag, so a restart
    /// that transiently reports the workspace stopped would make every one of them react to a stop the
    /// user never asked for, closing tracked browser tabs and code panes along the way (#799).
    /// This samples the flag at the two points a restart actually touches it: terminating each configured
    /// process's old session, and launching its replacement. Neither ever observes the workspace stopped,
    /// even though the relaunched process's own row is momentarily between the old and new session in
    /// between (its terminal has ended but the replacement has not landed yet).
    func testRestartWorkspaceNeverReportsStoppedWhileInFlight() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let samples = WorkspaceRunningStateSampleCapture(store: store)
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
            builtInTerminalSessionTerminator: { sessionID in
                samples.sample()
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
            },
            builtInTerminalSessionLauncher: { configuration in
                samples.sample()
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
        samples.workspaceID = workspace.id
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            // Only the restart below is under test; the cold launch above legitimately samples "not yet
            // running" from inside its own launcher call.
            samples.isRecording = true
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        XCTAssertFalse(samples.samples.isEmpty, "the restart's terminate and relaunch hooks both fired and were sampled")
        XCTAssertTrue(samples.samples.allSatisfy { $0 }, "no sample taken while the restart was in flight ever saw the workspace stopped")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true, "the successful restart still ends running")
    }

    /// A restart that fails to relaunch its one configured process still leaves the workspace marked
    /// running (#799): there is no other process for the workspace to fall back on being stopped by, and a
    /// user whose relaunch failed still has a workspace to look at and retry from, not one that vanished
    /// out from under them. The failed process's own row is what carries the failure, marked exited.
    func testFailedRestartLeavesTheWorkspaceRunning() throws {
        struct TerminalLaunchFailure: Error {}
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try makeTemporaryStore()
        let launchCount = TerminalLaunchAttemptCapture()
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
            }, builtInTerminalWindowCloser: { _, _ in },
            builtInTerminalSessionTerminator: { sessionID in
                guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
                try? TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: "2026-05-11T18:05:00Z"), paths: paths)
            },
            // The cold launch succeeds; the relaunch throws immediately, before it opens any replacement pane.
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

        var sessionBeforeRestart: String?
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            sessionBeforeRestart = try store.runningProcesses(workspaceID: workspace.id).first?.terminalTrackingID
            XCTAssertThrowsError(try orchestrator.restartWorkspace(workspaceID: workspace.id)) { error in
                XCTAssertTrue(String(describing: error).contains("api"), "the error names the process that failed to relaunch")
            }
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true, "the restart still ends the workspace running")
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1, "the failed process's row is kept rather than dropped")
        XCTAssertEqual(processes.first?.status, .exited, "and marked exited")
        XCTAssertEqual(processes.first?.terminalTrackingID, sessionBeforeRestart, "still naming the old, now-ended session")
    }

    /// A restart runs the workspace's configured stop script before relaunching anything, the same as a
    /// plain stop does, and then relaunches every configured process onto a fresh session while keeping
    /// each row's id (#799).
    func testRestartWorkspaceRunsStopScriptAndRelaunchesEveryProcessKeepingItsRowID() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let marker = root.appendingPathComponent("restart-stop-script-marker.txt")
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [ProcessTemplate(name: "api", command: "echo api"), ProcessTemplate(name: "web", command: "echo web")])
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo ran > '\(marker.path)'")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "row-api", workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: "Spaces", terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "row-web", workspaceID: workspace.id, templateName: "web", command: "echo web", terminalApp: "Spaces", terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) { try orchestrator.restartWorkspace(workspaceID: workspace.id) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the restart ran the workspace's stop script")
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(Set(processes.map(\.id)), ["row-api", "row-web"], "every configured process's row keeps its id across the relaunch")
        XCTAssertTrue(
            processes.allSatisfy { $0.status == .running && $0.terminalTrackingID != nil }, "and every one relaunches onto a fresh, running session")
    }

    /// A restart relaunches configured processes only (#799): a coding agent and an ad hoc terminal in the
    /// same workspace are neither of those, so they keep running through the restart untouched, and the
    /// configured process's own row is reused in place (same id, only the session it names changes) rather
    /// than deleted and recreated.
    func testRestartWorkspaceLeavesAdHocTerminalAndCodingAgentRunning() throws {
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
        XCTAssertEqual(processes.first?.id, "old-api", "the configured process's row is reused in place, not deleted and recreated")
        XCTAssertEqual(processes.first?.status, .running)
        XCTAssertTrue(
            try store.windows(workspaceID: workspace.id).contains(where: { $0.id == "ad-hoc-window" }), "restart leaves the ad hoc terminal running")
        XCTAssertTrue(
            try store.agentWindows(workspaceID: workspace.id).contains(where: { $0.id == "agent-codex" }), "restart leaves the coding agent running")
    }

    func testUpWorkspaceLaunchesWhenStopped() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.upWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

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

    /// Issue #438: a process removed from workspace settings while it was running keeps its
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

    /// `upWorkspace(restartIfRunning: true)` routes through the same in-place restart `restartWorkspace`
    /// uses. With no configured processes at all, the tracked row here resolves to no template, so the
    /// restart stops and drops it rather than relaunching it (#799).
    func testUpWorkspaceWithRestartIfRunningDropsAnUntemplatedRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, terminalTarget: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)

        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    func testUpWorkspaceAllocatesPortsWhenDefinitionsExistButNoPortsAllocated() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [ServiceDefinition(name: "web"), ServiceDefinition(name: "api")]
        }

        try orchestrator.upWorkspace(workspaceID: workspace.id)

        let allocatedPorts = try store.workspacePorts(workspaceID: workspace.id)
        XCTAssertEqual(allocatedPorts.count, 2)
    }

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

        var runningWorkspace = workspace
        runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, dir: "/nonexistent/workspace-\(UUID().uuidString)", dirname: workspace.dirname,
            branch: workspace.branch, baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isHidden: workspace.isHidden, isRunning: true,
            lastLaunchedAt: nil, notes: nil)
        try store.upsert(workspace: runningWorkspace)

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        XCTAssertTrue(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
    }

    func testStopWorkspaceClosesNonSpacesTrackedWindows() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Insert a tracked "editor" window (non-browser, non-Spaces) so that branch of the cleanup is reached.
        let editorWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Cursor", title: "editor", role: "editor", orderIndex: 100,
            lastSeenAt: "2024-01-01T00:00:00Z")
        try store.upsert(window: editorWindow)

        let runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, dir: projectDir.path, dirname: workspace.dirname, branch: workspace.branch,
            baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isHidden: workspace.isHidden, isRunning: true, lastLaunchedAt: nil,
            notes: nil)
        try store.upsert(workspace: runningWorkspace)

        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

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
