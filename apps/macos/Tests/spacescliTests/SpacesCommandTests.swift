import ArgumentParser
import Darwin
import Foundation
import XCTest
import spacesdeviceapi
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

    func testWorkspaceCreateParsesDeviceScopedArguments() throws {
        let command = try WorkspaceCreateCommand.parse([
            "--project", "project-1", "--branch", "feature/a", "--base-branch", "main", "--existing-branch",
        ])

        XCTAssertEqual(command.project, "project-1")
        XCTAssertEqual(command.branch, "feature/a")
        XCTAssertEqual(command.baseBranch, "main")
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
        let command = try AgentSignalCommand.parse(["--workspace", "workspace-1", "--session", "session-1", "blocked"])

        XCTAssertEqual(command.workspace, "workspace-1")
        XCTAssertEqual(command.session, "session-1")
        XCTAssertEqual(command.type, .blocked)
    }

    func testTerminalListParses() throws { XCTAssertNoThrow(try TerminalListCommand.parse([])) }

    func testTerminalCommandsParseDeviceSelector() throws {
        XCTAssertEqual(try TerminalListCommand.parse(["--device", "linux-box"]).device, "linux-box")
        let send = try TerminalSendCommand.parse(["session-1", "echo hi", "--newline", "--device", "linux-box"])
        XCTAssertEqual(send.sessionID, "session-1")
        XCTAssertEqual(send.text, "echo hi")
        XCTAssertTrue(send.newline)
        XCTAssertEqual(send.device, "linux-box")
        let tail = try TerminalTailCommand.parse(["session-1", "--lines", "40", "--device", "linux-box"])
        XCTAssertEqual(tail.lines, 40)
        XCTAssertEqual(tail.device, "linux-box")
    }

    func testDevicePairRequiresExactlyOneSource() throws {
        XCTAssertThrowsError(try DevicePairCommand.parse([]))
        XCTAssertThrowsError(try DevicePairCommand.parse(["--ssh", "user@host", "--link", "spaces://pair?v=2"]))
        XCTAssertThrowsError(try DevicePairCommand.parse(["--link", "spaces://pair?v=2", "--ssh-port", "2222"]))
        XCTAssertNoThrow(try DevicePairCommand.parse(["--ssh", "user@host", "--ssh-port", "2222"]))
        XCTAssertNoThrow(try DevicePairCommand.parse(["--link", "spaces://pair?v=2"]))
    }

    func testDevicePairParsesSSHDestination() {
        XCTAssertEqual(DevicePairCommand.parsedSSHDestination("yogesh@build-box").user, "yogesh")
        XCTAssertEqual(DevicePairCommand.parsedSSHDestination("yogesh@build-box").host, "build-box")
        XCTAssertNil(DevicePairCommand.parsedSSHDestination("build-box").user)
        XCTAssertEqual(DevicePairCommand.parsedSSHDestination("build-box").host, "build-box")
    }

    func testDeviceRemoveParsesSelector() throws { XCTAssertEqual(try DeviceRemoveCommand.parse(["linux-box"]).device, "linux-box") }

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

    func testPairCommandParses() throws {
        XCTAssertNoThrow(try PairCommand.parse([]))
        XCTAssertTrue(try PairCommand.parse(["--json"]).json)
    }

    func testPairCommandLinesUseSpacesScheme() throws {
        let window = SpacesDevicePairingWindowSnapshot(
            window: SpacesDevicePairingCoordinator().openWindow(
                host: "studio.local", port: 7443, certificateFingerprint: "SHA256:abc", name: "Studio",
                now: Date(timeIntervalSince1970: 1_782_000_000), duration: 300, code: "12345678", nonce: "N"))
        let lines = try pairCommandLines {
            SpacesDeviceAPIControlResponse(ok: true, message: "ok", result: .pairingWindow(.init(pairingWindow: window)))
        }

        XCTAssertEqual(lines[0], "Spaces pairing window")
        XCTAssertEqual(lines[1], "link=\(window.linkString)")
        XCTAssertTrue(lines[1].contains("spaces://pair?"))
        XCTAssertEqual(lines[2], "code=12345678")
        XCTAssertTrue(lines[3].hasPrefix("expires_at="))
    }

    func testPairCommandJSONPayloadUsesDeviceMetadata() throws {
        let window = SpacesDevicePairingWindowSnapshot(
            window: SpacesDevicePairingCoordinator().openWindow(
                host: "studio.local", port: 7443, certificateFingerprint: "SHA256:abc", name: "Studio",
                now: Date(timeIntervalSince1970: 1_782_000_000), duration: 300, code: "12345678", nonce: "N"))

        let payload = try pairCommandPayload {
            SpacesDeviceAPIControlResponse(ok: true, message: "ok", result: .pairingWindow(.init(pairingWindow: window)))
        }

        XCTAssertEqual(payload.name, "Studio")
        XCTAssertEqual(payload.host, "studio.local")
        XCTAssertEqual(payload.port, 7443)
        XCTAssertEqual(payload.pairingCode, "12345678")
        XCTAssertEqual(payload.pairingNonce, "N")
        XCTAssertEqual(payload.certificateFingerprint, "SHA256:abc")
        XCTAssertEqual(payload.pairingLink, window.linkString)
    }

    func testSpacesCommandListsGroupedPublicVerbs() {
        let subcommands = SpacesCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(
            subcommands,
            ["ProjectCommand", "WorkspaceCommand", "AgentCommand", "TerminalCommand", "DeviceCommand", "PairCommand", "MobileCommand", "MCPCommand"])
    }

    func testMCPToolDefinitionsExposeExplicitSpacesOperations() throws {
        let tools = SpacesMCPStdioServer.toolDefinitions()
        let names = try tools.map { try XCTUnwrap($0["name"] as? String) }

        XCTAssertEqual(
            names,
            [
                "spaces_project_list", "spaces_workspace_list", "spaces_workspace_create", "spaces_workspace_start", "spaces_workspace_restart",
                "spaces_terminal_list", "spaces_terminal_tail", "spaces_terminal_send", "spaces_device_list",
            ])
        XCTAssertFalse(names.contains("spaces_agent_signal"))

        let createTool = try XCTUnwrap(tools.first { ($0["name"] as? String) == "spaces_workspace_create" })
        let schema = try XCTUnwrap(createTool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["project", "branch"])

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
            XCTAssertTrue(rendered.contains("bogus") || rendered.contains("blocked"))
        }
    }

    func testSpacesCommandRejectsLegacyRootVerbs() {
        for verb in ["import", "update", "start", "restart", "signal"] {
            XCTAssertThrowsError(try SpacesCommand.parse([verb]), "Expected root verb \(verb) to be unavailable")
        }
    }
}
