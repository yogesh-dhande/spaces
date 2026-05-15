import ArgumentParser
import Darwin
import Foundation
import XCTest
import spacesterminalcore
import spacesterminalruntime
import systembridge
import workspacecore

@testable import spacescli

final class MXCommandTests: XCTestCase {
    private final class VerifyingIterm2Adapter: Iterm2Adapter, @unchecked Sendable {
        var verifyFocusedSessionCallCount = 0

        override func verifyFocusedSession(preferredSessionID: String, windowID: Int?) throws -> Bool {
            verifyFocusedSessionCallCount += 1
            return true
        }
    }

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
            sessionID: "session-live", backend: .scriptPTY, title: "shell", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-05-12T00:00:00Z")
        try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "session-live", backend: .scriptPTY, servicePID: getpid(), childPID: nil, state: .running,
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
        let command = try TerminalCommandCommand.parse(["--command", "cat", "--title", "session", "--cwd", "/tmp", "--backend", "script-pty"])

        XCTAssertEqual(command.command, "cat")
        XCTAssertEqual(command.title, "session")
        XCTAssertEqual(command.cwd, "/tmp")
        XCTAssertEqual(command.backend, .scriptPTY)
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
        XCTAssertFalse(command.viewer)
    }

    func testTerminalShowParsesViewerFlag() throws {
        let command = try TerminalShowCommand.parse(["session-1", "--viewer"])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertTrue(command.viewer)
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

    func testTerminalServeParsesBackend() throws {
        let command = try TerminalServeCommand.parse([
            "--session-id", "session-1", "--backend", "script-pty", "--title", "session", "--cwd", "/tmp", "--shell", "/bin/zsh",
        ])

        XCTAssertEqual(command.sessionID, "session-1")
        XCTAssertEqual(command.backend, .scriptPTY)
    }

    func testSpacesCommandListsFlattenedPublicVerbs() {
        let subcommands = SpacesCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(
            subcommands, ["ImportCommand", "UpdateCommand", "StartCommand", "RestartCommand", "OpenCommand", "SignalCommand", "TerminalCommand"])
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

        XCTAssertEqual(result?.text, "Dropped agent event start: unsupported terminal host")
        XCTAssertEqual(result?.payload.message, "Dropped unsupported agent event.")
    }

    func testAgentEventDropResultAcceptsGhosttyTermProgramWithoutBundleIdentifier() {
        let context = CLIContext()

        let result = agentEventDropResult(
            type: .start, environment: ["TERM_PROGRAM": "ghostty", WorkspaceOrchestrator.terminalTrackingIDEnvVar: "ghostty-hook-token-1"],
            context: context)

        XCTAssertNil(result)
    }

    func testAgentEventDropResultRejectsUntrackedGhosttyBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty"], context: context)

        XCTAssertEqual(result?.text, "Dropped agent event start: untracked Ghostty terminal")
        XCTAssertEqual(result?.payload.message, "Dropped untracked Ghostty agent event.")
    }

    func testAgentEventDropResultRejectsUntrackedGhosttyTermProgramBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: ["TERM_PROGRAM": "ghostty"], context: context)

        XCTAssertEqual(result?.text, "Dropped agent event start: untracked Ghostty terminal")
        XCTAssertEqual(result?.payload.message, "Dropped untracked Ghostty agent event.")
    }

    func testAgentEventDropResultRejectsUntrackedItermTermProgramWithoutSessionIdentifier() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: ["TERM_PROGRAM": "iTerm.app"], context: context)

        XCTAssertEqual(result?.text, "Dropped agent event start: untracked iTerm2 terminal")
        XCTAssertEqual(result?.payload.message, "Dropped untracked iTerm2 agent event.")
    }

    func testAgentEventDropResultAcceptsItermSessionIdentifierWithoutTermProgram() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: ["ITERM_SESSION_ID": "w0t0p0:ABC123"], context: context)

        XCTAssertNil(result)
    }

    func testAgentEventDropResultRejectsTmuxBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(
            type: .waiting, environment: ["__CFBundleIdentifier": "com.googlecode.iterm2", "TMUX": "/tmp/tmux-501/default,123,0"], context: context)

        XCTAssertEqual(result?.text, "Dropped agent event waiting: coding agents run from tmux are not supported by Spaces")
        XCTAssertEqual(result?.payload.message, "Dropped tmux-backed agent event.")
    }

    func testResolveAgentInvocationContextDropsUntrackedGhosttyEventWithoutHookToken() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock, "osascript": Self.ghosttyFocusedTerminalMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id, environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty", "CLAUDE_CODE_ENTRYPOINT": "1"],
                orchestrator: orchestrator, context: context)

            XCTAssertNil(agentContext)
        }
    }

    func testResolveAgentInvocationContextDropsGhosttyTermProgramEventWithoutHookToken() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock, "osascript": Self.ghosttyFocusedTerminalMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id, environment: ["TERM_PROGRAM": "ghostty", "CLAUDE_CODE_ENTRYPOINT": "1"], orchestrator: orchestrator,
                context: context)

            XCTAssertNil(agentContext)
        }
    }

    func testResolveAgentInvocationContextUsesGhosttyHookTokenWithoutFrontmostWindowBinding() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock, "osascript": Self.ghosttyFocusedTerminalMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: [
                    "__CFBundleIdentifier": "com.mitchellh.ghostty", "CLAUDE_CODE_ENTRYPOINT": "1",
                    WorkspaceOrchestrator.terminalTrackingIDEnvVar: "ghostty-hook-token-1",
                ], orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .ghostty)
            XCTAssertEqual(agentContext?.terminalTrackingID, "ghostty-hook-token-1")
            XCTAssertNil(agentContext?.terminalNativeID)
            XCTAssertNil(agentContext?.yabaiWindowID)
            XCTAssertEqual(agentContext?.environmentKeys, ["CLAUDE_CODE_ENTRYPOINT", "SPACES_TERMINAL_TRACKING_ID", "__CFBundleIdentifier"])
        }
    }

    func testResolveAgentInvocationContextInfersCodexLabelFromManagedByNpmFallback() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock, "osascript": Self.ghosttyFocusedTerminalMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: [
                    "__CFBundleIdentifier": "com.mitchellh.ghostty", "CODEX_MANAGED_BY_NPM": "1",
                    WorkspaceOrchestrator.terminalTrackingIDEnvVar: "ghostty-hook-token-1",
                ], orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .ghostty)
            XCTAssertEqual(agentContext?.label, "Codex CLI")
            XCTAssertEqual(agentContext?.codexThreadID, nil)
            XCTAssertEqual(agentContext?.environmentKeys, ["CODEX_MANAGED_BY_NPM", "SPACES_TERMINAL_TRACKING_ID", "__CFBundleIdentifier"])
        }
    }

    func testResolveAgentInvocationContextLoadsTrackedGhosttyNativeTerminalIDFromExistingRows() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.ghostty.appName, name: "Claude Code CLI", windowID: 106482,
                terminalTrackingID: "ghostty-hook-token-1", terminalNativeID: "ghostty-native-1", role: "terminal", orderIndex: 200, lastSeenAt: "now"
            ))

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: [
                    "__CFBundleIdentifier": "com.mitchellh.ghostty", "CLAUDE_CODE_ENTRYPOINT": "1",
                    WorkspaceOrchestrator.terminalTrackingIDEnvVar: "ghostty-hook-token-1",
                ], orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .ghostty)
            XCTAssertEqual(agentContext?.terminalTrackingID, "ghostty-hook-token-1")
            XCTAssertEqual(agentContext?.terminalNativeID, "ghostty-native-1")
            XCTAssertNil(agentContext?.yabaiWindowID)
        }
    }

    func testResolveAgentInvocationContextDoesNotBorrowFocusedWindowForItermSessionIdentity() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = WorkspaceOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id, environment: ["ITERM_SESSION_ID": "w0t0p0:ABC123", "CLAUDE_CODE_ENTRYPOINT": "1"],
                orchestrator: orchestrator, context: context)

            XCTAssertEqual(agentContext?.provider, .iterm2)
            XCTAssertEqual(agentContext?.terminalTrackingID, "ABC123")
            XCTAssertNil(agentContext?.yabaiWindowID)
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

    func testResolveAgentInvocationContextDropsItermEventWithoutSessionIdentifier() throws {
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

    func testCLIContextRunsItermVerificationBeforeReturningFocusControl() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let projectWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.iterm2.appName, name: "frontend", detail: "npm run dev",
            targetURL: nil, windowID: 77, terminalTrackingID: "session-77", terminalNativeID: nil, itermTabIndex: 2, tmuxWindowID: nil,
            role: "terminal", orderIndex: 200, lastSeenAt: "now")
        try store.upsert(window: projectWindow)

        let iterm = VerifyingIterm2Adapter()
        let context = CLIContext(storeFactory: { store }, itermFactory: { iterm })
        let orchestrator = try context.makeOrchestrator()

        try withMockCommands(["osascript": Self.itermSessionFocusSuccessMock]) {
            try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, name: "frontend")
        }

        XCTAssertEqual(iterm.verifyFocusedSessionCallCount, 1)
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

    private static let ghosttyFocusedTerminalMock = """
        #!/bin/bash
        script="${*: -1}"
        if [[ "$script" == *'tell application id "com.mitchellh.ghostty" to version'* ]]; then
          echo "1.3.1"
          exit 0
        fi
        if [[ "$script" == *'focused terminal of selected tab of front window'* ]]; then
          echo "ghostty-terminal-live-1"
          exit 0
        fi
        exit 1
        """

    private static let ghosttyFocusedTerminalFailureMock = """
        #!/bin/bash
        script="${*: -1}"
        if [[ "$script" == *'tell application id "com.mitchellh.ghostty" to version'* ]]; then
          echo "1.3.1"
          exit 0
        fi
        echo "lookup failed" >&2
        exit 1
        """

    private static let itermSessionFocusSuccessMock = """
        #!/bin/bash
        script="${*: -1}"
        if [[ "$script" == *'tell application "iTerm2" to version'* ]]; then
          echo "3.5.0"
          exit 0
        fi
        if [[ "$script" == *'set targetSessionID to "session-77"'* && "$script" == *'tell s to select'* ]]; then
          echo "session"
          exit 0
        fi
        if [[ "$script" == *'set targetSessionID to "session-77"'* && "$script" == *'repeat 10 times'* ]]; then
          echo "session"
          exit 0
        fi
        echo "unexpected script" >&2
        exit 1
        """
}
