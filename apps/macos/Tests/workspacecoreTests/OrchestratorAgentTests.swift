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
                id: "window-codex", workspaceID: workspace.id, app: "Spaces", name: "Codex", windowID: nil, terminalTrackingID: "session-codex",
                terminalNativeID: "session-codex", role: "terminal", orderIndex: 0, lastSeenAt: "now"))
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
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "old-session",
                codexThreadID: nil, status: .idle, createdAt: "now", updatedAt: "now"))
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
                codexThreadID: nil, status: .idle, createdAt: "now", updatedAt: "now"))
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
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "old-session",
                codexThreadID: nil, status: .idle, createdAt: "now", updatedAt: "now"))
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
            XCTAssertEqual(record.terminalTrackingID, record.terminalNativeID)
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
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "stale-session", terminalNativeID: "stale-session",
            status: .idle, claimedLauncherName: "Codex")

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            let record = try orchestrator.launchAgentLauncher(workspaceID: workspace.id, name: "Codex")
            XCTAssertEqual(record.label, "Codex")
            XCTAssertEqual(record.provider, .spaces)
            XCTAssertEqual(record.terminalTrackingID, record.terminalNativeID)
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
            workspaceID: workspace.id, provider: .spaces, label: "Mock Agent", terminalTrackingID: "session-a", terminalNativeID: "session-a",
            status: .idle, claimedLauncherName: "Mock Agent")

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "session-b", terminalNativeID: "session-b", label: "Mock Agent",
            status: .waiting)

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
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID,
                terminalNativeID: sessionID, codexThreadID: nil, status: .spinning, createdAt: "now", updatedAt: "now"))

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
        XCTAssertNil(windows.first?.windowID)
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
                id: "agent-1", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID,
                terminalNativeID: sessionID, codexThreadID: nil, status: .spinning, createdAt: "now", updatedAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: "agent-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "Codex", detail: nil, targetURL: nil,
                windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "process-session", terminalNativeID: "process-session", pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-1", workspaceID: childWorkspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "agent-session",
                terminalNativeID: "agent-session", codexThreadID: nil, status: .spinning, createdAt: "now", updatedAt: "now"))

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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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

    func testReconcileTerminalForegroundAgentClassificationsMarksExitedAdHocAgentSessionDone() throws {
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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            var agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(agent.id, "terminal-agent-\(sessionID)")
            XCTAssertEqual(agent.status, .idle)

            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .exited,
                    updatedAt: "2026-06-06T00:00:10Z", exitedAt: "2026-06-06T00:00:10Z", title: "codex", workingDirectory: workspace.dir),
                paths: paths)

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(agent.id, "terminal-agent-\(sessionID)")
            XCTAssertEqual(agent.status, .done)
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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: .spinning, eventSource: "spaces_signal")

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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: .spinning, eventSource: "spaces_signal")

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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: .spinning, eventSource: "spaces_signal")

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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
            let signalAgent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Custom Hook Agent", terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: .waiting, eventSource: "spaces_signal")

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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let detectedAgent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
            XCTAssertEqual(detectedAgent.id, "terminal-agent-\(sessionID)")
            XCTAssertEqual(detectedAgent.label, "Codex")

            let signaledAgent = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, terminalNativeID: sessionID, label: "Custom Hook Agent",
                status: .spinning, eventType: "start", eventSource: "spaces_signal")
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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).name, "shell-1")
            XCTAssertEqual(try XCTUnwrap(store.windows(workspaceID: workspace.id).first).detail, "codex --model gpt-5")

            let updated = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, codexThreadID: "thread-1", label: "Codex",
                status: .spinning)

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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
                        detail: nil, targetURL: nil, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal",
                        orderIndex: 200 + index, lastSeenAt: "now"))
            }

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            let labels = try store.agentWindows(workspaceID: workspace.id).compactMap(\.label)

            XCTAssertEqual(Set(labels), Set(["Codex", "Codex-2"]))
            XCTAssertNoThrow(try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in })
        }
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
                    windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))

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
                    terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                    startedAt: "now", exitedAt: nil))

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
                id: UUID().uuidString, workspaceID: workspace.id, app: "Spaces", title: "Claude Code", windowID: 501,
                terminalTrackingID: "workspace-session", role: "terminal", orderIndex: 201, lastSeenAt: "now"))
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .spaces, label: "Claude Code", terminalTrackingID: "workspace-session",
            codexThreadID: nil, status: .spinning, createdAt: "now", updatedAt: "now")
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
