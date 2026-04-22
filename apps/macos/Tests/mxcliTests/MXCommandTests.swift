import ArgumentParser
import Foundation
import streamctl
import XCTest
@testable import mxcli

final class MXCommandTests: XCTestCase {
    func testWorkspaceUpParsesLeafCommandOptions() throws {
        let command = try WorkspaceUpCommand.parse(["/tmp/worktree", "--restart", "--focus", "frontend"])

        XCTAssertEqual(command.path, "/tmp/worktree")
        XCTAssertTrue(command.restart)
        XCTAssertEqual(command.focus, "frontend")
    }

    func testWorkspaceUpdateRequiresMutationFlag() {
        XCTAssertThrowsError(try WorkspaceUpdateCommand.parse([])) { error in
            XCTAssertTrue(String(describing: error).contains("at least one field"))
        }
    }

    func testWorkspaceUpdateParsesPathAndMetadata() throws {
        let command = try WorkspaceUpdateCommand.parse(["/tmp/worktree", "--title", "Title", "--tooltip", "Summary"])

        XCTAssertEqual(command.path, "/tmp/worktree")
        XCTAssertEqual(command.title, "Title")
        XCTAssertEqual(command.tooltip, "Summary")
    }

    func testAgentEventParsesTypedEnums() throws {
        let command = try AgentEventCommand.parse(["--type", "waiting", "/tmp/worktree"])

        XCTAssertEqual(command.type, .waiting)
        XCTAssertEqual(command.path, "/tmp/worktree")
    }

    func testAgentEventRejectsUnknownEnumValue() {
        XCTAssertThrowsError(try AgentEventCommand.parse(["--type", "bogus"])) { error in
            let rendered = String(describing: error)
            XCTAssertTrue(rendered.contains("bogus") || rendered.contains("waiting"))
        }
    }

    func testAgentEventDropResultRejectsUnsupportedHostBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(
            type: .start,
            environment: ["__CFBundleIdentifier": "com.apple.Terminal"],
            context: context)

        XCTAssertEqual(result?.text, "Dropped agent event start: unsupported terminal host")
        XCTAssertEqual(result?.payload.message, "Dropped unsupported agent event.")
    }

    func testAgentEventDropResultRejectsTmuxBeforeWorkspaceLookup() {
        let context = CLIContext()

        let result = agentEventDropResult(
            type: .waiting,
            environment: [
                "__CFBundleIdentifier": "com.googlecode.iterm2",
                "TMUX": "/tmp/tmux-501/default,123,0",
            ],
            context: context)

        XCTAssertEqual(result?.text, "Dropped agent event waiting: coding agents run from tmux are not supported by muxy")
        XCTAssertEqual(result?.payload.message, "Dropped tmux-backed agent event.")
    }

    func testResolveAgentInvocationContextUsesYabaiWindowForGhosttyWithoutThreadID() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = MuxyOrchestrator(store: store)

        try withMockCommands(["yabai": Self.yabaiFocusedWindowMock]) {
            let context = CLIContext()
            let agentContext = try resolveAgentInvocationContext(
                workspaceID: workspace.id,
                environment: [
                    "__CFBundleIdentifier": "com.mitchellh.ghostty",
                    "CLAUDE_CODE_ENTRYPOINT": "1",
                ],
                orchestrator: orchestrator,
                context: context)

            XCTAssertEqual(agentContext?.provider, .ghostty)
            XCTAssertEqual(agentContext?.label, "Claude Code CLI")
            XCTAssertNil(agentContext?.iTermSessionID)
            XCTAssertEqual(agentContext?.yabaiWindowID, 106482)
        }
    }

    func testResolveAgentInvocationContextPrefersMuxyTrackingIDForGhostty() throws {
        let store = try makeTemporaryStore()
        let workspace = try makeWorkspace(store: store)
        let orchestrator = MuxyOrchestrator(store: store)
        let context = CLIContext()

        let agentContext = try resolveAgentInvocationContext(
            workspaceID: workspace.id,
            environment: [
                "__CFBundleIdentifier": "com.mitchellh.ghostty",
                "CLAUDE_CODE_ENTRYPOINT": "1",
                MuxyOrchestrator.terminalTrackingIDEnvVar: "ghostty-muxy-token-1",
            ],
            orchestrator: orchestrator,
            context: context)

        XCTAssertEqual(agentContext?.provider, .ghostty)
        XCTAssertEqual(agentContext?.iTermSessionID, "ghostty-muxy-token-1")
    }

    private func makeTemporaryStore() throws -> SQLiteStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteStore(path: directory.appendingPathComponent("muxy.db").path)
    }

    private func makeWorkspace(store: SQLiteStore) throws -> WorkspaceRecord {
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = ProjectRecord(
            id: UUID().uuidString,
            name: "TestProject",
            dir: projectDir.path,
            isGitRepo: false,
            defaultBranch: nil,
            setupScript: nil,
            stopScript: nil,
            ports: [],
            processes: [],
            statusChecks: [],
            browserSessions: [])
        try store.upsert(project: project)
        let workspace = WorkspaceRecord(
            id: UUID().uuidString,
            projectID: project.id,
            title: "default",
            dir: projectDir.appendingPathComponent("default", isDirectory: true).path,
            dirname: nil,
            branch: nil,
            isDefault: true,
            isArchived: false,
            isRunning: false,
            lastLaunchedAt: nil)
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
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
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
}
