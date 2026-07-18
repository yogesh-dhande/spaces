import XCTest
import spacesterminalcore

@testable import workspacecore

#if canImport(Darwin)
    import Darwin
#endif

/// Behavior coverage for the scheduled-automation scheduler and executor: the concurrency policy matrix,
/// missed-run catch-up on daemon start, the ended-only attributed-session sweep, run-history retention, and
/// the executor's real exit-code/timeout/cancel handling. Session launches route through a process-wide
/// fake terminal host so no real daemon or Ghostty PTY is needed; the exit-code, timeout, and cancel tests
/// run real short shell commands through that host so the executor's command wrapping and signal escalation
/// are exercised end to end.
@MainActor final class AutomationServiceTests: XCTestCase {
    // MARK: - Concurrency policy matrix

    func testAllowPolicyStartsConcurrentRuns() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        _ = harness.service.triggerManually(automationID: automation.id)
        _ = harness.service.triggerManually(automationID: automation.id)
        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.filter { $0.status == .running }.count, 2, "allow always starts a new run")
    }

    func testSkipPolicySkipsWhileRunning() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .skip)
        _ = harness.service.triggerManually(automationID: automation.id)
        let second = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(second.status, .skipped)
        XCTAssertEqual(second.skipReason, .concurrency)
        XCTAssertEqual(try harness.store.automationRuns(automationID: automation.id).filter { $0.status == .running }.count, 1)
    }

    func testSkipPolicyRunsWhenIdle() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .skip)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(run.status, .running)
    }

    func testQueuePolicyCoalescesToOnePendingRun() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .queue)
        _ = harness.service.triggerManually(automationID: automation.id)  // running
        let queued = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(queued.status, .queued)
        let overflow = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(overflow.status, .skipped, "a second fire while one run is queued is skipped")
        XCTAssertEqual(overflow.skipReason, .concurrency)
        XCTAssertEqual(try harness.store.activeAutomationRuns(automationID: automation.id).filter { $0.status == .queued }.count, 1)
    }

    func testQueuedRunPromotedWhenRunningCompletes() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .queue)
        let first = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let queued = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        XCTAssertEqual(queued.status, .queued)

        // Simulate the running command ending, then let the scheduler poll observe it and promote.
        let firstSessionID = try XCTUnwrap(harness.store.automationRun(id: first.id)?.terminalSessionID)
        harness.host.markSessionEnded(sessionID: firstSessionID)
        harness.service.tick()

        XCTAssertTrue(try XCTUnwrap(harness.store.automationRun(id: first.id)).status.isTerminal)
        XCTAssertEqual(try harness.store.automationRun(id: queued.id)?.status, .running, "the queued run executes once the current one finishes")
    }

    // MARK: - Missed-run catch-up

    func testMissedRunOnceFiresExactlyOnce() throws {
        let harness = try Harness(self)
        // A once-a-minute cron whose next fire time is days in the past: many occurrences were missed.
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .runOnce,
            nextFireTime: harness.now().addingTimeInterval(-3 * 24 * 60 * 60))
        harness.service.reconcileMissedRunsOnStart()
        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1, "run_once fires exactly one catch-up run regardless of occurrences missed")
        XCTAssertEqual(runs.first?.trigger, .missedCatchUp)
        XCTAssertNotNil(try harness.store.automation(id: automation.id)?.nextFireTime, "the next fire time is recomputed from now")
    }

    func testMissedSkipRecordsOneSkippedRow() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .skip,
            nextFireTime: harness.now().addingTimeInterval(-3 * 24 * 60 * 60))
        harness.service.reconcileMissedRunsOnStart()
        let runs = try harness.store.automationRuns(automationID: automation.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .skipped)
        XCTAssertEqual(runs.first?.skipReason, .missed)
    }

    func testFutureNextFireTimeIsNotCaughtUp() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(
            triggerKind: .cron, cronExpression: "* * * * *", missedRunPolicy: .runOnce,
            nextFireTime: harness.now().addingTimeInterval(60 * 60))
        harness.service.reconcileMissedRunsOnStart()
        XCTAssertTrue(try harness.store.automationRuns(automationID: automation.id).isEmpty)
    }

    // MARK: - Attributed-session sweep

    func testSweepFinalizesEndedAttributedSessionAndKeepsLiveOne() throws {
        let harness = try Harness(self)
        let (_, workspace) = try harness.makeProjectAndWorkspace()
        let automation = try harness.insertAutomation(concurrency: .allow)

        // A completed prior run that spawned two coding-agent sessions: one ended, one still live.
        let priorRun = try harness.insertRun(automationID: automation.id, status: .succeeded)
        let endedSessionID = UUID().uuidString
        let liveSessionID = UUID().uuidString
        let endedAgent = try harness.writeAttributedAgentSession(
            workspaceID: workspace.id, runID: priorRun.id, sessionID: endedSessionID, live: false)
        _ = try harness.writeAttributedAgentSession(workspaceID: workspace.id, runID: priorRun.id, sessionID: liveSessionID, live: true)
        try harness.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher", agentSessionID: endedAgent.id, createdAt: "t")

        // Starting a new run of the same automation triggers the prior-run sweep.
        _ = harness.service.triggerManually(automationID: automation.id)

        XCTAssertNil(try harness.store.agentWindow(id: endedAgent.id), "the ended attributed agent row is finalized away")
        XCTAssertTrue(try harness.store.terminalSessionIDs(automationRunID: priorRun.id).contains(liveSessionID), "the live session survives the sweep")
        XCTAssertFalse(
            try harness.store.terminalSessionIDs(automationRunID: priorRun.id).contains(endedSessionID), "the ended session is removed from the product")
        XCTAssertTrue(harness.host.delivered.contains { $0.sessionID == "watcher" && $0.line.contains("exited") }, "the watcher is told the child exited")
    }

    // MARK: - Retention

    func testRetentionPrunesToNewestHundredAndDeletesArtifacts() throws {
        let harness = try Harness(self)
        let automation = try harness.insertAutomation(concurrency: .allow)
        var oldestRunDir: URL?
        for index in 0..<105 {
            let run = try harness.insertRun(
                automationID: automation.id, status: .succeeded, createdAt: harness.now().addingTimeInterval(TimeInterval(index)))
            let directory = try AutomationPaths.ensureRunDirectory(runID: run.id)
            if index == 0 { oldestRunDir = directory }
        }
        // A terminal transition triggers retention: cancel a fresh running run (no session → no teardown).
        let running = try harness.insertRun(
            automationID: automation.id, status: .running, createdAt: harness.now().addingTimeInterval(1000))
        harness.service.cancelRun(runID: running.id)

        XCTAssertEqual(try harness.store.automationRuns(automationID: automation.id).count, 100, "only the newest 100 runs are kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(oldestRunDir).path), "a pruned run's artifact directory is deleted")
    }

    // MARK: - Executor exit codes

    func testExecutorRecordsZeroExitAsSucceeded() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(command: "exit 0", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let finished = try harness.runUntilTerminal(runID: run.id)
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertEqual(finished.exitCode, 0)
    }

    func testExecutorRecordsNonZeroExitCode() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(command: "exit 3", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let finished = try harness.runUntilTerminal(runID: run.id)
        XCTAssertEqual(finished.status, .failed)
        XCTAssertEqual(finished.exitCode, 3)
    }

    // MARK: - Timeout + cancel

    func testTimeoutKillsCommandAndRecordsTimedOut() throws {
        let clock = MutableClock(start: Date())
        let harness = try Harness(self, realCommands: true, now: clock.now)
        let automation = try harness.insertAutomation(command: "sleep 30", concurrency: .allow, timeoutSeconds: 1)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let childPID = try XCTUnwrap(harness.host.lastChildPID)

        clock.advance(by: 5)  // push past the 1s budget without waiting
        harness.service.tick()

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .timedOut)
        try harness.assertProcessDies(pid: childPID, drivingTicks: harness.service.tick)
    }

    func testCancelKillsCommandAndRecordsCanceled() throws {
        let harness = try Harness(self, realCommands: true)
        let automation = try harness.insertAutomation(command: "sleep 30", concurrency: .allow)
        let run = try XCTUnwrap(harness.service.triggerManually(automationID: automation.id))
        let childPID = try XCTUnwrap(harness.host.lastChildPID)

        harness.service.cancelRun(runID: run.id)

        XCTAssertEqual(try harness.store.automationRun(id: run.id)?.status, .canceled)
        try harness.assertProcessDies(pid: childPID, drivingTicks: harness.service.tick)
    }
}

// MARK: - Test harness

@MainActor private final class Harness {
    let store: SQLiteStore
    let orchestrator: WorkspaceOrchestrator
    let host: FakeAutomationTerminalHost
    let service: AutomationService
    let now: () -> Date

    init(_ testCase: XCTestCase, realCommands: Bool = false, now: @escaping () -> Date = Date.init) throws {
        store = try testCase.makeTemporaryStore()
        let host = FakeAutomationTerminalHost(realCommands: realCommands)
        self.host = host
        host.install()
        testCase.addTeardownBlock { host.uninstall() }
        orchestrator = WorkspaceOrchestrator(store: store)
        self.now = now
        service = AutomationService(
            store: store, orchestrator: orchestrator, binaryDirectory: "/usr/bin", timeZone: .current, now: now, terminationGrace: 0.2,
            logError: { _ in })
    }

    func insertAutomation(
        command: String = "true", triggerKind: AutomationTriggerKind = .manual, cronExpression: String? = nil,
        concurrency: AutomationConcurrencyPolicy = .allow, missedRunPolicy: AutomationMissedRunPolicy = .runOnce, timeoutSeconds: Int? = nil,
        nextFireTime: Date? = nil
    ) throws -> Automation {
        let automation = Automation(
            id: UUID().uuidString, name: "Test", enabled: true, triggerKind: triggerKind, cronExpression: cronExpression, command: command,
            workingDirectory: FileManager.default.temporaryDirectory.path, timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrency,
            missedRunPolicy: missedRunPolicy, nextFireTime: nextFireTime, createdAt: now(), updatedAt: now())
        try store.upsertAutomation(automation)
        return automation
    }

    @discardableResult func insertRun(automationID: String, status: AutomationRunStatus, createdAt: Date? = nil) throws -> AutomationRun {
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automationID, status: status, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: nil, startedAt: status == .running ? (createdAt ?? now()) : nil, endedAt: status.isTerminal ? (createdAt ?? now()) : nil,
            createdAt: createdAt ?? now())
        try store.insertAutomationRun(run)
        return run
    }

    func makeProjectAndWorkspace() throws -> (ProjectRecord, WorkspaceRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    /// Writes an attributed coding-agent terminal session (workspace-scoped, stamped with the run id) plus
    /// its agent row, modeling a `spaces agent spawn` a run's command performed. `live` controls whether the
    /// runtime state reads as interactive with a live control socket.
    @discardableResult func writeAttributedAgentSession(workspaceID: String, runID: String, sessionID: String, live: Bool) throws -> AgentWindowRecord {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "agent", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-06T00:00:00Z", workspaceID: workspaceID, kind: .agent, automationRunID: runID), paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: Data("agent transcript\n".utf8))
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: live ? getpid() : 1, childPID: nil, state: live ? .running : .exited,
                updatedAt: "2026-06-06T00:00:01Z", exitedAt: live ? nil : "2026-06-06T00:00:01Z", title: "agent", workingDirectory: "/tmp"), paths: paths)
        if live { FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()) }
        return try orchestrator.registerAgentWindow(
            workspaceID: workspaceID, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: .spinning)
    }

    /// Drives `tick()` until a run reaches a terminal status, waiting for the fake host's background waiter
    /// to publish the command's ended runtime state. Fails if the run does not settle within the deadline.
    func runUntilTerminal(runID: String, timeout: TimeInterval = 5) throws -> AutomationRun {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            service.tick()
            if let run = try store.automationRun(id: runID), run.status.isTerminal { return run }
            usleep(30_000)
        }
        throw XCTSkip("run \(runID) did not reach a terminal status within \(timeout)s")
    }

    /// Asserts a process is killed within a deadline, driving the escalation ticks so a SIGTERM that the
    /// command ignored escalates to SIGKILL.
    func assertProcessDies(pid: Int32, drivingTicks tick: () -> Void, timeout: TimeInterval = 3) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            tick()
            usleep(30_000)
        }
        XCTFail("process \(pid) was not terminated within \(timeout)s")
    }
}

/// A settable clock so timeout tests can jump past a budget without waiting real time while the command
/// process runs in real time.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { current = start }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// Process-wide terminal-session launcher/terminator stand-in for the daemon's PTY session machinery. In
/// `realCommands` mode it runs the exact wrapped command the executor built (`/bin/sh -c …`) in its own
/// session via `posix_spawn` (so a timeout's process-group signal is safe and effective), redirecting
/// output to the session's `output.log`, and publishes the session's `.running` then `.exited` runtime
/// state. Otherwise it writes a non-completing `.running` session so concurrency/retention tests observe a
/// run that stays running until the test ends it.
private final class FakeAutomationTerminalHost: @unchecked Sendable {
    private let realCommands: Bool
    private let lock = NSLock()
    private(set) var lastChildPID: Int32?
    var delivered: [(sessionID: String, line: String)] {
        lock.lock()
        defer { lock.unlock() }
        return deliveredStore
    }
    private var deliveredStore: [(sessionID: String, line: String)] = []
    private var trackedPIDs: [Int32] = []

    init(realCommands: Bool) { self.realCommands = realCommands }

    func install() {
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher { [weak self] configuration in
            guard let self else { throw NSError(domain: "test", code: 1) }
            return try self.launch(configuration)
        }
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator { [weak self] sessionID in self?.terminate(sessionID: sessionID) }
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { [weak self] sessionID, line in
            self?.lock.lock()
            self?.deliveredStore.append((sessionID: sessionID, line: line))
            self?.lock.unlock()
        }
    }

    func uninstall() {
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher(nil)
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator(nil)
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil)
        lock.lock()
        let pids = trackedPIDs
        lock.unlock()
        for pid in pids { kill(pid, SIGKILL) }
    }

    func markSessionEnded(sessionID: String) {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
        writeRuntimeState(sessionID: sessionID, paths: paths, state: .exited, childPID: nil)
    }

    private func launch(_ configuration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
        let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
        FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())

        var childPID: Int32?
        if realCommands, let command = configuration.command {
            let pid = Self.spawnDetachedSession(command: command, workingDirectory: configuration.workingDirectory, outputPath: paths.outputPath)
            childPID = pid
            lock.lock()
            lastChildPID = pid
            trackedPIDs.append(pid)
            lock.unlock()
            writeRuntimeState(sessionID: configuration.sessionID, paths: paths, state: .running, childPID: pid)
            Thread.detachNewThread {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                self.writeRuntimeState(sessionID: configuration.sessionID, paths: paths, state: .exited, childPID: pid)
            }
        } else {
            writeRuntimeState(sessionID: configuration.sessionID, paths: paths, state: .running, childPID: nil)
        }

        return TerminalServiceSessionSummary(
            id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
            backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: getpid(),
            childPID: childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
    }

    private func terminate(sessionID: String) {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return }
        writeRuntimeState(sessionID: sessionID, paths: paths, state: .exited, childPID: nil)
        try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
    }

    private func writeRuntimeState(sessionID: String, paths: TerminalSessionPaths, state: TerminalSessionState, childPID: Int32?) {
        try? TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: childPID, state: state,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                exitedAt: state.isInteractive ? nil : ISO8601DateFormatter().string(from: Date())), paths: paths)
    }

    /// Spawns `/bin/sh -c command` in a fresh session (so it becomes its own process-group leader, exactly
    /// like a PTY child), with stdout/stderr redirected to `outputPath`. Returns the child pid, or -1.
    private static func spawnDetachedSession(command: String, workingDirectory: String, outputPath: String) -> Int32 {
        #if canImport(Darwin)
            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawn_file_actions_addopen(&fileActions, 1, outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

            var cArguments: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", command].map { $0.withCString { strdup($0) } }
            cArguments.append(nil)
            defer { for argument in cArguments where argument != nil { free(argument) } }

            var pid: pid_t = 0
            let result = cArguments.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, buffer.baseAddress, environ)
            }
            return result == 0 ? pid : -1
        #else
            return -1
        #endif
    }
}
