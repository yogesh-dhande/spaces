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

    func testAgentSignalParsesEventWithoutExplicitContext() throws {
        let command = try AgentSignalCommand.parse(["done"])

        XCTAssertNil(command.workspace)
        XCTAssertNil(command.session)
        XCTAssertEqual(command.type, .done)
    }

    func testAgentSignalResolvesContextFromEnvironment() throws {
        let context = try AgentSignalCommand.resolvedSignalContext(
            workspace: nil, session: nil, environment: ["SPACES_WORKSPACE_ID": "workspace-env", "SPACES_TERMINAL_TRACKING_ID": "session-env"])

        XCTAssertEqual(context?.workspaceID, "workspace-env")
        XCTAssertEqual(context?.sessionID, "session-env")
    }

    func testAgentSignalExplicitContextOverridesEnvironment() throws {
        let context = try AgentSignalCommand.resolvedSignalContext(
            workspace: "workspace-explicit", session: "session-explicit",
            environment: ["SPACES_WORKSPACE_ID": "workspace-env", "SPACES_TERMINAL_TRACKING_ID": "session-env"])

        XCTAssertEqual(context?.workspaceID, "workspace-explicit")
        XCTAssertEqual(context?.sessionID, "session-explicit")
    }

    /// Outside a Spaces terminal, a hook that fires anyway must do nothing rather than fail.
    func testAgentSignalMissingContextIsNoOp() throws {
        XCTAssertNil(try AgentSignalCommand.resolvedSignalContext(workspace: nil, session: nil, environment: [:]))
    }

    /// Naming one ID and not the other is a caller mistake, not "outside a Spaces terminal".
    func testAgentSignalHalfSuppliedExplicitContextIsAnError() {
        XCTAssertThrowsError(try AgentSignalCommand.resolvedSignalContext(workspace: "workspace-explicit", session: nil, environment: [:]))
        XCTAssertThrowsError(try AgentSignalCommand.resolvedSignalContext(workspace: nil, session: "session-explicit", environment: [:]))
    }

    /// An explicit ID still combines with the environment for the other half.
    func testAgentSignalExplicitWorkspaceCombinesWithEnvironmentSession() throws {
        let context = try AgentSignalCommand.resolvedSignalContext(
            workspace: "workspace-explicit", session: nil, environment: ["SPACES_TERMINAL_TRACKING_ID": "session-env"])

        XCTAssertEqual(context?.workspaceID, "workspace-explicit")
        XCTAssertEqual(context?.sessionID, "session-env")
    }

    /// Signal, plus the read/annotate orchestration surface. Hook installation and status stay owned by
    /// the app and the daemon, never the CLI or MCP.
    func testAgentCommandExposesSignalAndOrchestrationCommands() {
        let subcommands = AgentCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(subcommands, ["AgentSignalCommand", "AgentListCommand", "AgentStatusCommand", "AgentAnnotateCommand"])
        XCTAssertThrowsError(try AgentCommand.parseAsRoot(["hooks", "status"]))
    }

    func testTerminalListParses() throws { XCTAssertNoThrow(try TerminalListCommand.parse([])) }

    func testTerminalCommandsParseDeviceSelector() throws {
        XCTAssertEqual(try TerminalListCommand.parse(["--device", "linux-box"]).device, "linux-box")
        let send = try TerminalSendTextCommand.parse(["session-1", "echo hi", "--newline", "--device", "linux-box"])
        XCTAssertEqual(send.sessionID, "session-1")
        XCTAssertEqual(send.text, "echo hi")
        XCTAssertTrue(send.newline)
        XCTAssertEqual(send.device, "linux-box")
        let bytes = try TerminalSendBytesCommand.parse(["session-1", "3", "13", "--device", "linux-box"])
        XCTAssertEqual(bytes.sessionID, "session-1")
        XCTAssertEqual(bytes.bytes.map(\.value), [3, 13])
        XCTAssertEqual(bytes.device, "linux-box")
        let tail = try TerminalTailCommand.parse(["session-1", "--lines", "40", "--device", "linux-box"])
        XCTAssertEqual(tail.lines, 40)
        XCTAssertEqual(tail.device, "linux-box")
    }

    func testDevicePairSourceRules() throws {
        // No source opens a pairing window on this device (optionally as JSON).
        XCTAssertNoThrow(try DevicePairCommand.parse([]))
        XCTAssertTrue(try DevicePairCommand.parse(["--json"]).json)
        // A source pairs this client with another device.
        XCTAssertEqual(try DevicePairCommand.parse(["--link", "spaces://pair"]).link, "spaces://pair")
        XCTAssertEqual(try DevicePairCommand.parse(["--ssh", "user@host"]).ssh, "user@host")
        XCTAssertNoThrow(try DevicePairCommand.parse(["--ssh", "user@host", "--ssh-port", "2222"]))
        // --ssh and --link are mutually exclusive; --ssh-port requires --ssh; --json is window-only.
        XCTAssertThrowsError(try DevicePairCommand.parse(["--ssh", "user@host", "--link", "spaces://pair"]))
        XCTAssertThrowsError(try DevicePairCommand.parse(["--link", "spaces://pair", "--ssh-port", "2222"]))
        XCTAssertThrowsError(try DevicePairCommand.parse(["--json", "--link", "spaces://pair"]))
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
                command: "cat", createdAt: "2026-05-12T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

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
            createdAt: "2026-05-12T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
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
        let command = try TerminalCommandCommand.parse(["--command", "cat", "--title", "session", "--workspace", "workspace-1"])

        XCTAssertEqual(command.command, "cat")
        XCTAssertEqual(command.title, "session")
        XCTAssertEqual(command.workspace, "workspace-1")
    }

    func testTerminalCommandParsesWithoutExplicitWorkspace() throws {
        let command = try TerminalCommandCommand.parse(["--command", "cat"])

        XCTAssertEqual(command.command, "cat")
        XCTAssertNil(command.workspace)
    }

    func testTerminalSendTextParsesSessionAndText() throws {
        let command = try TerminalSendTextCommand.parse(["session-1", "hello", "--newline"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.text, "hello")
        XCTAssertTrue(command.newline)
    }

    func testTerminalSendBytesParsesDecimalBytes() throws {
        let command = try TerminalSendBytesCommand.parse(["session-1", "3", "27", "91", "65", "255"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.bytes.map(\.value), [3, 27, 91, 65, 255])
    }

    func testTerminalSendBytesRejectsMissingAndInvalidPayloads() {
        XCTAssertThrowsError(try TerminalSendBytesCommand.parse(["session-1"]))
        XCTAssertThrowsError(try TerminalSendBytesCommand.parse(["session-1", "256"]))
        XCTAssertThrowsError(try TerminalSendBytesCommand.parse(["session-1", "-1"]))
        XCTAssertThrowsError(try TerminalSendBytesCommand.parse(["session-1", "0x03"]))
        XCTAssertThrowsError(try TerminalSendBytesCommand.parse(["session-1", "abc"]))
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

    func testTerminalCommandPublicSubcommands() {
        let subcommands = TerminalCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(
            subcommands, ["TerminalListCommand", "TerminalCommandCommand", "TerminalSendCommand", "TerminalTailCommand", "TerminalShowCommand"])
    }

    func testRemovedTerminalCommandsAndFormsAreUnavailable() {
        XCTAssertThrowsError(try TerminalCommand.parse(["key", "session-1", "ctrl+c"]))
        XCTAssertThrowsError(try TerminalCommand.parse(["takeover", "session-1", "client-1"]))
        XCTAssertThrowsError(try TerminalCommand.parse(["proxy", "session-1", "--auth-token", "SECRET"]))
        XCTAssertThrowsError(try TerminalCommand.parse(["send", "session-1", "hello"]))
    }

    func testPairCommandLinesUseSpacesScheme() throws {
        let window = SpacesDevicePairingWindowSnapshot(
            window: SpacesDevicePairingCoordinator().openWindow(
                host: "studio.local", port: 7443, certificateFingerprint: "SHA256:abc", name: "Studio", protocolVersion: 5, appVersion: "0.1.0",
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
                host: "studio.local", port: 7443, certificateFingerprint: "SHA256:abc", name: "Studio", protocolVersion: 5, appVersion: "0.1.0",
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
        // The SSH pairing path reads these from the JSON to run the compatibility gate.
        XCTAssertEqual(payload.protocolVersion, 5)
        XCTAssertEqual(payload.appVersion, "0.1.0")
    }

    func testSpacesCommandListsGroupedPublicVerbs() {
        let subcommands = SpacesCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(
            subcommands, ["ProjectCommand", "WorkspaceCommand", "AgentCommand", "TerminalCommand", "DeviceCommand", "DaemonCommand", "MCPCommand"])
    }

    func testDaemonApplyUpdateParses() throws { XCTAssertNoThrow(try DaemonApplyUpdateCommand.parse([])) }

    func testDaemonApplyUpdateFailsClearlyWhenDaemonNotRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalRuntimeDir = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, root.path, 1)
        defer {
            if let originalRuntimeDir {
                setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimeDir, 1)
            } else {
                unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            }
        }

        var command = try DaemonApplyUpdateCommand.parse([])
        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue("\(error)".contains("spacesd is not running"), "expected a not-running error, got \(error)")
        }
    }

    func testMCPToolDefinitionsExposeExplicitSpacesOperations() throws {
        let tools = SpacesMCPStdioServer.toolDefinitions()
        let names = try tools.map { try XCTUnwrap($0["name"] as? String) }

        XCTAssertEqual(
            names,
            [
                "spaces_project_list", "spaces_workspace_list", "spaces_workspace_create", "spaces_workspace_start", "spaces_workspace_restart",
                "spaces_terminal_list", "spaces_terminal_tail", "spaces_terminal_send", "spaces_agent_list", "spaces_agent_status",
                "spaces_agent_annotate", "spaces_device_list",
            ])
        // `agent signal` is CLI-only forever: an orchestrating agent may read peers' status but must not forge it.
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

    func testMCPTerminalInputMapsTextAndBytesToTypedInput() throws {
        let server = SpacesMCPStdioServer()
        XCTAssertEqual(try server.terminalInputPayload(from: ["text": ""]), .text(""))
        XCTAssertEqual(try server.terminalInputPayload(from: ["text": "hello"]), .text("hello"))
        XCTAssertEqual(try server.terminalInputPayload(from: ["bytes": [0, 10, 255]]), .bytes(Data([0, 10, 255])))
    }

    func testMCPTerminalInputRejectsMissingAndBothArguments() {
        let server = SpacesMCPStdioServer()
        XCTAssertThrowsError(try server.terminalInputPayload(from: [:])) { error in
            XCTAssertEqual(error.localizedDescription, "text or bytes is required.")
        }
        XCTAssertThrowsError(try server.terminalInputPayload(from: ["text": "hi", "bytes": [1]])) { error in
            XCTAssertEqual(error.localizedDescription, "Provide text or bytes, not both.")
        }
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
