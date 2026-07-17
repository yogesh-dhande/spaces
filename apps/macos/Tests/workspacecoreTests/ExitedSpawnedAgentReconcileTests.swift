import XCTest
import spacesterminalcore

@testable import workspacecore

/// Coverage for finalizing coding-agent rows whose backing `.agent`-launch-kind terminal session ended
/// without any exit signal — the codex/opencode and SIGKILL'd-claude case, where no `agent signal exit`
/// ever arrives and the row would otherwise stay `spinning`/`waiting` forever. The reconciler must run
/// the real exit flow: notify subscribers the child exited, then delete/`.done` the row via the shared
/// `handleAgentExit`. A still-live session and the existing ad-hoc `.shell` sweep must be untouched.
final class ExitedSpawnedAgentReconcileTests: XCTestCase {
    private final class DeliveryRecorder: @unchecked Sendable {
        var delivered: [(sessionID: String, line: String)] = []
        func deliver(_ sessionID: String, _ line: String) throws { delivered.append((sessionID: sessionID, line: line)) }
    }

    func testExitedSpawnedAgentRowIsFinalizedAndSubscriberToldItExited() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "codex")

        let sessionID = UUID().uuidString
        try writeEndedTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: .spinning)
        // A plain-shell subscriber terminal with no agent row of its own counts as idle: it receives now.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: agent.id, createdAt: "t")

        let didMutate = try orchestrator.reconcileExitedSpawnedAgentRows(excludingLiveSessionIDs: [], engine: engine)

        XCTAssertTrue(didMutate)
        XCTAssertNil(try store.agentWindow(id: agent.id), "the spawned agent row is deleted by handleAgentExit")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
    }

    func testLiveSpawnedAgentSessionIsLeftUntouched() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "codex")

        let sessionID = UUID().uuidString
        try writeLiveTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: agent.id, createdAt: "t")

        // A live session's id appears in the excluded live set the caller computes, so the sweep skips it.
        let didMutate = try orchestrator.reconcileExitedSpawnedAgentRows(excludingLiveSessionIDs: [sessionID], engine: engine)

        XCTAssertFalse(didMutate)
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.status, .spinning)
        XCTAssertTrue(recorder.delivered.isEmpty, "a live agent must not trigger an exited notification")
    }

    func testAdHocShellRowKeepsExistingDoneBehaviorAndIsNotSweptAsAgent() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "codex")

        let sessionID = UUID().uuidString
        try writeEndedTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .shell)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: sessionID, status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: agent.id, createdAt: "t")

        // The `.agent` sweep must ignore a `.shell`-launch-kind row entirely — no exit flow, no delete.
        let agentSweepMutated = try orchestrator.reconcileExitedSpawnedAgentRows(excludingLiveSessionIDs: [], engine: engine)

        XCTAssertFalse(agentSweepMutated)
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.status, .spinning, "the agent sweep must not touch a shell row")
        XCTAssertTrue(recorder.delivered.isEmpty, "a shell row is never notified through the agent exit flow")

        // The existing ad-hoc `.shell` sweep still marks the ended row `.done` and keeps it.
        let shellSweepMutated = try orchestrator.reconcileExitedAdHocForegroundAgentRows(excludingLiveSessionIDs: [])

        XCTAssertTrue(shellSweepMutated)
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.status, .done)
    }

    // MARK: - Fixtures

    private func makeEngine(store: SQLiteStore, recorder: DeliveryRecorder, kind: String?) -> AgentNotificationEngine {
        AgentNotificationEngine(store: store, deliver: recorder.deliver, resolveAgentKind: { _ in kind }, logError: { _ in })
    }

    private func makeProjectAndWorkspace(store: SQLiteStore) throws -> (ProjectRecord, WorkspaceRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    /// Writes the launch configuration + a non-interactive runtime state that models a terminal session
    /// whose child has exited, so the reconciler reads it as an ended session.
    private func writeEndedTerminalSession(sessionID: String, workspaceID: String, workspaceDir: String, kind: TerminalSessionKind) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "agent", workingDirectory: workspaceDir, shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-06T00:00:00Z", workspaceID: workspaceID, kind: kind), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: nil, state: .exited, updatedAt: "2026-06-06T00:00:01Z",
                exitedAt: "2026-06-06T00:00:01Z", title: "agent", workingDirectory: workspaceDir), paths: paths)
    }

    /// Writes a launch configuration + a running runtime state with this process's own service PID, so any
    /// liveness read treats the session as live.
    private func writeLiveTerminalSession(sessionID: String, workspaceID: String, workspaceDir: String, kind: TerminalSessionKind) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "agent", workingDirectory: workspaceDir, shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-06T00:00:00Z", workspaceID: workspaceID, kind: kind), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
                updatedAt: "2026-06-06T00:00:01Z", title: "agent", workingDirectory: workspaceDir), paths: paths)
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
    }
}
