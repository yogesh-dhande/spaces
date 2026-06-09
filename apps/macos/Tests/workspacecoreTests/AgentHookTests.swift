import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

private final class AgentHookTerminalCloseCapture: @unchecked Sendable { var sessionIDs: [String] = [] }

private final class AgentHookTerminalTerminateCapture: @unchecked Sendable { var sessionIDs: [String] = [] }

final class AgentHookTests: XCTestCase {
    override func invokeTest() {
        do { try withMockCommands(["yabai": Self.yabaiMockScript]) { super.invokeTest() } } catch {
            XCTFail("Failed to install mock commands: \(error)")
        }
    }

    func testRegisterAgentWindowCreatesDedicatedWindowRecord() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session", codexThreadID: "thread-1",
            yabaiWindowID: 101, status: .idle)

        XCTAssertEqual(record.provider, .spaces)
        XCTAssertEqual(record.label, "Codex CLI")
        XCTAssertEqual(record.terminalTrackingID, "workspace-session")
        XCTAssertEqual(record.windowID, 101)
        XCTAssertEqual(record.yabaiWindowID, 101)
        XCTAssertEqual(record.status, .idle)
    }

    func testRegisterAgentWindowUpdatesExistingWindowRecord() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", yabaiWindowID: 101, status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session-2", yabaiWindowID: 101,
            status: .spinning)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.label, "Codex CLI")
        XCTAssertEqual(second.terminalTrackingID, "workspace-session-2")
        XCTAssertEqual(second.status, .spinning)
    }

    func testRegisterAgentWindowKeepsSeparateDedicatedWindowsDistinct() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session-1", yabaiWindowID: 101, status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session-2", yabaiWindowID: 202, status: .spinning)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(try store.agentWindows(workspaceID: workspace.id).compactMap(\.yabaiWindowID)), Set([101, 202]))
    }

    func testRegisterAgentWindowAutoRenamesDuplicateAdHocAgentLabels() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "workspace-session-1",
            codexThreadID: "thread-1", yabaiWindowID: 101, status: .idle)
        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "workspace-session-2",
            codexThreadID: "thread-2", yabaiWindowID: 202, status: .idle)

        XCTAssertEqual(first.label, "Claude Code CLI")
        XCTAssertEqual(second.label, "Claude Code CLI-2")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 2)
    }

    func testRegisterAgentWindowReservesConfiguredLauncherNamesForLauncherOwnedAgent() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, iterm: MockIterm2Adapter(), ghostty: MockGhosttyAdapter(), tmux: MockTmuxAdapter())
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex")]
        }

        let adHoc = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "workspace-session-1", codexThreadID: "thread-1",
            yabaiWindowID: 101, status: .idle)
        let configured = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "workspace-session-2", codexThreadID: "thread-2",
            yabaiWindowID: 202, status: .idle, claimedLauncherName: "Codex")

        XCTAssertEqual(adHoc.label, "Codex-2")
        XCTAssertEqual(configured.label, "Codex")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 2)
    }

    func testUpdateAgentWindowStatusMatchesExistingWindowID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session", codexThreadID: "thread-1",
            yabaiWindowID: 101, status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", codexThreadID: "thread-1", yabaiWindowID: 101,
            label: "Codex CLI", status: .done)

        XCTAssertEqual(updated.status, .done)
        XCTAssertEqual(updated.yabaiWindowID, 101)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testUpdateAgentWindowStatusKeepsExistingLabelStable() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let existing = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "workspace-session",
            codexThreadID: "thread-1", yabaiWindowID: 101, status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", codexThreadID: "thread-1", yabaiWindowID: 101,
            label: "Claude Code CLI", status: .spinning)

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.label, "Claude Code CLI")
        XCTAssertEqual(updated.status, .spinning)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testUpdateAgentWindowStatusPrefersTerminalSessionMatchOverWindowID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let existing = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "workspace-session",
            codexThreadID: "thread-1", yabaiWindowID: 101, status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", codexThreadID: "thread-1", yabaiWindowID: 202,
            label: "Claude Code CLI", status: .waiting)

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.yabaiWindowID, 202)
        XCTAssertEqual(updated.status, .waiting)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    func testUpdateAgentWindowStatusIgnoresYabaiWindowIDForBuiltInSpacesSessionIdentity() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = UUID().uuidString

        let existing = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: sessionID, terminalNativeID: sessionID,
            codexThreadID: "thread-1", yabaiWindowID: 101, status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, codexThreadID: "thread-1", yabaiWindowID: 202,
            label: "Claude Code CLI", status: .waiting)

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertNil(updated.yabaiWindowID)
        XCTAssertEqual(updated.status, .waiting)
        XCTAssertFalse(try store.windows(workspaceID: workspace.id).contains { $0.windowID == 101 || $0.windowID == 202 })
    }

    func testUpdateAgentWindowStatusFallsBackToCodexThreadMatch() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", codexThreadID: "thread-xyz", yabaiWindowID: 101,
            status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session", codexThreadID: "thread-xyz", yabaiWindowID: nil,
            label: "Codex CLI", status: .spinning)

        XCTAssertEqual(updated.id, try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first).id)
        XCTAssertEqual(updated.label, "Codex CLI")
        XCTAssertEqual(updated.status, .spinning)
    }

    func testAgentWindowsReturnsOnlyWorkspaceRecords() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let (_, workspace2) = try makeProjectAndWorkspace(store: store, projectName: "proj2", workspaceName: "ws2")

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session-1", yabaiWindowID: 101, status: .idle)
        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "workspace-session-2", yabaiWindowID: 202, status: .spinning)
        try orchestrator.registerAgentWindow(
            workspaceID: workspace2.id, provider: .spaces, terminalTrackingID: "workspace-session-3", yabaiWindowID: 303, status: .waiting)

        let records = try orchestrator.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap(\.yabaiWindowID)), Set([101, 202]))
    }

    func testRegisterAgentWindowPreservesSpacesProvider() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code", terminalTrackingID: "spaces-terminal-1", codexThreadID: "thread-1",
            yabaiWindowID: 303, status: .waiting)

        XCTAssertEqual(record.provider, .spaces)
        XCTAssertEqual(try XCTUnwrap(store.agentWindows(workspaceID: workspace.id).first).provider, .spaces)
    }

    func testRegisterAgentWindowCreatesTrackedTerminalRowForAdHocAgent() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session", codexThreadID: "thread-1",
            yabaiWindowID: 101, status: .idle)

        let windows = try store.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.role, "terminal")
        XCTAssertEqual(windows.first?.windowID, 101)
        XCTAssertEqual(windows.first?.terminalTrackingID, "workspace-session")
    }

    func testHandleAgentExitDeletesClosedAdHocAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "workspace-session", codexThreadID: "thread-1",
            yabaiWindowID: 202, status: .done)

        let result = try orchestrator.handleAgentExit(agent, terminalNativeID: "workspace-session", yabaiWindowID: 202)

        XCTAssertNil(result)
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testHandleAgentExitKeepsLiveAdHocSpacesSessionIdleWithoutPersistingSignalWindowID() throws {
        let store = try makeTemporaryStore()
        let closeCapture = AgentHookTerminalCloseCapture()
        let terminateCapture = AgentHookTerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { closeCapture.sessionIDs.append($0) },
            builtInTerminalSessionTerminator: { terminateCapture.sessionIDs.append($0) })
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = UUID().uuidString
        try writeLiveBuiltInTerminalSession(sessionID: sessionID, workspaceDirectory: workspace.dir)

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: sessionID, terminalNativeID: sessionID,
            codexThreadID: "thread-1", yabaiWindowID: 101, status: .done)

        let result = try orchestrator.handleAgentExit(agent, terminalNativeID: sessionID, yabaiWindowID: 202)

        let record = try XCTUnwrap(result)
        XCTAssertEqual(record.status, .idle)
        XCTAssertEqual(record.terminalTrackingID, sessionID)
        XCTAssertNil(record.yabaiWindowID)
        let storedAgent = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertEqual(storedAgent.terminalTrackingID, sessionID)
        XCTAssertNil(storedAgent.yabaiWindowID)
        let trackedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first)
        XCTAssertEqual(trackedWindow.terminalTrackingID, sessionID)
        XCTAssertNil(trackedWindow.windowID)
        XCTAssertTrue(closeCapture.sessionIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    func testHandleAgentExitKeepsClosedConfiguredSpacesAgentRow() throws {
        let store = try makeTemporaryStore()
        let closeCapture = AgentHookTerminalCloseCapture()
        let terminateCapture = AgentHookTerminalTerminateCapture()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowCloser: { closeCapture.sessionIDs.append($0) },
            builtInTerminalSessionTerminator: { terminateCapture.sessionIDs.append($0) })
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.setWorkspaceAgentLaunchers(
            workspaceID: workspace.id, launchers: [AgentLauncher(name: "Configured Agent", command: "configured-agent")])

        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Configured Agent", terminalTrackingID: "configured-session",
            terminalNativeID: "configured-session", codexThreadID: "thread-1", yabaiWindowID: 202, status: .idle,
            claimedLauncherName: "Configured Agent")

        let result = try orchestrator.handleAgentExit(agent, terminalNativeID: "configured-session", yabaiWindowID: 303)

        let record = try XCTUnwrap(result)
        XCTAssertEqual(record.status, .done)
        XCTAssertEqual(record.terminalTrackingID, "configured-session")
        XCTAssertNil(record.yabaiWindowID)
        XCTAssertEqual(record.claimedLauncherName, "Configured Agent")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).first?.terminalTrackingID, "configured-session")
        XCTAssertNil(try store.agentWindows(workspaceID: workspace.id).first?.yabaiWindowID)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).first?.terminalTrackingID, "configured-session")
        XCTAssertNil(try store.windows(workspaceID: workspace.id).first?.windowID)
        XCTAssertTrue(closeCapture.sessionIDs.isEmpty)
        XCTAssertTrue(terminateCapture.sessionIDs.isEmpty)
    }

    func testRefreshWorkspaceWindowsDeletesClosedSpacesAdHocAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "spaces-terminal-202",
            codexThreadID: "thread-1", yabaiWindowID: 202, status: .idle)

        let didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)

        XCTAssertTrue(didMutate)
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    func testRefreshWorkspaceWindowsKeepsClosedConfiguredSpacesAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.setWorkspaceAgentLaunchers(
            workspaceID: workspace.id, launchers: [AgentLauncher(name: "Configured Agent", command: "configured-agent")])

        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Configured Agent", terminalTrackingID: "configured-session",
            terminalNativeID: "configured-session", codexThreadID: "thread-1", yabaiWindowID: 202, status: .idle,
            claimedLauncherName: "Configured Agent")

        let didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)

        let record = try XCTUnwrap(try store.agentWindows(workspaceID: workspace.id).first)
        XCTAssertTrue(didMutate)
        XCTAssertEqual(record.label, "Configured Agent")
        XCTAssertEqual(record.terminalTrackingID, "configured-session")
        XCTAssertEqual(record.claimedLauncherName, "Configured Agent")
        XCTAssertNil(record.runtimeTargetID)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    private func makeProjectAndWorkspace(store: SQLiteStore, projectName: String = "TestProject", workspaceName: String = "default") throws -> (
        ProjectRecord, WorkspaceRecord
    ) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = ProjectRecord(
            id: dir, name: projectName, dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [], processes: [],
            browserSessions: [])
        try store.upsert(project: project)
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: workspaceName, dir: dir + "/\(workspaceName)", dirname: nil, branch: nil,
            isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    private func writeLiveBuiltInTerminalSession(sessionID: String, workspaceDirectory: String) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "shell", workingDirectory: workspaceDirectory, shell: "/bin/zsh",
                command: nil, createdAt: "2026-06-06T00:00:00Z", workspaceID: nil, kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
                updatedAt: "2026-06-06T00:00:01Z", title: "shell", workingDirectory: workspaceDirectory), paths: paths)
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data()))
    }

    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let original { setenv(name, original, 1) } else { unsetenv(name) } }
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
          if [[ -n "${YABAI_FOCUSED_JSON:-}" ]]; then
            echo "$YABAI_FOCUSED_JSON"
          else
            echo '{"id":101,"pid":11,"app":"Spaces","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}'
          fi
          exit 0
        fi

        if [[ "$args" == *"query --windows"* ]]; then
          if [[ -n "${YABAI_WINDOWS_JSON:-}" ]]; then
            echo "$YABAI_WINDOWS_JSON"
          else
            echo '[{"id":101,"pid":11,"app":"Spaces","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]'
          fi
          exit 0
        fi

        if [[ "$args" == *"window --focus"* || "$args" == *"window --minimize"* || "$args" == *"window --close"* ]]; then
          exit 0
        fi

        echo 'unhandled yabai mock invocation' >&2
        exit 1
        """
}
