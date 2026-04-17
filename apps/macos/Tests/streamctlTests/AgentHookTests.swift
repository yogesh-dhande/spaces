import XCTest
import appctl

@testable import streamctl

final class AgentHookTests: XCTestCase {
    override func invokeTest() {
        do {
            try withMockCommands(["yabai": Self.yabaiMockScript]) {
                super.invokeTest()
            }
        } catch {
            XCTFail("Failed to install mock commands: \(error)")
        }
    }

    func testRegisterAgentWindowCreatesDedicatedWindowRecord() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Codex CLI",
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 101,
            status: .idle)

        XCTAssertEqual(record.provider, .iterm2)
        XCTAssertEqual(record.label, "Codex CLI")
        XCTAssertEqual(record.itermSessionID, "workspace-session")
        XCTAssertNil(record.tmuxWindowID)
        XCTAssertEqual(record.windowID, 101)
        XCTAssertEqual(record.yabaiWindowID, 101)
        XCTAssertEqual(record.status, .idle)
    }

    func testRegisterAgentWindowUpdatesExistingWindowRecord() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session",
            yabaiWindowID: 101,
            status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Codex CLI",
            itermSessionID: "workspace-session-2",
            yabaiWindowID: 101,
            status: .spinning)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.label, "Codex CLI")
        XCTAssertEqual(second.itermSessionID, "workspace-session-2")
        XCTAssertEqual(second.status, .spinning)
    }

    func testRegisterAgentWindowKeepsSeparateDedicatedWindowsDistinct() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session-1",
            yabaiWindowID: 101,
            status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session-2",
            yabaiWindowID: 202,
            status: .spinning)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(try store.agentWindows(workspaceID: workspace.id).compactMap(\.yabaiWindowID)), Set([101, 202]))
    }

    func testUpdateAgentWindowStatusMatchesExistingWindowID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Codex CLI",
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 101,
            status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 101,
            label: "Codex CLI",
            status: .done)

        XCTAssertEqual(updated.status, .done)
        XCTAssertEqual(updated.yabaiWindowID, 101)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testUpdateAgentWindowStatusFallsBackToCodexThreadMatch() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session",
            codexThreadID: "thread-xyz",
            yabaiWindowID: 101,
            status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session",
            codexThreadID: "thread-xyz",
            yabaiWindowID: nil,
            label: "Codex CLI",
            status: .spinning)

        XCTAssertEqual(updated.id, try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first).id)
        XCTAssertEqual(updated.label, "Codex CLI")
        XCTAssertEqual(updated.status, .spinning)
    }

    func testAgentWindowsReturnsOnlyWorkspaceRecords() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let (_, workspace2) = try makeProjectAndWorkspace(store: store, projectName: "proj2", workspaceName: "ws2")

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session-1",
            yabaiWindowID: 101,
            status: .idle)
        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session-2",
            yabaiWindowID: 202,
            status: .spinning)
        try orchestrator.registerAgentWindow(
            workspaceID: workspace2.id,
            provider: .iterm2,
            itermSessionID: "workspace-session-3",
            yabaiWindowID: 303,
            status: .waiting)

        let records = try orchestrator.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap(\.yabaiWindowID)), Set([101, 202]))
    }

    private func makeProjectAndWorkspace(store: SQLiteStore, projectName: String = "TestProject", workspaceName: String = "default") throws -> (
        ProjectRecord, WorkspaceRecord
    ) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = ProjectRecord(
            id: dir, name: projectName, dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [], processes: [],
            statusChecks: [], browserSessions: [])
        try store.upsert(project: project)
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, name: workspaceName, dir: dir + "/\(workspaceName)", dirname: nil, branch: nil,
            isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    private func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
        let directory = try makeTempDirectory()
        for (name, script) in commands {
            let file = directory.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        sharedPathMutationLock.lock()
        defer { sharedPathMutationLock.unlock() }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let updatedPath = originalPath.isEmpty ? directory.path : "\(directory.path):\(originalPath)"
        setenv("PATH", updatedPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        try run()
    }

    private static let yabaiMockScript = """
        #!/bin/bash
        args="$*"

        if [[ "$args" == *"query --displays"* ]]; then
          echo '[{"index":1}]'
          exit 0
        fi

        if [[ "$args" == *"query --spaces"* ]]; then
          echo '[{"index":1,"display":1}]'
          exit 0
        fi

        if [[ "$args" == *"query --windows --window"* ]]; then
          echo '{"id":101,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}'
          exit 0
        fi

        if [[ "$args" == *"query --windows"* ]]; then
          echo '[{"id":101,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]'
          exit 0
        fi

        if [[ "$args" == *"window --focus"* || "$args" == *"window --minimize"* || "$args" == *"window --close"* ]]; then
          exit 0
        fi

        echo 'unhandled yabai mock invocation' >&2
        exit 1
        """
}
