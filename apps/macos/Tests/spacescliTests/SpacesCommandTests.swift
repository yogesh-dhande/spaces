import ArgumentParser
import Darwin
import Foundation
import XCTest
import spacesterminalcore
import spacesterminalghostty
import systembridge
import workspacecore

@testable import spacescli

final class MXCommandTests: XCTestCase {
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

    func testMobileServeParsesHostPortAndPairingCode() throws {
        let command = try MobileServeCommand.parse(["--host", "0.0.0.0", "--port", "47071", "--pairing-code", "246810"])

        XCTAssertEqual(command.host, "0.0.0.0")
        XCTAssertEqual(command.port, 47071)
        XCTAssertEqual(command.pairingCode, "246810")
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
            XCTAssertEqual(agentContext?.label, "Codex CLI")
            XCTAssertEqual(agentContext?.codexThreadID, nil)
            XCTAssertEqual(agentContext?.environmentKeys, ["CODEX_MANAGED_BY_NPM", "SPACES_TERMINAL_HOST", "SPACES_TERMINAL_TRACKING_ID"])
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

    func testResolveAgentInvocationContextDropsNonSpacesEventWithoutTrackingIdentity() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id, environment: ["TERM_PROGRAM": "iTerm.app", "CLAUDE_CODE_ENTRYPOINT": "1"], orchestrator: orchestrator,
                context: context)

            XCTAssertNil(agentContext)
        }
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

    private static let yabaiFocusedWindowMock = """
        #!/bin/bash
        if [[ "$1 $2 $3 $4" == "-m query --windows --window" ]]; then
          echo '{"id":106482,"pid":123,"app":"Ghostty","title":"✳ Claude Code","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}'
          exit 0
        fi
        exit 1
        """

}
