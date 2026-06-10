import ArgumentParser
import Darwin
import Foundation
import XCTest
import spacesmobilebridge
import spacesterminalcore
import spacesterminalghostty
import systembridge
import workspacecore

@testable import spacescli

final class SpacesCommandTests: XCTestCase {
    func testImportParsesPath() throws {
        let command = try ImportCommand.parse(["."])

        XCTAssertEqual(command.path, ".")
    }

    func testUpdateRequiresMutationFlag() {
        XCTAssertThrowsError(try UpdateCommand.parse([])) { error in XCTAssertTrue(String(describing: error).contains("at least one field")) }
    }

    func testUpdateParsesPathAndMetadata() throws {
        let command = try UpdateCommand.parse([".", "--title", "Title", "--notes", "Ready for review"])

        XCTAssertEqual(command.path, ".")
        XCTAssertEqual(command.title, "Title")
        XCTAssertEqual(command.notes, "Ready for review")
    }

    func testStartParsesWorkspacePath() throws {
        let command = try StartCommand.parse(["."])

        XCTAssertEqual(command.path, ".")
    }

    func testRestartParsesWorkspacePath() throws {
        let command = try RestartCommand.parse(["."])

        XCTAssertEqual(command.path, ".")
    }

    func testOpenParsesNameAndOptionalWorkspacePath() throws {
        let command = try OpenCommand.parse(["frontend"])

        XCTAssertEqual(command.name, "frontend")
        XCTAssertNil(command.path)
    }

    func testSignalParsesTypedEnums() throws {
        let command = try SignalCommand.parse(["waiting"])

        XCTAssertEqual(command.type, .waiting)
        XCTAssertNil(command.path)
    }

    func testTerminalListParses() throws { XCTAssertNoThrow(try TerminalListCommand.parse([])) }

    func testTerminalListPrintsClearMessageWhenNoSessionsExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let output = try captureStandardOutput {
            let command = TerminalListCommand()
            try command.run()
        }

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "No terminal sessions.")
    }

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

    func testMobileServeParsesHostPortPairingCodeAndWindowCount() throws {
        let command = try MobileServeCommand.parse([
            "--host", "0.0.0.0", "--port", "47847", "--pairing-code", "246810", "--pairing-window-count", "2",
        ])

        XCTAssertEqual(command.host, "0.0.0.0")
        XCTAssertEqual(command.port, 47_847)
        XCTAssertEqual(command.pairingCode, "246810")
        XCTAssertEqual(command.pairingWindowCount, 2)
    }

    func testMobileServeDefaultsAreLanReachableAndStable() throws {
        let command = try MobileServeCommand.parse([])

        XCTAssertEqual(command.host, SpacesMobileBridgeDefaults.host)
        XCTAssertEqual(command.port, SpacesMobileBridgeDefaults.port)
    }

    func testMobileServePairingLinkHostTreatsIPv6WildcardAsWildcard() {
        let host = mobileServePairingLinkHost(host: "::")

        XCTAssertNotEqual(host, "::")
        XCTAssertFalse(SpacesMobileBridgeDefaults.isWildcardHost(host))
    }

    func testMobileStatusPropagatesControlLookupFailure() {
        XCTAssertThrowsError(try mobileStatusLines(loadControlResponse: { throw POSIXError(.ECONNREFUSED) })) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ECONNREFUSED)
        }
    }

    func testMobileStatusRejectsFailedControlResponseWithoutUsingStoredSettings() {
        XCTAssertThrowsError(
            try mobileStatusLines(loadControlResponse: { SpacesMobileBridgeControlResponse(ok: false, message: "Mobile bridge is not running.") })
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else {
                XCTFail("Expected WorkspaceError.invalidArgument, got \(error)")
                return
            }
            XCTAssertEqual(message, "Mobile bridge is not running.")
        }
    }

    func testMobileStatusRejectsMissingStatusPayloadWithoutUsingStoredSettings() {
        XCTAssertThrowsError(
            try mobileStatusLines(loadControlResponse: { SpacesMobileBridgeControlResponse(ok: true, message: "Loaded mobile bridge status.") })
        ) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else {
                XCTFail("Expected WorkspaceError.invalidArgument, got \(error)")
                return
            }
            XCTAssertEqual(message, "Mobile bridge status response did not include address details.")
        }
    }

    func testMobileStatusFormatsControlStatus() throws {
        let lines = try mobileStatusLines(loadControlResponse: {
            SpacesMobileBridgeControlResponse(
                ok: true, message: "Loaded mobile bridge status.",
                status: SpacesMobileBridgeStatus(
                    host: "0.0.0.0", port: 47_847, bonjourServiceName: "Spaces Mac", bonjourServiceType: "_spaces-mobile._tcp.",
                    networkAddresses: ["192.168.1.20"], certificateFingerprint: "SHA256:test"))
        })

        XCTAssertEqual(
            lines,
            [
                "Spaces mobile bridge", "port=47847", "bonjour=Spaces Mac\ttype=_spaces-mobile._tcp.", "fingerprint=SHA256:test",
                "addresses=192.168.1.20:47847", "iphone=Open Mobile Connection in the Mac app to show a QR code or pairing link.",
            ])
    }

    func testSpacesCommandListsFlattenedPublicVerbs() {
        let subcommands = SpacesCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(
            subcommands,
            [
                "ImportCommand", "UpdateCommand", "StartCommand", "RestartCommand", "OpenCommand", "SignalCommand", "TerminalCommand",
                "MobileCommand", "ProfileCommand",
            ])
    }

    func testProfileShowShellOutputIncludesDatabaseAndRuntimeExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databasePath = root.appendingPathComponent("spaces.db").path
        let runtimePath = root.appendingPathComponent("runtime").path
        let originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let originalRuntimePath = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        setenv("SPACES_DB_PATH", databasePath, 1)
        setenv("SPACES_RUNTIME_DIR", runtimePath, 1)
        defer {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimePath { setenv("SPACES_RUNTIME_DIR", originalRuntimePath, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        let output = try captureStandardOutput {
            let command = try ProfileShowCommand.parse(["--shell"])
            try command.run()
        }

        XCTAssertTrue(output.contains("export SPACES_DB_PATH='\(databasePath)'"))
        XCTAssertTrue(output.contains("export SPACES_RUNTIME_DIR='\(runtimePath)'"))
    }

    func testDeliverDesktopControlBusyNotificationUsesAppleScriptDisplayNotification() throws {
        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let originalCapture = ProcessInfo.processInfo.environment["SPACES_OSASCRIPT_CAPTURE"]
        setenv("SPACES_OSASCRIPT_CAPTURE", captureURL.path, 1)
        defer {
            if let originalCapture { setenv("SPACES_OSASCRIPT_CAPTURE", originalCapture, 1) } else { unsetenv("SPACES_OSASCRIPT_CAPTURE") }
            try? FileManager.default.removeItem(at: captureURL)
        }

        let osascriptMock = """
            #!/bin/sh
            printf '%s' "$2" > "$SPACES_OSASCRIPT_CAPTURE"
            """

        let owner = SpacesProcessLeaseOwner(
            pid: 4321, executablePath: "/tmp/SpacesApp", profileRoot: "/tmp/.spaces-dev/profiles/spaces/parallel-f46abb6175b3", token: "owner-token",
            acquiredAt: "2026-05-17T00:00:00Z")

        try withMockCommands(["osascript": osascriptMock]) { deliverDesktopControlBusyNotification(owner: owner) }

        let script = try String(contentsOf: captureURL, encoding: .utf8)
        XCTAssertTrue(script.contains("display notification"))
        XCTAssertTrue(script.contains("Close Spaces When You're Done"))
        XCTAssertTrue(script.contains("A real-system Spaces workflow is waiting"))
        XCTAssertTrue(script.contains("pid 4321"))
        XCTAssertTrue(script.contains("parallel-f46abb6175b3"))
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

    func testAgentEventDropResultRejectsUnsupportedHostBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: ["__CFBundleIdentifier": "com.apple.Terminal"], context: context)

        XCTAssertEqual(result?.text, "Dropped agent event start: non-Spaces terminal")
        XCTAssertEqual(result?.payload.message, "Dropped non-Spaces agent event.")
    }

    func testAgentEventDropResultAcceptsTrackedSpacesSession() {
        let context = CLIContext()

        let result = agentEventDropResult(
            type: .start,
            environment: [
                "SPACES_TERMINAL_HOST": TerminalHost.spaces.rawValue, WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1",
            ], context: context)

        XCTAssertNil(result)
    }

    func testAgentEventDropResultRejectsUntrackedSpacesSessionBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: ["SPACES_TERMINAL_HOST": TerminalHost.spaces.rawValue], context: context)

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
                environment: [
                    "SPACES_TERMINAL_HOST": TerminalHost.spaces.rawValue, WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1",
                    "CLAUDE_CODE_ENTRYPOINT": "1",
                ], orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.terminalTrackingID, "spaces-session-token-1")
            XCTAssertEqual(agentContext?.terminalNativeID, "spaces-session-token-1")
            XCTAssertEqual(agentContext?.yabaiWindowID, 106482)
            XCTAssertEqual(agentContext?.environmentKeys, ["CLAUDE_CODE_ENTRYPOINT", "SPACES_TERMINAL_HOST", "SPACES_TERMINAL_TRACKING_ID"])
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
                environment: [
                    "SPACES_TERMINAL_HOST": TerminalHost.spaces.rawValue, "CODEX_MANAGED_BY_NPM": "1",
                    WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1",
                ], orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.label, "codex cli")
            XCTAssertEqual(agentContext?.codexThreadID, nil)
            XCTAssertEqual(agentContext?.environmentKeys, ["CODEX_MANAGED_BY_NPM", "SPACES_TERMINAL_HOST", "SPACES_TERMINAL_TRACKING_ID"])
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
                environment: [
                    "SPACES_TERMINAL_HOST": TerminalHost.spaces.rawValue, "OPENCODE_EXPERIMENTAL_FILEWATCHER": "1",
                    WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1",
                ], orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.label, "opencode cli")
            XCTAssertEqual(agentContext?.codexThreadID, nil)
            XCTAssertEqual(
                agentContext?.environmentKeys, ["OPENCODE_EXPERIMENTAL_FILEWATCHER", "SPACES_TERMINAL_HOST", "SPACES_TERMINAL_TRACKING_ID"])
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
                    "SPACES_TERMINAL_HOST": TerminalHost.spaces.rawValue, WorkspaceOrchestrator.agentLabelEnvVar: "opencode",
                    WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1",
                ], orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .spaces)
            XCTAssertEqual(agentContext?.label, "opencode")
            XCTAssertEqual(agentContext?.terminalTrackingID, "spaces-session-token-1")
            XCTAssertEqual(agentContext?.environmentKeys, ["SPACES_AGENT_LABEL", "SPACES_TERMINAL_HOST", "SPACES_TERMINAL_TRACKING_ID"])
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
                environment: [
                    "SPACES_TERMINAL_HOST": TerminalHost.spaces.rawValue, WorkspaceOrchestrator.terminalTrackingIDEnvVar: "spaces-session-token-1",
                    "CLAUDE_CODE_ENTRYPOINT": "1",
                ], orchestrator: orchestrator, context: context)

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
            "SPACES_DB_PATH": dbPath, "SPACES_TERMINAL_HOST": TerminalHost.spaces.rawValue, WorkspaceOrchestrator.terminalTrackingIDEnvVar: sessionID,
            WorkspaceOrchestrator.agentLabelEnvVar: label, "CODEX_THREAD_ID": nil, "CODEX_MANAGED_BY_NPM": nil, "CLAUDE_CODE_ENTRYPOINT": nil,
            "OPENCODE_EXPERIMENTAL_FILEWATCHER": nil,
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
