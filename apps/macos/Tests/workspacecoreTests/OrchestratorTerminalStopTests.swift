import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Behavior coverage for `WorkspaceOrchestrator.stopWorkspaceTerminalSession`, the explicit-Stop decision
/// shared by the sidebar's Stop on a runtime target and `spaces terminal stop`, and for
/// `stopLiveWorkspaceTerminalSession`, the CLI's gated spelling of it. Each test drives one of the session
/// shapes a Stop can land on (automation run, coding agent, configured process, ad hoc terminal) and asserts
/// the outcome the caller reports and which teardown path actually ran.
final class OrchestratorTerminalStopTests: XCTestCase {
    func testStoppingAnAdHocTerminalTerminatesItsSession() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "ad-hoc-session"
        try seedTerminalSession(sessionID: sessionID, workspace: workspace, kind: .shell)

        let outcome = try orchestrator.stopWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil,
            killAgentSession: { _ in
                XCTFail("an ad hoc terminal must not route through the agent stop chokepoint")
                return false
            })

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
    }

    /// A session that has already ended reports `.alreadyStopped` rather than terminating something else.
    /// `spaces terminal stop` turns that into a refusal, so the distinction is what keeps the CLI honest.
    func testStoppingAnEndedTerminalReportsAlreadyStopped() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)

        let outcome = try orchestrator.stopWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: "session-that-never-existed", automationOperations: nil, killAgentSession: { _ in false })

        XCTAssertEqual(outcome, .alreadyStopped)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    /// A coding agent must go through the agent stop chokepoint (which notifies its subscribers before
    /// deleting its row), not the ad hoc terminator.
    func testStoppingASpawnedAgentRoutesThroughTheAgentStopChokepoint() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "agent-session"
        try seedTerminalSession(sessionID: sessionID, workspace: workspace, kind: .agent)
        var killedSessionIDs: [String] = []

        let outcome = try orchestrator.stopWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil,
            killAgentSession: { killed in
                killedSessionIDs.append(killed)
                return true
            })

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(killedSessionIDs, [sessionID])
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    func testAgentStopThatFindsNothingToKillReportsAlreadyStopped() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try seedWorkspace(store: store)
        let sessionID = "agent-session-gone"
        try seedTerminalSession(sessionID: sessionID, workspace: workspace, kind: .agent)

        let outcome = try orchestrator.stopWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil, killAgentSession: { _ in false })

        XCTAssertEqual(outcome, .alreadyStopped)
    }

    /// Stopping an active automation run's terminal cancels the run, which owns the teardown of everything
    /// the run launched.
    func testStoppingAnActiveAutomationRunsTerminalCancelsTheRun() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "automation-session"
        let run = try seedAutomationRun(store: store, workspace: workspace, sessionID: sessionID, status: .running)
        let canceledRunIDs = CanceledAutomationRunCapture()

        let outcome = try orchestrator.stopWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID,
            automationOperations: automationOperations(cancelRun: { runID in
                canceledRunIDs.append(runID)
                return Self.run(run, status: .canceled)
            }), killAgentSession: { _ in false })

        XCTAssertEqual(outcome, .canceledAutomationRun)
        XCTAssertEqual(canceledRunIDs.runIDs, [run.id])
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    /// A run that had already finished before Stop arrived does not own the Stop: its terminal falls
    /// through to the ordinary session teardown.
    func testStoppingAFinishedAutomationRunsTerminalFallsThroughToTheSessionStop() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "finished-automation-session"
        let run = try seedAutomationRun(store: store, workspace: workspace, sessionID: sessionID, status: .succeeded)

        let outcome = try orchestrator.stopWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID,
            automationOperations: automationOperations(cancelRun: { _ in Self.run(run, status: .succeeded) }), killAgentSession: { _ in false })

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
    }

    /// A daemon with no automation service cannot decide an automation-attributed Stop, so it refuses
    /// loudly instead of tearing the session down behind the run's back.
    func testStoppingAnAutomationTerminalWithoutAnAutomationServiceRefuses() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try seedWorkspace(store: store)
        let sessionID = "unserviceable-automation-session"
        _ = try seedAutomationRun(store: store, workspace: workspace, sessionID: sessionID, status: .running)

        XCTAssertThrowsError(
            try orchestrator.stopWorkspaceTerminalSession(
                workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil, killAgentSession: { _ in false })
        ) { error in XCTAssertEqual(error as? WorkspaceTerminalStopUnavailable, .automations) }
    }

    /// A configured process owns its terminal, so Stop on that session is the process Stop: the same
    /// orchestrator call the sidebar's process Stop reaches, which ends the process and retires its row.
    func testStoppingAConfiguredProcessTerminalStopsThroughTheProcessPath() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "configured-process-session"
        try seedTerminalSession(sessionID: sessionID, workspace: workspace, kind: .process)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2026-01-01T00:00:00Z",
                exitedAt: nil))

        let outcome = try orchestrator.stopWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil,
            killAgentSession: { _ in
                XCTFail("a configured process terminal must not route through the agent stop chokepoint")
                return false
            })

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    /// `spaces terminal stop` refuses a session that has already ended rather than acting on the rows it
    /// left behind. An automation run outlives the session it started, so a Stop aimed at the ended session
    /// must not cancel the run that has moved on.
    func testStoppingAnEndedAutomationSessionRefusesWithoutCancelingItsRun() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "ended-automation-session"
        let run = try seedAutomationRun(
            store: store, workspace: workspace, sessionID: sessionID, status: .running, sessionState: .exited, sessionHasControlSocket: false)
        let canceledRunIDs = CanceledAutomationRunCapture()

        let outcome = try orchestrator.stopLiveWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID,
            automationOperations: automationOperations(cancelRun: { runID in
                canceledRunIDs.append(runID)
                return Self.run(run, status: .canceled)
            }), killAgentSession: { _ in false })

        XCTAssertEqual(outcome, .alreadyStopped)
        XCTAssertTrue(canceledRunIDs.runIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
        XCTAssertEqual(try store.automationRun(id: run.id)?.status, .running)
    }

    /// The racy shape of the same refusal: the session's durable runtime row is written behind its exit, so
    /// a session that has just ended still reads `.running` there while its control socket is already gone.
    /// The gate reads the socket, so the run the next session is executing under is left alone.
    func testStoppingAJustExitedAutomationSessionRefusesWhileItsRowStillReadsRunning() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "just-exited-automation-session"
        let run = try seedAutomationRun(
            store: store, workspace: workspace, sessionID: sessionID, status: .running, sessionState: .running, sessionHasControlSocket: false)
        let canceledRunIDs = CanceledAutomationRunCapture()

        let outcome = try orchestrator.stopLiveWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID,
            automationOperations: automationOperations(cancelRun: { runID in
                canceledRunIDs.append(runID)
                return Self.run(run, status: .canceled)
            }), killAgentSession: { _ in false })

        XCTAssertEqual(outcome, .alreadyStopped)
        XCTAssertTrue(canceledRunIDs.runIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
        XCTAssertEqual(try store.automationRun(id: run.id)?.status, .running)
    }

    /// The same gate passes a live session straight through to the shared decision.
    func testStoppingALiveSessionThroughTheGatedEntryPointStopsIt() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "live-ad-hoc-session"
        try seedTerminalSession(sessionID: sessionID, workspace: workspace, kind: .shell)

        let outcome = try orchestrator.stopLiveWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil, killAgentSession: { _ in false })

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
    }

    /// A handoff that begins after the CLI's entry check reaches the orchestrator with its flag already
    /// raised, so from here the first read of it is the mutation-boundary veto. During a handoff the session
    /// terminator no-ops and live sessions are carried into the successor daemon, so a stop that deleted rows
    /// anyway would hand that daemon a live terminal nothing names. Both teardown branches refuse instead.
    func testStoppingAConfiguredProcessTerminalIsVetoedByADaemonHandoff() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) },
            daemonHandoffInProgress: { true })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "handoff-process-session"
        try seedTerminalSession(sessionID: sessionID, workspace: workspace, kind: .process)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-handoff", workspaceID: workspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "2026-01-01T00:00:00Z", exitedAt: nil))

        XCTAssertThrowsError(
            try orchestrator.stopLiveWorkspaceTerminalSession(
                workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil, killAgentSession: { _ in false })
        ) { error in
            guard case .daemonHandoffInProgress = error as? WorkspaceError else {
                XCTFail("expected the handoff veto to refuse the stop, got \(error)")
                return
            }
        }

        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.id), ["process-handoff"])
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    func testStoppingAnAdHocTerminalIsVetoedByADaemonHandoff() throws {
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) },
            daemonHandoffInProgress: { true })
        let workspace = try seedWorkspace(store: store)
        let sessionID = "handoff-ad-hoc-session"
        try seedTerminalSession(sessionID: sessionID, workspace: workspace, kind: .shell)
        try store.upsert(
            window: WindowRecord(
                id: "window-handoff", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: sessionID, detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "2026-01-01T00:00:00Z"))

        XCTAssertThrowsError(
            try orchestrator.stopLiveWorkspaceTerminalSession(
                workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil, killAgentSession: { _ in false })
        ) { error in
            guard case .daemonHandoffInProgress = error as? WorkspaceError else {
                XCTFail("expected the handoff veto to refuse the stop, got \(error)")
                return
            }
        }

        XCTAssertEqual(try store.windows(workspaceID: workspace.id).map(\.id), ["window-handoff"])
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    // MARK: - Fixtures

    private func seedWorkspace(store: SQLiteStore) throws -> WorkspaceRecord {
        let dir = try makeTempDirectory()
        let project = makeProjectRecord(dir: dir.path)
        try store.upsert(project: project)
        let workspaceDir = dir.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: workspaceDir.path)
        try store.upsert(workspace: workspace)
        return workspace
    }

    /// Writes the on-disk launch configuration and running runtime state of a live workspace terminal, the
    /// shape every stop path reads to decide what a session is and who owns it.
    private func seedTerminalSession(
        sessionID: String, workspace: WorkspaceRecord, kind: TerminalSessionKind, automationRunID: String? = nil,
        state: TerminalSessionState = .running, hasControlSocket: Bool = true
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: sessionID, workingDirectory: workspace.dir,
                shell: "/bin/zsh", command: nil, createdAt: "2026-01-01T00:00:00Z", workspaceID: workspace.id, kind: kind,
                automationRunID: automationRunID), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                state: state, updatedAt: "2026-01-01T00:00:00Z", title: sessionID, workingDirectory: workspace.dir), paths: paths)
        // The control socket is the live-session marker the session host unlinks the moment a session ends,
        // ahead of its exited runtime row, so a session fixture without one stands for a session that has
        // ended however its durable row still reads.
        if hasControlSocket { XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: nil)) }
    }

    @discardableResult private func seedAutomationRun(
        store: SQLiteStore, workspace: WorkspaceRecord, sessionID: String, status: AutomationRunStatus, sessionState: TerminalSessionState = .running,
        sessionHasControlSocket: Bool = true
    ) throws -> AutomationRun {
        let automation = Automation(
            id: UUID().uuidString, name: "Nightly", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "true",
            workspaceID: workspace.id, timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce, nextFireTime: nil,
            createdAt: Date(), updatedAt: Date())
        try store.upsertAutomation(automation)
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: status, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: sessionID, startedAt: Date(), endedAt: nil, createdAt: Date())
        try store.insertAutomationRun(run)
        try seedTerminalSession(
            sessionID: sessionID, workspace: workspace, kind: .automation, automationRunID: run.id, state: sessionState,
            hasControlSocket: sessionHasControlSocket)
        return run
    }

    private static func run(_ run: AutomationRun, status: AutomationRunStatus) -> AutomationRun {
        AutomationRun(
            id: run.id, automationID: run.automationID, kind: run.kind, status: status, skipReason: nil, trigger: run.trigger, exitCode: nil,
            terminalSessionID: run.terminalSessionID, startedAt: run.startedAt, endedAt: Date(), createdAt: run.createdAt)
    }

    /// An `AutomationOperations` bundle whose only live member is `cancelRun`; every other operation is
    /// unreachable from a terminal Stop, so calling one is a test failure rather than a stubbed result.
    private func automationOperations(cancelRun: @escaping @Sendable (String) throws -> AutomationRun) -> AutomationOperations {
        AutomationOperations(
            create: { _ in throw unreachableAutomationOperation }, update: { _, _ in throw unreachableAutomationOperation },
            setNextRun: { _, _ in throw unreachableAutomationOperation }, delete: { _ in throw unreachableAutomationOperation },
            list: { throw unreachableAutomationOperation }, runs: { _ in throw unreachableAutomationOperation },
            trigger: { _ in throw unreachableAutomationOperation }, cancelRun: cancelRun, endAgents: { _ in throw unreachableAutomationOperation })
    }
}

/// Records the run ids a `cancelRun` stub was asked for. The bundle's members are `@Sendable`, so the
/// capture has to be a reference type the closure may hold.
private final class CanceledAutomationRunCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []

    func append(_ runID: String) {
        lock.lock()
        captured.append(runID)
        lock.unlock()
    }

    var runIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private let unreachableAutomationOperation = WorkspaceError.invalidArgument(message: "a terminal stop must not reach this automation operation")
