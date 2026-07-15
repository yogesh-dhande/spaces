import Foundation
import XCTest
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
        let engine = makeEngine(store: store, recorder: recorder)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .waiting)
        // A plain-shell subscriber terminal with no agent row of its own counts as idle.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertEqual(recorder.delivered.map(\.line), ["[spaces] Claude Code CLI (spaces) is blocked — open: spaces://terminal/child-session"])
        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orchestrator-session").isEmpty)
    }

    func testImmediateInjectionRendersNoteWhenSet() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "child-session", status: .done)
        try store.setAgentSessionNote(id: child.id, note: "review the auth flow", updatedAt: "t")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")
        let noted = try XCTUnwrap(store.agentWindow(id: child.id))

        try engine.childDidTransition(agent: noted, transition: .done)

        XCTAssertEqual(
            recorder.delivered.map(\.line),
            ["[spaces] Codex CLI (spaces) is done — note: review the auth flow — open: spaces://terminal/child-session"])
    }

    func testBusySubscriberQueuesThenFlushesOnIdleInOrderExactlyOnce() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder)

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
            ["[spaces] A (spaces) is blocked — open: spaces://terminal/childA", "[spaces] B (spaces) is done — open: spaces://terminal/childB"])
        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub-session").isEmpty)

        // Flushing again delivers nothing: pending is delivered-once.
        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "sub-session")
        XCTAssertEqual(recorder.delivered.count, 2)
    }

    func testBlockedThenDoneWhileBusyCoalescesToSingleDoneLine() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let engine = makeEngine(store: store, recorder: DeliveryRecorder())

        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "sub-session", status: .spinning)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub-session", agentSessionID: child.id, createdAt: "t")

        try engine.childDidTransition(agent: child, transition: .blocked)
        let doneChild = try XCTUnwrap(store.agentWindow(id: child.id))
        try engine.childDidTransition(agent: doneChild, transition: .done)

        let pending = try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub-session")
        XCTAssertEqual(pending.count, 1, "The unique index must coalesce repeated transitions of one child to a single pending line.")
        XCTAssertEqual(pending.first?.message, "[spaces] Claude Code CLI (spaces) is done — open: spaces://terminal/child-session")
    }

    func testExitNotificationSurvivesAgentRowDeletionAndCascadedEdge() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder)

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
        XCTAssertEqual(pending.first?.message, "[spaces] Codex CLI (spaces) is exited — open: spaces://terminal/child-session")

        try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "sub-session")
        XCTAssertEqual(recorder.delivered.map(\.line), ["[spaces] Codex CLI (spaces) is exited — open: spaces://terminal/child-session"])
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

        // Opening the store runs the v2→v3 migration in place.
        let store = try SQLiteStore(path: dbPath)

        try store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: "sub", agentSessionID: "agent-1",
            message: "[spaces] X (spaces) is blocked — open: spaces://terminal/child-session", createdAt: "t0")
        // A second write for the same (subscriber, agent) coalesces onto one latest-state row.
        try store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: "sub", agentSessionID: "agent-1",
            message: "[spaces] X (spaces) is done — open: spaces://terminal/child-session", createdAt: "t1")

        let pending = try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.message, "[spaces] X (spaces) is done — open: spaces://terminal/child-session")
    }

    // MARK: - Fixtures

    /// An engine whose delivery is the recorder and whose clock advances one second per pending write so
    /// queue order is deterministic in tests. Logging is silenced.
    private func makeEngine(store: SQLiteStore, recorder: DeliveryRecorder) -> AgentNotificationEngine {
        let clock = ClockBox()
        return AgentNotificationEngine(store: store, deliver: recorder.deliver, logError: { _ in }, now: { clock.next() })
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
