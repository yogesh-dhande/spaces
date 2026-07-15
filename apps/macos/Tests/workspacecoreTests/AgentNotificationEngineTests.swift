import Foundation
import XCTest
import spacesdevicecore
import spacesterminalcore

@testable import workspacecore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Behavior coverage for the notification injection engine and the acyclic-subscription invariant:
/// idle subscribers get an immediate line in the exact wire format, busy subscribers queue and flush
/// once in order, repeated transitions coalesce, exit notifications outlive the deleted agent row, and
/// self/cycle subscriptions are rejected. Drives the same engine the daemon chokepoint attaches, with a
/// recorder standing in for the real terminal-send delivery.
final class AgentNotificationEngineTests: XCTestCase {
    /// Records delivered lines and can be told to fail specific sessions to simulate a dead subscriber.
    private final class DeliveryRecorder: @unchecked Sendable {
        var delivered: [(sessionID: String, line: String)] = []
        var failingSessionIDs: Set<String> = []
        func deliver(_ sessionID: String, _ line: String) throws {
            if failingSessionIDs.contains(sessionID) { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "dead session"]) }
            delivered.append((sessionID: sessionID, line: line))
        }
    }

    func testIdleSubscriberReceivesImmediateInjectionInExactFormat() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "claude")

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .waiting)
        // A plain-shell subscriber terminal with no agent row of its own counts as idle.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] Claude Code CLI (claude) is blocked
                  project: Project
                  workspace: \(workspace.dir)
                  session: child-session
                  link: spaces://terminal/child-session
                """
            ])
        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orchestrator-session").isEmpty)
    }

    /// When the kind resolver yields nothing (no session files to classify), the `(<kind>)` parenthetical
    /// falls back to `coding agent`, and the label falls back to that same value when the agent has none.
    func testImmediateInjectionFallsBackToCodingAgentKindWhenUnresolved() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: nil)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)

        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] coding agent (coding agent) is blocked
                  project: Project
                  workspace: \(workspace.dir)
                  session: child-session
                  link: spaces://terminal/child-session
                """
            ])
    }

    func testImmediateInjectionRendersNoteWhenSet() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "codex")

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "child-session", status: .done)
        try store.setAgentSessionNote(id: child.id, note: "review the auth flow", updatedAt: "t")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")
        let noted = try XCTUnwrap(store.agentWindow(id: child.id))

        try engine.childDidTransition(agent: noted, transition: .done)

        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] Codex CLI (codex) is done
                  project: Project
                  workspace: \(workspace.dir)
                  session: child-session
                  note: review the auth flow
                  link: spaces://terminal/child-session
                """
            ])
    }

    /// A git workspace carries a branch: the `workspace` line is the workspace's full directory path (not
    /// the branch-derived display name), the `branch` line carries the branch verbatim including slashes,
    /// and both are distinct so the branch is never duplicated into the workspace field. Non-git workspaces
    /// (branch nil, covered by the other cases) omit the `branch` line.
    func testImmediateInjectionRendersWorkspaceDirPathAndSlashedBranch() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, dir: dir + "/hello", dirname: "hello", branch: "smoke/hello",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "claude")

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)

        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] Claude Code CLI (claude) is blocked
                  project: Project
                  workspace: \(workspace.dir)
                  branch: smoke/hello
                  session: child-session
                  link: spaces://terminal/child-session
                """
            ])
    }

    /// Mirrors the daemon chokepoint exactly: the engine receives the record RETURNED by
    /// `updateAgentWindowStatus`, not a fresh store load, so that record must carry the stored note. A
    /// status transition after an annotate must still render the note in the injected line.
    func testNoteSurvivesStatusTransitionRecordThroughTheLivePath() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "claude")

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .idle)
        try store.setAgentSessionNote(id: child.id, note: "fix the flaky tests", updatedAt: "t")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")

        let transitioned = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .waiting)
        try engine.childDidTransition(agent: transitioned, transition: .blocked)

        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] Claude Code CLI (claude) is blocked
                  project: Project
                  workspace: \(workspace.dir)
                  session: child-session
                  note: fix the flaky tests
                  link: spaces://terminal/child-session
                """
            ])
    }

    func testBusySubscriberQueuesThenFlushesOnIdleInOrderExactlyOnce() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "claude")

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "sub-session", status: .spinning)
        let childA = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "A", terminalTrackingID: "childA", status: .waiting)
        let childB = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "B", terminalTrackingID: "childB", status: .done)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: childA.id, createdAt: "t0")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: childB.id, createdAt: "t1")

        try engine.childDidTransition(agent: childA, transition: .blocked)
        try engine.childDidTransition(agent: childB, transition: .done)

        XCTAssertTrue(recorder.delivered.isEmpty, "A busy subscriber must not receive an immediate line.")
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub-session").count, 2)

        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "sub-session")

        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] A (claude) is blocked
                  project: Project
                  workspace: \(workspace.dir)
                  session: childA
                  link: spaces://terminal/childA
                """,
                """
                [spaces] B (claude) is done
                  project: Project
                  workspace: \(workspace.dir)
                  session: childB
                  link: spaces://terminal/childB
                """,
            ])
        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub-session").isEmpty)

        // Flushing again delivers nothing: pending is delivered-once.
        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "sub-session")
        XCTAssertEqual(recorder.delivered.count, 2)
    }

    /// A row drained by the MCP piggyback path (`consumePendingAgentNotifications`) while the subscriber is
    /// still busy is gone from the queue, so the later idle flush re-delivers nothing: the busy-time drain
    /// and the idle-time flush share the same rows, and each row is delivered by exactly one path.
    func testPiggybackConsumeRemovesRowSoIdleFlushDoesNotRedeliver() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "claude")

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "sub-session", status: .spinning)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "A", terminalTrackingID: "childA", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: child.id, createdAt: "t0")

        // Busy subscriber: the transition queues rather than delivering immediately.
        try engine.childDidTransition(agent: child, transition: .blocked)
        XCTAssertTrue(recorder.delivered.isEmpty)

        // The MCP piggyback drains the held row while the subscriber is still busy.
        XCTAssertEqual(try store.consumePendingAgentNotifications(subscriberTerminalSessionID: "sub-session").count, 1)

        // When the subscriber later goes idle, the flush finds nothing to re-deliver.
        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "sub-session")
        XCTAssertTrue(recorder.delivered.isEmpty, "A row consumed by the piggyback path must not be re-delivered by the idle flush.")
    }

    func testBlockedThenDoneWhileBusyCoalescesToSingleDoneLine() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let engine = makeEngine(store: store, recorder: DeliveryRecorder(), kind: "claude")

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "sub-session", status: .spinning)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)
        let doneChild = try XCTUnwrap(store.agentWindow(id: child.id))
        try engine.childDidTransition(agent: doneChild, transition: .done)

        let pending = try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub-session")
        XCTAssertEqual(pending.count, 1, "The unique index must coalesce repeated transitions of one child to a single pending line.")
        XCTAssertEqual(
            pending.first?.message,
            """
            [spaces] Claude Code CLI (claude) is done
              project: Project
              workspace: \(workspace.dir)
              session: child-session
              link: spaces://terminal/child-session
            """)
    }

    /// A child that resumes working after an approval must withdraw its held "is blocked" line — the
    /// subscriber never receives stale misinformation, and going idle later delivers nothing.
    func testResumeAfterBlockedWithdrawsHeldBlockedLine() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "claude")

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "sub-session", status: .spinning)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub-session").count, 1)

        try engine.childDidResumeWorking(agentSessionID: child.id)

        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub-session").isEmpty)
        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "sub-session")
        XCTAssertTrue(recorder.delivered.isEmpty, "A withdrawn blocked line must never be delivered.")
    }

    /// The withdrawal keys on the transition the held row renders, not the child alone: a held `done`
    /// line is a terminal fact and survives a resume call, while a sibling's blocked line is dropped.
    func testResumeWithdrawsOnlyBlockedLinesHeldDoneLineSurvives() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "claude")

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "sub-session", status: .spinning)
        let blockedChild = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "A", terminalTrackingID: "childA", status: .waiting)
        let doneChild = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "B", terminalTrackingID: "childB", status: .done)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: blockedChild.id, createdAt: "t0")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: doneChild.id, createdAt: "t1")

        try engine.childDidTransition(agent: blockedChild, transition: .blocked)
        try engine.childDidTransition(agent: doneChild, transition: .done)

        try engine.childDidResumeWorking(agentSessionID: blockedChild.id)
        // A resume call against the done child's id must not withdraw its terminal-fact line.
        try engine.childDidResumeWorking(agentSessionID: doneChild.id)

        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "sub-session")
        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] B (claude) is done
                  project: Project
                  workspace: \(workspace.dir)
                  session: childB
                  link: spaces://terminal/childB
                """
            ])
    }

    /// The cross-device queue keys held rows on the remote child's terminal session id, so a remote
    /// resume (waiting→spinning in the device listing) withdraws through the same engine entry point.
    func testRemoteResumeWithdrawsHeldBlockedLine() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder)

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "orch", status: .spinning)
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "orch", deviceID: "dev-1", agentSessionID: "remote-term", createdAt: "t")
        let row = makeRemoteRow(terminalSessionID: "remote-term", agent: "codex", label: "Remote CLI", note: nil, status: "waiting")
        try engine.remoteChildDidTransition(deviceID: "dev-1", terminalSessionID: "remote-term", row: row, transition: .blocked)
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orch").count, 1)

        try engine.childDidResumeWorking(agentSessionID: "remote-term")

        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orch").isEmpty)
    }

    func testExitNotificationSurvivesAgentRowDeletionAndCascadedEdge() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "codex")

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "sub-session", status: .spinning)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "child-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: child.id, createdAt: "t")

        // Chokepoint order: render/enqueue the exit line, then let handleAgentExit delete the ad-hoc row.
        try engine.childDidTransition(agent: child, transition: .exited)
        _ = try orchestrator.handleAgentExit(child)

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).first(where: { $0.id == child.id }) == nil, "Ad-hoc row is deleted on exit.")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty, "The subscription edge cascades away with the row.")
        let pending = try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub-session")
        XCTAssertEqual(pending.count, 1, "The pending line has no FK, so it outlives the deleted agent row.")
        let expectedExitBlock = """
            [spaces] Codex CLI (codex) is exited
              project: Project
              workspace: \(workspace.dir)
              session: child-session
              link: spaces://terminal/child-session
            """
        XCTAssertEqual(pending.first?.message, expectedExitBlock)

        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "sub-session")
        XCTAssertEqual(recorder.delivered.map(\.line), [expectedExitBlock])
    }

    func testNoAgentRowSubscriberIsTreatedAsIdle() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "plain-shell", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["plain-shell"], "A terminal with no agent row delivers immediately.")
    }

    func testFailedImmediateDeliveryDropsSubscriptionEdge() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        recorder.failingSessionIDs = ["dead-sub"]
        let engine = makeEngine(store: store, recorder: recorder)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "dead-sub", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)

        XCTAssertTrue(recorder.delivered.isEmpty)
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty, "A dead subscriber's watch edge is torn down.")
    }

    func testFailedQueueFlushDropsPendingAndSubscription() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        recorder.failingSessionIDs = ["dead-sub"]
        let engine = makeEngine(store: store, recorder: recorder)

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "dead-sub", status: .spinning)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "dead-sub", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "dead-sub").count, 1)

        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "dead-sub")

        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "dead-sub").isEmpty)
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty)
    }

    func testSelfSubscriptionIsRejected() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "term-A", status: .idle)

        XCTAssertThrowsError(try orchestrator.validateAgentSubscription(subscriberTerminalSessionID: "term-A", agentSessionID: agent.id))
    }

    func testCycleClosingSubscriptionIsRejected() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let agentA = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "term-A", status: .idle)
        let agentB = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "term-B", status: .idle)

        // term-A watches agentB (edge term-A → term-B): allowed.
        try orchestrator.validateAgentSubscription(subscriberTerminalSessionID: "term-A", agentSessionID: agentB.id)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "term-A", agentSessionID: agentB.id, createdAt: "t")

        // term-B subscribing to agentA (edge term-B → term-A) would close the cycle: rejected.
        XCTAssertThrowsError(try orchestrator.validateAgentSubscription(subscriberTerminalSessionID: "term-B", agentSessionID: agentA.id))
    }

    func testMigrationFromV2AddsCoalescingPendingNotifications() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v2.db").path
        try createV2Database(at: dbPath, workspaceID: "workspace-1", agentID: "agent-1", terminalSessionID: "child-session")

        // Opening the store runs the v2→v3 (and onward to current) migrations in place.
        let store = try SQLiteStore(path: dbPath)

        try store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: "sub", agentSessionID: "agent-1", transition: "blocked",
            message: "[spaces] X (spaces) is blocked — spaces://terminal/child-session", createdAt: "t0")
        // A second write for the same (subscriber, agent) coalesces onto one latest-state row.
        try store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: "sub", agentSessionID: "agent-1", transition: "done",
            message: "[spaces] X (spaces) is done — spaces://terminal/child-session", createdAt: "t1")

        let pending = try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.message, "[spaces] X (spaces) is done — spaces://terminal/child-session")
    }

    // MARK: - Cross-device (remote) watch delivery

    func testRemoteChildIdleSubscriberReceivesDeviceQualifiedLineWithNote() throws {
        let store = try makeTemporaryStore()
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder)
        // A plain local terminal (no agent row of its own) counts as idle.
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-orch", deviceID: "dev-1", agentSessionID: "remote-term", createdAt: "t")
        let row = makeRemoteRow(terminalSessionID: "remote-term", agent: "codex", label: "Codex CLI", note: "ship the fix", status: "waiting")

        try engine.remoteChildDidTransition(deviceID: "dev-1", terminalSessionID: "remote-term", row: row, transition: .blocked)

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["local-orch"])
        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] Codex CLI (codex) is blocked
                  project: P
                  workspace: /remote/workspaces/W
                  session: remote-term
                  note: ship the fix
                  link: spaces://terminal/remote-term?device=dev-1
                """
            ])
        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "local-orch").isEmpty)
    }

    func testBusySubscriberQueuesLocalAndRemoteThenFlushesBothInOrder() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder, kind: "claude")

        // The subscriber terminal runs its own agent that is spinning, i.e. busy: everything queues.
        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "orch", status: .spinning)
        let localChild = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Local CLI", terminalTrackingID: "local-child", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orch", agentSessionID: localChild.id, createdAt: "t")
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "orch", deviceID: "dev-1", agentSessionID: "remote-term", createdAt: "t")

        try engine.childDidTransition(agent: localChild, transition: .blocked)
        let remoteRow = makeRemoteRow(terminalSessionID: "remote-term", agent: "codex", label: "Remote CLI", note: nil, status: "done")
        try engine.remoteChildDidTransition(deviceID: "dev-1", terminalSessionID: "remote-term", row: remoteRow, transition: .done)

        // Both queued while busy — nothing delivered yet.
        XCTAssertTrue(recorder.delivered.isEmpty)
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orch").count, 2)

        // Idle flush delivers the local and remote pending lines once, in enqueue order.
        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "orch")
        XCTAssertEqual(
            recorder.delivered.map(\.line),
            [
                """
                [spaces] Local CLI (claude) is blocked
                  project: Project
                  workspace: \(workspace.dir)
                  session: local-child
                  link: spaces://terminal/local-child
                """,
                """
                [spaces] Remote CLI (codex) is done
                  project: P
                  workspace: /remote/workspaces/W
                  session: remote-term
                  link: spaces://terminal/remote-term?device=dev-1
                """,
            ])
        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orch").isEmpty)
    }

    func testRemoteExitDeliveredLineReadsExitedAndFailedDeliveryDropsRemoteEdge() throws {
        let store = try makeTemporaryStore()
        let recorder = DeliveryRecorder()
        recorder.failingSessionIDs = ["dead-orch"]
        let engine = makeEngine(store: store, recorder: recorder)
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "dead-orch", deviceID: "dev-1", agentSessionID: "remote-term", createdAt: "t")
        let row = makeRemoteRow(terminalSessionID: "remote-term", label: "Remote CLI", note: nil, status: "done")

        // The subscriber session is gone: a failed immediate delivery drops the cross-device edge.
        try engine.remoteChildDidTransition(deviceID: "dev-1", terminalSessionID: "remote-term", row: row, transition: .exited)

        XCTAssertTrue(recorder.delivered.isEmpty)
        XCTAssertTrue(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "remote-term").isEmpty)
    }

    // MARK: - Fixtures

    private func makeRemoteRow(terminalSessionID: String?, agent: String? = nil, label: String?, note: String?, status: String)
        -> SpacesDeviceAgentSessionRow
    {
        SpacesDeviceAgentSessionRow(
            id: "row-\(terminalSessionID ?? "none")", terminalSessionID: terminalSessionID, agent: agent ?? label, label: label, status: status,
            note: note, projectID: "p", projectName: "P", workspaceID: "w", workspaceName: "W", workspaceDir: "/remote/workspaces/W", branch: nil,
            updatedAt: "now", lastSignalAt: "now")
    }

    // MARK: - Shared engine fixtures

    /// An engine whose delivery is the recorder and whose clock advances one second per pending write so
    /// queue order is deterministic in tests. Logging is silenced. `kind` stands in for the daemon's
    /// runtime agent-kind resolution (which reads session files unavailable in a unit test); a `nil` kind
    /// exercises the `coding agent` fallback.
    private func makeEngine(store: SQLiteStore, recorder: DeliveryRecorder, kind: String? = nil) -> AgentNotificationEngine {
        let clock = ClockBox()
        return AgentNotificationEngine(
            store: store, deliver: recorder.deliver, resolveAgentKind: { _ in kind }, logError: { _ in }, now: { clock.next() })
    }

    private final class ClockBox: @unchecked Sendable {
        private var seconds = 0
        func next() -> String {
            seconds += 1
            return String(format: "2026-07-14T00:00:%02dZ", seconds)
        }
    }

    private func makeProjectAndWorkspace(store: SQLiteStore) throws -> (ProjectRecord, WorkspaceRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    /// Writes a minimal schema-v2 database (`migration_state` at 2, the note-bearing `agent_sessions`,
    /// the `agent_subscriptions` graph, and `runtime_targets` for the agent join) with one agent row and
    /// no `agent_pending_notifications` table. The migrator upgrades this fixture to v3 on open.
    private func createV2Database(at path: String, workspaceID: String, agentID: String, terminalSessionID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (2);
            CREATE TABLE runtime_targets (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, type TEXT NOT NULL, name TEXT, detail TEXT,
              app TEXT NOT NULL, tracking_id TEXT, order_index INTEGER NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE agent_sessions (
              id TEXT PRIMARY KEY,
              workspace_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              label TEXT,
              status TEXT NOT NULL DEFAULT 'idle',
              runtime_target_id TEXT,
              terminal_session_id TEXT,
              session_key TEXT,
              claimed_launcher_id TEXT,
              claimed_launcher_name TEXT,
              note TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE TABLE agent_subscriptions (
              subscriber_terminal_session_id TEXT NOT NULL,
              agent_session_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (subscriber_terminal_session_id, agent_session_id),
              FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE
            );
            INSERT INTO agent_sessions(id, workspace_id, provider, label, status, terminal_session_id, created_at, updated_at)
            VALUES ('\(agentID)', '\(workspaceID)', 'spaces', 'X', 'spinning', '\(terminalSessionID)', 'now', 'now');
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v2 fixture: \(message)")
            return
        }
    }
}
