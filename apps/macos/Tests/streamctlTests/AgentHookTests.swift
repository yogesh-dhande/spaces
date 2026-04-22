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
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
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
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
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
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
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

    func testRegisterAgentWindowAutoRenamesDuplicateAdHocAgentLabels() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Claude Code CLI",
            itermSessionID: "workspace-session-1",
            codexThreadID: "thread-1",
            yabaiWindowID: 101,
            status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Claude Code CLI",
            itermSessionID: "workspace-session-2",
            codexThreadID: "thread-2",
            yabaiWindowID: 202,
            status: .idle)

        XCTAssertEqual(first.label, "Claude Code CLI")
        XCTAssertEqual(second.label, "Claude Code CLI-2")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 2)
    }

    func testUpdateAgentWindowStatusMatchesExistingWindowID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
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

    func testUpdateAgentWindowStatusKeepsExistingLabelStable() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let existing = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Claude Code CLI",
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
            label: "Claude Code CLI",
            status: .spinning)

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.label, "Claude Code CLI")
        XCTAssertEqual(updated.status, .spinning)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testUpdateAgentWindowStatusPrefersItermSessionMatchOverWindowID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let existing = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Claude Code CLI",
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 101,
            status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 202,
            label: "Claude Code CLI",
            status: .waiting)

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.yabaiWindowID, 202)
        XCTAssertEqual(updated.status, .waiting)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testUpdateAgentWindowStatusFallsBackToCodexThreadMatch() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
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
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
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

    func testRegisterAgentWindowPreservesGhosttyProvider() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .ghostty,
            label: "Claude Code",
            itermSessionID: "ghostty-terminal-1",
            codexThreadID: "thread-1",
            yabaiWindowID: 303,
            status: .waiting)

        XCTAssertEqual(record.provider, .ghostty)
        XCTAssertEqual(try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first).provider, .ghostty)
    }

    func testUpdateGhosttyAgentStatusMatchesTrackingTokenBeforeWindowID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .ghostty,
            label: "Claude Code CLI",
            itermSessionID: "ghostty-muxy-token-1",
            codexThreadID: "thread-1",
            yabaiWindowID: 303,
            status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id,
            provider: .ghostty,
            itermSessionID: "ghostty-muxy-token-1",
            codexThreadID: "thread-1",
            yabaiWindowID: 404,
            label: "Claude Code CLI",
            status: .spinning)

        XCTAssertEqual(updated.itermSessionID, "ghostty-muxy-token-1")
        XCTAssertEqual(updated.yabaiWindowID, 404)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)

        let windows = try store.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.itermSessionID, "ghostty-muxy-token-1")
        XCTAssertEqual(windows.first?.windowID, 404)
    }

    func testRegisterAgentWindowLinksMatchingWorkspaceProcessTerminal() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1",
                workspaceID: workspace.id,
                templateName: "api",
                command: "run api",
                terminalApp: "iTerm2",
                windowID: 101,
                itermSessionID: "workspace-session",
                itermTabIndex: nil,
                tmuxWindowID: "tmux-1",
                pid: 1,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: nil,
                exitedAt: nil))

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Codex CLI",
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 101,
            status: .idle)

        XCTAssertEqual(record.tmuxWindowID, "tmux-1")
    }

    func testUpdateAgentWindowStatusMatchesTmuxBackedWorkspaceProcessBeforeSharedItermSession() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-claude",
                workspaceID: workspace.id,
                templateName: "claude",
                command: "claude",
                terminalApp: "iTerm2",
                windowID: 101,
                itermSessionID: "shared-session",
                itermTabIndex: nil,
                tmuxWindowID: "@2",
                pid: 2,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: nil,
                exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "window-claude",
                workspaceID: workspace.id,
                app: "iTerm2",
                name: "claude",
                detail: "claude",
                targetURL: nil,
                windowID: 101,
                itermSessionID: "shared-session",
                itermTabIndex: nil,
                tmuxWindowID: "@2",
                role: "terminal",
                orderIndex: 201,
                lastSeenAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-existing",
                workspaceID: workspace.id,
                provider: .iterm2,
                label: "Claude Code CLI",
                itermSessionID: "other-session",
                tmuxWindowID: "@2",
                codexThreadID: "thread-1",
                windowID: 101,
                yabaiWindowID: 101,
                status: .idle,
                createdAt: "now",
                updatedAt: "now"))

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "shared-session",
            codexThreadID: "thread-2",
            tmuxWindowID: "@2",
            yabaiWindowID: 101,
            label: "Claude Code CLI",
            status: .spinning)

        XCTAssertEqual(updated.id, "agent-existing")
        XCTAssertEqual(updated.tmuxWindowID, "@2")
        XCTAssertEqual(updated.itermSessionID, "shared-session")
        XCTAssertEqual(updated.status, AgentWindowStatus.spinning)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testRegisterAgentWindowDoesNotClaimTmuxProcessFromDifferentTabInSameItermWindow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-web",
                workspaceID: workspace.id,
                templateName: "web server",
                command: "npm run dev",
                terminalApp: "iTerm2",
                windowID: 101,
                itermSessionID: "session-web",
                itermTabIndex: 1,
                tmuxWindowID: "@2",
                pid: 2,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: nil,
                exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "window-web",
                workspaceID: workspace.id,
                app: "iTerm2",
                name: "web server",
                detail: "npm run dev",
                targetURL: nil,
                windowID: 101,
                itermSessionID: "session-web",
                itermTabIndex: 1,
                tmuxWindowID: "@2",
                role: "terminal",
                orderIndex: 201,
                lastSeenAt: "now"))

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Claude Code CLI",
            itermSessionID: "session-agent",
            codexThreadID: "thread-1",
            yabaiWindowID: 101,
            status: .idle)

        XCTAssertNil(agent.tmuxWindowID)
        XCTAssertEqual(agent.itermSessionID, "session-agent")

        let process = try XCTUnwrap(store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(process.itermSessionID, "session-web")
        XCTAssertEqual(process.tmuxWindowID, "@2")

        let trackedTerminal = try XCTUnwrap(store.windows(workspaceID: workspace.id).first(where: { $0.id == "window-web" }))
        XCTAssertEqual(trackedTerminal.itermSessionID, "session-web")
        XCTAssertEqual(trackedTerminal.tmuxWindowID, "@2")
    }

    func testRegisterAgentWindowCreatesTrackedTerminalRowForAdHocAgent() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Codex CLI",
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 101,
            status: .idle)

        let windows = try store.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.role, "terminal")
        XCTAssertEqual(windows.first?.windowID, 101)
        XCTAssertEqual(windows.first?.itermSessionID, "workspace-session")
    }

    func testHandleAgentExitDeletesClosedAdHocAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Codex CLI",
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 202,
            status: .done)

        let result = try orchestrator.handleAgentExit(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 202,
            label: "Codex CLI")

        XCTAssertNil(result)
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testRefreshWorkspaceWindowsDeletesClosedGhosttyAdHocAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .ghostty,
            label: "Claude Code CLI",
            itermSessionID: "ghostty-terminal-202",
            codexThreadID: "thread-1",
            yabaiWindowID: 202,
            status: .idle)

        let didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)

        XCTAssertTrue(didMutate)
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testHandleAgentExitKeepsWorkspaceProcessAgentRowIdleWhenWindowClosed() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-1",
                workspaceID: workspace.id,
                templateName: "api",
                command: "run api",
                terminalApp: "iTerm2",
                windowID: 202,
                itermSessionID: "workspace-session",
                itermTabIndex: nil,
                tmuxWindowID: "tmux-1",
                pid: 1,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: nil,
                exitedAt: nil))
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id,
            provider: .iterm2,
            label: "Codex CLI",
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 202,
            status: .done)

        let result = try orchestrator.handleAgentExit(
            workspaceID: workspace.id,
            provider: .iterm2,
            itermSessionID: "workspace-session",
            codexThreadID: "thread-1",
            yabaiWindowID: 202,
            label: "Codex CLI")

        XCTAssertEqual(result?.status, .idle)
        XCTAssertEqual(result?.tmuxWindowID, "tmux-1")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
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
            id: UUID().uuidString, projectID: project.id, title: workspaceName, dir: dir + "/\(workspaceName)", dirname: nil, branch: nil,
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
