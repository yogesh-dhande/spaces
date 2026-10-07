import Foundation
import XCTest
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesdeviceapi

/// What a daemon exit (clean shutdown or crash) leaves for the next start to settle: the terminals and
/// configured processes it ended raise no end-of-session alert, and everything else still alerts.
final class DaemonExitAlertSettleTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteStore!
    private var orchestrator: WorkspaceOrchestrator!
    private var workspace: WorkspaceRecord!
    private var originalEnvironment: [(name: String, value: String?)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
        originalEnvironment = names.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
        orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(id: "process-web", name: "web", command: "npm run dev")])
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-10-01T00:00:00Z")
    }

    override func tearDownWithError() throws {
        for (name, value) in originalEnvironment { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private let deadPID: Int32 = 2_147_000_000

    /// A terminal session in `state`, with the window row that lists it as an ad hoc terminal pane.
    private func seedShell(_ sessionID: String, state: TerminalSessionState, bellAt: String? = nil) throws {
        try seedSession(sessionID, state: state, bellAt: bellAt)
        try store.upsert(
            window: WindowRecord(
                id: "window-\(sessionID)", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: sessionID, detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "2026-10-01T00:00:00Z"))
    }

    /// A configured process "web" whose terminal session is in `state`.
    private func seedProcess(_ sessionID: String, state: TerminalSessionState) throws {
        try seedSession(sessionID, state: state)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-\(sessionID)", workspaceID: workspace.id, templateID: "process-web", templateName: "web", command: "npm run dev",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "2026-10-01T00:00:00Z", exitedAt: nil))
    }

    private func seedSession(_ sessionID: String, state: TerminalSessionState, bellAt: String? = nil) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: sessionID, workingDirectory: workspace.dir,
                shell: "/bin/zsh", command: nil, createdAt: "2026-10-01T00:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: state.isInteractive ? deadPID : 1, childPID: 4321, state: state,
                updatedAt: "2026-10-01T00:05:00Z", exitedAt: state.isInteractive ? nil : "2026-10-01T00:05:00Z", title: sessionID,
                workingDirectory: workspace.dir, bellAt: bellAt), paths: paths)
    }

    private func overview() throws -> SpacesDeviceOverviewPayload {
        try SpacesDeviceOverviewLoader(
            store: store, orchestrator: orchestrator, liveInMemorySessions: [], workspaceIDsWithTeardownInFlight: [], deviceAPIAddresses: []
        ).load()
    }

    /// The alerts a client would show: candidates the stored dismissals have not answered.
    private func alerts() throws -> [SpacesDeviceAlertCandidate] {
        let overview = try overview()
        let dismissed = Set(overview.dismissedAlertKeys)
        return overview.alertCandidates().filter { !dismissed.contains($0.key) }
    }

    private func endAlertSessionIDs() throws -> Set<String> {
        Set(try alerts().filter { [.terminalExited, .terminalFailed, .processExited].contains($0.kind) }.compactMap(\.sessionID))
    }

    /// What the daemon's startup runs: stale recovery, then the settle over what it stranded.
    private func restartDaemon() throws {
        let result = try orchestrator.recoverStaleTerminalSessions(adoptedSessionIDs: [], resumedFromHandoff: false)
        try DaemonExitAlertSettle.settle(store: store, strandedSessionIDs: result.sessionsStrandedByUncleanExit, adoptedSessionIDs: [])
    }

    /// What a clean shutdown leaves behind: the record, then every session ended.
    private func shutDownDaemon(sessionIDs: [String]) throws {
        try orchestrator.recordSessionsEndedByDaemonShutdown(sessionIDs)
        for sessionID in sessionIDs { try seedSession(sessionID, state: .exited) }
    }

    // MARK: - Tests

    func testAnUncleanExitRaisesNoEndAlertAndLeavesProcessesNotStarted() throws {
        try seedShell("adhoc", state: .running)
        try seedProcess("proc", state: .running)
        try restartDaemonWithoutSettle()
        XCTAssertEqual(try endAlertSessionIDs(), ["adhoc"], "the repair alone leaves the ended terminal alerting")

        try DaemonExitAlertSettle.settle(store: store, strandedSessionIDs: ["adhoc", "proc"], adoptedSessionIDs: [])

        XCTAssertEqual(try endAlertSessionIDs(), [])
        XCTAssertTrue(try store.runningProcessesByTerminalSession(terminalSessionID: "proc").isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)
        let web = try XCTUnwrap(overview().workspaces.first?.processRows.first)
        XCTAssertEqual(web.runState, .notStarted)
    }

    func testACleanShutdownRaisesNoEndAlertAfterTheNextStart() throws {
        try seedShell("adhoc", state: .running)
        try seedProcess("proc", state: .running)
        try shutDownDaemon(sessionIDs: ["adhoc", "proc"])

        try restartDaemon()

        XCTAssertEqual(try endAlertSessionIDs(), [])
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)
    }

    func testABellOnASessionTheDaemonEndedStillAlerts() throws {
        try seedShell("adhoc", state: .running, bellAt: "2026-10-01T00:04:00Z")
        try shutDownDaemon(sessionIDs: ["adhoc"])
        try seedSession("adhoc", state: .exited, bellAt: "2026-10-01T00:04:00Z")

        try restartDaemon()

        XCTAssertEqual(try alerts().filter { $0.kind == .bell }.map(\.sessionID), ["adhoc"])
        XCTAssertEqual(try endAlertSessionIDs(), [])
    }

    func testAnAutomationRunCutShortByTheRestartStillAlerts() throws {
        try seedShell("run-terminal", state: .running)
        let automation = Automation(
            id: "automation-1", name: "Nightly", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "true",
            workspaceID: workspace.id, timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce, nextFireTime: nil,
            createdAt: Date(), updatedAt: Date())
        try store.upsertAutomation(automation)
        try store.insertAutomationRun(
            AutomationRun(
                id: "run-1", automationID: automation.id, kind: .script, status: .failed, skipReason: nil, trigger: .manual, exitCode: nil,
                terminalSessionID: "run-terminal", startedAt: Date(), endedAt: Date(), createdAt: Date()))
        try shutDownDaemon(sessionIDs: ["run-terminal"])

        try restartDaemon()

        XCTAssertEqual(try alerts().filter { $0.kind == .automationRunFailed }.map(\.subjectID), ["run-1"])
        XCTAssertEqual(try endAlertSessionIDs(), [])
    }

    func testASessionThatEndedOnItsOwnBeforeTheRestartStillAlerts() throws {
        try seedShell("finished-earlier", state: .exited)
        try seedShell("adhoc", state: .running)
        try shutDownDaemon(sessionIDs: ["adhoc"])

        try restartDaemon()

        XCTAssertEqual(try endAlertSessionIDs(), ["finished-earlier"])
    }

    func testSessionsAnInPlaceHandoffAdoptedAreNotSettled() throws {
        try seedShell("adopted", state: .exited)
        try orchestrator.recordSessionsEndedByDaemonShutdown(["adopted"])

        try DaemonExitAlertSettle.settle(store: store, strandedSessionIDs: [], adoptedSessionIDs: ["adopted"])

        XCTAssertEqual(try endAlertSessionIDs(), ["adopted"])
    }

    func testSettlingNeverRemovesOtherDismissals() throws {
        try store.applyAlertStateChange(
            dismissing: ["agent:gone:done:2026-01-01T00:00:00Z", "process:gone:2026-01-01T00:00:00Z"], dismissedAt: "2026-10-01T00:00:00Z",
            clearingFlags: [], pruning: [])
        try seedShell("adhoc", state: .running)
        try shutDownDaemon(sessionIDs: ["adhoc"])

        try restartDaemon()

        let stored = try store.alertDismissalKeys()
        XCTAssertTrue(stored.contains("agent:gone:done:2026-01-01T00:00:00Z"))
        XCTAssertTrue(stored.contains("process:gone:2026-01-01T00:00:00Z"))
        XCTAssertEqual(try endAlertSessionIDs(), [])
    }

    func testTheSettleClearsTheShutdownRecord() throws {
        try seedShell("adhoc", state: .running)
        try shutDownDaemon(sessionIDs: ["adhoc"])
        XCTAssertEqual(try orchestrator.sessionsRecordedAsEndedByDaemonShutdown(), ["adhoc"])

        try restartDaemon()

        XCTAssertTrue(try orchestrator.sessionsRecordedAsEndedByDaemonShutdown().isEmpty)
    }

    /// Stale recovery without the settle, to show what the repair alone leaves alerting.
    private func restartDaemonWithoutSettle() throws {
        try orchestrator.recoverStaleTerminalSessions(adoptedSessionIDs: [], resumedFromHandoff: false)
    }
}
