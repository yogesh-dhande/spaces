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

        let finalizedWorkspaceIDs = try orchestrator.reconcileExitedSessionBackedAgentRows(
            index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [])

        XCTAssertFalse(finalizedWorkspaceIDs.isEmpty)
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
        let finalizedWorkspaceIDs = try orchestrator.reconcileExitedSessionBackedAgentRows(
            index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [sessionID])

        XCTAssertTrue(finalizedWorkspaceIDs.isEmpty)
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

        let finalizedWorkspaceIDs = try orchestrator.reconcileExitedSessionBackedAgentRows(
            index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [])

        XCTAssertFalse(finalizedWorkspaceIDs.isEmpty)
        XCTAssertNil(try store.agentWindow(id: agent.id), "the dead ad-hoc shell agent row is deleted by handleAgentExit, not marked .done")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertTrue(
            try store.agentSubscriptions(subscriberTerminalSessionID: sessionID).isEmpty,
            "the closed shell terminal's own outgoing watch edge must be torn down")

        // A second pass finds no live-status row for the deleted session, so it re-notifies nothing.
        let secondPassFinalized = try orchestrator.reconcileExitedSessionBackedAgentRows(
            index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [])
        XCTAssertTrue(secondPassFinalized.isEmpty)
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

        let finalizedWorkspaceIDs = try orchestrator.reconcileExitedSessionBackedAgentRows(
            index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [])

        XCTAssertFalse(finalizedWorkspaceIDs.isEmpty)
        XCTAssertNil(try store.agentWindow(id: agent.id), "the dead hookless .done row is finalized (deleted) by handleAgentExit")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: agent.id).isEmpty, "the dead row's inbound edge is dropped")

        // A second pass finds no live-status row for the deleted session, so it re-notifies nothing.
        let secondPassFinalized = try orchestrator.reconcileExitedSessionBackedAgentRows(
            index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [])
        XCTAssertTrue(secondPassFinalized.isEmpty)
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

        let finalizedWorkspaceIDs = try orchestrator.reconcileExitedSessionBackedAgentRows(
            index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [])

        XCTAssertFalse(finalizedWorkspaceIDs.isEmpty, "the reincarnated row is sweepable again: the old life's exit event no longer blocks it")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session", "orchestrator-session"])
        XCTAssertTrue(
            recorder.delivered.last?.line.contains("is exited") == true,
            "the subscriber must be told the NEW life exited, got: \(recorder.delivered.last?.line ?? "nothing")")

        // The new life's terminal had already ended, so the sweep deleted the row; a further pass finds
        // nothing left to finalize and re-notifies nothing.
        let thirdPassFinalized = try orchestrator.reconcileExitedSessionBackedAgentRows(
            index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [])
        XCTAssertTrue(thirdPassFinalized.isEmpty)
        XCTAssertEqual(recorder.delivered.count, 2, "exactly one notice per life, none re-delivered")
    }

    /// The startup sweep's pane contract. A daemon that came back from an unclean exit has already
    /// recorded the agents it stranded as restorable, and this sweep is what finalizes their rows moments
    /// later. Telling the client to close those panes would take away the very seats the restored agents
    /// come back to, so the offer would be answered into fresh tabs instead of the panes the user left.
    /// The session itself is still ended: only the pane is left standing, for the answer to settle.
    func testStrandedAgentOfferedForRestoreKeepsItsPaneWhileTheSessionStillEnds() throws {
        let store = try makeTemporaryStore()
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowCloser: { sessionID, disposition in
                closeCapture.sessionIDs.append(sessionID)
                closeCapture.dispositions.append(disposition)
            }, builtInTerminalSessionTerminator: { terminateCapture.sessionIDs.append($0) })
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let offeredSessionID = UUID().uuidString
        let unofferedSessionID = UUID().uuidString
        for sessionID in [offeredSessionID, unofferedSessionID] {
            try writeEndedTerminalSession(sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent)
            _ = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, status: .spinning)
        }
        try store.replaceRestorableSessions(
            generation: "gen-1", capturedAt: "2026-06-06T00:00:02Z",
            captures: [
                RestorableSessionCapture(
                    sessionID: offeredSessionID, workspaceID: workspace.id, agentKind: .codex, agentSessionKey: "conversation-1",
                    launchCommand: "codex", workingDirectory: workspace.dir, title: "Codex")
            ])

        _ = try orchestrator.reconcileExitedSessionBackedAgentRows(index: orchestrator.builtInTerminalOwnershipIndex(), excludingLiveSessionIDs: [])

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "both ended agents are finalized either way")
        XCTAssertEqual(
            closeCapture.sessionIDs, [unofferedSessionID],
            "only the agent nobody is being offered back has its pane closed; the offered one keeps the seat its restore claims")
        XCTAssertEqual(
            terminateCapture.sessionIDs.sorted(), [offeredSessionID, unofferedSessionID].sorted(),
            "keeping the pane keeps nothing else: the ended session is torn down either way")
    }

    /// A session Spaces launched to run one coding agent (`agent spawn`, the MCP server, an automation, or a
    /// session restore, all `.agent` launch kind) gets no `agent_sessions` row at launch: the row appears only
    /// once the agent's hooks report it, or once `reconcileTerminalForegroundAgentClassifications` mints one
    /// from live foreground detection. codex and opencode fire no hook until their first turn, and a hook can
    /// be broken outright, so without the detection insert such a session sits in the sidebar as a plain
    /// terminal forever. This is the same detection insert a plain shell the user typed an agent into gets,
    /// with the same deterministic id, so a later hook `init` adopts the row in place.
    func testAgentLaunchKindSessionWithNoRowGetsOneFromForegroundDetection() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let sessionID = UUID().uuidString
        try writeLiveTerminalSession(
            sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent, foregroundDetectedAgentKind: .claude,
            foregroundExecutableName: "claude", foregroundArgv: ["claude"], foregroundDisplayLabel: "Claude Code", foregroundDisplayCommand: "claude")

        XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())

        let agent = try XCTUnwrap(try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID))
        XCTAssertEqual(agent.id, "terminal-agent-\(sessionID)", "the row carries the same deterministic id a plain shell's detection row gets")
        XCTAssertEqual(agent.detectedAgentKind, "claude")
    }

    /// A hook `init` signal that lands on the `.agent`-launched session after detection has already minted
    /// its row (the common case: the agent's own hooks are simply slower than the next reconcile pass)
    /// updates that SAME row in place, through the identical restart-reuse chokepoint a plain shell's
    /// detection row is adopted by, rather than minting a second row for the one agent the session runs.
    func testAgentLaunchKindSessionHookInitAdoptsTheDetectionRowInPlace() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let sessionID = UUID().uuidString
        try writeLiveTerminalSession(
            sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent, foregroundDetectedAgentKind: .claude,
            foregroundExecutableName: "claude", foregroundArgv: ["claude"], foregroundDisplayLabel: "Claude Code", foregroundDisplayCommand: "claude")
        XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
        let detected = try XCTUnwrap(try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID))

        let adopted = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code", terminalTrackingID: sessionID, status: .spinning, eventType: "init",
            eventSource: "spaces_agent_signal")

        XCTAssertEqual(adopted.id, detected.id, "the hook init reuses the detection row's id rather than minting a second row")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
        XCTAssertEqual(adopted.status, .spinning)
    }

    /// A live agent's terminal can momentarily report its own bare shell as the foreground sample (between
    /// the agent's turns, or a foreground read that lands mid-transition) without the agent having actually
    /// exited. Because this session is `.agent`-launch-kind it exists for the one agent it was launched to
    /// run, so that momentary read must never be mistaken for the agent quitting: the plain-shell demote
    /// branch is for a row detection promoted out of a terminal the user typed an agent into, not this one.
    func testAgentLaunchKindSessionMomentaryBareShellForegroundDoesNotDropTheRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let sessionID = UUID().uuidString
        try writeLiveTerminalSession(
            sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent, foregroundDetectedAgentKind: .claude,
            foregroundExecutableName: "claude", foregroundArgv: ["claude"], foregroundDisplayLabel: "Claude Code", foregroundDisplayCommand: "claude")
        XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
        let detected = try XCTUnwrap(try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID))

        // The foreground reverts to the session's own configured shell with nothing running in it: the
        // same unambiguous bare-shell signal `foregroundHasRevertedToPlainShell` reads for a plain terminal.
        try writeLiveTerminalSession(
            sessionID: sessionID, workspaceID: workspace.id, workspaceDir: workspace.dir, kind: .agent, foregroundExecutableName: "zsh",
            foregroundArgv: ["zsh"])

        XCTAssertFalse(
            try orchestrator.reconcileTerminalForegroundAgentClassifications(),
            "a momentary bare-shell foreground on an .agent-launched session is not a relaunch, a demote, or any other mutation")
        let stillThere = try XCTUnwrap(
            try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID), "the row must survive the momentary bare foreground")
        XCTAssertEqual(stillThere.id, detected.id)
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
    /// liveness read treats the session as live. The foreground-detection parameters default to nil (a bare
    /// interactive session with nothing classified in it); passing them models a live session whose
    /// foreground currently reports a coding agent or, when only the shell fields are set, its own bare
    /// prompt.
    private func writeLiveTerminalSession(
        sessionID: String, workspaceID: String, workspaceDir: String, kind: TerminalSessionKind,
        foregroundDetectedAgentKind: TerminalDetectedAgentKind? = nil, foregroundExecutableName: String? = nil, foregroundArgv: [String]? = nil,
        foregroundDisplayLabel: String? = nil, foregroundDisplayCommand: String? = nil
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "agent", workingDirectory: workspaceDir, shell: "/bin/zsh", command: nil,
                createdAt: "2026-06-06T00:00:00Z", workspaceID: workspaceID, kind: kind), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
                updatedAt: "2026-06-06T00:00:01Z", title: "agent", workingDirectory: workspaceDir, foregroundExecutableName: foregroundExecutableName,
                foregroundArgv: foregroundArgv, foregroundDetectedAgentKind: foregroundDetectedAgentKind,
                foregroundDisplayLabel: foregroundDisplayLabel, foregroundDisplayCommand: foregroundDisplayCommand), paths: paths)
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
    }
}
