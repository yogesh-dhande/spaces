import XCTest
import spacesterminalcore

@testable import workspacecore

private final class AgentHookTerminalCloseCapture: @unchecked Sendable { var sessionIDs: [String] = [] }

private final class AgentHookTerminalTerminateCapture: @unchecked Sendable { var sessionIDs: [String] = [] }

final class AgentHookTests: XCTestCase {

    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    func testRegisterAgentWindowCreatesDedicatedWindowRecord() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "workspace-session")

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session", sessionKey: "thread-1",
            status: .idle)

        XCTAssertEqual(record.provider, .spaces)
        XCTAssertEqual(record.label, "Codex CLI")
        XCTAssertEqual(record.terminalTrackingID, "workspace-session")
        XCTAssertEqual(record.status, .idle)
    }

    func testRegisterAgentWindowKeepsSeparateDedicatedWindowsDistinct() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session-1", status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session-2", status: .spinning)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(
            Set(try store.agentWindows(workspaceID: workspace.id).compactMap(\.terminalTrackingID)),
            Set(["workspace-session-1", "workspace-session-2"]))
    }

    func testRegisterAgentWindowAutoRenamesDuplicateAdHocAgentLabels() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "workspace-session-1")
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "workspace-session-2")

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "workspace-session-1", sessionKey: "thread-1",
            status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "workspace-session-2", sessionKey: "thread-2",
            status: .idle)

        XCTAssertEqual(first.label, "Claude Code CLI")
        XCTAssertEqual(second.label, "Claude Code CLI-2")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 2)
    }

    func testRegisterAgentWindowReservesConfiguredLauncherNamesForLauncherOwnedAgent() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex")]
        }
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "workspace-session-1")
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "workspace-session-2")

        let adHoc = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "workspace-session-1", sessionKey: "thread-1",
            status: .idle)
        let configured = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "workspace-session-2", sessionKey: "thread-2",
            status: .idle, claimedLauncherName: "Codex")

        XCTAssertEqual(adHoc.label, "Codex-2")
        XCTAssertEqual(configured.label, "Codex")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 2)
    }

    func testUpdateAgentWindowStatusDoesNotMatchConfiguredLauncherByLabel() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "configured-session")
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "ad-hoc-session")
        let configured = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "configured-session", status: .idle,
            claimedLauncherName: "Codex")

        let adHoc = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "ad-hoc-session", label: "Codex", status: .spinning)

        let configuredAfterUpdate = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first { $0.id == configured.id })
        XCTAssertEqual(configuredAfterUpdate.label, "Codex")
        XCTAssertEqual(configuredAfterUpdate.terminalTrackingID, "configured-session")
        XCTAssertEqual(configuredAfterUpdate.status, .idle)
        XCTAssertNotEqual(adHoc.id, configured.id)
        XCTAssertEqual(adHoc.label, "Codex-2")
        XCTAssertEqual(adHoc.terminalTrackingID, "ad-hoc-session")
        XCTAssertNil(adHoc.claimedLauncherName)
        XCTAssertEqual(adHoc.status, .spinning)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 2)
    }

    func testUpdateAgentWindowStatusMatchesExistingSession() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session", sessionKey: "thread-1",
            status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", sessionKey: "thread-1", label: "Codex CLI",
            status: .done)

        XCTAssertEqual(updated.status, .done)
        XCTAssertEqual(updated.terminalTrackingID, "workspace-session")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testUpdateAgentWindowStatusKeepsExistingLabelStable() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let existing = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "workspace-session", sessionKey: "thread-1",
            status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", sessionKey: "thread-1", label: "Claude Code CLI",
            status: .spinning)

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.label, "Claude Code CLI")
        XCTAssertEqual(updated.status, .spinning)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testUpdateAgentWindowStatusFallsBackToCodexThreadMatch() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", sessionKey: "thread-xyz", status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", sessionKey: "thread-xyz", label: "Codex CLI",
            status: .spinning)

        XCTAssertEqual(updated.id, try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first).id)
        XCTAssertEqual(updated.label, "Codex CLI")
        XCTAssertEqual(updated.status, .spinning)
    }

    func testAgentWindowsReturnsOnlyWorkspaceRecords() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let (_, workspace2) = try makeProjectAndWorkspace(store: store, projectName: "proj2", workspaceName: "ws2")

        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session-1", status: .idle)
        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session-2", status: .spinning)
        try orchestrator.registerAgentWindow(
            workspaceID: workspace2.id, provider: .spaces, terminalTrackingID: "workspace-session-3", status: .waiting)

        let records = try orchestrator.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap(\.terminalTrackingID)), Set(["workspace-session-1", "workspace-session-2"]))
    }

    func testRegisterAgentWindowPreservesSpacesProvider() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code", terminalTrackingID: "spaces-terminal-1", sessionKey: "thread-1",
            status: .waiting)

        XCTAssertEqual(record.provider, .spaces)
        XCTAssertEqual(try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first).provider, .spaces)
    }

    func testRegisterAgentWindowCreatesTrackedTerminalRowForAdHocAgent() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session", sessionKey: "thread-1",
            status: .idle)

        let windows = try store.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.role, "terminal")
        XCTAssertEqual(windows.first?.terminalTrackingID, "workspace-session")
    }

    func testHandleAgentExitDeletesClosedAdHocAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session", sessionKey: "thread-1",
            status: .done)

        let result = try orchestrator.handleAgentExit(agent)

        XCTAssertNil(result)
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testHandleAgentExitMarksLiveAdHocSpacesSessionExitedWithoutPersistingSignalWindowID() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces-test.db").path
        let store = try SQLiteStore(path: dbPath)
        let closeCapture = AgentHookTerminalCloseCapture()
        let terminateCapture = AgentHookTerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowCloser: { closeCapture.sessionIDs.append($0) },
            builtInTerminalSessionTerminator: { terminateCapture.sessionIDs.append($0) })
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = UUID().uuidString
        try withSpacesProfileEnvironment(dbPath: dbPath) {
            try writeLiveBuiltInTerminalSession(sessionID: sessionID, workspaceDirectory: workspace.dir, workspaceID: workspace.id)
        }

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, sessionKey: "thread-1", status: .done)

        let result = try withSpacesProfileEnvironment(dbPath: dbPath) { try orchestrator.handleAgentExit(agent) }

        let record = try XCTUnwrap(result)
        // The agent process is gone but its terminal session is still live: the row survives and records
        // `.exited` (not `.idle`, which would read as "no agent started here yet").
        XCTAssertEqual(record.status, .exited)
        XCTAssertEqual(record.terminalTrackingID, sessionID)
        let storedAgent = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(storedAgent.terminalTrackingID, sessionID)
        let trackedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first)
        XCTAssertEqual(trackedWindow.terminalTrackingID, sessionID)
        XCTAssertTrue(closeCapture.sessionIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    /// An `init` signal preserves a row's status across a reconnect, but a terminal whose previous agent
    /// `.exited` and now inits again is running a fresh agent reusing that terminal, so `registerAgentWindow`
    /// (the shared chokepoint for both the daemon and remote init paths) resets `.exited` to `.idle`.
    func testRegisterAgentWindowResetsExitedRowToIdleOnInit() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "reused-session", sessionKey: "thread-1",
            status: .spinning)
        try store.updateAgentWindowStatus(id: agent.id, status: .exited, updatedAt: "now")

        // The init path re-registers preserving the existing (now `.exited`) status.
        let reinit = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "reused-session", sessionKey: "thread-1",
            status: .exited, eventType: "init")

        XCTAssertEqual(reinit.status, .idle)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.status, .idle)
        // The daemon flushes queued child notifications when this resulting status leaves the subscriber
        // idle: a restart-on-exited lands at idle and correctly flushes.
        XCTAssertTrue(reinit.status.leavesSubscriberIdle)
    }

    /// The daemon's flush-on-signal decision reads the status `registerAgentWindow` returns. An `init`
    /// that preserves a live busy agent's `.spinning` (a reconnecting hook, or Claude Code's SessionStart
    /// on auto-compact) must keep the row busy so queued child events are NOT flushed into a still-working
    /// agent. Paired with the exited→idle reset test, this pins both arms of the resulting-status gate.
    func testRegisterAgentWindowInitPreservesSpinningStatusSoSubscriberStaysBusy() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "live-session", sessionKey: "thread-1",
            status: .spinning)
        // A reconnecting init re-registers preserving the existing (still `.spinning`) status.
        let reinit = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "live-session", sessionKey: "thread-1",
            status: .spinning, eventType: "init")

        XCTAssertEqual(reinit.status, .spinning)
        XCTAssertFalse(reinit.status.leavesSubscriberIdle, "a still-spinning row must not trigger a queued-notification flush")
    }

    /// A blocked agent that reports tool activity again is working, and its workspace stops counting it
    /// as a waiting agent — which is what removes it from Alerts and from dock attention. This is the
    /// contract the agents' post-approval hooks drive: whatever event a given agent emits once its
    /// permission prompt is answered arrives here as one `working` signal.
    func testWorkingSignalClearsABlockedAgentAndItsWaitingAlert() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "agent-session")

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code", terminalTrackingID: "agent-session", status: .idle)
        let blocked = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .waiting, eventType: "blocked")
        XCTAssertEqual(blocked.status, .waiting)
        XCTAssertEqual(try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id).waitingAgentWindowCount, 1)

        let resumed = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .spinning, eventType: "working")

        XCTAssertEqual(resumed.id, blocked.id)
        XCTAssertEqual(resumed.status, .spinning)
        XCTAssertEqual(try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id).waitingAgentWindowCount, 0)
    }

    /// The single authority for the flush decision (shared by the daemon signal path and the notification
    /// engine's live idle check): only idle and done leave a subscriber ready to receive queued lines.
    /// Exited is a bare shell — its queue must wait for a new agent to init and reset it to idle.
    func testAgentWindowStatusLeavesSubscriberIdleIsIdleAndDoneOnly() {
        XCTAssertTrue(AgentWindowStatus.idle.leavesSubscriberIdle)
        XCTAssertTrue(AgentWindowStatus.done.leavesSubscriberIdle)
        XCTAssertFalse(AgentWindowStatus.spinning.leavesSubscriberIdle)
        XCTAssertFalse(AgentWindowStatus.waiting.leavesSubscriberIdle)
        XCTAssertFalse(AgentWindowStatus.exited.leavesSubscriberIdle)
    }

    func testHandleAgentExitKeepsClosedConfiguredSpacesAgentRow() throws {
        let store = try makeTemporaryStore()
        let closeCapture = AgentHookTerminalCloseCapture()
        let terminateCapture = AgentHookTerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowCloser: { closeCapture.sessionIDs.append($0) },
            builtInTerminalSessionTerminator: { terminateCapture.sessionIDs.append($0) })
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.setWorkspaceAgentLaunchers(
            workspaceID: workspace.id, launchers: [AgentLauncher(name: "Configured Agent", command: "configured-agent")])

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Configured Agent", terminalTrackingID: "configured-session", sessionKey: "thread-1",
            status: .idle, claimedLauncherName: "Configured Agent")

        let result = try orchestrator.handleAgentExit(agent)

        let record = try XCTUnwrap(result)
        XCTAssertEqual(record.status, .done)
        XCTAssertEqual(record.terminalTrackingID, "configured-session")
        XCTAssertEqual(record.claimedLauncherName, "Configured Agent")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.terminalTrackingID, "configured-session")
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).first?.terminalTrackingID, "configured-session")
        XCTAssertTrue(closeCapture.sessionIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    func testRecordRemoteAgentSignalUpdatesConfiguredAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Mock Agent", command: "mock-agent")])
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Mock Agent", terminalTrackingID: "remote-session", status: .idle,
            claimedLauncherName: "Mock Agent")

        let blockedApplied = try orchestrator.recordRemoteAgentSignal(
            remoteSignalEvent(
                id: "event-blocked", sessionID: "remote-session", workspaceID: workspace.id, workspacePath: workspace.dir, type: "blocked"))

        XCTAssertTrue(blockedApplied)
        var agent = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(agent.status, .waiting)
        XCTAssertEqual(agent.label, "Mock Agent")
        XCTAssertEqual(agent.terminalTrackingID, "remote-session")
        XCTAssertEqual(agent.claimedLauncherName, "Mock Agent")

        let doneApplied = try orchestrator.recordRemoteAgentSignal(
            remoteSignalEvent(id: "event-done", sessionID: "remote-session", workspaceID: workspace.id, workspacePath: workspace.dir, type: "done"))

        XCTAssertTrue(doneApplied)
        agent = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(agent.status, .done)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testRefreshWorkspaceWindowsDeletesClosedSpacesAdHocAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "spaces-terminal-202", sessionKey: "thread-1",
            status: .idle)

        let didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)

        XCTAssertTrue(didMutate)
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testRefreshWorkspaceWindowsKeepsClosedConfiguredSpacesAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.setWorkspaceAgentLaunchers(
            workspaceID: workspace.id, launchers: [AgentLauncher(name: "Configured Agent", command: "configured-agent")])
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "configured-session")

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Configured Agent", terminalTrackingID: "configured-session", sessionKey: "thread-1",
            status: .idle, claimedLauncherName: "Configured Agent")

        let didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)

        let record = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertTrue(didMutate)
        XCTAssertEqual(record.label, "Configured Agent")
        XCTAssertEqual(record.terminalTrackingID, "configured-session")
        XCTAssertEqual(record.claimedLauncherName, "Configured Agent")
        XCTAssertNil(record.runtimeTargetID)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    private func makeProjectAndWorkspace(store: SQLiteStore, projectName: String = "TestProject", workspaceName: String = "default") throws -> (
        ProjectRecord, WorkspaceRecord
    ) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = ProjectRecord(
            id: dir, name: projectName, dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [], processes: [],
            browserSessions: [])
        try store.upsert(project: project)
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, dir: dir + "/\(workspaceName)", dirname: nil, branch: nil, isDefault: true,
            isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    private func writeLiveBuiltInTerminalSession(sessionID: String, workspaceDirectory: String, workspaceID: String) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "shell", workingDirectory: workspaceDirectory, shell: "/bin/zsh",
                command: nil, createdAt: "2026-06-06T00:00:00Z", workspaceID: workspaceID, kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
                updatedAt: "2026-06-06T00:00:01Z", title: "shell", workingDirectory: workspaceDirectory), paths: paths)
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
    }

    private func remoteSignalEvent(id: String, sessionID: String, workspaceID: String?, workspacePath: String?, type: String)
        -> TerminalServiceAgentSignalEvent
    {
        TerminalServiceAgentSignalEvent(
            id: id, sessionID: sessionID, workspaceID: workspaceID, workspacePath: workspacePath, type: type, provider: AgentProvider.spaces.rawValue,
            label: "Mock Agent", terminalTrackingID: sessionID, environmentKeys: ["SPACES_WORKSPACE_ID", "SPACES_TERMINAL_TRACKING_ID"],
            createdAt: "2026-05-08T00:00:00Z")
    }

    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
        if name == SpacesProfile.databasePathEnvironmentVariable {
            try withSpacesProfileEnvironment(dbPath: value, run: run)
            return
        }
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let original { setenv(name, original, 1) } else { unsetenv(name) } }
        try run()
    }
}
