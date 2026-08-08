import XCTest
import spacesterminalcore

@testable import workspacecore

/// Coverage for finalizing coding-agent rows whose backing terminal session ended without any exit
/// signal — the codex/opencode and SIGKILL'd-claude case, where no `agent signal exit` ever arrives and
/// the row would otherwise stay `spinning`/`waiting` forever. The single sweep covers both a spawned
/// `.agent`-launch-kind session and an ad-hoc foreground-detected agent in a closed `.shell`-launch-kind
/// terminal. The reconciler must run the real exit flow: notify subscribers the child exited, then
/// delete the row via the shared `handleAgentExit`. A still-live session must be untouched.
final class ExitedSpawnedAgentReconcileTests: XCTestCase {
    private final class DeliveryRecorder: @unchecked Sendable {
        var delivered: [(sessionID: String, line: String)] = []
        func deliver(_ sessionID: String, _ line: String) throws { delivered.append((sessionID: sessionID, line: line)) }
    }

    func testExitedSpawnedAgentRowIsFinalizedAndSubscriberToldItExited() throws {
        let store = try makeTemporaryStore()
        let recorder = DeliveryRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.deliver($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let sessionID = UUID().uuidString
        try writeEndedTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: .spinning)
        // A plain-shell subscriber terminal with no agent row of its own counts as idle: it receives now.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: agent.id, createdAt: "t")

        let didMutate = try orchestrator.reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: [])

        XCTAssertTrue(didMutate)
        XCTAssertNil(try store.agentWindow(id: agent.id), "the spawned agent row is deleted by handleAgentExit")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
    }

    func testLiveSpawnedAgentSessionIsLeftUntouched() throws {
        let store = try makeTemporaryStore()
        let recorder = DeliveryRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.deliver($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let sessionID = UUID().uuidString
        try writeLiveTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: agent.id, createdAt: "t")

        // A live session's id appears in the excluded live set the caller computes, so the sweep skips it.
        let didMutate = try orchestrator.reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: [sessionID])

        XCTAssertFalse(didMutate)
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.status, .spinning)
        XCTAssertTrue(recorder.delivered.isEmpty, "a live agent must not trigger an exited notification")
    }

    /// A watched ad-hoc foreground-detected agent whose `.shell`-launch-kind terminal was closed is
    /// finalized by the same exit flow as a spawned agent: its subscriber is told it `exited` before the
    /// row is deleted, and the closed terminal's own outgoing watch edge is torn down. The dead row is
    /// deleted (not left as a phantom `.done` "finished" alert), and a second sweep pass — the row now
    /// gone — delivers nothing more.
    func testExitedAdHocShellAgentRowIsDeletedAndSubscriberToldItExited() throws {
        let store = try makeTemporaryStore()
        let recorder = DeliveryRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.deliver($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let sessionID = UUID().uuidString
        try writeEndedTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .shell)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: sessionID, status: .spinning)
        // A plain-shell subscriber terminal with no agent row of its own counts as idle: it receives now.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: agent.id, createdAt: "t")
        // The closed shell was itself watching another agent, so its own outgoing edge must be torn down.
        let otherChild = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Other CLI", terminalTrackingID: "other-child", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: sessionID, agentSessionID: otherChild.id, createdAt: "t")

        let didMutate = try orchestrator.reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: [])

        XCTAssertTrue(didMutate)
        XCTAssertNil(try store.agentWindow(id: agent.id), "the dead ad-hoc shell agent row is deleted by handleAgentExit, not marked .done")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertTrue(
            try store.agentSubscriptions(subscriberTerminalSessionID: sessionID).isEmpty,
            "the closed shell terminal's own outgoing watch edge must be torn down")

        // A second pass finds no live-status row for the deleted session, so it re-notifies nothing.
        let secondPassMutated = try orchestrator.reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: [])
        XCTAssertFalse(secondPassMutated)
        XCTAssertEqual(recorder.delivered.count, 1, "the idempotent sweep must not re-deliver an exited notice on a later pass")
    }

    /// A hookless coding agent (codex/opencode) that completed a turn sits `.done`; if its terminal is then
    /// closed no exit hook fires. The sweep must still finalize such a `.done` row — `.done` is not a
    /// finalized fact without a recorded exit event — delivering the exited notice its subscribers are owed
    /// and clearing its edges before deleting the dead row, and a second pass over the now-gone row stays
    /// silent. Before the finalized-fact change the sweep skipped every `.done` row, leaving this one stale
    /// forever and its watchers never told it exited.
    func testExitedHooklessDoneAgentRowIsFinalizedAndSubscriberToldItExited() throws {
        let store = try makeTemporaryStore()
        let recorder = DeliveryRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.deliver($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let sessionID = UUID().uuidString
        try writeEndedTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .shell)
        // A hookless agent that finished a turn: `.done`, but with no recorded exit event.
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: .done)
        XCTAssertFalse(try store.agentSessionHasRecordedExitEvent(agentSessionID: agent.id), "a turn-complete .done row is not yet finalized")
        // A plain-shell subscriber terminal with no agent row of its own counts as idle: it receives now.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: agent.id, createdAt: "t")

        let didMutate = try orchestrator.reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: [])

        XCTAssertTrue(didMutate)
        XCTAssertNil(try store.agentWindow(id: agent.id), "the dead hookless .done row is finalized (deleted) by handleAgentExit")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: agent.id).isEmpty, "the dead row's inbound edge is dropped")

        // A second pass finds no live-status row for the deleted session, so it re-notifies nothing.
        let secondPassMutated = try orchestrator.reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: [])
        XCTAssertFalse(secondPassMutated)
        XCTAssertEqual(recorder.delivered.count, 1, "the idempotent sweep must not re-deliver an exited notice on a later pass")
    }

    /// A reincarnated row (a fresh agent's `init` reused a kept, previously-exited row) must be sweepable
    /// again: when the NEW life's terminal dies hookless, the sweep finalizes it with a fresh exited
    /// notice. The previous life's exit event must not keep the row permanently "finalized" — that would
    /// leave the new life's death silent and the row stale. A further pass over the re-finalized row
    /// stays silent.
    func testSweepFinalizesReincarnatedRowWhoseNewLifeTerminalDiedHookless() throws {
        let store = try makeTemporaryStore()
        let recorder = DeliveryRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.deliver($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        // Life 1: an agent exits while its terminal is still live — row kept `.exited` with a recorded
        // exit event, watcher notified once (the kept row retains its inbound edge).
        let sessionID = UUID().uuidString
        try writeLiveTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID, status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: agent.id, createdAt: "t")
        _ = try orchestrator.finalizeAgentRow(agent, reason: .exited(eventType: "exit", eventSource: "spaces_agent_signal", environmentKeys: nil))
        XCTAssertEqual(recorder.delivered.count, 1, "life 1's exit is notified once")

        // Life 2: a fresh agent inits in the same terminal (same row id, an `init` event recorded), then
        // its terminal dies without any exit hook.
        let reincarnated = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID,
            status: try XCTUnwrap(try store.agentWindow(id: agent.id)).status, eventType: "init", eventSource: "spaces_agent_signal")
        XCTAssertEqual(reincarnated.id, agent.id, "the restart-reuse init reuses the same row id")
        try writeEndedTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent)

        let didMutate = try orchestrator.reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: [])

        XCTAssertTrue(didMutate, "the reincarnated row is sweepable again — the old life's exit event no longer blocks it")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session", "orchestrator-session"])
        XCTAssertTrue(
            recorder.delivered.last?.line.contains("is exited") == true,
            "the subscriber must be told the NEW life exited, got: \(recorder.delivered.last?.line ?? "nothing")")

        // The new life's terminal had already ended, so the sweep deleted the row; a further pass finds
        // nothing left to finalize and re-notifies nothing.
        let thirdPassMutated = try orchestrator.reconcileExitedSessionBackedAgentRows(excludingLiveSessionIDs: [])
        XCTAssertFalse(thirdPassMutated)
        XCTAssertEqual(recorder.delivered.count, 2, "exactly one notice per life, none re-delivered")
    }

    // MARK: - Fixtures

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
