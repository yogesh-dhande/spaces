import ArgumentParser
import Darwin
import Foundation
import XCTest
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty

@testable import spacescli
@testable import spacesclientcore

final class SpacesCommandTests: XCTestCase {
    func testProjectListParses() throws { XCTAssertNoThrow(try ProjectListCommand.parse([])) }

    func testDiscoveryAndLifecycleCommandsParseDeviceSelector() throws {
        XCTAssertEqual(try ProjectListCommand.parse(["--device", "phone"]).device, "phone")
        XCTAssertEqual(try WorkspaceListCommand.parse(["--device", "phone"]).device, "phone")
        XCTAssertEqual(try WorkspaceCreateCommand.parse(["--project", "project-1", "--branch", "feature/a", "--device", "phone"]).device, "phone")
        XCTAssertEqual(try WorkspaceStartCommand.parse(["--workspace", "workspace-1", "--device", "phone"]).device, "phone")
        XCTAssertEqual(try WorkspaceRestartCommand.parse(["--workspace", "workspace-1", "--device", "phone"]).device, "phone")
    }

    func testWorkspaceListParsesProjectFilter() throws {
        let command = try WorkspaceListCommand.parse(["--project", "project-1"])

        XCTAssertEqual(command.project, "project-1")
    }

    func testProjectListRowRendersColumnsFromLocalAndDeviceSummaries() {
        let local = TerminalServiceProfileProjectSummary(
            id: "project-1", name: "Spaces", dir: "/repos/spaces", isGitRepo: true, defaultBranch: "main")
        let remote = SpacesDeviceProjectSummary(id: "project-1", name: "Spaces", dir: "/repos/spaces", isGitRepo: true, defaultBranch: "main")

        let expected = "project-1\tname=Spaces\tdir=/repos/spaces"
        XCTAssertEqual(projectListRow(local), expected)
        XCTAssertEqual(projectListRow(remote), expected)
    }

    func testWorkspaceListRowRendersColumnsFromLocalAndDeviceSummaries() {
        let local = TerminalServiceProfileWorkspaceRecord(
            id: "workspace-1", projectID: "project-1", dir: "/repos/spaces/ws", dirname: nil, branch: "feature", baseBranch: "main", isDefault: false,
            isHidden: false, isRunning: true, lastLaunchedAt: nil, notes: nil)
        let remote = SpacesDeviceWorkspaceSummary(
            id: "workspace-1", projectID: "project-1", projectName: "Spaces", branch: "feature", baseBranch: "main", dir: "/repos/spaces/ws",
            isRunning: true, isHidden: false, isDefault: false, sessionCount: 0)

        let expected = "workspace-1\tproject=project-1\tbranch=feature\trunning=true\tname=feature"
        XCTAssertEqual(workspaceListRow(local), expected)
        XCTAssertEqual(workspaceListRow(remote), expected)
    }

    func testWorkspaceListRowRendersFolderNameAndDashForNonGitWorkspace() {
        let remote = SpacesDeviceWorkspaceSummary(
            id: "workspace-2", projectID: "project-2", projectName: "Tools", branch: nil, baseBranch: nil, dir: "/repos/tools", isRunning: false,
            isHidden: false, isDefault: true, sessionCount: 0)

        XCTAssertEqual(workspaceListRow(remote), "workspace-2\tproject=project-2\tbranch=-\trunning=false\tname=tools")
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

    func testWorkspaceStartAndRestartParseWithoutWorkspaceID() throws {
        XCTAssertNil(try WorkspaceStartCommand.parse([]).workspace)
        XCTAssertNil(try WorkspaceRestartCommand.parse([]).workspace)
    }

    func testRemoteWorkspaceLifecycleRequiresExplicitWorkspaceBeforeDeviceLookup() throws {
        XCTAssertThrowsError(try requiredRemoteWorkspaceID(nil)) { error in
            XCTAssertTrue("\(error)".contains("--workspace is required with --device"))
            XCTAssertTrue("\(error)".contains("Pass --workspace <id>"))
        }
        XCTAssertThrowsError(try requiredRemoteWorkspaceID("  "))
        XCTAssertEqual(try requiredRemoteWorkspaceID("  workspace-1  "), "workspace-1")

        let start = try WorkspaceStartCommand.parse(["--device", "missing-device"])
        XCTAssertThrowsError(try start.run()) { error in XCTAssertTrue("\(error)".contains("--workspace is required with --device")) }
        let restart = try WorkspaceRestartCommand.parse(["--device", "missing-device"])
        XCTAssertThrowsError(try restart.run()) { error in XCTAssertTrue("\(error)".contains("--workspace is required with --device")) }
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
        XCTAssertEqual(
            subcommands,
            [
                "AgentSignalCommand", "AgentListCommand", "AgentStatusCommand", "AgentAnnotateCommand", "AgentSpawnCommand", "AgentKillCommand",
                "AgentSubscribeCommand", "AgentUnsubscribeCommand",
            ])
        XCTAssertThrowsError(try AgentCommand.parseAsRoot(["hooks", "status"]))
    }

    func testTerminalListParses() throws { XCTAssertNoThrow(try TerminalListCommand.parse([])) }

    func testTerminalCommandsParseDeviceSelector() throws {
        XCTAssertEqual(try TerminalListCommand.parse(["--device", "linux-box"]).device, "linux-box")
        let send = try TerminalSendTextCommand.parse(["session-1", "echo hi", "--submit", "--device", "linux-box"])
        XCTAssertEqual(send.sessionID, "session-1")
        XCTAssertEqual(send.text, "echo hi")
        XCTAssertTrue(send.submit)
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

    func testDevicePairAutoInstallsOnlyWhenTheFailureCarriesAnInstallCommand() {
        let linuxFailure = SpacesRemoteDevicePairingError.remoteSpacesNotInstalled(
            message: "Spaces is not installed on build-box.", linuxInstallCommand: "curl -fsSL https://usespaces.dev/install.sh | bash -s -- 1.2.3")
        XCTAssertEqual(
            DevicePairCommand.automaticInstallCommand(forPairingFailure: linuxFailure),
            "curl -fsSL https://usespaces.dev/install.sh | bash -s -- 1.2.3")
        // A remote Mac reports Spaces missing with no command: it cannot be installed over SSH.
        let macFailure = SpacesRemoteDevicePairingError.remoteSpacesNotInstalled(
            message: "Install the Spaces app on the remote Mac, open it once, then pair again.", linuxInstallCommand: nil)
        XCTAssertNil(DevicePairCommand.automaticInstallCommand(forPairingFailure: macFailure))
        XCTAssertNil(DevicePairCommand.automaticInstallCommand(forPairingFailure: SpacesRemoteDevicePairingError.sshValidationFailed("no route")))
    }

    /// The install-and-pair path runs the installer and then pairs, so only the installer's own failures
    /// may be reported as an install failure. A pairing failure raised after the installer finished (an
    /// unreachable Device API on the freshly installed daemon, a rejected pairing) is not fixable by
    /// re-running the installer, and dressing it up as one would also hide that the install completed.
    func testOnlyInstallerRunFailuresAreReportedAsAnInstallFailure() {
        XCTAssertTrue(
            DevicePairCommand.isRemoteInstallRunFailure(SpacesRemoteDevicePairingError.remoteInstallFailed("exit 1: no space left on device")))
        XCTAssertTrue(DevicePairCommand.isRemoteInstallRunFailure(SpacesRemoteDevicePairingError.remoteInstallTimedOut("build-box")))
        // Everything the pairing phase raises after a successful install run.
        XCTAssertFalse(
            DevicePairCommand.isRemoteInstallRunFailure(
                SpacesRemoteDevicePairingError.deviceAPIUnreachable(hosts: ["build-box"], port: 47_847, message: "Connection refused.")))
        XCTAssertFalse(DevicePairCommand.isRemoteInstallRunFailure(SpacesRemoteDevicePairingError.pairingRejected("The pairing code expired.")))
        XCTAssertFalse(
            DevicePairCommand.isRemoteInstallRunFailure(SpacesRemoteDevicePairingError.remotePairCommandFailed("spaces: command not found")))
        XCTAssertFalse(DevicePairCommand.isRemoteInstallRunFailure(SpacesRemoteDevicePairingError.missingAuthToken))
        XCTAssertFalse(DevicePairCommand.isRemoteInstallRunFailure(CocoaError(.fileNoSuchFile)))
    }

    func testRemoteDeviceInstallFailureKeepsTheUnderlyingMessageAndSpellsOutTheManualCommand() {
        let failure = RemoteDeviceInstallFailure(
            underlyingMessage: "Installing Spaces on build-box failed (exit 1): no space left on device.",
            installCommand: "curl -fsSL https://usespaces.dev/install.sh | bash -s -- 1.2.3")

        XCTAssertEqual(
            failure.errorDescription,
            """
            Installing Spaces on build-box failed (exit 1): no space left on device.
            Run the installer on the device, then pair again:
              curl -fsSL https://usespaces.dev/install.sh | bash -s -- 1.2.3
            """)
    }

    func testDeviceRemoveParsesSelector() throws { XCTAssertEqual(try DeviceRemoveCommand.parse(["linux-box"]).device, "linux-box") }

    func testTerminalSessionRowsReturnsEmptyListWhenNoSessionsExist() { XCTAssertEqual(terminalSessionRows([]), []) }

    func testAvailableTerminalSessionRowsSkipsMetadataOnlySessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
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
        let originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
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

    func testTerminalCreateParsesOptions() throws {
        let command = try TerminalCreateCommand.parse(["--command", "cat", "--title", "session", "--workspace", "workspace-1"])

        XCTAssertEqual(command.command, "cat")
        XCTAssertEqual(command.title, "session")
        XCTAssertEqual(command.workspace, "workspace-1")
    }

    func testTerminalCreateParsesWithoutExplicitWorkspace() throws {
        let command = try TerminalCreateCommand.parse(["--command", "cat"])

        XCTAssertEqual(command.command, "cat")
        XCTAssertNil(command.workspace)
    }

    func testTerminalSendTextParsesSessionAndText() throws {
        let command = try TerminalSendTextCommand.parse(["session-1", "hello", "--submit"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.text, "hello")
        XCTAssertTrue(command.submit)
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

    func testTerminalPublicSubcommands() {
        let subcommands = TerminalCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(
            subcommands, ["TerminalListCommand", "TerminalCreateCommand", "TerminalSendCommand", "TerminalTailCommand", "TerminalShowCommand"])
    }

    func testRemovedTerminalCommandsAndFormsAreUnavailable() {
        XCTAssertThrowsError(try TerminalCommand.parse(["command", "--command", "cat"]))
        XCTAssertThrowsError(try TerminalCommand.parse(["start", "--command", "cat"]))
        XCTAssertThrowsError(try TerminalCommand.parse(["key", "session-1", "ctrl+c"]))
        XCTAssertThrowsError(try TerminalCommand.parse(["takeover", "session-1", "client-1"]))
        XCTAssertThrowsError(try TerminalCommand.parse(["proxy", "session-1", "--auth-token", "SECRET"]))
        XCTAssertThrowsError(try TerminalCommand.parse(["send", "session-1", "hello"]))
    }

    func testPairCommandLinesUseSpacesScheme() throws {
        let window = SpacesDevicePairingWindowSnapshot(
            window: SpacesDevicePairingCoordinator().openWindow(
                hosts: ["studio.local"], port: 7443, certificateFingerprint: "SHA256:abc", name: "Studio", protocolVersion: 5, appVersion: "0.1.0",
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
                hosts: ["studio.local"], port: 7443, certificateFingerprint: "SHA256:abc", name: "Studio", protocolVersion: 5, appVersion: "0.1.0",
                now: Date(timeIntervalSince1970: 1_782_000_000), duration: 300, code: "12345678", nonce: "N"))

        let payload = try pairCommandPayload {
            SpacesDeviceAPIControlResponse(ok: true, message: "ok", result: .pairingWindow(.init(pairingWindow: window)))
        }

        XCTAssertEqual(payload.name, "Studio")
        XCTAssertEqual(payload.hosts, ["studio.local"])
        XCTAssertEqual(payload.port, 7443)
        XCTAssertEqual(payload.pairingCode, "12345678")
        XCTAssertEqual(payload.pairingNonce, "N")
        XCTAssertEqual(payload.certificateFingerprint, "SHA256:abc")
        XCTAssertEqual(payload.pairingLink, window.linkString)
        // The SSH pairing path reads these from the JSON to run the compatibility gate.
        XCTAssertEqual(payload.protocolVersion, 5)
        XCTAssertEqual(payload.appVersion, "0.1.0")
    }

    /// Guards the SSH pairing path's producer/consumer contract directly: `spaces device pair --json`
    /// (spacescli's `PairingWindowPayload`) and `SpacesDevicePairingClient`'s SSH-metadata decoder
    /// (`RemotePairingMetadata`, spacesclientcore) must decode the exact same JSON shape. A prior
    /// version of this test hand-built the JSON with a stale `host` key while the real producer had
    /// already moved to `hosts`, so the decoder's `keyNotFound` break went unnoticed. Encoding a real
    /// `PairingWindowPayload` and feeding the bytes straight into the real decoder means the two types
    /// can never again drift apart silently — this failed to compile, then failed to decode, exactly as
    /// it should have the first time `hosts` was introduced.
    func testPairingWindowPayloadRoundTripsThroughRemotePairingMetadata() throws {
        let window = SpacesDevicePairingWindowSnapshot(
            window: SpacesDevicePairingCoordinator().openWindow(
                hosts: ["10.0.0.5", "100.64.12.34"], port: 7443, certificateFingerprint: "SHA256:abc", name: "Studio", protocolVersion: 5,
                appVersion: "0.1.0", now: Date(timeIntervalSince1970: 1_782_000_000), duration: 300, code: "12345678", nonce: "N"))
        let payload = try pairCommandPayload {
            SpacesDeviceAPIControlResponse(ok: true, message: "ok", result: .pairingWindow(.init(pairingWindow: window)))
        }

        let data = try JSONEncoder().encode(payload)
        let metadata = try JSONDecoder().decode(RemotePairingMetadata.self, from: data).validated()

        XCTAssertEqual(metadata.name, "Studio")
        XCTAssertEqual(metadata.hosts, ["10.0.0.5", "100.64.12.34"])
        XCTAssertEqual(metadata.port, 7443)
        XCTAssertEqual(metadata.pairingNonce, "N")
        XCTAssertEqual(metadata.pairingCode, "12345678")
        XCTAssertEqual(metadata.certificateFingerprint, "SHA256:abc")
        XCTAssertEqual(metadata.protocolVersion, 5)
        XCTAssertEqual(metadata.appVersion, "0.1.0")
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
        let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, root.path, 1)
        setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalRuntimeDir {
                setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimeDir, 1)
            } else {
                unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            }
            if let originalDatabasePath {
                setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
            } else {
                unsetenv(SpacesProfile.databasePathEnvironmentVariable)
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
                "spaces_agent_annotate", "spaces_agent_spawn", "spaces_agent_kill", "spaces_agent_subscribe", "spaces_agent_unsubscribe",
                "spaces_device_list",
            ])
        // `agent signal` is CLI-only forever: an orchestrating agent may read peers' status but must not forge it.
        XCTAssertFalse(names.contains("spaces_agent_signal"))
        // Sending a key is a keystroke, not a lifecycle event. There is no agent-scoped tool that claims to
        // interrupt a turn: an orchestrator sends ESC (or any other key) with `spaces_terminal_send`.
        XCTAssertFalse(names.contains("spaces_agent_interrupt"))

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
        XCTAssertNotNil(sendProperties["submit"])
        XCTAssertEqual(sendSchema["oneOf"] as? [[String: [String]]], [["required": ["text"]], ["required": ["bytes"]]])

        // Pins every remaining tool's `required` set against the Codable argument structs in
        // SpacesMCPServerArguments.swift: each struct's non-optional fields must exactly match what its
        // descriptor advertises, so a struct that silently drops or adds a required field is caught here
        // rather than only surfacing as a client-visible schema/decoding mismatch.
        let expectedRequired: [String: [String]] = [
            "spaces_project_list": [], "spaces_workspace_list": [], "spaces_workspace_start": ["workspace"],
            "spaces_workspace_restart": ["workspace"], "spaces_terminal_list": [], "spaces_agent_list": [],
            "spaces_agent_status": [], "spaces_agent_annotate": ["note"], "spaces_agent_spawn": ["command"],
            "spaces_agent_kill": ["session"], "spaces_agent_subscribe": ["session"], "spaces_agent_unsubscribe": ["session"],
            "spaces_device_list": [],
        ]
        for (name, required) in expectedRequired {
            let tool = try XCTUnwrap(tools.first { ($0["name"] as? String) == name }, "missing tool \(name)")
            let toolSchema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(toolSchema["required"] as? [String], required, "unexpected required set for \(name)")
        }
    }

    func testMCPStdioFramingIsNewlineDelimited() throws {
        // Drive the server with the MCP stdio handshake: initialize, the client's post-initialize
        // notification (no id, no response expected), then tools/list — all newline-delimited.
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        inputPipe.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try inputPipe.fileHandleForWriting.close()

        let server = SpacesMCPStdioServer(input: inputPipe.fileHandleForReading, output: outputPipe.fileHandleForWriting)
        try server.run()
        try outputPipe.fileHandleForWriting.close()

        let outputText = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // The notification draws no reply, so initialize + tools/list produce exactly two lines, each a
        // single compact JSON message with no embedded newline.
        let lines = outputText.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)

        let initialize = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(initialize["id"] as? Int, 1)
        let initializeResult = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual((initializeResult["serverInfo"] as? [String: Any])?["name"] as? String, "spaces")

        let toolsList = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(toolsList["id"] as? Int, 2)
        let tools = try XCTUnwrap((toolsList["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        let agentTools = [
            "spaces_agent_list", "spaces_agent_status", "spaces_agent_annotate", "spaces_agent_spawn", "spaces_agent_kill", "spaces_agent_subscribe",
            "spaces_agent_unsubscribe",
        ]
        XCTAssertTrue(agentTools.allSatisfy(names.contains), "expected all agent tools, got \(names.sorted())")
    }

    private func terminalInputPayload(from arguments: [String: Any]) throws -> TerminalProfileInput {
        try decodeMCPArguments(TerminalInputArguments.self, from: arguments).resolvedInput()
    }

    func testMCPTerminalInputMapsTextAndBytesToTypedInput() throws {
        XCTAssertEqual(try terminalInputPayload(from: ["text": ""]), .text(""))
        XCTAssertEqual(try terminalInputPayload(from: ["text": "hello"]), .text("hello"))
        XCTAssertEqual(try terminalInputPayload(from: ["bytes": [0, 10, 255]]), .bytes(Data([0, 10, 255])))
    }

    func testMCPTerminalInputRejectsMissingAndBothArguments() {
        XCTAssertThrowsError(try terminalInputPayload(from: [:])) { error in
            XCTAssertEqual(error.localizedDescription, "text or bytes is required.")
        }
        XCTAssertThrowsError(try terminalInputPayload(from: ["text": "hi", "bytes": [1]])) { error in
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
