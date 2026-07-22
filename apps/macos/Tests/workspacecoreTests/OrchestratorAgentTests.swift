import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {

    func testStopCodingAgentRemovesRuntimeAndPreservesConfiguredLauncher() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: "window-codex", workspaceID: workspace.id, app: "Spaces", name: "Codex", terminalTrackingID: "session-codex", role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", runtimeTargetID: "window-codex",
                terminalTarget: TerminalTargetRecord(runtimeTargetID: "window-codex", trackingID: "session-codex"), sessionKey: nil,
                claimedLauncherName: "Codex", status: .idle, createdAt: "now", updatedAt: "now"))
        let closed = TerminalCloseCapture()
        let terminated = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { closed.sessionIDs.append($0) },
            builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) })

        try orchestrator.stopCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspaceAgentLaunchers(workspaceID: workspace.id).map(\.name), ["Codex"])
        XCTAssertEqual(closed.sessionIDs, ["session-codex"])
        XCTAssertEqual(terminated.sessionIDs, ["session-codex"])
    }

    func testRestartCodingAgentRelaunchesClaimedLauncher() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "old-session", sessionKey: nil,
                status: .idle, createdAt: "now", updatedAt: "now"))
        let launches = TerminalLaunchConfigurationCapture()
        let terminated = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalWindowCloser: { _ in },
            builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) },
            builtInTerminalSessionLauncher: { configuration in
                launches.append(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })

        let relaunched = try orchestrator.restartCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")

        XCTAssertEqual(terminated.sessionIDs, ["old-session"])
        XCTAssertEqual(launches.snapshot().map(\.title), ["Codex"])
        XCTAssertEqual(relaunched.label, "Codex")
        XCTAssertEqual(try store.workspaceAgentLaunchers(workspaceID: workspace.id).map(\.name), ["Codex"])
    }

    func testRestartCodingAgentRejectsUnconfiguredAdHocRuntime() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-review", workspaceID: workspace.id, provider: .spaces, label: "reviewer", terminalTrackingID: "session-review",
                sessionKey: nil, status: .idle, createdAt: "now", updatedAt: "now"))
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.restartCodingAgent(workspaceID: workspace.id, agentID: "agent-review")) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid argument: Unconfigured live coding agents cannot be restarted from Spaces.")
        }
    }

    func testRestartCodingAgentRejectsStaleClaimedLauncherBeforeStopping() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceAgentLaunchers(
            workspaceID: workspace.id, launchers: [AgentLauncher(id: "launcher-current", name: "Reviewer", command: "codex --review")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "old-session", sessionKey: nil,
                status: .idle, createdAt: "now", updatedAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "old-session"), claimedLauncherID: "launcher-codex", claimedLauncherName: "Codex",
                status: .idle, createdAt: "now", updatedAt: "now"))
        let terminated = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) })

        XCTAssertThrowsError(try orchestrator.restartCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid argument: Configured coding agent not found.")
        }

        XCTAssertEqual(terminated.sessionIDs, [])
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).map(\.id), ["agent-codex"])
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

        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

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

    /// Restarting a watched coding agent stops the old child through the same chokepoint, so its
    /// subscribers are owed — and must receive — the exited notice for the OLD child before the relaunch.
    func testRestartCodingAgentDeliversExitedNoticeForOldChild() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "old-session", sessionKey: nil,
                status: .spinning, createdAt: "now", updatedAt: "now"))
        // A plain-shell subscriber terminal (no agent row of its own) is idle and receives immediately.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: "agent-codex", createdAt: "t")

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }

        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalWindowCloser: { _ in },
            builtInTerminalSessionTerminator: { _ in },
            builtInTerminalSessionLauncher: { configuration in
                TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })

        _ = try orchestrator.restartCodingAgent(workspaceID: workspace.id, agentID: "agent-codex")

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["watcher-session"])
        XCTAssertTrue(
            recorder.delivered.first?.line.contains("is exited") == true,
            "the subscriber must be told the OLD child exited, got: \(recorder.delivered.first?.line ?? "nothing")")
        XCTAssertEqual(recorder.delivered.count, 1, "the relaunch itself must not deliver a second notice")
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

    func testLaunchAgentLauncherUsesBuiltInSpacesTerminalAndRegistersAgentWindow() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let terminateCapture = TerminalTerminateCapture()
        let launchedConfigurations = TerminalLaunchConfigurationCapture()
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher { configuration in
            launchedConfigurations.append(configuration)
            let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                .init(
                    sessionID: configuration.sessionID, backend: configuration.backend, servicePID: Int32(ProcessInfo.processInfo.processIdentifier),
                    childPID: 5432, state: .running, updatedAt: "2026-05-18T18:00:00Z", title: configuration.title,
                    workingDirectory: configuration.workingDirectory), paths: paths)
            return TerminalServiceSessionSummary(
                id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running,
                servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 5432, controlSocketPath: paths.controlSocketPath,
                outputPath: paths.outputPath)
        }
        defer { WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher(nil) }
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 101, childPID: 5432, state: .running,
                        updatedAt: "2026-05-10T18:00:00Z"), paths: paths)
            }, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex --dangerously-skip-permissions")]
        }

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let record = try orchestrator.launchAgentLauncher(workspaceID: workspace.id, name: "Codex")
            XCTAssertEqual(record.label, "Codex")
            XCTAssertEqual(record.provider, .spaces)
        }

        XCTAssertEqual(openCapture.modes, [.owner])
        let launchedConfiguration = try XCTUnwrap(launchedConfigurations.snapshot().first)
        XCTAssertEqual(launchedConfiguration.workspaceID, workspace.id)
        XCTAssertEqual(launchedConfiguration.kind, .agent)
        let launchedCommand = try XCTUnwrap(launchedConfiguration.command)
        XCTAssertTrue(launchedCommand.contains(" -ilc "))
        XCTAssertTrue(launchedCommand.contains("\\033]0;Codex\\007"))
        XCTAssertTrue(launchedCommand.contains("codex --dangerously-skip-permissions"))
        let agentWindows = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agentWindows.count, 1)
        XCTAssertEqual(agentWindows.first?.provider, .spaces)
        let trackedTerminalWindows = try store.windows(workspaceID: workspace.id).filter { $0.role == "terminal" }
        XCTAssertTrue(trackedTerminalWindows.isEmpty || trackedTerminalWindows.first?.app == TerminalHost.spaces.appName)
        XCTAssertTrue(trackedTerminalWindows.isEmpty || trackedTerminalWindows.first?.terminalTrackingID == agentWindows.first?.terminalTrackingID)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    func testLaunchAgentLauncherReplacesStaleConfiguredSpacesAgentRowAndClosesPreviousSession() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let openCapture = TerminalOpenCapture()
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode in
                openCapture.sessionIDs.append(sessionID)
                openCapture.modes.append(mode)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 101, childPID: 5432, state: .running,
                        updatedAt: "2026-05-10T18:00:00Z"), paths: paths)
            }, builtInTerminalWindowCloser: { sessionID in closeCapture.sessionIDs.append(sessionID) },
            builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex --dangerously-skip-permissions")]
        }
        // The pre-existing (stale) agent owns a live session window; seed it so the stale row keeps its
        // configured "Codex" label and is matched/replaced on relaunch.
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "stale-session")
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "stale-session", status: .idle,
            claimedLauncherName: "Codex")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let record = try orchestrator.launchAgentLauncher(workspaceID: workspace.id, name: "Codex")
            XCTAssertEqual(record.label, "Codex")
            XCTAssertEqual(record.provider, .spaces)
            XCTAssertNotEqual(record.terminalTrackingID, "stale-session")
        }

        XCTAssertEqual(openCapture.modes, [.owner])
        XCTAssertEqual(closeCapture.sessionIDs, ["stale-session"])
        XCTAssertEqual(terminateCapture.sessionIDs, ["stale-session"])
        let agentWindows = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(agentWindows.count, 1)
        XCTAssertEqual(agentWindows.first?.label, "Codex")
        XCTAssertEqual(agentWindows.first?.provider, .spaces)
        XCTAssertNotEqual(agentWindows.first?.terminalTrackingID, "stale-session")
    }

    func testUpdateAgentWindowStatusDoesNotMatchConfiguredLauncherByLabel() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Mock Agent", command: "mock-agent")])
        // A live Spaces terminal session already owns its tracked window before an agent hook fires;
        // the agent correlates to that window instead of minting its own (which would otherwise make
        // the dedup suffix the agent against a window it just created for itself).
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "session-a")
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: "session-b")

        let configured = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Mock Agent", terminalTrackingID: "session-a", status: .idle,
            claimedLauncherName: "Mock Agent")

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "session-b", label: "Mock Agent", status: .waiting)

        let agentWindows = try store.agentWindows(workspaceID: workspace.id)
        let configuredAfterUpdate = try XCTUnwrap(agentWindows.first { $0.id == configured.id })
        XCTAssertEqual(agentWindows.count, 2)
        XCTAssertEqual(configuredAfterUpdate.label, "Mock Agent")
        XCTAssertEqual(configuredAfterUpdate.status, .idle)
        XCTAssertEqual(configuredAfterUpdate.terminalTrackingID, "session-a")
        XCTAssertNotEqual(updated.id, configured.id)
        XCTAssertEqual(updated.label, "Mock Agent-2")
        XCTAssertEqual(updated.status, .waiting)
        XCTAssertEqual(updated.terminalTrackingID, "session-b")
    }

    func testRefreshWorkspaceWindowsKeepsBuiltInAgentTerminalWindowAfterOwnerCloses() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db")
        let store = try SQLiteStore(path: dbPath.path)
        let orchestrator = WorkspaceOrchestrator(store: store)
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

    func testUpdateProjectConfigRejectsDuplicateConfiguredCodingAgentNames() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(
            try orchestrator.updateProjectConfig(projectID: project.id) { config in
                config.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex"), AgentLauncher(name: "codex", command: "codex --review")]
            }
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("coding agents"))
            XCTAssertTrue(message.contains("Codex"))
        }
    }

    func testImportSpacesYAMLWithWorkspaceSyncPreservesAgentLauncherIDsForLiveAgents() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let launches = TerminalLaunchConfigurationCapture()
        let terminated = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalWindowCloser: { _ in },
            builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) },
            builtInTerminalSessionLauncher: { configuration in
                launches.append(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.agentLaunchers = [AgentLauncher(id: "project-launcher-codex", name: "Codex", command: "codex")]
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: defaultWorkspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(id: "workspace-launcher-codex", name: "Codex", command: "codex")]
        }
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: defaultWorkspace.id, provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "old-session"), claimedLauncherID: "workspace-launcher-codex",
                claimedLauncherName: "Codex", status: .idle, createdAt: "now", updatedAt: "now"))
        try spacesYAMLFixture(stopScript: "echo synced-stop").write(
            to: try orchestrator.spacesYAMLConfigURL(projectID: project.id), atomically: true, encoding: .utf8)

        _ = try orchestrator.importSpacesYAML(projectID: project.id, updateAllWorkspaces: true)
        _ = try orchestrator.restartCodingAgent(workspaceID: defaultWorkspace.id, agentID: "agent-codex")

        XCTAssertEqual(try store.project(id: project.id)?.agentLaunchers.first?.id, "project-launcher-codex")
        XCTAssertEqual(try store.workspaceAgentLaunchers(workspaceID: defaultWorkspace.id).first?.id, "workspace-launcher-codex")
        XCTAssertEqual(terminated.sessionIDs, ["old-session"])
        XCTAssertEqual(launches.snapshot().map(\.title), ["Codex"])
    }

    func testUserClosedBuiltInTerminalSessionLeavesOwningAgentRunning() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let closeCapture = TerminalCloseCapture()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
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
        let orchestrator = WorkspaceOrchestrator(
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
                    terminalTarget: TerminalTargetRecord(trackingID: sessionID), sessionKey: "thread-1", claimedLauncherName: "Codex",
                    status: .spinning, createdAt: "now", updatedAt: "now"))
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
        let orchestrator = WorkspaceOrchestrator(
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
        let orchestrator = WorkspaceOrchestrator(store: store)
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
            XCTAssertNil(promotedAgent.claimedLauncherID)
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
        let orchestrator = WorkspaceOrchestrator(store: store)
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

    /// A detection-created ad-hoc row that has SINCE recorded a hook lifecycle signal is no longer pure
    /// detection state: it has subscribers owed an `exited` notice. When its foreground reverts to a plain
    /// shell, the reconciler must run the full hookless-exit flow — deliver the exited notice, record the
    /// row `.exited` (not silently delete it), and tear down the reverted terminal's own outgoing watch
    /// edges and pending queue — instead of the silent demote a never-signaled row gets.
    func testReconcileTerminalForegroundAgentClassificationsRecordsExitedForSignaledAdHocAgentOnShellRevert() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
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
                try store.agentWindow(id: promoted.id)?.status, .exited,
                "A signaled detection row is recorded `.exited`, not silently deleted.")
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
    /// teardown, stale-slot relaunch, and orphan prune — must notify a watched child's subscribers it
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
        let orchestrator = WorkspaceOrchestrator(store: store)

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
        let orchestrator = WorkspaceOrchestrator(store: store)

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
        let orchestrator = WorkspaceOrchestrator(store: store)
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

            let result = try orchestrator.handleAgentExit(signaled, eventType: "exit", eventSource: "spaces_agent_signal")

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
        let orchestrator = WorkspaceOrchestrator(store: store)
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
        let orchestrator = WorkspaceOrchestrator(store: store)
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

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let stickyAgents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(stickyAgents.map(\.id), [signalAgent.id])
            XCTAssertEqual(stickyAgents.first?.label, "Custom Hook Agent")
            XCTAssertEqual(stickyAgents.first?.status, .spinning)
            XCTAssertNil(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail)
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesSignalAgentAcrossShellForeground() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
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
        let orchestrator = WorkspaceOrchestrator(store: store)
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
        let orchestrator = WorkspaceOrchestrator(store: store)
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
        let orchestrator = WorkspaceOrchestrator(store: store)
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
        let orchestrator = WorkspaceOrchestrator(store: store)
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

            let updated = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, sessionKey: "thread-1", label: "Codex", status: .spinning
            )

            XCTAssertNil(updated.claimedLauncherName)
            let window = try XCTUnwrap(store.windows(workspaceID: workspace.id).first)
            XCTAssertEqual(window.name, "shell-1")
            XCTAssertEqual(window.detail, "codex --model gpt-5")
        }
    }

    func testRefreshWorkspaceWindowsPreservesAdHocDetectedAgentForegroundCommandDetail() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
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
        let orchestrator = WorkspaceOrchestrator(store: store)
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
        let orchestrator = WorkspaceOrchestrator(store: store)
        let sessionID = "ad-hoc-overlapping-agent"
        let detectedAgent = (label: "claude", displayCommand: "claude")

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

    func testReconcileTerminalForegroundAgentClassificationsReservesConfiguredLauncherNames() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        let sessionID = "ad-hoc-reserved-foreground-agent"

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try writeTerminalSessionFixture(
                sessionID: sessionID, workspace: workspace, kind: .shell,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:00Z", title: "shell-1", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"))
            try store.upsert(
                window: WindowRecord(
                    id: "terminal-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                    terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let promotedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)

            XCTAssertEqual(promotedAgent.label, "Codex-2")
            XCTAssertNoThrow(try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in })
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsPreservesConfiguredLauncherRowOnUnknownForeground() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
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
                    terminalTarget: TerminalTargetRecord(trackingID: sessionID), claimedLauncherName: "Codex", status: .idle, createdAt: "now",
                    updatedAt: "now"))

            XCTAssertFalse(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            let agents = try store.agentWindows(workspaceID: workspace.id)
            XCTAssertEqual(agents.map(\.id), ["agent-1"])
            XCTAssertEqual(agents.first?.claimedLauncherName, "Codex")
        }
    }

    func testReconcileTerminalForegroundAgentClassificationsSkipsConfiguredProcessSession() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(store: store)
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

    func testUpdateWorkspaceSettingsRejectsDuplicateFocusNamesAcrossProcessAndCodingAgent() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "Reviewer", command: "npm run review")]
                settings.agentLaunchers = [AgentLauncher(name: "reviewer", command: "codex --review")]
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
private final class AgentNotificationSubmitterRecorder: @unchecked Sendable {
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
        let orchestrator = WorkspaceOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

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

    /// A configured launcher's exit is finalized to `.done` WITH a recorded exit event. A later termination
    /// path — terminal teardown, workspace stop, or a sweep pass — must read that recorded fact and NOT
    /// re-notify, even though the row's status is `.done`, which a live launcher also carries between turns.
    func testLauncherExitFinalizeThenDestroyDoesNotReNotify() throws {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = WorkspaceOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "launcher-session", status: .spinning,
            claimedLauncherName: "Codex")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        // The launcher's exit hook finalizes the row to `.done` with a recorded exit event, notifying once.
        _ = try orchestrator.finalizeAgentRow(child, reason: .exited(eventType: "exit", eventSource: "spaces_agent_signal", environmentKeys: nil))
        XCTAssertEqual(try store.agentWindow(id: child.id)?.status, .done, "a configured launcher's exit is finalized to .done")
        XCTAssertTrue(try store.agentSessionHasRecordedExitEvent(agentSessionID: child.id), "the exit-finalization records the exit event")
        XCTAssertEqual(recorder.delivered.count, 1, "the exit is notified exactly once")

        // A later terminal-teardown/workspace-stop destroy must not re-notify the already-finalized launcher.
        let finalized = try XCTUnwrap(try store.agentWindow(id: child.id))
        try orchestrator.finalizeAgentRow(finalized, reason: .destroyed(terminateTerminalSession: false))

        XCTAssertNil(try store.agentWindow(id: child.id), "the destroy still deletes the row")
        XCTAssertEqual(recorder.delivered.count, 1, "no second exited notice for a launcher whose exit was already delivered")
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
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")

        let recorder = AgentNotificationSubmitterRecorder()
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { try recorder.submit($0, $1) }
        defer { WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter(nil) }
        let orchestrator = WorkspaceOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

        // Life 1: a configured launcher exits — the row is kept `.done` with a recorded exit event, and the
        // watcher (edge retained on a kept row) receives the first exited notice.
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "launcher-session", status: .spinning,
            claimedLauncherName: "Codex")
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")
        _ = try orchestrator.finalizeAgentRow(child, reason: .exited(eventType: "exit", eventSource: "spaces_agent_signal", environmentKeys: nil))
        XCTAssertEqual(try store.agentWindow(id: child.id)?.status, .done)
        XCTAssertTrue(try store.agentSessionHasRecordedExitEvent(agentSessionID: child.id), "life 1's exit is the finalized fact")
        XCTAssertEqual(recorder.delivered.count, 1, "life 1's exit is notified once")

        // Life 2: a fresh agent inits in the same terminal. The daemon init path re-registers the SAME row
        // (id preserved), passing the preserved existing status, and records an `init` event on it.
        let reincarnated = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "launcher-session",
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
        let orchestrator = WorkspaceOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .waiting)
        // A watcher terminal OUTSIDE the deleted project (a plain shell, no agent row of its own) is owed the exit.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-session", agentSessionID: child.id, createdAt: "t")

        // Failing-first: the store's bulk `agent_sessions` delete throws under RESTRICT while the watched row
        // still holds its inbound edge. The transaction rolls back, so the project remains intact.
        XCTAssertThrowsError(try store.deleteProject(id: project.id), "the bulk delete must fail loudly while a watched agent retains an inbound edge")
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
        let orchestrator = WorkspaceOrchestrator(store: store, builtInTerminalWindowCloser: { _ in }, builtInTerminalSessionTerminator: { _ in })

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
        let orchestrator = WorkspaceOrchestrator(store: store)
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
}
