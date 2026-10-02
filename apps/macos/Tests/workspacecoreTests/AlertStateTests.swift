import Foundation
import XCTest
import spacesdatabase
import spacesdevicecore
import spacesterminalcore

@testable import workspacecore

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

/// The device-held alert state: what a dismissal, a visit, and a Come Back Later flag do to the stored
/// dismissals and flags, decided against the daemon's own overview.
final class AlertStateTests: XCTestCase {
    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    private let doneKey = "agent:agent-1:done:2026-07-14T09:00:00Z"
    private let waitingKey = "agent:agent-2:waiting:2026-07-14T09:01:00Z"
    private let exitedKey = "process:proc-1:2026-07-14T09:02:00Z"
    private let bellKey = "bell:s1:2026-07-14T09:03:00Z"
    private let flagKey = "comebacklater:agent:agent-2"
    private let otherDoneKey = "agent:agent-3:done:2026-07-14T09:04:00Z"

    /// One workspace holding: a done agent and the exited process on session `s1` (with a bell), a waiting
    /// agent on `s2`, a done agent on a different session `s3`, and a process that never started.
    private func overview(stored store: SQLiteStore) throws -> SpacesDeviceOverviewPayload {
        let base = SpacesDeviceOverviewPayload(
            workspaces: [
                SpacesDeviceWorkspaceSummary(
                    id: "w1", projectID: "p1", projectName: "Project", branch: "main", baseBranch: nil, dir: "/tmp/w1", isRunning: false, isHidden: true,
                    isDefault: false, hasTrackedRuntimeIndicators: false,
                    processRows: [
                        SpacesDeviceWorkspaceProcessRow(
                            id: "proc-1", workspaceID: "w1", name: "web", command: "npm run dev", processID: "proc-1", sessionID: "s1", runState: .exited,
                            exitedAt: "2026-07-14T09:02:00Z", canRun: true, canStop: false, canRestart: false),
                        SpacesDeviceWorkspaceProcessRow(
                            id: "proc-never", workspaceID: "w1", name: "worker", command: "npm run worker", processID: nil, sessionID: nil,
                            runState: .notStarted, canRun: true, canStop: false, canRestart: false),
                    ],
                    codingAgentRows: [
                        agent("agent-1", session: "s1", state: .done, at: "2026-07-14T09:00:00Z"),
                        agent("agent-2", session: "s2", state: .waiting, at: "2026-07-14T09:01:00Z"),
                        agent("agent-3", session: "s3", state: .done, at: "2026-07-14T09:04:00Z"),
                    ],
                    terminalRows: [
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "term-1", workspaceID: "w1", title: "shell", workingDirectory: "/tmp", sessionID: "s4", runState: .running,
                            canOpenTerminal: true)
                    ])
            ],
            sessions: [session("s1", bellAt: "2026-07-14T09:03:00Z"), session("s2"), session("s3"), session("s4")],
            daemonStatus: TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0),
            dismissedAlertKeys: Array(try store.alertDismissalKeys()), comeBackLaterFlags: try store.comeBackLaterFlags())
        return base.reconcilingAlertState()
    }

    private func agent(_ id: String, session: String, state: SpacesDeviceCodingAgentActivityState, at updatedAt: String)
        -> SpacesDeviceWorkspaceCodingAgentRow
    {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: "w1", name: id, command: "claude", agentID: id, sessionID: session, runState: .running, activityState: state,
            updatedAt: updatedAt, brief: nil, briefUpdatedAt: nil, canStop: true)
    }

    private func session(_ id: String, bellAt: String? = nil) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: id, workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 1, childPID: nil, workspaceID: "w1", workspaceTitle: nil, projectID: nil, projectName: nil,
            createdAt: "2026-07-14T08:00:00Z", updatedAt: "2026-07-14T08:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), bellAt: bellAt)
    }

    func testDismissingAlertsRecordsOnlyCurrentCandidateKeys() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        try orchestrator.dismissAlerts(keys: [doneKey, "agent:agent-1:done:2026-01-01T00:00:00Z", "nonsense"], in: try overview(stored: store))

        XCTAssertEqual(try store.alertDismissalKeys(), [doneKey])
        XCTAssertEqual(try overview(stored: store).dismissedAlertKeys, [doneKey])
    }

    func testDismissingAFlagsAlertKeyClearsTheFlag() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        try orchestrator.setComeBackLater(rowKind: .agent, rowID: "agent-2", isOn: true, in: try overview(stored: store))
        XCTAssertEqual(try store.comeBackLaterFlags().map(\.rowID), ["agent-2"])

        try orchestrator.dismissAlerts(keys: ["comebacklater:agent:agent-2"], in: try overview(stored: store))

        XCTAssertTrue(try store.comeBackLaterFlags().isEmpty)
        XCTAssertTrue(try store.alertDismissalKeys().isEmpty, "a flag's key is never stored as a dismissal")
    }

    func testVisitDismissesTheSessionsDoneAndExitedAlertsOnly() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        try orchestrator.visitTerminalSession(
            sessionID: "s1", focusedForSeconds: 2, keys: [doneKey, exitedKey, bellKey], in: try overview(stored: store))

        // s1 shows the done agent and the exited process; its bell stays, and so do other sessions' alerts.
        XCTAssertEqual(try store.alertDismissalKeys(), [doneKey, exitedKey])
        XCTAssertFalse(try store.alertDismissalKeys().contains(bellKey))

        try orchestrator.visitTerminalSession(
            sessionID: "s2", focusedForSeconds: 2, keys: [waitingKey, otherDoneKey], in: try overview(stored: store))
        XCTAssertFalse(try store.alertDismissalKeys().contains(waitingKey), "visiting never dismisses a waiting agent")
        XCTAssertFalse(try store.alertDismissalKeys().contains(otherDoneKey))
    }

    func testVisitDismissesOnlyTheKeysItNames() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        try orchestrator.visitTerminalSession(sessionID: "s1", focusedForSeconds: 2, keys: [doneKey], in: try overview(stored: store))

        XCTAssertEqual(try store.alertDismissalKeys(), [doneKey], "the exited process is also clearable on s1 but was not named")
    }

    func testVisitIgnoresNamedKeysOfOtherSessionsAndKindsThatSurviveAVisit() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        try orchestrator.visitTerminalSession(
            sessionID: "s1", focusedForSeconds: 2, keys: [otherDoneKey, waitingKey, bellKey], in: try overview(stored: store))

        XCTAssertTrue(try store.alertDismissalKeys().isEmpty)
    }

    func testVisitKeepsAFlagItDoesNotName() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let flaggedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try orchestrator.setComeBackLater(rowKind: .agent, rowID: "agent-2", isOn: true, in: try overview(stored: store), now: flaggedAt)

        try orchestrator.visitTerminalSession(
            sessionID: "s2", focusedForSeconds: 2, keys: [], in: try overview(stored: store), now: flaggedAt.addingTimeInterval(60))

        XCTAssertEqual(try store.comeBackLaterFlags().map(\.rowID), ["agent-2"], "set well before the visit, but never named")
    }

    func testVisitKeepsANamedFlagSetAfterTheVisitBegan() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let flaggedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try orchestrator.setComeBackLater(rowKind: .agent, rowID: "agent-2", isOn: true, in: try overview(stored: store), now: flaggedAt)

        // The visit began 5s before the report, i.e. 1s before the flag was set (the mark was removed and set again).
        try orchestrator.visitTerminalSession(
            sessionID: "s2", focusedForSeconds: 5, keys: [flagKey], in: try overview(stored: store), now: flaggedAt.addingTimeInterval(4))

        XCTAssertEqual(try store.comeBackLaterFlags().map(\.rowID), ["agent-2"])
    }

    func testVisitClearsAFlagOnlyWhenTheVisitStartedAfterFlagging() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let flaggedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try orchestrator.setComeBackLater(rowKind: .agent, rowID: "agent-2", isOn: true, in: try overview(stored: store), now: flaggedAt)

        // The user was already focused on the session when they flagged it: the visit began 30s before.
        try orchestrator.visitTerminalSession(
            sessionID: "s2", focusedForSeconds: 30, keys: [flagKey], in: try overview(stored: store), now: flaggedAt.addingTimeInterval(10))
        XCTAssertEqual(try store.comeBackLaterFlags().map(\.rowID), ["agent-2"])

        // Leaving and returning later starts a new visit after the flag was set.
        try orchestrator.visitTerminalSession(
            sessionID: "s2", focusedForSeconds: 2, keys: [flagKey], in: try overview(stored: store), now: flaggedAt.addingTimeInterval(60))
        XCTAssertTrue(try store.comeBackLaterFlags().isEmpty)
    }

    func testVisitLeavesFlagsOnOtherSessionsAlone() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let flaggedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try orchestrator.setComeBackLater(rowKind: .agent, rowID: "agent-2", isOn: true, in: try overview(stored: store), now: flaggedAt)

        try orchestrator.visitTerminalSession(
            sessionID: "s3", focusedForSeconds: 2, keys: [flagKey], in: try overview(stored: store), now: flaggedAt.addingTimeInterval(60))

        XCTAssertEqual(try store.comeBackLaterFlags().map(\.rowID), ["agent-2"])
    }

    func testFlaggingAnAlreadyFlaggedRowRefreshesItsTime() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        try orchestrator.setComeBackLater(rowKind: .agent, rowID: "agent-2", isOn: true, in: try overview(stored: store), now: first)
        try orchestrator.setComeBackLater(
            rowKind: .agent, rowID: "agent-2", isOn: true, in: try overview(stored: store), now: first.addingTimeInterval(120))

        let flags = try store.comeBackLaterFlags()
        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(GhosttyRemoteSessionStateTimestamp.date(from: try XCTUnwrap(flags.first).flaggedAt), first.addingTimeInterval(120))
    }

    func testFlaggingANeverStartedProcessOrAnUnknownRowIsRejected() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let current = try overview(stored: store)

        XCTAssertThrowsError(try orchestrator.setComeBackLater(rowKind: .process, rowID: "proc-never", isOn: true, in: current)) { error in
            XCTAssertTrue("\(error)".contains("has not started"), "\(error)")
        }
        XCTAssertThrowsError(try orchestrator.setComeBackLater(rowKind: .terminal, rowID: "ghost", isOn: true, in: current))
        XCTAssertTrue(try store.comeBackLaterFlags().isEmpty)

        // An exited process has a session to come back to, so it can be flagged.
        try orchestrator.setComeBackLater(rowKind: .process, rowID: "proc-1", isOn: true, in: current)
        XCTAssertEqual(try store.comeBackLaterFlags().map(\.rowID), ["proc-1"])
    }

    func testClearingAFlagRemovesIt() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        try orchestrator.setComeBackLater(rowKind: .terminal, rowID: "term-1", isOn: true, in: try overview(stored: store))
        try orchestrator.setComeBackLater(rowKind: .terminal, rowID: "term-1", isOn: false, in: try overview(stored: store))
        XCTAssertTrue(try store.comeBackLaterFlags().isEmpty)
    }

    func testAStaleDismissalIsPrunedOnTheNextMutationButNeverByBuildingTheOverview() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        try orchestrator.dismissAlerts(keys: [doneKey], in: try overview(stored: store))

        // The agent finishes again later: the old key stops being a candidate.
        var later = try overview(stored: store)
        later = SpacesDeviceOverviewPayload(
            workspaces: later.workspaces.map { workspace in
                SpacesDeviceWorkspaceSummary(
                    id: workspace.id, projectID: workspace.projectID, projectName: workspace.projectName, branch: workspace.branch, baseBranch: nil,
                    dir: workspace.dir, isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false,
                    codingAgentRows: [agent("agent-1", session: "s1", state: .done, at: "2026-07-14T12:00:00Z")])
            }, sessions: later.sessions, daemonStatus: later.daemonStatus,
            dismissedAlertKeys: Array(try store.alertDismissalKeys()), comeBackLaterFlags: [])
        XCTAssertEqual(later.reconcilingAlertState().dismissedAlertKeys, [], "the published view drops it")
        XCTAssertEqual(try store.alertDismissalKeys(), [doneKey], "building the view does not touch the stored row")

        try orchestrator.dismissAlerts(keys: [], in: later.reconcilingAlertState())

        XCTAssertTrue(try store.alertDismissalKeys().isEmpty)
    }

    func testAFlagWhoseRowIsGoneIsPrunedOnTheNextMutationWhileTheFlagBeingSetIsKept() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        try orchestrator.setComeBackLater(rowKind: .terminal, rowID: "term-1", isOn: true, in: try overview(stored: store))

        // The terminal row is closed; the next mutation (flagging another row) sees an overview without it.
        let current = try overview(stored: store)
        let withoutTerminal = SpacesDeviceOverviewPayload(
            workspaces: current.workspaces.map { workspace in
                SpacesDeviceWorkspaceSummary(
                    id: workspace.id, projectID: workspace.projectID, projectName: workspace.projectName, branch: workspace.branch, baseBranch: nil,
                    dir: workspace.dir, isRunning: false, isHidden: true, isDefault: false, hasTrackedRuntimeIndicators: false,
                    processRows: workspace.processRows, codingAgentRows: workspace.codingAgentRows)
            }, sessions: current.sessions, daemonStatus: current.daemonStatus, dismissedAlertKeys: Array(try store.alertDismissalKeys()),
            comeBackLaterFlags: try store.comeBackLaterFlags()
        ).reconcilingAlertState()

        try orchestrator.setComeBackLater(rowKind: .agent, rowID: "agent-2", isOn: true, in: withoutTerminal)

        XCTAssertEqual(try store.comeBackLaterFlags().map(\.rowID), ["agent-2"])
    }

    func testAVisitThatChangesNothingWritesNothing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        // `data_version` moves on this second connection whenever another connection commits.
        let observer = try makeSecondTestStoreConnection()
        let before = try XCTUnwrap(observer.queryRows(sql: "PRAGMA data_version").first)

        try orchestrator.visitTerminalSession(sessionID: "s4", focusedForSeconds: 2, keys: [doneKey], in: try overview(stored: store))
        try orchestrator.dismissAlerts(keys: [], in: try overview(stored: store))
        try orchestrator.setComeBackLater(rowKind: .agent, rowID: "agent-1", isOn: false, in: try overview(stored: store))

        XCTAssertEqual(try observer.queryRows(sql: "PRAGMA data_version").first, before)

        // Dismissing what is already dismissed is also not a write.
        try orchestrator.dismissAlerts(keys: [doneKey], in: try overview(stored: store))
        let afterFirstDismissal = try XCTUnwrap(observer.queryRows(sql: "PRAGMA data_version").first)
        XCTAssertNotEqual(afterFirstDismissal, before)
        try orchestrator.dismissAlerts(keys: [doneKey], in: try overview(stored: store))
        XCTAssertEqual(try observer.queryRows(sql: "PRAGMA data_version").first, afterFirstDismissal)
    }

    func testInvalidFocusDurationIsRejected() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        XCTAssertThrowsError(try orchestrator.visitTerminalSession(sessionID: "s1", focusedForSeconds: -1, keys: [], in: try overview(stored: store)))
        XCTAssertThrowsError(try orchestrator.visitTerminalSession(sessionID: "s1", focusedForSeconds: .nan, keys: [], in: try overview(stored: store)))
    }

    /// A v25 profile gains both alert tables with its existing data untouched, and the new tables work.
    func testMigrationFromV25KeepsExistingDataAndAddsAlertState() throws {
        let dir = try makeTempDirectory()
        let dbPath = dir.appendingPathComponent("v25.db").path
        bindSpacesProfileForTest(databasePath: dbPath)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        let seeded = sqlite3_exec(
            handle,
            """
            CREATE TABLE migration_state (current_version INTEGER NOT NULL);
            INSERT INTO migration_state(current_version) VALUES (25);
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO settings(key, value) VALUES ('app.router_port', '48123');
            CREATE TABLE runtime_targets (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, type TEXT NOT NULL, name TEXT, detail TEXT,
              app TEXT NOT NULL, tracking_id TEXT, order_index INTEGER NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE agent_sessions (
              id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL, label TEXT, user_label TEXT,
              status TEXT NOT NULL DEFAULT 'idle', runtime_target_id TEXT, terminal_session_id TEXT, session_key TEXT,
              brief TEXT, brief_updated_at TEXT, detected_agent_kind TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, launch_command TEXT
            );
            INSERT INTO agent_sessions(id, workspace_id, provider, label, status, terminal_session_id, brief, brief_updated_at, created_at, updated_at)
            VALUES ('agent-1', 'w1', 'spaces', 'Claude', 'done', 's1', 'review auth', '2026-07-14T09:00:00Z', '2026-07-14T08:00:00Z', '2026-07-14T09:00:00Z');
            """, nil, nil, nil)
        XCTAssertEqual(seeded, SQLITE_OK)
        sqlite3_close(handle)

        let store = try SQLiteStore(path: dbPath)

        XCTAssertEqual(try store.setting(key: "app.router_port"), "48123")
        let migrated = try XCTUnwrap(store.agentWindow(id: "agent-1"))
        XCTAssertEqual(migrated.brief, "review auth")
        XCTAssertEqual(migrated.updatedAt, "2026-07-14T09:00:00Z")
        XCTAssertTrue(try store.alertDismissalKeys().isEmpty)
        XCTAssertTrue(try store.comeBackLaterFlags().isEmpty)

        try store.setComeBackLaterFlag(rowKind: .agent, rowID: "agent:agent-1", flaggedAt: "2026-07-14T10:00:00Z")
        try store.applyAlertStateChange(dismissing: ["agent:x:done:y"], dismissedAt: "2026-07-14T10:00:00Z", clearingFlags: [], pruning: [])
        XCTAssertEqual(try store.comeBackLaterFlags().map(\.rowID), ["agent:agent-1"])
        XCTAssertEqual(try store.alertDismissalKeys(), ["agent:x:done:y"])
    }
}
