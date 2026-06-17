import ArgumentParser
import Darwin
import Foundation
import XCTest
import spacesterminalcore
import spacesterminalghostty

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
        XCTAssertEqual(subcommands, ["ProjectCommand", "WorkspaceCommand", "AgentCommand", "TerminalCommand", "MobileCommand", "MCPCommand"])
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

    func testAgentSignalRejectsUnknownEnumValue() {
        XCTAssertThrowsError(try AgentSignalCommand.parse(["--workspace", "workspace-1", "--session", "session-1", "bogus"])) { error in
            let rendered = String(describing: error)
            XCTAssertTrue(rendered.contains("bogus") || rendered.contains("waiting"))
        }
    }

    func testSpacesCommandRejectsLegacyRootVerbs() {
        for verb in ["import", "update", "start", "restart", "signal"] {
            XCTAssertThrowsError(try SpacesCommand.parse([verb]), "Expected root verb \(verb) to be unavailable")
        }
    }
}
