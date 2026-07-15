import Foundation
import XCTest
import spacesterminalcore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

@testable import workspacecore

/// Behavior coverage for the schema-v2 orchestration surface: explicit notes, subscription edges,
/// hook-signal readiness, and the v1→v2 migration carrying existing agent rows forward.
final class AgentOrchestrationStoreTests: XCTestCase {
    func testAnnotatedNoteSurvivesStatusSignalCycle() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "agent-session", status: .idle)
        try store.setAgentSessionNote(id: agent.id, note: "review the auth flow", updatedAt: "2026-07-14T00:00:00Z")

        // A working then blocked signal re-upserts the agent row with a nil note; the annotation must
        // be preserved through both.
        _ = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .spinning)
        let afterWorking = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(afterWorking.note, "review the auth flow")
        XCTAssertEqual(afterWorking.status, .spinning)

        _ = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .waiting)
        let afterBlocked = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(afterBlocked.note, "review the auth flow")
        XCTAssertEqual(afterBlocked.status, .waiting)
    }

    func testSetAgentSessionNoteWithEmptyStringClearsNote() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        try store.setAgentSessionNote(id: agent.id, note: "temporary", updatedAt: "2026-07-14T00:00:00Z")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.note, "temporary")

        try store.setAgentSessionNote(id: agent.id, note: nil, updatedAt: "2026-07-14T00:01:00Z")
        XCTAssertNil(try store.agentWindows(workspaceID: workspace.id).first?.note)
    }

    func testSubscriptionInsertListAndCascadeOnAgentDelete() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .idle)

        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "2026-07-14T00:00:00Z")
        // Duplicate insert is a no-op (PRIMARY KEY conflict ignored).
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "2026-07-14T00:02:00Z")

        XCTAssertEqual(try store.agentSubscriptions(agentSessionID: child.id).map(\.subscriberTerminalSessionID), ["orchestrator-session"])
        XCTAssertEqual(try store.agentSubscriptions(subscriberTerminalSessionID: "orchestrator-session").map(\.agentSessionID), [child.id])

        try store.deleteAgentWindow(id: child.id)
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty)
        XCTAssertTrue(try store.agentSubscriptions(subscriberTerminalSessionID: "orchestrator-session").isEmpty)
    }

    func testDeleteSubscriptionRemovesOnlyMatchingEdge() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let first = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "first", status: .idle)
        let second = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "second", status: .idle)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub", agentSessionID: first.id, createdAt: "2026-07-14T00:00:00Z")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub", agentSessionID: second.id, createdAt: "2026-07-14T00:00:01Z")

        try store.deleteAgentSubscription(subscriberTerminalSessionID: "sub", agentSessionID: first.id)

        XCTAssertEqual(try store.agentSubscriptions(subscriberTerminalSessionID: "sub").map(\.agentSessionID), [second.id])
    }

    /// Per-tool hooks make an active agent signal `working` on every tool call. Repeat `working`
    /// signals while the row already spins are suppressed — the event log records state transitions,
    /// not tool calls — while a real blocked→working resume records a fresh transition event.
    func testDuplicateConsecutiveWorkingSignalsRecordOneTransitionEvent() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        func signalWorking() throws -> AgentWindowRecord {
            try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .spinning, eventType: "working",
                eventSource: "spaces_agent_signal")
        }

        // The first working is a transition; the next two are per-tool-call repeats and record nothing.
        let entered = try signalWorking()
        _ = try signalWorking()
        let suppressed = try signalWorking()
        XCTAssertEqual(try workingEventCount(store: store, agentID: agent.id), 1)
        XCTAssertEqual(suppressed.status, .spinning)
        XCTAssertEqual(suppressed.updatedAt, entered.updatedAt, "A suppressed repeat must not refresh updated_at: it marks the transition time.")

        // blocked then working again is a real resume: a second working transition is recorded.
        _ = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .waiting, eventType: "blocked",
            eventSource: "spaces_agent_signal")
        _ = try signalWorking()
        XCTAssertEqual(try workingEventCount(store: store, agentID: agent.id), 2)
    }

    private func workingEventCount(store: SQLiteStore, agentID: String) throws -> Int {
        let row = try store.queryRow(
            sql: "SELECT COUNT(*) FROM agent_session_events WHERE agent_session_id = ? AND event_type = 'working' AND source = 'spaces_agent_signal'",
            bindings: [agentID])
        return Int(row?.first ?? "0") ?? 0
    }

    func testLastAgentSignalAtCountsOnlyHookSignalEvents() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        // A foreground-detection event (different source) never counts as a readiness signal.
        try store.appendAgentSessionEvent(
            agentSessionID: agent.id, eventType: "foreground_identity", source: "foreground_agent_signal", message: nil,
            createdAt: "2026-07-14T09:00:00Z")
        XCTAssertNil(try store.lastAgentSignalAt(agentSessionID: agent.id))

        try store.appendAgentSessionEvent(
            agentSessionID: agent.id, eventType: "working", source: "spaces_agent_signal", message: nil, createdAt: "2026-07-14T10:00:00Z")
        try store.appendAgentSessionEvent(
            agentSessionID: agent.id, eventType: "blocked", source: "spaces_agent_signal", message: nil, createdAt: "2026-07-14T11:00:00Z")

        XCTAssertEqual(try store.lastAgentSignalAt(agentSessionID: agent.id), "2026-07-14T11:00:00Z")
    }

    func testMigrationFromV1CarriesAgentRowForwardAndEnablesAnnotate() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v1.db").path
        try createV1Database(at: dbPath, workspaceID: "workspace-1", agentID: "agent-1", terminalSessionID: "agent-session")

        // Opening the store runs the v1→v2 migration in place.
        let store = try SQLiteStore(path: dbPath)

        let migrated = try XCTUnwrap(store.agentWindows(workspaceID: "workspace-1").first)
        XCTAssertEqual(migrated.id, "agent-1")
        XCTAssertEqual(migrated.terminalTrackingID, "agent-session")
        XCTAssertNil(migrated.note)

        try store.setAgentSessionNote(id: "agent-1", note: "carried forward", updatedAt: "2026-07-14T00:00:00Z")
        XCTAssertEqual(try store.agentWindows(workspaceID: "workspace-1").first?.note, "carried forward")

        // The new subscriptions table exists post-migration and cascades on the carried-forward row.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub", agentSessionID: "agent-1", createdAt: "2026-07-14T00:01:00Z")
        XCTAssertEqual(try store.agentSubscriptions(agentSessionID: "agent-1").count, 1)
        try store.deleteAgentWindow(id: "agent-1")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: "agent-1").isEmpty)
    }

    // MARK: - Cross-device watch edges (agent_remote_subscriptions)

    func testRemoteSubscriptionInsertListBySubscriberAndDevice() throws {
        let store = try makeTemporaryStore()

        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "child-1", createdAt: "2026-07-14T00:00:00Z")
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-A", deviceID: "dev-2", agentSessionID: "child-2", createdAt: "2026-07-14T00:00:01Z")
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-B", deviceID: "dev-1", agentSessionID: "child-1", createdAt: "2026-07-14T00:00:02Z")
        // Duplicate insert is a no-op (composite PRIMARY KEY conflict ignored).
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "child-1", createdAt: "2026-07-14T00:00:03Z")

        XCTAssertEqual(
            try store.agentRemoteSubscriptions(subscriberTerminalSessionID: "local-A").map(\.agentSessionID), ["child-1", "child-2"])
        XCTAssertEqual(Set(try store.agentRemoteSubscriptions(deviceID: "dev-1").map(\.subscriberTerminalSessionID)), ["local-A", "local-B"])
        XCTAssertEqual(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "child-1"), ["local-A", "local-B"])
        XCTAssertEqual(try store.agentRemoteSubscriptionDeviceIDs(), ["dev-1", "dev-2"])
    }

    func testRemoteSubscriptionDeleteOneEdgeAndDeleteAllForDeviceAgent() throws {
        let store = try makeTemporaryStore()
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "child-1", createdAt: "t0")
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-B", deviceID: "dev-1", agentSessionID: "child-1", createdAt: "t1")
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "child-2", createdAt: "t2")

        // Deleting one edge leaves the others.
        try store.deleteAgentRemoteSubscription(subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "child-1")
        XCTAssertEqual(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "child-1"), ["local-B"])
        XCTAssertEqual(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "child-2"), ["local-A"])

        // Deleting all edges for a (device, agent) — the exit path — drops every subscriber of that child.
        try store.deleteAgentRemoteSubscriptions(deviceID: "dev-1", agentSessionID: "child-1")
        XCTAssertTrue(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "child-1").isEmpty)
        XCTAssertEqual(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "child-2"), ["local-A"])
        XCTAssertEqual(try store.agentRemoteSubscriptionDeviceIDs(), ["dev-1"])
    }

    func testMigrationFromV3CarriesAgentRowForwardAndEnablesRemoteWatches() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v3.db").path
        try createV3Database(at: dbPath, workspaceID: "workspace-1", agentID: "agent-1", terminalSessionID: "agent-session")

        // Opening the store runs the v3→v4 migration in place.
        let store = try SQLiteStore(path: dbPath)

        // Existing agent, note, and pending-notification data survive the migration.
        let migrated = try XCTUnwrap(store.agentWindows(workspaceID: "workspace-1").first)
        XCTAssertEqual(migrated.id, "agent-1")
        XCTAssertEqual(migrated.note, "carried")
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub").count, 1)

        // The new cross-device watch table exists post-migration and accepts a remote-agent id.
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "remote-child", createdAt: "t")
        XCTAssertEqual(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "remote-child"), ["local-A"])
    }

    // MARK: - Shared orchestration rows (profile command + Device API)

    func testAgentSessionRowsCarryNoteProjectContextAndReadiness() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (project, workspace) = try makeProjectAndWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "agent-session", status: .waiting)
        try store.setAgentSessionNote(id: agent.id, note: "review auth", updatedAt: "2026-07-14T00:00:00Z")

        // No hook signal yet: the row carries its note and context but is not ready.
        let beforeSignal = try XCTUnwrap(orchestrator.agentSessionRows(sessionID: "agent-session").first)
        XCTAssertEqual(beforeSignal.terminalSessionID, "agent-session")
        XCTAssertEqual(beforeSignal.note, "review auth")
        XCTAssertEqual(beforeSignal.status, "waiting")
        XCTAssertEqual(beforeSignal.projectID, project.id)
        XCTAssertEqual(beforeSignal.workspaceID, workspace.id)
        XCTAssertNil(beforeSignal.lastSignalAt)

        try store.appendAgentSessionEvent(
            agentSessionID: agent.id, eventType: "working", source: "spaces_agent_signal", message: nil, createdAt: "2026-07-14T10:00:00Z")
        let afterSignal = try XCTUnwrap(orchestrator.agentSessionRows(sessionID: "agent-session").first)
        XCTAssertEqual(afterSignal.lastSignalAt, "2026-07-14T10:00:00Z")
    }

    func testAnnotateAgentSessionSanitizesControlCharacters() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        let updated = try orchestrator.annotateAgentSession(terminalSessionID: "agent-session", note: "line one\nline two\u{07}")

        // Embedded newlines and control characters are stripped so the note stays a single safe line.
        XCTAssertEqual(updated.note, "line oneline two")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.note, "line oneline two")
    }

    func testAnnotateAgentSessionWithEmptyNoteClearsAndReportsNilNote() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        _ = try orchestrator.annotateAgentSession(terminalSessionID: "agent-session", note: "temporary")
        let cleared = try orchestrator.annotateAgentSession(terminalSessionID: "agent-session", note: "  ")
        XCTAssertNil(cleared.note)
    }

    func testAnnotateAgentSessionThrowsWhenNoAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        _ = try makeProjectAndWorkspace(store: store)
        XCTAssertThrowsError(try orchestrator.annotateAgentSession(terminalSessionID: "missing-session", note: "note"))
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

    /// Writes a minimal schema-v1 database: the `migration_state` marker at version 1 and the
    /// pre-note `agent_sessions` table (plus the `runtime_targets` table the agent read joins), with one
    /// agent row. Only the tables this migration test reads through are created; the migrator upgrades
    /// this fixture to v2 on open.
    private func createV1Database(at path: String, workspaceID: String, agentID: String, terminalSessionID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (1);
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
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            INSERT INTO agent_sessions(id, workspace_id, provider, label, status, terminal_session_id, created_at, updated_at)
            VALUES ('\(agentID)', '\(workspaceID)', 'spaces', 'Claude Code CLI', 'spinning', '\(terminalSessionID)', 'now', 'now');
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v1 fixture: \(message)")
            return
        }
    }

    /// Writes a minimal schema-v3 database (`migration_state` at 3, the note-bearing `agent_sessions`, the
    /// `agent_subscriptions` graph, and `agent_pending_notifications`) with one annotated agent row and one
    /// pending notification. The migrator upgrades this fixture to v4 (adding `agent_remote_subscriptions`)
    /// on open; the test asserts the pre-existing rows survive.
    private func createV3Database(at path: String, workspaceID: String, agentID: String, terminalSessionID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (3);
            CREATE TABLE runtime_targets (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, type TEXT NOT NULL, name TEXT, detail TEXT,
              app TEXT NOT NULL, tracking_id TEXT, order_index INTEGER NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE agent_sessions (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL, label TEXT,
              status TEXT NOT NULL DEFAULT 'idle', runtime_target_id TEXT, terminal_session_id TEXT, session_key TEXT,
              claimed_launcher_id TEXT, claimed_launcher_name TEXT, note TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE agent_subscriptions (
              subscriber_terminal_session_id TEXT NOT NULL, agent_session_id TEXT NOT NULL, created_at TEXT NOT NULL,
              PRIMARY KEY (subscriber_terminal_session_id, agent_session_id),
              FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE
            );
            CREATE TABLE agent_pending_notifications (
              id TEXT PRIMARY KEY, subscriber_terminal_session_id TEXT NOT NULL, agent_session_id TEXT NOT NULL,
              message TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX idx_agent_pending_per_target
              ON agent_pending_notifications(subscriber_terminal_session_id, agent_session_id);
            INSERT INTO agent_sessions(id, workspace_id, provider, label, status, terminal_session_id, note, created_at, updated_at)
            VALUES ('\(agentID)', '\(workspaceID)', 'spaces', 'X', 'spinning', '\(terminalSessionID)', 'carried', 'now', 'now');
            INSERT INTO agent_pending_notifications(id, subscriber_terminal_session_id, agent_session_id, message, created_at)
            VALUES ('pending-1', 'sub', '\(agentID)', '[spaces] X (spaces) is blocked — project: Project — workspace: workspace-1 — session: \(terminalSessionID) — spaces://terminal/\(terminalSessionID)', 't0');
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v3 fixture: \(message)")
            return
        }
    }
}
