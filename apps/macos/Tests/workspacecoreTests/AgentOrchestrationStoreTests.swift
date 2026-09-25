import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// Behavior coverage for the orchestration surface: agent briefs, subscription edges, hook-signal
/// readiness, and the migrations carrying existing agent rows forward.
final class AgentOrchestrationStoreTests: XCTestCase {

    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    func testBriefSurvivesStatusSignalCycle() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "agent-session", status: .idle)
        _ = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: "# Reviewing the auth flow")

        // A working then blocked signal re-upserts the agent row; the brief must be preserved through both.
        _ = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .spinning)
        let afterWorking = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(afterWorking.brief, "# Reviewing the auth flow")
        XCTAssertEqual(afterWorking.status, .spinning)

        _ = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .waiting)
        let afterBlocked = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(afterBlocked.brief, "# Reviewing the auth flow")
        XCTAssertEqual(afterBlocked.status, .waiting)
    }

    /// A hook signal upserts a record built from a snapshot it read earlier, and the agent writes its brief
    /// while it works, so a signal can land holding the brief from before the latest write. The upsert
    /// must never put that older document back.
    func testStatusUpsertFromAnOlderSnapshotKeepsTheNewerBrief() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)
        _ = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: "first draft")
        let staleSnapshot = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)

        _ = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: "second draft")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: staleSnapshot.id, workspaceID: staleSnapshot.workspaceID, provider: staleSnapshot.provider, label: staleSnapshot.label,
                runtimeTargetID: staleSnapshot.runtimeTargetID, terminalTarget: staleSnapshot.terminalTarget, sessionKey: staleSnapshot.sessionKey,
                status: .waiting, brief: staleSnapshot.brief, briefUpdatedAt: staleSnapshot.briefUpdatedAt, createdAt: staleSnapshot.createdAt,
                updatedAt: "2026-07-14T00:00:00Z"))

        let stored = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(stored.status, .waiting)
        XCTAssertEqual(stored.brief, "second draft")
    }

    func testBriefWriteReplacesTheWholeDocumentAndClearRemovesIt() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        _ = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: "## Status\nRunning tests\n\n## Tasks\n- [ ] fix")
        _ = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: "## Status\nDone")
        XCTAssertEqual(try orchestrator.readAgentBrief(terminalSessionID: "agent-session").brief, "## Status\nDone")

        let cleared = try orchestrator.clearAgentBrief(terminalSessionID: "agent-session")
        XCTAssertNil(cleared.briefSummary)
        XCTAssertNil(try orchestrator.readAgentBrief(terminalSessionID: "agent-session").brief)
    }

    /// `updated_at` is read by macOS and iOS Alerts as the lifecycle event date and ordering key, so
    /// writing or clearing a waiting/done agent's brief must not bump it (an old blocked or finished alert
    /// would appear newly occurred). Each write and each clear dates itself on `brief_updated_at` instead.
    func testBriefWritesMoveBriefUpdatedAtButNeverUpdatedAt() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        let lifecycleTimestamp = "2026-07-14T00:00:00Z"
        try store.updateAgentWindowStatus(id: agent.id, status: .waiting, updatedAt: lifecycleTimestamp)
        XCTAssertNil(try orchestrator.readAgentBrief(terminalSessionID: "agent-session").updatedAt, "a brief never written has no timestamp")

        let written = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: "Reviewing the auth flow")
        XCTAssertEqual(written.updatedAt, lifecycleTimestamp)
        XCTAssertNotNil(written.briefUpdatedAt)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.updatedAt, lifecycleTimestamp)

        try store.setAgentSessionBrief(id: agent.id, brief: "Reviewing the auth flow", updatedAt: "2026-07-15T00:00:00Z")
        _ = try orchestrator.clearAgentBrief(terminalSessionID: "agent-session")
        let afterClear = try orchestrator.readAgentBrief(terminalSessionID: "agent-session")
        XCTAssertNil(afterClear.brief)
        XCTAssertNotNil(afterClear.updatedAt)
        XCTAssertNotEqual(afterClear.updatedAt, "2026-07-15T00:00:00Z", "a clear stamps its own time")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.updatedAt, lifecycleTimestamp)
    }

    func testSubscriptionInsertListAndRestrictBlocksBypassDelete() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .idle)

        try store.insertAgentSubscription(
            subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "2026-07-14T00:00:00Z")
        // Duplicate insert is a no-op (PRIMARY KEY conflict ignored).
        try store.insertAgentSubscription(
            subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "2026-07-14T00:02:00Z")

        XCTAssertEqual(try store.agentSubscriptions(agentSessionID: child.id).map(\.subscriberTerminalSessionID), ["orchestrator-session"])
        XCTAssertEqual(try store.agentSubscriptions(subscriberTerminalSessionID: "orchestrator-session").map(\.agentSessionID), [child.id])

        // The FK is ON DELETE RESTRICT: deleting a watched row directly (bypassing the chokepoint) fails
        // loudly instead of silently stranding the watcher's notice.
        XCTAssertThrowsError(try store.deleteAgentWindow(id: child.id))
        XCTAssertEqual(try store.agentSubscriptions(agentSessionID: child.id).count, 1, "The blocked delete leaves the edge intact.")

        // The termination chokepoint drops the inbound edge explicitly, then deletes the row.
        try orchestrator.finalizeAgentRow(child, reason: .destroyed(terminateTerminalSession: false))
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty)
        XCTAssertNil(try store.agentWindow(id: child.id))
    }

    func testDeleteSubscriptionRemovesOnlyMatchingEdge() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let first = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "first", status: .idle)
        let second = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "second", status: .idle)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub", agentSessionID: first.id, createdAt: "2026-07-14T00:00:00Z")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub", agentSessionID: second.id, createdAt: "2026-07-14T00:00:01Z")

        try store.deleteAgentSubscription(subscriberTerminalSessionID: "sub", agentSessionID: first.id)

        XCTAssertEqual(try store.agentSubscriptions(subscriberTerminalSessionID: "sub").map(\.agentSessionID), [second.id])
    }

    /// The MCP piggyback drain returns a subscriber's held notifications in enqueue order and removes them
    /// atomically, so a busy orchestrator receives each held child event exactly once on its next tool
    /// result. A second drain (or a subscriber that never queued anything) returns nothing, and another
    /// subscriber's rows are untouched.
    func testConsumePendingAgentNotificationsReturnsInOrderAndClears() throws {
        let store = try makeTemporaryStore()
        try store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: "orch", agentSessionID: "childA", transition: "blocked", message: "A is blocked",
            createdAt: "2026-07-14T00:00:01Z")
        try store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: "orch", agentSessionID: "childB", transition: "done", message: "B is done", createdAt: "2026-07-14T00:00:02Z"
        )
        try store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: "other", agentSessionID: "childC", transition: "exited", message: "C is exited",
            createdAt: "2026-07-14T00:00:03Z")

        let drained = try store.consumePendingAgentNotifications(subscriberTerminalSessionID: "orch")
        XCTAssertEqual(drained, ["A is blocked", "B is done"])
        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orch").isEmpty)
        // Delivered-once: a second drain returns nothing.
        XCTAssertEqual(try store.consumePendingAgentNotifications(subscriberTerminalSessionID: "orch"), [])
        // An unrelated subscriber's row is not consumed.
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "other").map(\.message), ["C is exited"])
        // A subscriber that never queued anything drains empty.
        XCTAssertEqual(try store.consumePendingAgentNotifications(subscriberTerminalSessionID: "nobody"), [])
    }

    /// Per-tool hooks make an active agent signal `working` on every tool call. Repeat `working`
    /// signals while the row already spins are suppressed — the event log records state transitions,
    /// not tool calls — while a real blocked→working resume records a fresh transition event.
    func testDuplicateConsecutiveWorkingSignalsRecordOneTransitionEvent() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
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
        let orchestrator = makeTestOrchestrator(store: store)
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

    func testMigrationFromV1CarriesAgentRowForwardAndEnablesBrief() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v1.db").path
        try createV1Database(at: dbPath, workspaceID: "workspace-1", agentID: "agent-1", terminalSessionID: "agent-session")

        // Opening the store runs the v1→v2 migration in place.
        let store = try SQLiteStore(path: dbPath)

        let migrated = try XCTUnwrap(store.agentWindows(workspaceID: "workspace-1").first)
        XCTAssertEqual(migrated.id, "agent-1")
        XCTAssertEqual(migrated.terminalTrackingID, "agent-session")
        XCTAssertNil(migrated.brief)

        try store.setAgentSessionBrief(id: "agent-1", brief: "carried forward", updatedAt: "2026-07-14T00:01:00Z")
        XCTAssertEqual(try store.agentWindows(workspaceID: "workspace-1").first?.brief, "carried forward")

        // The new subscriptions table exists post-migration and accepts an edge to the carried-forward row.
        // Its FK migrates forward as ON DELETE RESTRICT, so a bypass delete of the watched row is rejected.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "sub", agentSessionID: "agent-1", createdAt: "2026-07-14T00:01:00Z")
        XCTAssertEqual(try store.agentSubscriptions(agentSessionID: "agent-1").count, 1)
        XCTAssertThrowsError(try store.deleteAgentWindow(id: "agent-1"))
        XCTAssertEqual(try store.agentSubscriptions(agentSessionID: "agent-1").count, 1)
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

        XCTAssertEqual(try store.agentRemoteSubscriptions(subscriberTerminalSessionID: "local-A").map(\.agentSessionID), ["child-1", "child-2"])
        XCTAssertEqual(Set(try store.agentRemoteSubscriptions(deviceID: "dev-1").map(\.subscriberTerminalSessionID)), ["local-A", "local-B"])
        XCTAssertEqual(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "child-1"), ["local-A", "local-B"])
        XCTAssertEqual(try store.agentRemoteSubscriptionDeviceIDs(), ["dev-1", "dev-2"])
    }

    func testRemoteSubscriptionDeleteOneEdgeAndDeleteAllForDeviceAgent() throws {
        let store = try makeTemporaryStore()
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "child-1", createdAt: "t0")
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "local-B", deviceID: "dev-1", agentSessionID: "child-1", createdAt: "t1")
        try store.insertAgentRemoteSubscription(subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "child-2", createdAt: "t2")

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

        // Existing agent, note (carried into the brief), and pending-notification data survive the migration.
        let migrated = try XCTUnwrap(store.agentWindows(workspaceID: "workspace-1").first)
        XCTAssertEqual(migrated.id, "agent-1")
        XCTAssertEqual(migrated.brief, "carried")
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "sub").count, 1)

        // The new cross-device watch table exists post-migration and accepts a remote-agent id.
        try store.insertAgentRemoteSubscription(
            subscriberTerminalSessionID: "local-A", deviceID: "dev-1", agentSessionID: "remote-child", createdAt: "t")
        XCTAssertEqual(try store.agentRemoteSubscribers(deviceID: "dev-1", agentSessionID: "remote-child"), ["local-A"])
    }

    /// A profile written before agent rows could be renamed keeps every row it had (label, note carried into the
    /// brief, and detected kind) with no rename stored, so each row still reads as the label its agent reports.
    /// Renaming then works on the carried-forward row.
    func testMigrationFromV11CarriesAgentRowForwardAndEnablesRename() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v11.db").path
        try createV11Database(at: dbPath, workspaceID: "workspace-1", agentID: "agent-1", terminalSessionID: "agent-session")

        // Opening the store runs the v11→v12 migration in place.
        let store = try SQLiteStore(path: dbPath)

        let migrated = try XCTUnwrap(store.agentWindows(workspaceID: "workspace-1").first)
        XCTAssertEqual(migrated.id, "agent-1")
        XCTAssertEqual(migrated.label, "Claude Code CLI")
        XCTAssertEqual(migrated.brief, "carried")
        XCTAssertEqual(migrated.detectedAgentKind, "claude")
        XCTAssertNil(migrated.userLabel)

        XCTAssertTrue(try store.setAgentSessionUserLabel(id: "agent-1", userLabel: "Reviewer"))
        XCTAssertEqual(try store.agentWindow(id: "agent-1")?.userLabel, "Reviewer")
    }

    /// A profile written while agents carried a one-line note turns each note into that agent's brief,
    /// dated by the row's lifecycle time since the note kept no time of its own, and leaves a row with no
    /// note (or an empty one) without a brief. The lifecycle time itself does not move, and a status signal
    /// afterwards keeps the carried brief.
    func testMigrationFromV24TurnsEachNoteIntoTheAgentsBrief() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v24.db").path
        try createV24Database(at: dbPath, workspaceID: "workspace-1")

        let store = try SQLiteStore(path: dbPath)

        let annotated = try XCTUnwrap(store.agentWindow(id: "agent-noted"))
        XCTAssertEqual(annotated.brief, "review the auth flow")
        XCTAssertEqual(annotated.briefUpdatedAt, "2026-07-14T09:00:00Z")
        XCTAssertEqual(annotated.updatedAt, "2026-07-14T09:00:00Z")
        XCTAssertEqual(annotated.detectedAgentKind, "claude")
        XCTAssertEqual(annotated.launchCommand, "claude --resume")
        for id in ["agent-empty-note", "agent-no-note"] {
            let row = try XCTUnwrap(store.agentWindow(id: id))
            XCTAssertNil(row.brief, "\(id) has no brief")
            XCTAssertNil(row.briefUpdatedAt, "\(id) has no brief timestamp")
        }

        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: annotated.id, workspaceID: annotated.workspaceID, provider: annotated.provider, label: annotated.label,
                sessionKey: annotated.sessionKey, status: .waiting, createdAt: annotated.createdAt, updatedAt: "2026-07-14T10:00:00Z"))
        let afterSignal = try XCTUnwrap(store.agentWindow(id: "agent-noted"))
        XCTAssertEqual(afterSignal.status, .waiting)
        XCTAssertEqual(afterSignal.brief, "review the auth flow")
    }

    // MARK: - Shared orchestration rows (profile command + Device API)

    func testAgentSessionRowsCarryBriefHeadlineProjectContextAndReadiness() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (project, workspace) = try makeProjectAndWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "agent-session", status: .waiting)
        try store.setAgentSessionBrief(id: agent.id, brief: "## Review auth\n\nStep 2 of 3", updatedAt: "2026-07-14T09:00:00Z")

        // No hook signal yet: the row carries its brief's headline and context but is not ready.
        let beforeSignal = try XCTUnwrap(orchestrator.agentSessionRows(sessionID: "agent-session").first)
        XCTAssertEqual(beforeSignal.terminalSessionID, "agent-session")
        XCTAssertEqual(beforeSignal.briefSummary, "Review auth")
        XCTAssertEqual(beforeSignal.briefUpdatedAt, "2026-07-14T09:00:00Z")
        XCTAssertEqual(beforeSignal.status, "waiting")
        XCTAssertEqual(beforeSignal.projectID, project.id)
        XCTAssertEqual(beforeSignal.workspaceID, workspace.id)
        XCTAssertNil(beforeSignal.lastSignalAt)

        try store.appendAgentSessionEvent(
            agentSessionID: agent.id, eventType: "working", source: "spaces_agent_signal", message: nil, createdAt: "2026-07-14T10:00:00Z")
        let afterSignal = try XCTUnwrap(orchestrator.agentSessionRows(sessionID: "agent-session").first)
        XCTAssertEqual(afterSignal.lastSignalAt, "2026-07-14T10:00:00Z")
    }

    /// An agent row's `workspaceName` is derived through the project's kind, like every other workspace
    /// name surface: the home workspace names `~` even though its stored `WorkspaceRecord.displayName`
    /// would read the directory name (or, for an adopted git home, the retained branch).
    func testAgentSessionRowInTheHomeWorkspaceNamesTilde() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first)
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "home-agent-session", status: .idle)

        let row = try XCTUnwrap(orchestrator.agentSessionRows(sessionID: "home-agent-session").first)

        XCTAssertEqual(row.workspaceName, "~")
    }

    /// An agent row's `branch` is masked the same way `workspaceName` is: adopting a git repository at the
    /// home path keeps the branch on the workspace record, but the row must not report it, or `spaces
    /// agent list`/`status` and the device agent APIs would put a `branch=main` reading on the `~` row.
    func testAgentSessionRowInTheHomeWorkspaceMasksAnAdoptedBranch() throws {
        let home = try makeTempGitRepo(name: "dotfiles-with-a-branch")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: home.path)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        XCTAssertNotNil(workspace.branch, "precondition: adoption keeps the workspace record's branch")
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "home-branch-agent-session", status: .idle)

        let row = try XCTUnwrap(orchestrator.agentSessionRows(sessionID: "home-branch-agent-session").first)

        XCTAssertNil(row.branch, "the home row has no git lifecycle of its own")
    }

    /// An orchestration row separates the machine-readable detected kind (`agent:`) from the human-facing
    /// launch title (`label:`). A `.agent`-launch session titled "Reviewer" whose foreground the daemon
    /// detected as claude must report `agent == "claude"` and `label == "Reviewer"` — not both "Reviewer",
    /// which made remote rendering emit "Reviewer (Reviewer)" and dropped the kind from listings.
    func testAgentSessionRowSeparatesDetectedKindFromLaunchTitle() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "agent-session"
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Reviewer", terminalTrackingID: sessionID, status: .spinning)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "Reviewer", workingDirectory: workspace.dir,
                shell: "/bin/zsh", command: "claude", createdAt: "now", workspaceID: workspace.id, kind: .agent), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running, updatedAt: "now",
                title: "Reviewer", workingDirectory: workspace.dir, foregroundDetectedAgentKind: .claude), paths: paths)

        let row = try XCTUnwrap(orchestrator.agentSessionRows(sessionID: sessionID).first)
        XCTAssertEqual(row.agent, "claude", "agent: carries the detected kind, never the launch title")
        XCTAssertEqual(row.label, "Reviewer", "label: keeps the launch title")
    }

    /// Before any foreground kind is detected, `agent:` is nil (honest — `renderRemoteLine` falls back to
    /// "coding agent"), while `label:` still carries the launch title.
    func testAgentSessionRowLeavesAgentNilWhenNoKindDetected() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "agent-session"
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Reviewer", terminalTrackingID: sessionID, status: .spinning)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "Reviewer", workingDirectory: workspace.dir,
                shell: "/bin/zsh", command: "claude", createdAt: "now", workspaceID: workspace.id, kind: .agent), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running, updatedAt: "now",
                title: "Reviewer", workingDirectory: workspace.dir), paths: paths)

        let row = try XCTUnwrap(orchestrator.agentSessionRows(sessionID: sessionID).first)
        XCTAssertNil(row.agent, "agent: is nil until a kind is detected")
        XCTAssertEqual(row.label, "Reviewer")
    }

    func testWriteAgentBriefStoresTheSanitizedDocument() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        let updated = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: "  # Status\r\nline two\u{07}\n")

        // Line structure survives; the bell and the CR are dropped and the document is trimmed.
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.brief, "# Status\nline two")
        XCTAssertEqual(updated.briefSummary, "Status")
    }

    func testWriteAgentBriefWithWhitespaceOnlyMarkdownClearsTheBrief() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)

        _ = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: "temporary")
        let cleared = try orchestrator.writeAgentBrief(terminalSessionID: "agent-session", markdown: " \n\t ")
        XCTAssertNil(cleared.briefSummary)
        XCTAssertNil(try orchestrator.readAgentBrief(terminalSessionID: "agent-session").brief)
    }

    /// `spaces agent brief write` and the MCP write tool print the daemon's message, so a write that
    /// cleared the brief (nothing left after sanitizing) reports the clear, in the words a clear uses.
    func testAgentBriefWriteMessageReportsAClearWhenNothingSurvivesSanitizing() {
        XCTAssertEqual(WorkspaceOrchestrator.agentBriefWriteMessage(markdown: "## Status\nRunning tests"), "Wrote agent brief.")
        for cleared in ["", " \r\n\t ", "\u{07}\u{1B}"] {
            XCTAssertEqual(WorkspaceOrchestrator.agentBriefWriteMessage(markdown: cleared), "Cleared agent brief.", cleared.debugDescription)
        }
        XCTAssertEqual(WorkspaceOrchestrator.agentBriefClearedMessage, "Cleared agent brief.")
    }

    /// A brief needs no hook: an agent foreground detection found, which has never signaled, keeps one too.
    func testWriteAgentBriefWorksForADetectedAgentThatNeverSignaled() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (project, workspace) = try makeProjectAndWorkspace(store: store)
        try orchestrator.insertAdHocDetectedAgent(
            detectedAgent: AdHocDetectedForegroundAgent(kind: "claude", label: "Claude Code", displayCommand: "claude", launchCommand: "claude"),
            workspace: workspace, sessionID: "detected-session")
        XCTAssertEqual(try orchestrator.agentSessionRows(sessionID: "detected-session").first?.projectID, project.id)
        XCTAssertNil(try orchestrator.agentSessionRows(sessionID: "detected-session").first?.lastSignalAt)

        _ = try orchestrator.writeAgentBrief(terminalSessionID: "detected-session", markdown: "Investigating the flaky test")
        XCTAssertEqual(try orchestrator.readAgentBrief(terminalSessionID: "detected-session").brief, "Investigating the flaky test")
    }

    func testBriefCommandsThrowWhenNoAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        _ = try makeProjectAndWorkspace(store: store)
        let expected = "No agent session for terminal missing-session. A brief needs a coding-agent session (detected or hook-signaled)."
        XCTAssertThrowsError(try orchestrator.writeAgentBrief(terminalSessionID: "missing-session", markdown: "brief")) { error in
            XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
        }
        XCTAssertThrowsError(try orchestrator.readAgentBrief(terminalSessionID: "missing-session"))
        XCTAssertThrowsError(try orchestrator.clearAgentBrief(terminalSessionID: "missing-session"))
    }

    // MARK: - Brief sanitization

    func testSanitizedAgentBriefNormalizesLineEndingsAndKeepsTabs() {
        XCTAssertEqual(WorkspaceOrchestrator.sanitizedAgentBrief("## Status\r\n\tindented\r\ndone"), "## Status\n\tindented\ndone")
    }

    func testSanitizedAgentBriefStripsControlCharactersOtherThanNewlineAndTab() {
        XCTAssertEqual(WorkspaceOrchestrator.sanitizedAgentBrief("a\u{1B}[31mred\u{1B}[0m\u{07}\u{00}\nb\rc"), "a[31mred[0m\nbc")
    }

    func testSanitizedAgentBriefKeepsEmojiJoinersAndVariationSelectors() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let heart = "\u{2764}\u{FE0F}"
        XCTAssertEqual(WorkspaceOrchestrator.sanitizedAgentBrief("Team \(family) \u{07}ships\u{1B} \(heart)"), "Team \(family) ships \(heart)")
    }

    func testSanitizedAgentBriefTrimsSurroundingWhitespace() {
        XCTAssertEqual(WorkspaceOrchestrator.sanitizedAgentBrief("\n\n  # Title  \n\n"), "# Title")
    }

    func testSanitizedAgentBriefCapsAt8000Characters() throws {
        let sanitized = try XCTUnwrap(WorkspaceOrchestrator.sanitizedAgentBrief(String(repeating: "é", count: 9000)))
        XCTAssertEqual(sanitized.count, 8000)
        XCTAssertEqual(WorkspaceOrchestrator.agentBriefCharacterLimit, 8000)
    }

    func testSanitizedAgentBriefOfWhitespaceOnlyIsNil() {
        XCTAssertNil(WorkspaceOrchestrator.sanitizedAgentBrief(""))
        XCTAssertNil(WorkspaceOrchestrator.sanitizedAgentBrief(" \r\n\t\n "))
        XCTAssertNil(WorkspaceOrchestrator.sanitizedAgentBrief("\u{07}\u{1B}"))
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

    /// The `terminal_sessions` table as it stood at every schema version before v8 (workspace_id NOT NULL,
    /// no automation_run_id). No pre-v8 migration step touched terminal_sessions, so a real database always
    /// carries this shape by the time it reaches v7; the minimal fixtures include it so the full chain can
    /// run the v7→v8 rebuild that copies terminal_sessions forward.
    private let preV8TerminalSessionsTableSQL = """
        CREATE TABLE terminal_sessions (
          session_id TEXT PRIMARY KEY,
          root_directory TEXT NOT NULL UNIQUE,
          backend TEXT NOT NULL,
          lifetime_policy TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          kind TEXT NOT NULL DEFAULT 'shell',
          title TEXT NOT NULL,
          user_title TEXT,
          working_directory TEXT NOT NULL,
          shell TEXT NOT NULL,
          command TEXT,
          created_at TEXT NOT NULL
        );
        """

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
            \(preV8TerminalSessionsTableSQL)
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
            \(preV8TerminalSessionsTableSQL)
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v3 fixture: \(message)")
            return
        }
    }

    /// Writes a minimal schema-v24 database (`migration_state` at 24, the v24 `agent_sessions` shape with its
    /// `note` column, and the `runtime_targets` table the agent read joins) with three agent rows: one with a
    /// note, one with an empty note, and one with none. The migrator upgrades it to the current version on
    /// open.
    private func createV24Database(at path: String, workspaceID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (24);
            CREATE TABLE runtime_targets (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, type TEXT NOT NULL, name TEXT, detail TEXT,
              app TEXT NOT NULL, tracking_id TEXT, order_index INTEGER NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE agent_sessions (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL, label TEXT, user_label TEXT,
              status TEXT NOT NULL DEFAULT 'idle', runtime_target_id TEXT, terminal_session_id TEXT, session_key TEXT,
              note TEXT, detected_agent_kind TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, launch_command TEXT
            );
            INSERT INTO agent_sessions(
              id, workspace_id, provider, label, status, terminal_session_id, note, detected_agent_kind, created_at, updated_at, launch_command)
            VALUES
              ('agent-noted', '\(workspaceID)', 'spaces', 'Claude Code CLI', 'spinning', 'session-noted', 'review the auth flow', 'claude',
               '2026-07-14T08:00:00Z', '2026-07-14T09:00:00Z', 'claude --resume'),
              ('agent-empty-note', '\(workspaceID)', 'spaces', 'Codex', 'idle', 'session-empty', '', 'codex',
               '2026-07-14T08:00:00Z', '2026-07-14T09:00:00Z', NULL),
              ('agent-no-note', '\(workspaceID)', 'spaces', 'Reviewer', 'idle', 'session-none', NULL, NULL,
               '2026-07-14T08:00:00Z', '2026-07-14T09:00:00Z', NULL);
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v24 fixture: \(message)")
            return
        }
    }

    /// Writes a minimal schema-v11 database (`migration_state` at 11 and the pre-rename `agent_sessions`
    /// shape, plus the `runtime_targets` table the agent read joins) with one annotated, kind-detected
    /// agent row. The migrator upgrades this fixture through v12 (adding `agent_sessions.user_label`) to
    /// the current version on open; the test asserts the pre-existing row survives with no rename stored.
    private func createV11Database(at path: String, workspaceID: String, agentID: String, terminalSessionID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            XCTFail("Failed opening fixture database at \(path)")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (11);
            CREATE TABLE runtime_targets (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, type TEXT NOT NULL, name TEXT, detail TEXT,
              app TEXT NOT NULL, tracking_id TEXT, order_index INTEGER NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE agent_sessions (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL, label TEXT,
              status TEXT NOT NULL DEFAULT 'idle', runtime_target_id TEXT, terminal_session_id TEXT, session_key TEXT,
              claimed_launcher_id TEXT, claimed_launcher_name TEXT, note TEXT, detected_agent_kind TEXT,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            INSERT INTO agent_sessions(
              id, workspace_id, provider, label, status, terminal_session_id, note, detected_agent_kind, created_at, updated_at)
            VALUES ('\(agentID)', '\(workspaceID)', 'spaces', 'Claude Code CLI', 'spinning', '\(terminalSessionID)', 'carried', 'claude', 'now', 'now');
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            if let errorMessage { sqlite3_free(errorMessage) }
            XCTFail("Failed seeding v11 fixture: \(message)")
            return
        }
    }
}
