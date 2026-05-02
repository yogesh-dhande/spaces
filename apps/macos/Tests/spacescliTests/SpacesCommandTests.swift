import ArgumentParser
import Foundation
import XCTest
import systembridge
import workspacecore

@testable import spacescli

private let testAppleScriptOptInEnvVar = "SPACES_ALLOW_TEST_APPLESCRIPT"

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

    func testSpacesCommandListsFlattenedPublicVerbs() {
        let subcommands = SpacesCommand.configuration.subcommands.map { String(describing: $0) }
        XCTAssertEqual(subcommands, ["ImportCommand", "UpdateCommand", "StartCommand", "RestartCommand", "OpenCommand", "SignalCommand"])
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

    func testAgentEventDropResultAcceptsItermTermProgramWithoutBundleIdentifier() {
        let context = CLIContext()

        let result = agentEventDropResult(type: .start, environment: ["TERM_PROGRAM": "iTerm.app"], context: context)

        XCTAssertNil(result)
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

    private func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (name, content) in commands {
            let url = tempDir.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(tempDir.path):\(originalPath ?? "")", 1)
        defer { if let originalPath { setenv("PATH", originalPath, 1) } else { unsetenv("PATH") } }
        let originalAppleScriptOptIn = ProcessInfo.processInfo.environment[testAppleScriptOptInEnvVar]
        if commands.keys.contains("osascript") { setenv(testAppleScriptOptInEnvVar, "1", 1) }
        defer {
            if commands.keys.contains("osascript") {
                if let originalAppleScriptOptIn {
                    setenv(testAppleScriptOptInEnvVar, originalAppleScriptOptIn, 1)
                } else {
                    unsetenv(testAppleScriptOptInEnvVar)
                }
            }
        }
        try run()
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
