import ArgumentParser
import Darwin
import Foundation
import XCTest
import spacesterminalcore
import spacesterminalghostty
import systembridge
import workspacecore

@testable import spacescli

final class SpacesCommandTests: XCTestCase {
    func testProjectListParses() throws { XCTAssertNoThrow(try ProjectListCommand.parse([])) }

    func testWorkspaceListParsesProjectFilter() throws {
        let command = try WorkspaceListCommand.parse(["--project", "project-1", "--include-archived"])

        XCTAssertEqual(command.project, "project-1")
        XCTAssertTrue(command.includeArchived)
    }

    func testWorkspaceCreateParsesExplicitHostScopedArguments() throws {
        let command = try WorkspaceCreateCommand.parse([
            "--project", "project-1", "--branch", "feature/a", "--host", "local", "--title", "Feature A", "--target-branch", "main",
            "--existing-branch",
        ])

        XCTAssertEqual(command.project, "project-1")
        XCTAssertEqual(command.branch, "feature/a")
        XCTAssertEqual(command.host, "local")
        XCTAssertEqual(command.title, "Feature A")
        XCTAssertEqual(command.targetBranch, "main")
        XCTAssertTrue(command.existingBranch)
    }

    func testWorkspaceStartParsesWorkspaceID() throws {
        let command = try WorkspaceStartCommand.parse(["--workspace", "workspace-1"])

        XCTAssertEqual(command.workspace, "workspace-1")
    }

    func testWorkspaceRestartParsesWorkspaceID() throws {
        let command = try WorkspaceRestartCommand.parse(["--workspace", "workspace-1"])

        XCTAssertEqual(command.workspace, "workspace-1")
    }

    func testAgentSignalParsesExplicitWorkspaceSessionAndEvent() throws {
        let command = try AgentSignalCommand.parse(["--workspace", "workspace-1", "--session", "session-1", "waiting"])

        XCTAssertEqual(command.workspace, "workspace-1")
        XCTAssertEqual(command.session, "session-1")
        XCTAssertEqual(command.type, .waiting)
    }

    func testTerminalListParses() throws { XCTAssertNoThrow(try TerminalListCommand.parse([])) }

    func testTerminalSessionRowsReturnsEmptyListWhenNoSessionsExist() { XCTAssertEqual(terminalSessionRows([]), []) }

    func testAvailableTerminalSessionRowsSkipsMetadataOnlySessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let paths = try TerminalSessionPaths.forSession(id: "session-stale")
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: "session-stale", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-05-12T00:00:00Z"), paths: paths)

        XCTAssertEqual(try availableTerminalSessionRows(), [])
    }

    func testAvailableTerminalSessionRowsIncludesLiveSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let paths = try TerminalSessionPaths.forSession(id: "session-live")
        let configuration = TerminalSessionLaunchConfiguration(
            sessionID: "session-live", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-05-12T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "session-live", backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
                updatedAt: "2026-05-12T00:00:01Z"), paths: paths)
        FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())

        let rows = try availableTerminalSessionRows()

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].hasPrefix("session-live\t"))
        XCTAssertTrue(rows[0].contains("state=running"))
        XCTAssertTrue(rows[0].contains("cwd=/tmp/work"))
        XCTAssertFalse(rows[0].contains("terminal\t"))
        XCTAssertFalse(rows[0].contains("title="))
        XCTAssertFalse(rows[0].contains("backend="))
        XCTAssertFalse(rows[0].contains("command="))
        XCTAssertFalse(rows[0].contains("owner="))
        XCTAssertFalse(rows[0].contains("clients="))
        XCTAssertFalse(rows[0].contains("viewers="))
    }

    func testTerminalCommandParsesOptions() throws {
        let command = try TerminalCommandCommand.parse(["--command", "cat", "--title", "session", "--cwd", "/tmp", "--backend", "ghostty-embedded"])

        XCTAssertEqual(command.command, "cat")
        XCTAssertEqual(command.title, "session")
        XCTAssertEqual(command.cwd, "/tmp")
        XCTAssertEqual(command.backend, .ghosttyEmbedded)
    }

    func testTerminalCommandLaunchConfigurationUsesPersistentLifetime() throws {
        let launchConfiguration = terminalCommandLaunchConfiguration(
            sessionID: "session-cli", backend: .ghosttyEmbedded, command: "cat", title: "session", cwd: "/tmp", shell: "/bin/sh",
            createdAt: "2026-05-26T00:00:00Z")

        XCTAssertEqual(launchConfiguration.lifetimePolicy, .persistent)
        XCTAssertEqual(launchConfiguration.sessionID, "session-cli")
        XCTAssertEqual(launchConfiguration.command, "cat")
        XCTAssertEqual(launchConfiguration.title, "session")
        XCTAssertEqual(launchConfiguration.workingDirectory, "/tmp")
        XCTAssertEqual(launchConfiguration.shell, "/bin/sh")
    }

    func testTerminalSendParsesSessionAndText() throws {
        let command = try TerminalSendCommand.parse(["session-1", "hello", "--newline"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.text, "hello")
        XCTAssertTrue(command.newline)
    }

    func testTerminalKeyParsesSessionAndKeySpec() throws {
        let command = try TerminalKeyCommand.parse(["session-1", "ctrl+c"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.key, "ctrl+c")
    }

    func testTerminalTailParsesDefaults() throws {
        let command = try TerminalTailCommand.parse(["session-1"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.lines, 20)
    }

    func testTerminalShowParsesSessionID() throws {
        let command = try TerminalShowCommand.parse(["session-1"])

        XCTAssertEqual(command.sessionID, "session-1")
    }

    func testTerminalTakeoverParsesSessionAndClient() throws {
        let command = try TerminalTakeoverCommand.parse(["session-1", "client-1"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.clientID, "client-1")
    }

    func testTerminalProxyParsesSessionHostPortAndAuthToken() throws {
        let command = try TerminalProxyCommand.parse(["session-1", "--host", "127.0.0.1", "--port", "9123", "--auth-token", "SECRET"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.host, "127.0.0.1")
        XCTAssertEqual(command.port, 9123)
        XCTAssertEqual(command.authToken, "SECRET")
    }

    func testSpacesCommandListsGroupedPublicVerbs() {
        let subcommands = SpacesCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(subcommands, ["ProjectCommand", "WorkspaceCommand", "AgentCommand", "TerminalCommand", "MCPCommand"])
    }

    func testMCPToolDefinitionsExposeExplicitSpacesOperations() throws {
        let tools = SpacesMCPStdioServer.toolDefinitions()
        let names = try tools.map { try XCTUnwrap($0["name"] as? String) }

        XCTAssertEqual(
            names,
            [
                "spaces_project_list", "spaces_workspace_list", "spaces_workspace_create", "spaces_workspace_start", "spaces_workspace_restart",
                "spaces_terminal_list", "spaces_terminal_tail", "spaces_terminal_send",
            ])
        XCTAssertFalse(names.contains("spaces_agent_signal"))

        let createTool = try XCTUnwrap(tools.first { ($0["name"] as? String) == "spaces_workspace_create" })
        let schema = try XCTUnwrap(createTool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["project", "branch", "host"])

        let tailTool = try XCTUnwrap(tools.first { ($0["name"] as? String) == "spaces_terminal_tail" })
        let tailSchema = try XCTUnwrap(tailTool["inputSchema"] as? [String: Any])
        XCTAssertEqual(tailSchema["required"] as? [String], ["session"])

        let sendTool = try XCTUnwrap(tools.first { ($0["name"] as? String) == "spaces_terminal_send" })
        let sendSchema = try XCTUnwrap(sendTool["inputSchema"] as? [String: Any])
        XCTAssertEqual(sendSchema["required"] as? [String], ["session"])
        let sendProperties = try XCTUnwrap(sendSchema["properties"] as? [String: Any])
        XCTAssertNotNil(sendProperties["bytes"])
        XCTAssertEqual(sendSchema["oneOf"] as? [[String: [String]]], [["required": ["text"]], ["required": ["bytes"]]])
    }

    private func captureStandardOutput(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let originalDescriptor = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(originalDescriptor, 0)
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try body()
            fflush(stdout)
            pipe.fileHandleForWriting.closeFile()
            dup2(originalDescriptor, STDOUT_FILENO)
            close(originalDescriptor)
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            fflush(stdout)
            pipe.fileHandleForWriting.closeFile()
            dup2(originalDescriptor, STDOUT_FILENO)
            close(originalDescriptor)
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
    }

    func testSignalRejectsUnknownEnumValue() {
        XCTAssertThrowsError(try SignalCommand.parse(["bogus"])) { error in
            let rendered = String(describing: error)
            XCTAssertTrue(rendered.contains("bogus") || rendered.contains("waiting"))
        }
    }

    func testAgentEventDropResultRejectsUntrackedSessionBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: ["__CFBundleIdentifier": "com.apple.Terminal"], context: context)

        XCTAssertEqual(result?.text, "Dropped agent event start: untracked Spaces terminal")
        XCTAssertEqual(result?.payload.message, "Dropped untracked Spaces agent event.")
    }

    func testAgentEventDropResultAcceptsTrackedSpacesSession() {
        let context = CLIContext()

        let result = agentEventDropResult(
            type: .start, environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1"], context: context)

        XCTAssertNil(result)
    }

    func testAgentEventDropResultRejectsUntrackedSpacesSessionBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: [:], context: context)

        XCTAssertEqual(result?.text, "Dropped agent event start: untracked Spaces terminal")
        XCTAssertEqual(result?.payload.message, "Dropped untracked Spaces agent event.")
    }

    func testResolveAgentInvocationContextDropsUnsupportedNonSpacesEvent() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id, environment: ["TERM_PROGRAM": "ghostty", "CLAUDE_CODE_ENTRYPOINT": "1"], orchestrator: orchestrator,
                context: context)

            XCTAssertNil(agentContext)
        }
    }

    func testResolveAgentInvocationContextUsesSpacesTrackingToken() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1", "CLAUDE_CODE_ENTRYPOINT": "1"],
                orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.terminalTrackingID, "spaces-session-token-1")
            XCTAssertEqual(agentContext?.terminalNativeID, "spaces-session-token-1")
            XCTAssertEqual(agentContext?.yabaiWindowID, 106482)
            XCTAssertEqual(agentContext?.environmentKeys, ["CLAUDE_CODE_ENTRYPOINT", "SPACES_TERMINAL_TRACKING_ID"])
        }
    }

    func testResolveAgentInvocationContextInfersCodexLabelFromManagedByNpmFallback() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: ["CODEX_MANAGED_BY_NPM": "1", WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1"],
                orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.label, "codex cli")
            XCTAssertEqual(agentContext?.codexThreadID, nil)
            XCTAssertEqual(agentContext?.environmentKeys, ["CODEX_MANAGED_BY_NPM", "SPACES_TERMINAL_TRACKING_ID"])
        }
    }

    func testResolveAgentInvocationContextInfersOpencodeLabelFromEnvironment() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: ["OPENCODE_EXPERIMENTAL_FILEWATCHER": "1", WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1"],
                orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.label, "opencode cli")
            XCTAssertEqual(agentContext?.codexThreadID, nil)
            XCTAssertEqual(agentContext?.environmentKeys, ["OPENCODE_EXPERIMENTAL_FILEWATCHER", "SPACES_TERMINAL_TRACKING_ID"])
        }
    }

    func testResolveAgentInvocationContextUsesExplicitAgentLabelOverride() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: [
                    WorkspaceOrchestrator.agentLabelEnvVar: "opencode", WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1",
                ], orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.label, "opencode")
            XCTAssertEqual(agentContext?.terminalTrackingID, "spaces-session-token-1")
            XCTAssertEqual(agentContext?.environmentKeys, ["SPACES_AGENT_LABEL", "SPACES_TERMINAL_TRACKING_ID"])
        }
    }

    func testResolveAgentInvocationContextUsesSpacesTrackingTokenForBuiltInTerminal() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1", "CLAUDE_CODE_ENTRYPOINT": "1"],
                orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.terminalTrackingID, "spaces-session-token-1")
            XCTAssertEqual(agentContext?.terminalNativeID, "spaces-session-token-1")
            XCTAssertEqual(agentContext?.yabaiWindowID, 106482)
        }
    }

    func testResolveAgentInvocationContextDropsEventWithoutTrackingIdentity() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id, environment: ["CLAUDE_CODE_ENTRYPOINT": "1"], orchestrator: orchestrator, context: context)

            XCTAssertNil(agentContext)
        }
    }

    func testSignalStartIgnoresMissingAgentRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)

        var output = ""
        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: "signal-start-without-init") {
            try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
                output = try captureStandardOutput {
                    let command = try SignalCommand.parse(["start", workspace.dir])
                    try command.run()
                }
            }
        }

        XCTAssertTrue(output.contains("Ignored agent start: no active agent row"))
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
    }

    func testSignalExitIgnoresTrackedSpacesTerminalWithoutAgentRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)

        var output = ""
        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: "signal-exit-without-agent") {
            try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
                output = try captureStandardOutput {
                    let command = try SignalCommand.parse(["exit", workspace.dir])
                    try command.run()
                }
            }
        }

        XCTAssertTrue(output.contains("Ignored agent exit: no active agent row"))
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
    }

    func testSignalExitReportsRecordedWhenAdHocAgentRowIsDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)
        let sessionID = "signal-exit-deletes-agent"
        let orchestrator = WorkspaceOrchestrator(store: store)
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID, terminalNativeID: sessionID, status: .done)

        var output = ""
        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: sessionID) {
            try withMockCommands(["yabai": Self.failingYabaiMock]) {
                output = try captureStandardOutput {
                    let command = try SignalCommand.parse(["exit", workspace.dir])
                    try command.run()
                }
            }
        }

        XCTAssertTrue(output.contains("Agent exit: workspace=\(workspace.id)"))
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
    }

    func testSignalExitDeletesAdHocAgentWhenRuntimeLabelMatchesConfiguredLauncher() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        let sessionID = "signal-exit-runtime-label-reserved-by-launcher"
        let orchestrator = WorkspaceOrchestrator(store: store)
        let adHocAgent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID, terminalNativeID: sessionID, status: .done)
        XCTAssertEqual(adHocAgent.label, "Codex-2")
        XCTAssertNil(adHocAgent.claimedLauncherName)

        var output = ""
        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: sessionID) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "shell", workingDirectory: workspace.dir, shell: "/bin/zsh", command: nil,
                    createdAt: "2026-06-06T00:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:01Z", title: "shell", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"), paths: paths)
            try withMockCommands(["yabai": Self.failingYabaiMock]) {
                output = try captureStandardOutput {
                    let command = try SignalCommand.parse(["exit", workspace.dir])
                    try command.run()
                }
            }
        }

        XCTAssertTrue(output.contains("Agent exit: workspace=\(workspace.id)"))
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
    }

    func testSignalStartUpdatesExistingAgentRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)

        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: "signal-start-after-init", label: "Custom Hook Agent") {
            try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
                _ = try captureStandardOutput {
                    let command = try SignalCommand.parse(["init", workspace.dir])
                    try command.run()
                }
                _ = try captureStandardOutput {
                    let command = try SignalCommand.parse(["start", workspace.dir])
                    try command.run()
                }
            }
        }

        let agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(agent.label, "Custom Hook Agent")
        XCTAssertEqual(agent.status, .spinning)
        XCTAssertEqual(agent.terminalTrackingID, "signal-start-after-init")
    }

    func testSignalStartWithExplicitLabelCreatesAgentRowWithoutInit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)

        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: "signal-start-custom-agent", label: "Custom Hook Agent") {
            try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
                _ = try captureStandardOutput {
                    let command = try SignalCommand.parse(["start", workspace.dir])
                    try command.run()
                }
            }
        }

        let agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(agent.label, "Custom Hook Agent")
        XCTAssertEqual(agent.status, .spinning)
        XCTAssertEqual(agent.terminalTrackingID, "signal-start-custom-agent")
    }

    func testSignalInitDoesNotDowngradeExistingStartedAgentRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)

        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: "signal-start-before-init", label: "Custom Hook Agent") {
            try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
                _ = try captureStandardOutput {
                    let command = try SignalCommand.parse(["start", workspace.dir])
                    try command.run()
                }
                _ = try captureStandardOutput {
                    let command = try SignalCommand.parse(["init", workspace.dir])
                    try command.run()
                }
            }
        }

        let agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(agent.label, "Custom Hook Agent")
        XCTAssertEqual(agent.status, .spinning)
        XCTAssertEqual(agent.terminalTrackingID, "signal-start-before-init")
    }

    func testSignalStartUsesForegroundRuntimeAgentBeforeMonitorPromotesRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)
        let sessionID = "signal-start-runtime-agent"

        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: sessionID) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "shell", workingDirectory: workspace.dir, shell: "/bin/zsh", command: nil,
                    createdAt: "2026-06-06T00:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:01Z", title: "shell", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"), paths: paths)
            try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
                _ = try captureStandardOutput {
                    let command = try SignalCommand.parse(["start", workspace.dir])
                    try command.run()
                }
            }
        }

        let agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(agent.label, "Codex")
        XCTAssertEqual(agent.status, .spinning)
        XCTAssertEqual(agent.terminalTrackingID, sessionID)
    }

    func testSignalStartRuntimeLabelMatchingConfiguredLauncherCreatesAdHocRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: [AgentLauncher(name: "Codex", command: "codex")])
        let orchestrator = WorkspaceOrchestrator(store: store)
        let configuredAgent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "configured-codex-session",
            terminalNativeID: "configured-codex-session", status: .waiting, claimedLauncherName: "Codex")
        let adHocSessionID = "signal-start-runtime-label-configured-launcher"

        var output = ""
        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: adHocSessionID) {
            let paths = try TerminalSessionPaths.forSession(id: adHocSessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: adHocSessionID, backend: .ghosttyEmbedded, title: "shell", workingDirectory: workspace.dir, shell: "/bin/zsh",
                    command: nil, createdAt: "2026-06-06T00:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: adHocSessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:01Z", title: "shell", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/codex", foregroundExecutableName: "codex", foregroundArgv: ["codex"],
                    foregroundDetectedAgentKind: .codex, foregroundDisplayLabel: "Codex", foregroundDisplayCommand: "codex"), paths: paths)
            try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
                output = try captureStandardOutput {
                    let command = try SignalCommand.parse(["start", workspace.dir])
                    try command.run()
                }
            }
        }

        XCTAssertTrue(output.contains("Agent start: workspace=\(workspace.id)"))
        let configuredAfterSignal = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first { $0.id == configuredAgent.id })
        let adHocAgent = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first { $0.id != configuredAgent.id })
        XCTAssertEqual(configuredAfterSignal.label, "Codex")
        XCTAssertEqual(configuredAfterSignal.terminalTrackingID, "configured-codex-session")
        XCTAssertEqual(configuredAfterSignal.status, .waiting)
        XCTAssertEqual(adHocAgent.label, "Codex-2")
        XCTAssertEqual(adHocAgent.terminalTrackingID, adHocSessionID)
        XCTAssertEqual(adHocAgent.status, .spinning)
        XCTAssertNil(adHocAgent.claimedLauncherName)
    }

    func testSignalStartRefreshesStaleExistingLabelFromRuntimeAgent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let workspace = try makeWorkspace(store: store)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)
        let orchestrator = WorkspaceOrchestrator(store: store)
        let sessionID = "signal-start-stale-label-runtime-agent"
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: sessionID, terminalNativeID: sessionID, status: .idle)

        try withAgentSignalEnvironment(dbPath: dbPath, sessionID: sessionID) {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "shell", workingDirectory: workspace.dir, shell: "/bin/zsh", command: nil,
                    createdAt: "2026-06-06T00:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                    updatedAt: "2026-06-06T00:00:01Z", title: "shell", workingDirectory: workspace.dir, foregroundPID: 123,
                    foregroundExecutablePath: "/opt/homebrew/bin/claude", foregroundExecutableName: "claude", foregroundArgv: ["claude"],
                    foregroundDetectedAgentKind: .claude, foregroundDisplayLabel: "Claude", foregroundDisplayCommand: "claude"), paths: paths)
            try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
                _ = try captureStandardOutput {
                    let command = try SignalCommand.parse(["start", workspace.dir])
                    try command.run()
                }
            }
        }

        let agent = try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(agent.label, "Claude")
        XCTAssertEqual(agent.status, .spinning)
        XCTAssertEqual(agent.terminalTrackingID, sessionID)
    }

    private func makeTemporaryStore() throws -> SQLiteStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStore(path: directory.appendingPathComponent("spaces.db").path)
    }

    private func makeWorkspace(store: SQLiteStore) throws -> WorkspaceRecord {
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = ProjectRecord(
            id: UUID().uuidString, name: "TestProject", dir: projectDir.path, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil,
            ports: [], processes: [], browserSessions: [])
        try store.upsert(project: project)
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: "default", dir: projectDir.appendingPathComponent("default", isDirectory: true).path,
            dirname: nil, branch: nil, isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        return workspace
    }

    private func withAgentSignalEnvironment<T>(dbPath: String, sessionID: String, label: String? = nil, run: () throws -> T) throws -> T {
        let values: [String: String?] = [
            "SPACES_DB_PATH": dbPath, WorkspaceOrchestrator.terminalTrackingIDEnvVar: sessionID, WorkspaceOrchestrator.agentLabelEnvVar: label,
            "CODEX_THREAD_ID": nil, "CODEX_MANAGED_BY_NPM": nil, "CLAUDE_CODE_ENTRYPOINT": nil, "OPENCODE_EXPERIMENTAL_FILEWATCHER": nil,
        ]
        return try withEnv(values, run: run)
    }

    private func withEnv<T>(_ values: [String: String?], run: () throws -> T) throws -> T {
        let previousValues = Dictionary(uniqueKeysWithValues: values.keys.map { name in (name, getenv(name).map { String(cString: $0) }) })
        for (name, value) in values { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
        defer { for (name, value) in previousValues { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        return try run()
    }

    private static let yabaiFocusedWindowMock = """
        #!/bin/bash
        if [[ "$1 $2 $3 $4" == "-m query --windows --window" ]]; then
          echo '{"id":106482,"pid":123,"app":"Ghostty","title":"✳ Claude Code","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}'
          exit 0
        fi
        exit 1
        """

    private static let failingYabaiMock = """
        #!/bin/bash
        exit 1
        """

}
