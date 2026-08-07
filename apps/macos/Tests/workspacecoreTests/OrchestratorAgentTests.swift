import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {

    func testStopCodingAgentRemovesRuntimeAndTerminatesItsSession() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: "window-codex", workspaceID: workspace.id, app: "Spaces", name: "Codex", terminalTrackingID: "session-codex", role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", runtimeTargetID: "window-codex",
                terminalTarget: TerminalTargetRecord(runtimeTargetID: "window-codex", trackingID: "session-codex"), sessionKey: nil,
                status: .idle, createdAt: "now", updatedAt: "now"))
        let closed = TerminalCloseCapture()
        let terminated = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowCloser: { closed.sessionIDs.append($0) },
            builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) })

        try orchestrator.stopCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(closed.sessionIDs, ["session-codex"])
        XCTAssertEqual(terminated.sessionIDs, ["session-codex"])
    }

    /// The exit reconcilers run on their own store connection without the workspace lifecycle lock, so a
    /// pass that snapshotted an agent's row can reach its finalization write after a stop already deleted
    /// that row — the stop's own terminate is what wakes those reconcilers. Finalizing the stale snapshot
    /// must not bring the row back: a resurrected row reports "exited" on a dead session forever instead of
    /// disappearing.
    func testStopCodingAgentIsNotUndoneByStaleExitReconcile() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        let originalRecord = AgentWindowRecord(
            id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex",
            terminalTarget: TerminalTargetRecord(trackingID: "old-session"), status: .idle, createdAt: "now", updatedAt: "now")
        try store.upsertAgentWindow(originalRecord)
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        try orchestrator.stopCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")
        try orchestrator.finalizeAgentRow(
            originalRecord, reason: .exited(eventType: "exit", eventSource: "foreground_reconciler", environmentKeys: nil))

        XCTAssertTrue(
            try store.agentWindows(workspaceID: workspace.id).isEmpty, "A stopped agent must stay stopped instead of reappearing as an exited row.")
    }

    /// Stopping a watched coding agent (macOS sidebar / Device API stop) routes through the shared stop
    /// chokepoint, which must tell the child's subscribers it exited before deleting the row, and tear
    /// down the stopped terminal's OWN watch state (its outgoing edge and queued inbound line).
    func testStopCodingAgentDeliversExitedNoticeAndTearsDownStoppedTerminalWatchState() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }

        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)
        // A plain-shell subscriber terminal (no agent row of its own) is idle and receives immediately.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")
        // The stopped agent's OWN terminal was ALSO watching another agent and holds a queued inbound line.
        let otherChild = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Other", terminalTrackingID: "other-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "child-session", agentSessionID: otherChild.id, createdAt: "t")
        try store.upsertPendingAgentNotification(
            subscriberTerminalSessionID: "child-session", agentSessionID: otherChild.id, transition: "blocked", message: "held", createdAt: "t")

        try orchestrator.stopCodingAgent(workspaceID: workspace.id, agentID: child.id)

        XCTAssertNil(try store.agentWindow(id: child.id), "stop deletes the agent row")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertTrue(
            try store.agentSubscriptions(subscriberTerminalSessionID: "child-session").isEmpty,
            "the stopped terminal's own outgoing watch edge is torn down")
        XCTAssertTrue(
            try store.pendingAgentNotifications(subscriberTerminalSessionID: "child-session").isEmpty,
            "the stopped terminal's own inbound queue is dropped")
    }

    /// Stopping a whole workspace ends every coding agent in it. A subscriber watching one of those agents
    /// (which may live in another workspace) must be told the child exited BEFORE the bulk row delete
    /// cascades the subscription edges away — the delivery only happens if notify precedes delete.
    func testStopWorkspaceDeliversExitedNoticeBeforeAgentRowsVanish() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)
        // A plain-shell watcher terminal (idle, receives immediately); it need not share the workspace.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) { try orchestrator.stopWorkspace(workspaceID: workspace.id) }

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "workspace stop deletes the agent rows")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the child exited before the rows vanished, got: \(recorder.delivered.first?.line ?? "nothing")")
    }

    func testRefreshWorkspaceWindowsKeepsBuiltInAgentTerminalWindowAfterOwnerCloses() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        _ = project

        let sessionID = "spaces-agent-session"
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID, sessionKey: nil,
                status: .spinning, createdAt: "now", updatedAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath.path) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, title: "Codex", workingDirectory: projectDir.path, shell: "/bin/zsh", command: "codex",
                    createdAt: timestamp, workspaceID: workspace.id, kind: .agent), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 4321,
                    state: .running, updatedAt: timestamp), paths: paths)
            let ownerClient = TerminalClient(
                id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
                connectedAt: timestamp)
            try TerminalSessionPersistence.attachClient(sessionID: sessionID, client: ownerClient, mode: .owner, paths: paths, attachedAt: timestamp)
            try TerminalSessionPersistence.detachClient(id: ownerClient.id, paths: paths, detachedAt: timestamp)

            _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.map(\.terminalTrackingID), [sessionID])
        let agents = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agents.map(\.id), ["agent-codex"])
        XCTAssertEqual(agents.first?.terminalTrackingID, sessionID)
    }

    func testUserClosedBuiltInTerminalSessionLeavesOwningAgentRunning() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowCloser: { sessionID in closeCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "agent-session-close-1"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID, sessionKey: nil,
                status: .spinning, createdAt: "now", updatedAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: "agent-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "Codex", detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .agent,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "Codex", workingDirectory: workspace.dir))

            XCTAssertFalse(try orchestrator.stopBuiltInTerminalSessionClosedByUser(sessionID: sessionID))
        }

        XCTAssertTrue(closeCapture.sessionIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), ["agent-1"])
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).map(\.terminalTrackingID), [sessionID])
    }

    func testUserClosedAdHocShellSessionStopsEvenWhenAgentRegistered() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-shell-with-agent-signal"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir))
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex",
                    terminalTarget: TerminalTargetRecord(trackingID: sessionID), sessionKey: "thread-1", status: .spinning, createdAt: "now",
                    updatedAt: "now"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.stopBuiltInTerminalSessionClosedByUser(sessionID: sessionID))
        }

        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    func testStopAdHocBuiltInTerminalSessionRejectsProcessAndAgentOwnedSessionsGlobally() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let parentDir = root.appendingPathComponent("project", isDirectory: true)
        let childDir = parentDir.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbPath)
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let project = makeProjectRecord(dir: parentDir.path)
        let parentWorkspace = makeWorkspaceRecord(projectID: project.id, dir: parentDir.path)
        let childWorkspace = makeWorkspaceRecord(projectID: project.id, dir: childDir.path)
        try store.upsert(project: project)
        try store.upsert(workspace: parentWorkspace)
        try store.upsert(workspace: childWorkspace)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1", workspaceID: childWorkspace.id, templateName: "api", command: "npm run api",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "process-session", pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: childWorkspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "agent-session",
                sessionKey: nil, status: .spinning, createdAt: "now", updatedAt: "now"))

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: "agent-session", workspace: childWorkspace, kind: .agent,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "agent-session", backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "Codex", workingDirectory: childWorkspace.dir))

            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: parentWorkspace.id, sessionID: "process-session"))
            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: childWorkspace.id, sessionID: "process-session"))
            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: parentWorkspace.id, sessionID: "agent-session"))
            XCTAssertFalse(try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: childWorkspace.id, sessionID: "agent-session"))
        }
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    func testReconcileTerminalForegroundAgentClassificationsPromotesAndKeepsAdHocShellSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-foreground-agent"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promotedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(promotedAgent.label, "Codex")
            let promotedWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first)
            XCTAssertEqual(promotedWindow.name, "shell-1")
            XCTAssertEqual(promotedWindow.detail, "codex --model gpt-5")

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir),
                paths: try TerminalSessionPaths.forSession(id: sessionID))

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(stickyAgent.id, promotedAgent.id)
            XCTAssertEqual(stickyAgent.label, "Codex")
            let stickyWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first)
            XCTAssertEqual(stickyWindow.name, "shell-1")
            XCTAssertEqual(stickyWindow.detail, "codex --model gpt-5")
        }
    }

    /// A promoted ad-hoc agent whose detected process ends while its shell terminal stays live (foreground
    /// reverts to a plain shell, not exited) must be demoted back to a plain terminal — not left as a
    /// phantom coding-agent row — and the still-live terminal window must survive the demotion untouched.
    func testReconcileTerminalForegroundAgentClassificationsDemotesAdHocAgentWhenForegroundRevertsToShell() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-foreground-agent-demote"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            // A live session keeps its control socket for its whole lifetime, so the demote path reads the
            // terminal as still open and preserves its window (rather than the dead-session delete).
            XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promotedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(promotedAgent.id, "terminal-agent-\(sessionID)")
            // This row is pure detection state — no hook lifecycle signal ever landed on it — which is
            // exactly what makes a silent demote (delete) safe. A signaled row would take the `.exited`
            // exit path instead (see `...RecordsExitedForSignaledAdHocAgentOnShellRevert`).
            XCTAssertNil(try store.lastAgentSignalAt(agentSessionID: promotedAgent.id))

            // The detected process ends but the shell terminal itself stays live — the foreground sample
            // reverts to a plain shell rather than the session exiting.
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]), paths: paths)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "Demotion removes the ad-hoc agent row.")
            let survivingWindow = try XCTUnwrap(store.windows(workspaceID: workspace.id).first)
            XCTAssertEqual(survivingWindow.terminalTrackingID, sessionID, "Demotion must not delete the still-live terminal window.")
            XCTAssertNil(survivingWindow.detail, "Demotion clears the agent-command detail written onto the shared terminal window.")
        }
    }

    /// A shell that is interpreting a script is running the user's program, not sitting at a prompt, so a
    /// detected coding-agent row must NOT be demoted while its foreground reports `zsh build.sh` even
    /// though the foreground executable is the session's own shell.
    func testReconcileTerminalForegroundAgentClassificationsKeepsAdHocAgentWhileShellRunsAScript() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-foreground-agent-script"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promotedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh", "build.sh"]), paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), [promotedAgent.id])
        }
    }

    /// A detection-created ad-hoc row that has SINCE recorded a hook lifecycle signal is no longer pure
    /// detection state: it has subscribers owed an `exited` notice. When its foreground reverts to a plain
    /// shell, the reconciler must run the full hookless-exit flow — deliver the exited notice, record the
    /// row `.exited` (not silently delete it), and tear down the reverted terminal's own outgoing watch
    /// edges and pending queue — instead of the silent demote a never-signaled row gets.
    func testReconcileTerminalForegroundAgentClassificationsRecordsExitedForSignaledAdHocAgentOnShellRevert() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-signaled-agent-shell-revert"
        let subscriberSessionID = "orchestrator-subscriber"

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            // A live terminal (control socket present) so `handleAgentExit` reads the session as still open
            // and records `.exited` rather than deleting the row as a fully-gone session.
            XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promoted = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(promoted.id, "terminal-agent-\(sessionID)")

            // A real hook signal lands on the detection row through the daemon signal path, updating it in
            // place (its detection id is preserved). The row is now signal-established.
            _ = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, status: .spinning, eventType: "working",
                eventSource: "spaces_agent_signal")
            XCTAssertNotNil(try store.lastAgentSignalAt(agentSessionID: promoted.id))

            // A plain-shell subscriber (no agent row of its own) is idle and receives immediately.
            try store.insertAgentSubscription(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: promoted.id, createdAt: "t")
            // The exiting terminal itself was ALSO watching another agent and holds a queued line; both its
            // outgoing edge and its inbound queue must be torn down when it sheds its agent identity.
            let otherAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Watcher", terminalTrackingID: "other-agent-session", status: .idle)
            try store.insertAgentSubscription(subscriberTerminalSessionID: sessionID, agentSessionID: otherAgent.id, createdAt: "t")
            try store.upsertPendingAgentNotification(
                subscriberTerminalSessionID: sessionID, agentSessionID: otherAgent.id, transition: "blocked", message: "held", createdAt: "t")

            // The detected process ends but the shell terminal stays live — the foreground reverts to zsh.
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]), paths: paths)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            XCTAssertEqual(
                try store.agentWindow(id: promoted.id)?.status, .exited, "A signaled detection row is recorded `.exited`, not silently deleted.")
            XCTAssertEqual(recorder.delivered.map(\.sessionID), [subscriberSessionID])
            XCTAssertTrue(
                recorder.delivered.first?.line.contains("is exited") == true,
                "The subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
            XCTAssertTrue(
                try store.agentSubscriptions(subscriberTerminalSessionID: sessionID).isEmpty,
                "The exited terminal's own outgoing watch edges are torn down.")
            XCTAssertTrue(
                try store.pendingAgentNotifications(subscriberTerminalSessionID: sessionID).isEmpty,
                "The exited terminal's own inbound queue is dropped, not flushed into its shell.")

            // A second reconcile pass sees the row already `.exited` and must NOT re-enter the shell-revert
            // branch: no mutation, no duplicate exited notice to the subscriber, and no duplicate exit event.
            XCTAssertFalse(
                try orchestrator.reconcileTerminalForegroundAgentClassifications(), "A settled `.exited` shell-revert row is not re-finalized.")
            XCTAssertEqual(recorder.delivered.count, 1, "The exited notice is delivered exactly once across repeated reconcile passes.")
            let exitEventCount = try store.queryRows(
                sql: "SELECT COUNT(*) FROM agent_session_events WHERE agent_session_id = ? AND event_type = 'exit'", bindings: [promoted.id]
            ).first?.first
            XCTAssertEqual(exitEventCount, "1", "Exactly one exit event is recorded for the shell-revert exit.")
        }
    }

    /// The termination chokepoint's `.destroyed` reason — shared by stop, kill, workspace stop, terminal
    /// teardown, and orphan prune — must notify a watched child's subscribers it
    /// exited and drop its inbound watch edge; and a delete that bypasses the chokepoint must fail loudly
    /// under the RESTRICT foreign key. This is what makes the notify-before-delete flow enforceable rather
    /// than conventional.
    func testFinalizeDestroyedRowNotifiesWatcherCleansEdgesAndBlocksBypassDelete() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "child-session", status: .spinning)
        // A plain-shell watcher (no agent row of its own) is idle and receives immediately.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher", agentSessionID: child.id, createdAt: "t")

        // A watched row deleted OUTSIDE the chokepoint is rejected by the RESTRICT foreign key.
        XCTAssertThrowsError(try store.deleteAgentWindow(id: child.id), "A watched row deleted outside the chokepoint must fail loudly.")

        try orchestrator.finalizeAgentRow(child, reason: .destroyed(terminateTerminalSession: false))

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher"])
        XCTAssertTrue(recorder.delivered.first?.line.contains("is exited") == true, "The watcher is told the child exited.")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty, "The inbound watch edge is dropped by the chokepoint.")
        XCTAssertNil(try store.agentWindow(id: child.id), "The row is deleted through the chokepoint.")
    }

    /// The Device API signal-recording path (`recordRemoteAgentSignal`) must route its `exit` through the
    /// same chokepoint, so a child's subscribers are told it exited and its edges are torn down — the gap
    /// this path previously had when it called the bare exit decision without the notify/teardown wrap.
    func testRecordRemoteAgentSignalExitNotifiesWatcherAndTearsDownEdges() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Mock Agent", terminalTrackingID: "remote-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher", agentSessionID: child.id, createdAt: "t")

        let applied = try orchestrator.recordRemoteAgentSignal(
            TerminalServiceAgentSignalEvent(
                id: "event-exit", sessionID: "remote-session", workspaceID: workspace.id, workspacePath: workspace.dir, type: "exit",
                provider: AgentProvider.spaces.rawValue, label: "Mock Agent", terminalTrackingID: "remote-session", environmentKeys: [],
                createdAt: "now"))

        XCTAssertTrue(applied)
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher"])
        XCTAssertTrue(recorder.delivered.first?.line.contains("is exited") == true, "The watcher is told the remote child exited.")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty, "The child's inbound edge is torn down on exit.")
        XCTAssertNil(try store.agentWindow(id: child.id), "The dead-session row is deleted.")
    }

    /// An explicit hook `.exit` (or any direct `handleAgentExit`) on a signaled detection-created row whose
    /// terminal is still live must record the row `.exited` — the demote branch deliberately does not claim
    /// it, so the exited display state and the restart-reuse flush cue are preserved.
    func testHandleAgentExitRecordsExitedForSignaledAdHocDetectedAgentOnLiveTerminal() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-signaled-agent-explicit-exit"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "codex", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "codex", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promoted = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(promoted.id, "terminal-agent-\(sessionID)")

            _ = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, status: .spinning, eventType: "working",
                eventSource: "spaces_agent_signal")
            let signaled = try XCTUnwrap(store.agentWindow(id: promoted.id))
            XCTAssertNotNil(try store.lastAgentSignalAt(agentSessionID: promoted.id))

            let result = try orchestrator.handleAgentExit(signaled)

            XCTAssertEqual(result?.status, .exited)
            XCTAssertEqual(
                try store.agentWindow(id: promoted.id)?.status, .exited,
                "A signaled detection row on a live terminal records `.exited`, not a silent delete.")
        }
    }

    /// A foreground-detected ad-hoc agent whose `.shell` terminal then EXITS is finalized by the unified
    /// session-backed sweep: the row is deleted (not left as a phantom `.done` that would raise a spurious
    /// "finished" alert), matching the spawned-agent sweep. A dead-terminal row disappears from listings,
    /// which a remote overview diffs as `exited`.
    func testReconcileTerminalForegroundAgentClassificationsDeletesExitedAdHocAgentSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-agent-session-exit"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "codex", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "codex", foregroundDisplayCommand: "codex"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "codex", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(agent.id, "terminal-agent-\(sessionID)")
            XCTAssertEqual(agent.status, .idle)

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                    updatedAt: "2026-06-06T00:00:10Z", exitedAt: "2026-06-06T00:00:10Z", title: "codex", workingDirectory: workspace.dir),
                paths: paths)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertTrue(
                try store.agentWindows(workspaceID: workspace.id).isEmpty,
                "the exited ad-hoc agent row is deleted by handleAgentExit, not marked .done")

            // Idempotent: with the row gone, a later sweep finds nothing and reports no mutation.
            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesSignalAgentAcrossTransientAndRealForegrounds() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "signal-custom-agent-unknown-foreground"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/usr/bin/python3", foregroundExecutableName: "python3", foregroundArgv: ["python3", "agent.py"]))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, status: .spinning,
                eventSource: "spaces_signal")

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            let agents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(agents.map(\.id), [signalAgent.id])
            XCTAssertEqual(agents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(agents.first?.status, .spinning)
            XCTAssertNil(
                try store.latestAgentSessionEventMessage(id: signalAgent.id, eventType: "foreground_identity", source: "foreground_agent_signal"))

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"), paths: try TerminalSessionPaths.forSession(id: sessionID))

            // The sample now classifies the foreground, which the row learns — but that is a kind, not a
            // re-classification: the signaled row keeps its own id, label, status, and bare terminal detail.
            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(stickyAgents.map(\.id), [signalAgent.id])
            XCTAssertEqual(stickyAgents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(stickyAgents.first?.status, .spinning)
            XCTAssertEqual(stickyAgents.first?.detectedAgentKind, "codex", "a classification arriving after registration is persisted")
            XCTAssertEqual(stickyAgents.first?.updatedAt, signalAgent.updatedAt, "learning the kind is not a lifecycle transition")
            XCTAssertNil(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail)
            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications(), "and is not rewritten on every later pass")
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesSignalAgentAcrossShellForeground() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "signal-agent-pending-foreground"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, status: .spinning,
                eventSource: "spaces_signal")

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), [signalAgent.id])

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]), paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(stickyAgents.map(\.id), [signalAgent.id])
            XCTAssertEqual(stickyAgents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(stickyAgents.first?.status, .spinning)
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsDoesNotRecordSignalIdentityFromFirstNonShellSample() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "signal-agent-first-sample"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, status: .spinning,
                eventSource: "spaces_signal")

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/usr/bin/python3", foregroundExecutableName: "python3", foregroundArgv: ["python3", "agent.py"]),
                paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), [signalAgent.id])
            XCTAssertNil(
                try store.latestAgentSessionEventMessage(id: signalAgent.id, eventType: "foreground_identity", source: "foreground_agent_signal"))

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:20Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]), paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), [signalAgent.id])
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesSignalLabelOnKnownForeground() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "signal-custom-agent-known-foreground"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, status: .waiting,
                eventSource: "spaces_signal")

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            let agents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(agents.map(\.id), [signalAgent.id])
            XCTAssertEqual(agents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(agents.first?.status, .waiting)
            XCTAssertNil(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail)
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsKeepsSignaledDetectorRowAfterForegroundChanges() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "detector-row-signal-update"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let detectedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(detectedAgent.id, "terminal-agent-\(sessionID)")
            XCTAssertEqual(detectedAgent.label, "Codex")

            let signaledAgent = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, label: "Custom Hook Agent", status: .spinning,
                eventType: "start", eventSource: "spaces_signal")
            XCTAssertEqual(signaledAgent.id, detectedAgent.id)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let knownForegroundAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(knownForegroundAgent.id, detectedAgent.id)
            XCTAssertEqual(knownForegroundAgent.label, "Custom Hook Agent")
            XCTAssertEqual(knownForegroundAgent.status, .spinning)

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/usr/bin/python3", foregroundExecutableName: "python3", foregroundArgv: ["python3", "agent.py"]),
                paths: paths)

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(stickyAgent.id, detectedAgent.id)
            XCTAssertEqual(stickyAgent.label, "Custom Hook Agent")
            XCTAssertEqual(stickyAgent.status, .spinning)
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")
        }
    }

    func testUpdateAgentWindowStatusPreservesAdHocDetectedTerminalNameAndDetail() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-foreground-agent-signal"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).name, "shell-1")
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")

            _ = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, sessionKey: "thread-1", label: "Codex", status: .spinning
            )

            let window = try XCTUnwrap(store.windows(workspaceID: workspace.id).first)
            XCTAssertEqual(window.name, "shell-1")
            XCTAssertEqual(window.detail, "codex --model gpt-5")
        }
    }

    func testRefreshWorkspaceWindowsPreservesAdHocDetectedAgentForegroundCommandDetail() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-foreground-agent-title-refresh"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                    foregroundArgv: ["codex", "--model", "gpt-5"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                    foregroundDisplayCommand: "codex --model gpt-5"))
            try markBuiltInSessionLive(sessionID: sessionID)
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")

            _ = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
        }

        XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")
    }

    func testReconcileTerminalForegroundAgentClassificationsSuffixesDuplicateAdHocLabels() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let firstSessionID = "ad-hoc-foreground-agent-1"
        let secondSessionID = "ad-hoc-foreground-agent-2"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            for (index, sessionID) in [firstSessionID, secondSessionID].enumerated() {
                try writeTerminalSessionFixture(
                    sessionID: sessionID, workspace: workspace, kind: .shell,
                    runtimeState: TerminalSessionRuntimeState(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: Int32(123 + index), state: .running,
                        updatedAt: "2026-06-06T00:00:00Z", title: "shell-\(index + 1)", workingDirectory: workspace.dir,
                        foregroundPID: Int32(123 + index), foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex",
                        foregroundArgv: ["codex"], foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex",
                        foregroundDisplayCommand: "codex"))
                try store.upsert(
                    window: WindowRecord(
                        id: "terminal-window-\(index + 1)", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-\(index + 1)",
                        detail: nil, targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 200 + index, lastSeenAt: "now"))
            }

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let labels = try store.agentWindows(workspaceID: workspace.id).compactMap(\.label)

            XCTAssertEqual(Set(labels), Set(["Codex", "Codex-2"]))
            XCTAssertNoThrow(try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in })
        }
    }

    /// Regression for a live rename bug: `TerminalForegroundAgentReconciler` and
    /// `ProcessExitMonitorService` both run `reconcileTerminalForegroundAgentClassifications` detached, so
    /// two overlapping passes can each read `existingRow == nil` for the same session and both call
    /// `insertAdHocDetectedAgent`. The row id is deterministic, so the second call upserts the SAME row —
    /// but must not treat the first call's own already-inserted row as a name conflict with itself and
    /// suffix it "-2".
    func testInsertAdHocDetectedAgentIsIdempotentAcrossOverlappingReconcilePasses() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        let orchestrator = makeTestOrchestrator(store: store)
        let sessionID = "ad-hoc-overlapping-agent"
        let detectedAgent = (kind: "claude", label: "claude", displayCommand: "claude")

        try orchestrator.insertAdHocDetectedAgent(detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID)
        try orchestrator.insertAdHocDetectedAgent(detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID)

        let agents = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.label, "claude")

        // A genuinely different session detecting the same label is a real collision and still suffixes.
        let otherSessionID = "ad-hoc-overlapping-agent-other"
        try orchestrator.insertAdHocDetectedAgent(detectedAgent: detectedAgent, workspace: workspace, sessionID: otherSessionID)
        let labelsAfterDistinctSession = try store.agentWindows(workspaceID: workspace.id).compactMap(\.label)
        XCTAssertEqual(Set(labelsAfterDistinctSession), Set(["claude", "claude-2"]))
    }

    /// Regression: the SAME overlapping-reconcile-pass race as
    /// `testInsertAdHocDetectedAgentIsIdempotentAcrossOverlappingReconcilePasses`, but with a hook landing
    /// in the window between the two passes' `insertAdHocDetectedAgent` calls. Pass A inserts the
    /// detection row; a hook then advances it to `.spinning` with a session key; the delayed pass B (which
    /// also read `existingRow == nil` before A's insert) must merge into that live state rather than
    /// re-upserting its stale `.idle`/`sessionKey: nil` detection defaults over it.
    func testInsertAdHocDetectedAgentPreservesHookStateFromDelayedOverlappingPass() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        let orchestrator = makeTestOrchestrator(store: store)
        let sessionID = "ad-hoc-stale-detection-agent"
        let detectedAgent = (kind: "claude", label: "claude", displayCommand: "claude")

        // Pass A's insert.
        try orchestrator.insertAdHocDetectedAgent(detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID)
        let agentID = orchestrator.adHocDetectedAgentID(sessionID: sessionID)
        guard let inserted = try store.agentWindow(id: agentID) else { return XCTFail("expected inserted detection row") }

        // A hook fires between the two passes, moving the row to spinning with a session key — real
        // lifecycle state pass B must not clobber.
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: inserted.id, workspaceID: inserted.workspaceID, provider: inserted.provider, label: inserted.label,
                runtimeTargetID: inserted.runtimeTargetID, terminalTarget: inserted.terminalTarget, sessionKey: "session-key-from-hook",
                status: .spinning, note: inserted.note, createdAt: inserted.createdAt, updatedAt: "2026-01-01T00:00:01Z"))

        // Pass B: the delayed second reconcile pass re-runs the same detection.
        try orchestrator.insertAdHocDetectedAgent(detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID)

        let agents = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.label, "claude")
        XCTAssertEqual(agents.first?.status, .spinning)
        XCTAssertEqual(agents.first?.sessionKey, "session-key-from-hook")
        XCTAssertEqual(agents.first?.createdAt, inserted.createdAt)
    }

    /// Pins the SQL contract that closes the detection read-modify-upsert race: the product invariant that
    /// a detection refresh never regresses an agent's lifecycle state. `upsertDetectedAgentWindow` merges a
    /// fresh label/binding onto a row while preserving whatever `status`, `session_key`, and `created_at`
    /// the stored row already holds — enforced in the ON CONFLICT clause, so it holds even against a stale
    /// caller snapshot with no injection seam between the read and the write.
    func testUpsertDetectedAgentWindowPreservesLifecycleStateAgainstStaleRefresh() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let agentID = "terminal-agent-detected-session"
        let terminalTarget = TerminalTargetRecord(trackingID: "detected-session")

        // Detection creates the row with fresh idle defaults.
        try store.upsertDetectedAgentWindow(
            AgentWindowRecord(
                id: agentID, workspaceID: workspace.id, provider: .spaces, label: "claude", terminalTarget: terminalTarget, sessionKey: nil,
                status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))

        // A hook advances the row to spinning with a session key through the lifecycle-owning upsert.
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: agentID, workspaceID: workspace.id, provider: .spaces, label: "claude", terminalTarget: terminalTarget,
                sessionKey: "session-key-from-hook", status: .spinning, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z"))

        // A delayed detection refresh carrying a stale idle/nil-session-key snapshot with a bogus creation
        // time must not regress the live lifecycle state; its label binding still applies, but updated_at
        // (the lifecycle-state-entered timestamp) must stay with the stored status rather than jump to
        // this refresh's value.
        try store.upsertDetectedAgentWindow(
            AgentWindowRecord(
                id: agentID, workspaceID: workspace.id, provider: .spaces, label: "claude-renamed", terminalTarget: terminalTarget, sessionKey: nil,
                status: .idle, createdAt: "2099-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:02Z"))

        guard let refreshed = try store.agentWindow(id: agentID) else { return XCTFail("expected agent row") }
        XCTAssertEqual(refreshed.status, .spinning)
        XCTAssertEqual(refreshed.sessionKey, "session-key-from-hook")
        XCTAssertEqual(refreshed.createdAt, "2026-01-01T00:00:00Z")
        XCTAssertEqual(refreshed.label, "claude-renamed")
        XCTAssertEqual(refreshed.updatedAt, "2026-01-01T00:00:01Z")
    }

    /// A session whose foreground the classifier cannot identify leaves an existing agent row alone rather
    /// than demoting or renaming it.
    func testReconcileTerminalForegroundAgentClassificationsPreservesAgentRowOnUnknownForeground() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "configured-agent-session"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .agent,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "Codex", workingDirectory: workspace.dir))
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex",
                    terminalTarget: TerminalTargetRecord(trackingID: sessionID), status: .idle, createdAt: "now", updatedAt: "now"))

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            let agents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(agents.map(\.id), ["agent-1"])
            XCTAssertEqual(agents.first?.label, "Codex")
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsSkipsConfiguredProcessSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "process-foreground-agent"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .process,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "api", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: "process-1", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: TerminalHost.spaces.appName,
                    terminalTrackingID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        }
    }

    // Tests restart workspace clears agent windows by arranging a running workspace with an Spaces2 agent window and asserting the record and built-in terminal window are removed before relaunch.
    func testRestartWorkspaceClearsAgentWindows() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "Claude Code", terminalTrackingID: "workspace-session",
                role: "terminal", orderIndex: 201, lastSeenAt: "now"))
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Claude Code", terminalTrackingID: "workspace-session",
            sessionKey: nil, status: .spinning, createdAt: "now", updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)

        try orchestrator.restartWorkspace(workspaceID: workspace.id)

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "Agent window records should be cleared during restart")
    }

    /// A live agent row's name is part of the workspace's name space, so a settings write that would give
    /// a process the same name is refused rather than producing two rows a user cannot tell apart.
    func testUpdateWorkspaceSettingsRejectsProcessNameTakenByALiveCodingAgent() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "reviewer", terminalTrackingID: "agent-session")

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "Reviewer", command: "npm run review")]
            }
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("coding agents"))
            XCTAssertTrue(message.contains("Reviewer"))
        }
    }

    func testRegisterAgentWindowAutoRenamesDuplicateFocusName() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "Claude", command: "claude")])

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude", terminalTrackingID: "agent-session")

        XCTAssertEqual(record.label, "Claude-2")
    }

}

/// Captures the lines the process-wide agent-notification submitter is asked to deliver, so a reconcile
/// path that routes through `makeAgentNotificationEngine()` can be asserted against without a live daemon.
/// Shared with the workspace-teardown tests, which assert the same delivery from the archive path.
final class AgentNotificationSubmitterRecorder: @unchecked Sendable {
    private(set) var delivered: [(sessionID: String, line: String)] = []
    func submit(_ sessionID: String, _ line: String) throws { delivered.append((sessionID: sessionID, line: line)) }
}

// MARK: - Finalized-fact idempotency (a `.done` agent is not finalized without a recorded exit event)

extension OrchestratorTests {
    /// Killing/stopping a live coding agent that is merely resting `.done` after completing a turn — the
    /// most common orchestration scenario (review a finished child, then kill it) — must deliver exactly
    /// one exited notice. `.done` is not a finalized fact on its own (no recorded exit event), so the
    /// chokepoint no longer suppresses the notice as it did when it treated `.done` as already-finalized.
    func testStopCodingAgentOnLiveDoneAgentDeliversExactlyOneExitedNotice() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        // A live agent that finished a turn: `.done`, with no recorded exit event.
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .done)
        XCTAssertFalse(try store.agentSessionHasRecordedExitEvent(agentSessionID: child.id), "a turn-complete .done row is not yet finalized")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        try orchestrator.stopCodingAgent(workspaceID: workspace.id, agentID: child.id)

        XCTAssertNil(try store.agentWindow(id: child.id), "the killed row is deleted")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "killing a done agent must tell the watcher it exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertEqual(recorder.delivered.count, 1, "killing a done agent delivers exactly one exited notice")
    }

    /// An agent that exits while its terminal is still open is kept at `.exited` WITH a recorded exit
    /// event. A later termination path — terminal teardown, workspace stop, or a sweep pass — must read
    /// that recorded fact and NOT re-notify.
    func testExitFinalizeThenDestroyDoesNotReNotify() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try writeLiveAgentTerminalSession(sessionID: "agent-session", workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "agent-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        // The agent's exit hook finalizes the row to `.exited` with a recorded exit event, notifying once.
        _ = try orchestrator.finalizeAgentRow(child, reason: .exited(eventType: "exit", eventSource: "spaces_agent_signal", environmentKeys: nil))
        XCTAssertEqual(try store.agentWindow(id: child.id)?.status, .exited, "an exit on a live terminal keeps the row at .exited")
        XCTAssertTrue(try store.agentSessionHasRecordedExitEvent(agentSessionID: child.id), "the exit-finalization records the exit event")
        XCTAssertEqual(recorder.delivered.count, 1, "the exit is notified exactly once")

        // A later terminal-teardown/workspace-stop destroy must not re-notify the already-finalized row.
        let finalized = try XCTUnwrap(try store.agentWindow(id: child.id))
        try orchestrator.finalizeAgentRow(finalized, reason: .destroyed(terminateTerminalSession: false))

        XCTAssertNil(try store.agentWindow(id: child.id), "the destroy still deletes the row")
        XCTAssertEqual(recorder.delivered.count, 1, "no second exited notice for an agent whose exit was already delivered")
    }

    /// The finalized fact must be scoped to the row's CURRENT life. A kept row is reused when a fresh
    /// agent starts in the same terminal (the restart-reuse `init` preserves the row id), so the previous
    /// life's recorded exit event must not mark the reincarnated, live agent as finalized — killing it
    /// must deliver a NEW exited notice, not silently skip it because the old life already exited.
    func testKillAfterRestartReuseDeliversFreshExitedNoticeForNewLife() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try writeLiveAgentTerminalSession(sessionID: "agent-session", workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        // Life 1: the agent exits while its terminal stays open — the row is kept `.exited` with a recorded
        // exit event, and the watcher (edge retained on a kept row) receives the first exited notice.
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "agent-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")
        _ = try orchestrator.finalizeAgentRow(child, reason: .exited(eventType: "exit", eventSource: "spaces_agent_signal", environmentKeys: nil))
        XCTAssertEqual(try store.agentWindow(id: child.id)?.status, .exited)
        XCTAssertTrue(try store.agentSessionHasRecordedExitEvent(agentSessionID: child.id), "life 1's exit is the finalized fact")
        XCTAssertEqual(recorder.delivered.count, 1, "life 1's exit is notified once")

        // Life 2: a fresh agent inits in the same terminal. The daemon init path re-registers the SAME row
        // (id preserved), passing the preserved existing status, and records an `init` event on it.
        let reincarnated = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "agent-session",
            status: try XCTUnwrap(try store.agentWindow(id: child.id)).status, eventType: "init", eventSource: "spaces_agent_signal")
        XCTAssertEqual(reincarnated.id, child.id, "the restart-reuse init reuses the same row id")
        XCTAssertFalse(
            try store.agentSessionHasRecordedExitEvent(agentSessionID: child.id),
            "the previous life's exit event is discounted once a later init lands — the new life is not finalized")

        // Killing the new, live agent must deliver exactly one NEW exited notice for life 2.
        try orchestrator.stopCodingAgent(workspaceID: workspace.id, agentID: child.id)

        XCTAssertNil(try store.agentWindow(id: child.id), "the kill deletes the row")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session", "watcher-session"])
        XCTAssertTrue(
            recorder.delivered.last?.line.contains("is exited") == true,
            "the watcher must be told the NEW life exited, got: \(recorder.delivered.last?.line ?? "nothing")")
        XCTAssertEqual(recorder.delivered.count, 2, "one notice per life: the reincarnated agent's exit is neither skipped nor duplicated")
    }

    // MARK: - Bulk project/workspace deletion vs the RESTRICT foreign key (Fix 1)

    /// Removing a project whose workspace holds a watched coding agent must succeed. The store's bulk
    /// `agent_sessions` delete throws under `ON DELETE RESTRICT` while the watched row retains an inbound
    /// edge (failing-first), so `removeProject` finalizes every agent through the chokepoint first — which
    /// delivers the exited notice to a watcher OUTSIDE the deleted project and drops the edges — before the
    /// bulk delete runs.
    func testRemoveProjectFinalizesWatchedAgentSoBulkDeleteSucceedsAndNotifiesOutsideWatcher() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .waiting)
        // A watcher terminal OUTSIDE the deleted project (a plain shell, no agent row of its own) is owed the exit.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        // Failing-first: the store's bulk `agent_sessions` delete throws under RESTRICT while the watched row
        // still holds its inbound edge. The transaction rolls back, so the project remains intact.
        XCTAssertThrowsError(
            try store.deleteProject(id: project.id), "the bulk delete must fail loudly while a watched agent retains an inbound edge")
        XCTAssertNotNil(try store.project(id: project.id), "the failed bulk delete rolled back, leaving the project intact")

        try orchestrator.removeProject(dir: projectDir.path)

        XCTAssertNil(try store.project(id: project.id), "the project is removed")
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "the agent rows are gone")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the outside watcher must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty, "no inbound edges remain")
    }

    /// There is no orchestrator-level hard workspace delete (archive is a soft flag), but the store's
    /// `deleteWorkspace` carries the same RESTRICT hazard: its bulk `agent_sessions` delete throws while a
    /// watched agent in the workspace retains an inbound edge. Any workspace-scoped hard delete must
    /// finalize through the chokepoint first — delivering the exited notice to an outside watcher and
    /// clearing the edges — exactly as project removal does.
    func testDeleteWorkspaceWithWatchedAgentRequiresChokepointFinalizeFirst() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        // Failing-first: the raw workspace delete throws under RESTRICT and rolls back.
        XCTAssertThrowsError(try store.deleteWorkspace(id: workspace.id), "the workspace bulk delete must fail loudly with a watched agent present")
        XCTAssertNotNil(try store.workspace(id: workspace.id), "the failed delete rolled back")

        for agent in try store.agentWindows(workspaceID: workspace.id) {
            try orchestrator.finalizeAgentRow(agent, reason: .destroyed(terminateTerminalSession: false))
        }
        XCTAssertNoThrow(try store.deleteWorkspace(id: workspace.id), "after finalize-first the bulk delete succeeds")

        XCTAssertNil(try store.workspace(id: workspace.id))
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the outside watcher must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty, "no inbound edges remain")
    }

    /// The shell-revert branch must finalize a `.done` (turn-complete) ad-hoc detection row whose
    /// foreground reverted to a plain shell — that reversion after a completed turn means the agent quit,
    /// so its subscribers are owed the exited notice and the row must not be left stale. `.done` is not a
    /// finalized fact (no recorded exit event), so the branch no longer skips it.
    func testReconcileShellRevertFinalizesDoneTurnCompleteAdHocAgentWithNotice() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "ad-hoc-done-agent-shell-revert"

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            // A live terminal (control socket present) so `handleAgentExit` records `.exited` rather than deleting.
            XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promoted = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)

            // The agent completes a turn: a `done` hook signal lands, moving the row to `.done` (a live,
            // turn-complete resting state — no exit event recorded).
            _ = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, status: .done, eventType: "done",
                eventSource: "spaces_agent_signal")
            XCTAssertEqual(try store.agentWindow(id: promoted.id)?.status, .done)
            XCTAssertFalse(try store.agentSessionHasRecordedExitEvent(agentSessionID: promoted.id), "a turn-complete .done row is not finalized")
            try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-subscriber", agentSessionID: promoted.id, createdAt: "t")

            // The agent quits after its turn: the foreground reverts to the plain shell while the terminal stays live.
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]), paths: paths)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try store.agentWindow(id: promoted.id)?.status, .exited, "the done turn-complete row is finalized to .exited, not skipped")
            XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-subscriber"])
            XCTAssertTrue(
                recorder.delivered.first?.line.contains("is exited") == true,
                "the subscriber must be told the child exited, got: \(recorder.delivered.first?.line ?? "nothing")")

            // A second pass sees the now-finalized `.exited` row and re-notifies nothing.
            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(recorder.delivered.count, 1, "the exited notice is delivered exactly once")
        }
    }

    /// Two reconcile passes observe the SAME exit transition. In the daemon they are the foreground-agent
    /// reconciler and the process-exit monitor, each on its own database connection and each woken by the
    /// same terminal runtime-state change, so both hold a snapshot read before either finalized and both
    /// reach the chokepoint. Exactly one may take effect: the injected exited block is submitted into the
    /// subscribing orchestrator's composer, so a second one prompts it to act on one child exit twice.
    func testSecondExitFinalizationOfTheSameTransitionNotifiesNothing() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        // A live terminal keeps the row (and its recorded events) after the exit; a dead one would
        // delete the row and cascade away the very event this test counts.
        try writeLiveAgentTerminalSession(sessionID: "agent-session", workspace: workspace)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "agent-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        // Both passes carry the identical pre-exit snapshot and the identical reconciler exit reason.
        let reason = WorkspaceOrchestrator.AgentTerminationReason.exited(
            eventType: "exit", eventSource: "foreground_reconciler", environmentKeys: nil)
        _ = try orchestrator.finalizeAgentRow(child, reason: reason)
        _ = try orchestrator.finalizeAgentRow(child, reason: reason)

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        XCTAssertEqual(recorder.delivered.count, 1, "one child exit delivers exactly one exited notice")
        let exitEventCount = try store.queryRows(
            sql: "SELECT COUNT(*) FROM agent_session_events WHERE agent_session_id = ? AND event_type = 'exit'", bindings: [child.id]
        ).first?.first
        XCTAssertEqual(exitEventCount, "1", "one child exit records exactly one exit event")
    }

    /// The chokepoint's idempotency is one atomic claim rather than a finalized check followed by a
    /// separate write, because the passes that observe an exit run on their own connections: a check-then-
    /// write window let both pass the check and both record. Exactly one caller may claim an agent's exit
    /// per life, judged against committed state, and a fresh agent reusing the row (its `init`) opens a new
    /// life that is claimable again.
    func testExitClaimAdmitsOneCallerPerAgentLifeAcrossConnections() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let otherConnection = try SQLiteStore(path: dbPath)
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        let orchestrator = makeTestOrchestrator(store: store)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)

        XCTAssertTrue(
            try store.claimAgentSessionExitEvent(
                agentSessionID: child.id, eventType: "exit", source: "foreground_reconciler", message: nil, createdAt: "t1",
                exitedNoticeTransition: "exited", exitedNoticeMessage: "[spaces] Codex (codex) is exited"))
        XCTAssertFalse(
            try otherConnection.claimAgentSessionExitEvent(
                agentSessionID: child.id, eventType: "exit", source: "foreground_reconciler", message: nil, createdAt: "t1",
                exitedNoticeTransition: "exited", exitedNoticeMessage: "[spaces] Codex (codex) is exited"),
            "a second pass observing the same exit claims nothing, on any connection")

        // A fresh agent inits in the same terminal, reusing the row: its exit is a new fact to claim.
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .idle, eventType: "init",
            eventSource: "spaces_agent_signal")
        XCTAssertTrue(
            try otherConnection.claimAgentSessionExitEvent(
                agentSessionID: child.id, eventType: "exit", source: "foreground_reconciler", message: nil, createdAt: "t2",
                exitedNoticeTransition: "exited", exitedNoticeMessage: "[spaces] Codex (codex) is exited"),
            "the reincarnated agent's exit is claimable again")

        // A row that is gone (stopped or restarted out from under the pass) has no exit left to claim.
        try store.deleteAgentSubscriptions(agentSessionID: child.id)
        try store.deleteAgentWindow(id: child.id)
        XCTAssertFalse(
            try store.claimAgentSessionExitEvent(
                agentSessionID: child.id, eventType: "exit", source: "foreground_reconciler", message: nil, createdAt: "t3",
                exitedNoticeTransition: "exited", exitedNoticeMessage: "[spaces] Codex (codex) is exited"))
    }

    /// The issue's whole scenario: a coding agent that emits no session-end hook (codex, opencode) quits in
    /// its own shell terminal, so the foreground reconciler is what finalizes it. Its subscriber must be
    /// told exactly once, and the injected block must name the child's coding agent — the kind is detected
    /// from live foreground state, which the exit clears, so a row that does not carry the detected kind
    /// renders the anonymous "coding agent" exactly when the notice is sent.
    func testHooklessAgentExitNotifiesOnceAndNamesTheDetectedAgentKind() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "hookless-codex-shell-revert"

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "codex", foregroundDisplayCommand: "codex"))
            // A live terminal (control socket present): the shell outlives the agent, which is what keeps
            // the row (and its lifecycle log) around to be read after the exit.
            XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let child = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            // A hookless agent still signals its turns; that hook evidence is what a subscribe requires.
            _ = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, status: .spinning, eventType: "working",
                eventSource: "spaces_agent_signal")
            try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-subscriber", agentSessionID: child.id, createdAt: "t")

            // The agent quits without any session-end hook: the foreground reverts to the plain shell.
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:10Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]), paths: paths)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            XCTAssertEqual(recorder.delivered.count, 1, "the hookless exit notifies the subscriber exactly once")
            let line = try XCTUnwrap(recorder.delivered.first?.line)
            XCTAssertTrue(line.contains("(codex) is exited"), "the block must name the child's coding agent, got: \(line)")
            XCTAssertEqual(
                try orchestrator.agentSessionRows(sessionID: sessionID).first?.agent, "codex",
                "the exited row still reports its coding agent to orchestration listings")
        }
    }

    /// A teardown that lands in the window between an exit claim committing and the claimant delivering
    /// its notice. The claim publishes the finalized fact, so the teardown correctly announces nothing —
    /// and then drops the row's watch edges and deletes it. If the exited notice only came into existence
    /// after the claim committed, the claimant would come back to no subscribers and the child's exit
    /// would reach NOBODY, which is worse than the duplicate this branch set out to fix. The notice is
    /// queued inside the claim's own transaction instead, so it exists the instant the finalized fact does
    /// and outlives the teardown.
    ///
    /// The interleaving is built at the commit boundary rather than with threads: the store call below is
    /// exactly the transaction `finalizeAgentRow(.exited)` runs before it delivers anything, so every line
    /// after it is what a concurrent teardown does while the claimant is still between COMMIT and delivery.
    func testTeardownDuringAClaimedExitStillDeliversTheNoticeExactlyOnce() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        let claimedNotice = "[spaces] Codex (codex) is exited"
        XCTAssertTrue(
            try store.claimAgentSessionExitEvent(
                agentSessionID: child.id, eventType: "exit", source: "foreground_reconciler", message: nil, createdAt: "t1",
                exitedNoticeTransition: "exited", exitedNoticeMessage: claimedNotice))

        try orchestrator.finalizeAgentRow(child, reason: .destroyed(terminateTerminalSession: false))

        XCTAssertNil(try store.agentWindow(id: child.id), "the teardown deletes the row")
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty, "the teardown drops the watch edge")
        XCTAssertTrue(recorder.delivered.isEmpty, "a teardown announces nothing for an exit another caller already claimed")

        // The claimed notice survived the teardown and is still owed to the watcher, which receives it on
        // its next drain — one exit, one block, and never a second one.
        XCTAssertEqual(try store.consumePendingAgentNotifications(subscriberTerminalSessionID: "watcher-session"), [claimedNotice])
        XCTAssertTrue(try store.consumePendingAgentNotifications(subscriberTerminalSessionID: "watcher-session").isEmpty)
    }

    /// A configured coding agent registers its row the moment Spaces launches its terminal, which is
    /// before the agent command is running and therefore before foreground detection can classify it — so
    /// the kind sampled at registration is nil. Nothing else refreshes it: the foreground reconciler skips
    /// a session with a configured owner, and a repeated `working` signal is a deliberate no-op. Detection
    /// arriving later must still be persisted, or the child's exit block names an anonymous "coding agent"
    /// for an agent live listings had identified all along.
    func testConfiguredAgentKindDetectedAfterRegistrationNamesTheAgentInItsExitBlock() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        let sessionID = "configured-agent-late-detection"

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            // The launch instant: the wrapper shell is up, the configured command has not started, so
            // foreground detection has nothing to classify yet.
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .agent,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "Codex", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/bin/zsh", foregroundExecutableName: "zsh", foregroundArgv: ["zsh"]))
            XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))

            let child = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID, status: .idle)
            XCTAssertNil(child.detectedAgentKind, "registration precedes classification, so the row starts with no kind")
            try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-subscriber", agentSessionID: child.id, createdAt: "t")

            // Detection lands: the configured command is now the foreground process.
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .running,
                    updatedAt: "2026-06-06T00:00:05Z", title: "Codex", workingDirectory: workspace.dir, foregroundPID: 456,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "codex", foregroundDisplayCommand: "codex"), paths: paths)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications(), "the pass persists the newly detected kind")
            let classified = try XCTUnwrap(store.agentWindow(id: child.id))
            XCTAssertEqual(classified.detectedAgentKind, "codex")
            XCTAssertEqual(classified.updatedAt, child.updatedAt, "learning the kind is not a lifecycle transition and must not re-date the row")
            XCTAssertNil(try store.lastAgentSignalAt(agentSessionID: child.id), "and records no lifecycle signal of its own")
            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications(), "a settled kind is not rewritten on every pass")

            // The agent's terminal ends without any session-end hook, so the sweep is what finalizes it.
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 456, state: .exited,
                    updatedAt: "2026-06-06T00:00:10Z", title: "Codex", workingDirectory: workspace.dir), paths: paths)
            try FileManager.default.removeItem(atPath: paths.controlSocketPath)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-subscriber"])
            let line = try XCTUnwrap(recorder.delivered.first?.line)
            XCTAssertTrue(line.contains("(codex) is exited"), "the exit block must name the agent detection identified, got: \(line)")
        }
    }

    /// Per-tool hooks make a working agent signal `working` on every tool call. That repetition is not a
    /// lifecycle transition: it must append no event to the agent's history and must leave `updated_at`
    /// reading the time the agent ENTERED working, which clients render as the event's time. This is the
    /// contract that makes a live agent's kind unrefreshable through the signal path, so it is asserted
    /// alongside the reconciler-side kind refresh rather than left implicit.
    func testRepeatedWorkingSignalsRecordNothingAndLeaveTheRowUntouched() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        let orchestrator = makeTestOrchestrator(store: store)

        let working = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", label: "Codex", status: .spinning,
            eventType: "working", eventSource: "spaces_agent_signal")
        let firstSignalAt = try store.lastAgentSignalAt(agentSessionID: working.id)
        let signalledEventCount = try agentSessionEventCount(store: store, agentSessionID: working.id)

        for _ in 0..<3 {
            _ = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", label: "Codex", status: .spinning,
                eventType: "working", eventSource: "spaces_agent_signal")
        }

        let settled = try XCTUnwrap(store.agentWindow(id: working.id))
        XCTAssertEqual(settled.updatedAt, working.updatedAt, "updated_at stays the time the agent entered working, not tool-call recency")
        XCTAssertEqual(
            try agentSessionEventCount(store: store, agentSessionID: working.id), signalledEventCount,
            "a repeated working signal appends no lifecycle event")
        XCTAssertEqual(try store.lastAgentSignalAt(agentSessionID: working.id), firstSignalAt)
    }

    /// Two drains reach the same queued exit notice: the claimant's own delivery pass and the subscriber's
    /// idle flush, each on its own daemon connection. The queue row is the unit of delivery, so exactly one
    /// of them may hand it to the terminal — listing the rows and deleting each only after it is delivered
    /// would let both read the same row and inject the block twice, moving the duplicate the exit claim
    /// removed one layer down into the queue.
    ///
    /// Built at the consume boundary rather than with threads: the claimant's candidate listing is taken
    /// first (what its delivery pass reads before it delivers anything), the idle flush then runs to
    /// completion on the other connection, and the claimant resumes against the candidate it still holds.
    func testConcurrentDrainsOfOneQueuedExitNoticeDeliverItExactlyOnce() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let flushConnection = try SQLiteStore(path: dbPath)
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        let orchestrator = makeTestOrchestrator(store: store)

        let recorder = AgentNotificationSubmitterRecorder()
        let claimantEngine = AgentNotificationEngine(store: store, deliver: { try recorder.submit($0, $1) }, logError: { _ in })
        let flushEngine = AgentNotificationEngine(store: flushConnection, deliver: { try recorder.submit($0, $1) }, logError: { _ in })

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        let notice = "[spaces] Codex (codex) is exited"
        XCTAssertTrue(
            try store.claimAgentSessionExitEvent(
                agentSessionID: child.id, eventType: "exit", source: "foreground_reconciler", message: nil, createdAt: "t1",
                exitedNoticeTransition: "exited", exitedNoticeMessage: notice))

        // The claimant reads its candidates and is descheduled before delivering any of them.
        let claimantCandidates = try store.pendingAgentNotifications(agentSessionID: child.id)
        XCTAssertEqual(claimantCandidates.map(\.message), [notice])
        let heldCandidate = try XCTUnwrap(claimantCandidates.first)

        // The subscriber's idle flush runs to completion in that window, on its own connection.
        try flushEngine.subscriberDidBecomeIdle(subscriberTerminalSessionID: "watcher-session")
        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        XCTAssertEqual(recorder.delivered.map(\.line), [notice])

        // The claimant resumes holding a row that is no longer in the queue, so it delivers nothing and
        // its whole pass is a no-op.
        XCTAssertNil(try store.claimPendingAgentNotification(id: heldCandidate.id), "a row another drain already consumed is never handed out again")
        try claimantEngine.deliverClaimedExitNotices(agentSessionID: child.id)
        XCTAssertEqual(recorder.delivered.count, 1, "one queued exit notice is injected exactly once across concurrent drains")
    }

    /// Overlapping reconcile passes each hold their own pre-exit snapshot of the agent row, and one pass
    /// can persist the detected kind while another still holds a copy taken before it. If that older copy
    /// wins the exit claim, the block it renders is the only one anyone receives — and nothing downstream
    /// can repair it, because live foreground state is cleared by the very exit being announced. So the
    /// notice must be rendered from the row as the database holds it, or a child whose agent Spaces
    /// identified is announced as an anonymous "coding agent".
    func testExitClaimedFromAStaleSnapshotStillNamesThePersistedAgentKind() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = makeTestOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        // The snapshot a reconcile pass read before classification landed.
        let stale = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)
        XCTAssertNil(stale.detectedAgentKind, "the snapshot predates classification")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: stale.id, createdAt: "t")

        // Another pass classifies the session and persists the kind. There is no live session behind this
        // row, so live foreground state reports nothing — the row is the only place the kind now exists.
        try store.setAgentSessionDetectedKind(id: stale.id, kind: "codex")
        XCTAssertNil(orchestrator.resolvedAgentKind(stale), "the stale snapshot alone cannot name the agent")

        try orchestrator.finalizeAgentRow(stale, reason: .exited(eventType: "exit", eventSource: "foreground_reconciler", environmentKeys: nil))

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        let line = try XCTUnwrap(recorder.delivered.first?.line)
        XCTAssertTrue(line.contains("(codex) is exited"), "the exit block must name the kind the row carries, got: \(line)")
    }

    /// A hook `init` carries no label, and foreground detection cannot classify every command, so a row
    /// registered with nothing to name it would otherwise have no name at all. Registration materializes
    /// "Coding Agent" as the row's real stored label, so the row, its pane, and focus all read one string.
    func testRegisteringAnAgentWithNoReportedLabelStoresTheDefaultName() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle, eventType: "init",
            eventSource: "spaces_agent_signal")

        XCTAssertEqual(agent.label, "Coding Agent")
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.label, "Coding Agent")
    }

    /// The materialized name runs through the same uniquifier a reported label does, so two nameless
    /// agents in one workspace keep a one-name-to-one-row mapping instead of both answering to one name.
    func testASecondAgentWithNoReportedLabelIsSuffixed() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session-1", status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session-2", status: .idle)

        XCTAssertEqual(first.label, "Coding Agent")
        XCTAssertEqual(second.label, "Coding Agent-2")
        XCTAssertEqual(try store.agentWindow(id: second.id)?.label, "Coding Agent-2")
    }

    /// `spaces open` resolves a name against the workspace's focusable targets, and the app routes the
    /// request by the row's own name. With the label materialized both read the same string, so an agent
    /// nothing named is reachable by name.
    func testAnAgentWithNoReportedLabelIsFocusableByItsMaterializedName() throws {
        let (_, orchestrator, workspace) = try makeAgentRenameFixture()
        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session-1", status: .idle)
        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session-2", status: .idle)

        let names = try orchestrator.workspaceFocusableWindowNames(workspaceID: workspace.id)

        XCTAssertTrue(names.contains("Coding Agent"), "got: \(names)")
        XCTAssertTrue(names.contains("Coding Agent-2"), "got: \(names)")
        XCTAssertEqual(Set(names).count, names.count, "no two rows may share a visible name, got: \(names)")
    }

    /// Clearing a rename recovers the row's stored label, and a materialized one is a stored label like
    /// any other: the row comes back under the name registration gave it rather than under no name.
    func testClearingARenameOnAnUnnamedAgentRestoresItsMaterializedName() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", status: .idle)
        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: agent.id, title: "Reviewer")

        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: agent.id, title: "  ")

        XCTAssertNil(try store.agentWindow(id: agent.id)?.userLabel)
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.effectiveLabel, "Coding Agent")
    }

    /// A renamed agent has to answer to the name the user gave it. Focus resolution reads names, so a row
    /// still listed under the label nothing displays is unreachable by the name on screen.
    func testRenamingAnAgentMovesItsFocusNameToTheNewName() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        try store.upsertAgentWindow(makeRenameFixtureAgent(id: "agent-1", workspaceID: workspace.id, label: "Claude", session: "session-1"))

        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: "agent-1", title: "Reviewer")

        let names = try orchestrator.workspaceFocusableWindowNames(workspaceID: workspace.id)
        XCTAssertTrue(names.contains("Reviewer"), "got: \(names)")
        XCTAssertFalse(names.contains("Claude"), "the old label must stop answering to focus, got: \(names)")
    }

    /// A rename obeys the same one-visible-name-per-row rule a config edit does, so it is refused when the
    /// name is already taken by a process, a browser session, or another agent.
    func testRenamingAnAgentOntoATakenNameIsRefusedAndWritesNothing() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "web", command: "npm run dev")])
        try store.upsertAgentWindow(makeRenameFixtureAgent(id: "agent-1", workspaceID: workspace.id, label: "Claude", session: "session-1"))
        try store.upsertAgentWindow(makeRenameFixtureAgent(id: "agent-2", workspaceID: workspace.id, label: "Opencode", session: "session-2"))

        for taken in ["web", "Opencode"] {
            XCTAssertThrowsError(try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: "agent-1", title: taken), taken) { error in
                guard case WorkspaceError.invalidArgument = error else { return XCTFail("expected invalidArgument for \(taken), got \(error)") }
            }
            XCTAssertNil(try store.agentWindow(id: "agent-1")?.userLabel, "the refused rename must write nothing")
        }

        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: "agent-1", title: "Reviewer")
        XCTAssertEqual(try store.agentWindow(id: "agent-1")?.userLabel, "Reviewer")
    }

    /// Clearing is never refused, and with the reported label free it is a plain revert: the stored rename
    /// goes away and the row falls back to the name the agent reports for itself.
    func testClearingAnAgentRenameRevertsToTheReportedLabelWhenItIsFree() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        try store.upsertAgentWindow(makeRenameFixtureAgent(id: "agent-1", workspaceID: workspace.id, label: "Codex", session: "session-1"))
        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: "agent-1", title: "Reviewer")

        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: "agent-1", title: "   ")

        XCTAssertNil(try store.agentWindow(id: "agent-1")?.userLabel)
        XCTAssertEqual(try store.agentWindow(id: "agent-1")?.effectiveLabel, "Codex")
    }

    /// A rename hides the reported label, so another row can take it while the rename stands. Clearing
    /// still has to succeed, but it must not put two rows under one name: the row comes back under the
    /// suffixed variant registration would have given it, which the user can rename again.
    func testClearingAnAgentRenameRecoversAFreeNameWhenTheReportedLabelWasTaken() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        try store.upsertAgentWindow(makeRenameFixtureAgent(id: "agent-1", workspaceID: workspace.id, label: "Codex", session: "session-1"))
        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: "agent-1", title: "Reviewer")
        // Registered through the orchestrator, which is free to take "Codex" precisely because the rename
        // standing on agent-1 means nothing displays that name.
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "session-2", status: .idle)
        XCTAssertEqual(second.effectiveLabel, "Codex", "the reported label really was free while the rename stood")

        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: "agent-1", title: "   ")

        XCTAssertEqual(try store.agentWindow(id: "agent-1")?.userLabel, "Codex-2")
        XCTAssertEqual(try store.agentWindow(id: "agent-1")?.effectiveLabel, "Codex-2")
        let names = try orchestrator.workspaceFocusableWindowNames(workspaceID: workspace.id)
        XCTAssertEqual(Set(names).count, names.count, "no two rows may share a visible name, got: \(names)")
        XCTAssertTrue(names.contains("Codex") && names.contains("Codex-2"), "got: \(names)")
    }

    /// A rename lives in its own column that no lifecycle write touches, so the row keeps it. The record a
    /// status update hands back has to keep it too: the daemon renders the watcher's notice straight off
    /// that returned record, so one rebuilt without the rename announces the agent under the label the user
    /// replaced.
    func testStatusUpdateAfterARenameKeepsTheRenameOnTheReturnedRecordAndItsNotice() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude", terminalTrackingID: "agent-session", status: .spinning)
        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: child.id, title: "Reviewer")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        // The signal path's own call: it reports the label the agent still calls itself, which is exactly
        // what must not win over the rename.
        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "agent-session", label: "Claude", status: .waiting)

        XCTAssertEqual(updated.userLabel, "Reviewer")
        XCTAssertEqual(updated.effectiveLabel, "Reviewer")
        try orchestrator.makeAgentNotificationEngine().childDidTransition(agent: updated, transition: .blocked)
        let line = try XCTUnwrap(recorder.delivered.first?.line)
        XCTAssertTrue(line.contains("Reviewer"), "the notice must name the row's visible name, got: \(line)")
        XCTAssertFalse(line.contains("Claude"), "the notice must not name the label the rename replaced, got: \(line)")
    }

    /// The exit disposition rebuilds the row from the caller's snapshot too, and its record is what the
    /// caller reads on from, so the rename rides along there as well.
    func testExitStatusRecordKeepsTheRename() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude", terminalTrackingID: "agent-session", status: .spinning)
        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: child.id, title: "Reviewer")

        let stored = try XCTUnwrap(store.agentWindow(id: child.id))
        let exited = try XCTUnwrap(orchestrator.recordAgentExitStatus(stored))

        XCTAssertEqual(exited.effectiveLabel, "Reviewer")
    }

    /// The rename's write names the row by id, so it reports whether a row was actually there. A rename
    /// racing the stop that deletes the row rides on that answer instead of reporting a success the user
    /// will never see.
    func testSetAgentSessionUserLabelReportsWhetherARowMatched() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude", terminalTrackingID: "agent-session", status: .spinning)

        XCTAssertTrue(try store.setAgentSessionUserLabel(id: child.id, userLabel: "Reviewer"))
        XCTAssertFalse(try store.setAgentSessionUserLabel(id: "ghost-agent", userLabel: "Reviewer"))
    }

    /// Every agent row is renameable: a row created by an agent's own hook signal takes the name the user
    /// gives it, stored on the session so later signals cannot overwrite it.
    func testRenamingAHookRegisteredAgentNamesItsRow() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "agent-session", status: .spinning,
            eventType: "init", eventSource: "spaces_agent_signal")

        try orchestrator.renameAgentSession(workspaceID: workspace.id, agentID: agent.id, title: "Reviewer")

        XCTAssertEqual(try store.agentWindow(id: agent.id)?.userLabel, "Reviewer")
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.effectiveLabel, "Reviewer")
    }

    /// An agent whose process ends while its terminal session stays open keeps its row at `.exited`: the
    /// terminal is still addressable and a fresh agent can reuse the row. There is no keep-at-`.done`
    /// disposition for any row.
    func testHandleAgentExitRecordsExitedForAgentOnLiveTerminal() throws {
        let (store, orchestrator, workspace) = try makeAgentRenameFixture()
        try writeLiveAgentTerminalSession(sessionID: "agent-session", workspace: workspace)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "agent-session", status: .spinning)

        let result = try XCTUnwrap(orchestrator.handleAgentExit(agent))

        XCTAssertEqual(result.status, .exited)
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.status, .exited)
    }

    private func makeAgentRenameFixture() throws -> (SQLiteStore, WorkspaceOrchestrator, WorkspaceRecord) {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        return (store, makeTestOrchestrator(store: store), workspace)
    }

    /// Writes the on-disk artifacts that make a built-in terminal session read as live: a launch
    /// configuration, a running runtime state owned by this process, and the control socket. An agent row
    /// bound to such a session survives its exit as `.exited` instead of being deleted with a dead terminal.
    private func writeLiveAgentTerminalSession(sessionID: String, workspace: WorkspaceRecord) throws {
        try writeTerminalSessionFixture(
            sessionID: sessionID, workspace: workspace, kind: .agent,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                updatedAt: "2026-06-06T00:00:00Z", title: "Codex", workingDirectory: workspace.dir))
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
    }

    private func makeRenameFixtureAgent(id: String, workspaceID: String, label: String, session: String) -> AgentWindowRecord {
        AgentWindowRecord(
            id: id, workspaceID: workspaceID, provider: .spaces, label: label,
            terminalTarget: TerminalTargetRecord(trackingID: session), status: .idle, createdAt: "now", updatedAt: "now")
    }

    private func agentSessionEventCount(store: SQLiteStore, agentSessionID: String) throws -> Int {
        let row = try store.queryRows(sql: "SELECT COUNT(*) FROM agent_session_events WHERE agent_session_id = ?", bindings: [agentSessionID])
        return Int(row.first?.first ?? "") ?? -1
    }
}
