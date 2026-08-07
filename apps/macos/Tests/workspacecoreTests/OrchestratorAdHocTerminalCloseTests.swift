import XCTest
import spacesterminalcore

@testable import workspacecore

/// The conditional stop that runs when a user closes the pane owning an ad hoc terminal: the terminal
/// ends only when it is idle at a bare prompt with nothing else holding it, and otherwise stays
/// recoverable. Every case here is a decision the daemon makes on its own, so they are exercised through
/// the orchestrator rather than through the client that asks.
extension OrchestratorTests {

    private struct AdHocCloseFixture {
        let orchestrator: WorkspaceOrchestrator
        let store: SQLiteStore
        let workspace: WorkspaceRecord
        let sessionID: String
        let terminateCapture: TerminalTerminateCapture
        let databasePath: String
    }

    /// Seeds a workspace with one built-in terminal session of `kind` plus its tracked terminal window,
    /// and an orchestrator whose fresh-foreground read answers `foreground`.
    private func makeAdHocCloseFixture(sessionID: String, kind: TerminalSessionKind = .shell, foreground: TerminalForegroundProcessSnapshot?) throws
        -> AdHocCloseFixture
    {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) },
            builtInTerminalForegroundProcessSampler: { _ in foreground })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: kind,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        }
        return AdHocCloseFixture(
            orchestrator: orchestrator, store: store, workspace: workspace, sessionID: sessionID, terminateCapture: terminateCapture,
            databasePath: dbPath)
    }

    private func bareShellForeground() -> TerminalForegroundProcessSnapshot {
        TerminalForegroundProcessSnapshot(pid: 123, executablePath: "/bin/zsh", argv: ["/bin/zsh"])
    }

    private func attachOwnerClient(sessionID: String, clientID: String) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.attachClient(
            sessionID: sessionID,
            client: TerminalClient(id: clientID, kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "now"),
            mode: .owner, paths: paths, attachedAt: "now")
    }

    func testConditionalCloseStopsUnattachedBareShellSession() throws {
        let fixture = try makeAdHocCloseFixture(sessionID: "ad-hoc-bare-shell", foreground: bareShellForeground())

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertTrue(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertEqual(fixture.terminateCapture.sessionIDs, [fixture.sessionID])
        XCTAssertTrue(try fixture.store.windows(workspaceID: fixture.workspace.id).isEmpty)
        XCTAssertEqual(try fixture.store.workspace(id: fixture.workspace.id)?.isRunning, false)
    }

    func testConditionalCloseKeepsSessionRunningARealProcess() throws {
        let fixture = try makeAdHocCloseFixture(
            sessionID: "ad-hoc-busy-shell",
            foreground: TerminalForegroundProcessSnapshot(pid: 321, executablePath: "/usr/bin/vim", argv: ["vim", "notes.md"]))

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertFalse(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertTrue(fixture.terminateCapture.sessionIDs.isEmpty)
        XCTAssertFalse(try fixture.store.windows(workspaceID: fixture.workspace.id).isEmpty)
    }

    /// A shell interpreting a script is the user's program, not an idle prompt, even though the
    /// foreground executable is the session's own shell.
    func testConditionalCloseKeepsShellRunningAScript() throws {
        let fixture = try makeAdHocCloseFixture(
            sessionID: "ad-hoc-script-shell",
            foreground: TerminalForegroundProcessSnapshot(pid: 321, executablePath: "/bin/zsh", argv: ["/bin/zsh", "build.sh"]))

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertFalse(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertTrue(fixture.terminateCapture.sessionIDs.isEmpty)
    }

    /// Ownership transferring to another pane on detach (a local mirror, or another device) leaves a live
    /// owner attachment standing, and that owner keeps the session.
    func testConditionalCloseKeepsSessionWithSurvivingOwnerAttachment() throws {
        let fixture = try makeAdHocCloseFixture(sessionID: "ad-hoc-owned-elsewhere", foreground: bareShellForeground())

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            try attachOwnerClient(sessionID: fixture.sessionID, clientID: "surviving-owner")
            XCTAssertFalse(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertTrue(fixture.terminateCapture.sessionIDs.isEmpty)
        XCTAssertFalse(try fixture.store.windows(workspaceID: fixture.workspace.id).isEmpty)
    }

    /// An `agent spawn` session is not ad hoc: closing its pane only ever detaches.
    func testConditionalCloseRefusesSpawnedAgentSession() throws {
        let fixture = try makeAdHocCloseFixture(sessionID: "spawned-agent-session", kind: .agent, foreground: bareShellForeground())

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertFalse(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertTrue(fixture.terminateCapture.sessionIDs.isEmpty)
    }

    func testConditionalCloseRefusesConfiguredProcessSession() throws {
        let fixture = try makeAdHocCloseFixture(sessionID: "configured-process-session", foreground: bareShellForeground())
        try fixture.store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: fixture.workspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: fixture.sessionID, pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertFalse(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertTrue(fixture.terminateCapture.sessionIDs.isEmpty)
    }

    /// No resolvable foreground means no process left to protect, so the close stops the session rather
    /// than leaking a shell nothing can reach.
    func testConditionalCloseStopsSessionWithUnresolvableForeground() throws {
        let fixture = try makeAdHocCloseFixture(sessionID: "ad-hoc-no-foreground", foreground: nil)

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertTrue(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertEqual(fixture.terminateCapture.sessionIDs, [fixture.sessionID])
    }

    /// The user closed the terminal at a bare prompt, so the session and its detection history go
    /// together: an agent row already finalized `.exited` is removed with the session rather than left
    /// behind as a history row, and its inbound watch edges go with it.
    func testConditionalCloseRemovesExitedAgentRowAndItsSubscriptions() throws {
        let fixture = try makeAdHocCloseFixture(sessionID: "ad-hoc-with-exited-agent", foreground: bareShellForeground())
        try fixture.store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: fixture.workspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: fixture.sessionID), sessionKey: "thread-1", status: .exited, createdAt: "now",
                updatedAt: "now"))
        try fixture.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: "agent-1", createdAt: "now")

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertTrue(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertTrue(try fixture.store.agentWindows(workspaceID: fixture.workspace.id).isEmpty)
        XCTAssertTrue(try fixture.store.agentSubscriptions(agentSessionID: "agent-1").isEmpty)
    }

    func testConditionalCloseRemovesLiveAgentRowBoundToTheSession() throws {
        let fixture = try makeAdHocCloseFixture(sessionID: "ad-hoc-with-live-agent", foreground: bareShellForeground())
        try fixture.store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: fixture.workspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: fixture.sessionID), sessionKey: "thread-1", status: .spinning, createdAt: "now",
                updatedAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertTrue(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertTrue(try fixture.store.agentWindows(workspaceID: fixture.workspace.id).isEmpty)
    }

    func testConditionalCloseLeavesAgentRowsUntouchedWhenSessionIsKept() throws {
        let fixture = try makeAdHocCloseFixture(
            sessionID: "ad-hoc-kept-with-agent",
            foreground: TerminalForegroundProcessSnapshot(pid: 321, executablePath: "/opt/homebrew/bin/codex", argv: ["codex"]))
        try fixture.store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: fixture.workspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: fixture.sessionID), sessionKey: "thread-1", status: .spinning, createdAt: "now",
                updatedAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: fixture.databasePath) {
            XCTAssertFalse(
                try fixture.orchestrator.stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
                    workspaceID: fixture.workspace.id, sessionID: fixture.sessionID))
        }

        XCTAssertEqual(try fixture.store.agentWindows(workspaceID: fixture.workspace.id).map(\.id), ["agent-1"])
        XCTAssertTrue(fixture.terminateCapture.sessionIDs.isEmpty)
    }
}
