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

    // Tests registerAgentWindow creates new record for iTerm2.
    func testRegisterAgentWindowCreatesNewIterm2Record() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (project, workspace) = try makeProjectAndWorkspace(store: store)
        _ = project
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        let record = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .idle)

        XCTAssertEqual(record.workspaceID, workspace.id)
        XCTAssertEqual(record.provider, .iterm2)
        XCTAssertEqual(record.tmuxWindowID, "@1")
        XCTAssertEqual(record.status, .idle)

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
        XCTAssertEqual(allRecords[0].id, record.id)
    }

    // Tests registerAgentWindow updates existing iTerm2 session (same sessionID → same row).
    func testRegisterAgentWindowUpdatesSameItermSession() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        mockTmux.createSession(named: "muxy-\(workspace.id)")
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "agent-1", index: 0, isActive: true)
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "agent-2", index: 1)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .idle)

        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .spinning)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.status, .spinning)

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
    }

    // Tests registerAgentWindow keeps separate iTerm2 rows for distinct sessions.
    func testRegisterAgentWindowKeepsDistinctItermSessions() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        mockTmux.createSession(named: "muxy-\(workspace.id)")
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "agent-1", index: 0, isActive: true)
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "agent-2", index: 1)

        let first = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .idle)

        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@2", status: .spinning)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.tmuxWindowID, "@2")

        let allRecords = try store.agentWindowsByProvider(workspaceID: workspace.id, provider: .iterm2)
        XCTAssertEqual(allRecords.count, 2)
        XCTAssertEqual(Set(allRecords.compactMap(\.tmuxWindowID)), Set(["@1", "@2"]))
    }

    // Tests updateAgentWindowStatus creates record when not found.
    func testUpdateAgentWindowStatusCreatesWhenNotFound() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        let record = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .waiting)

        XCTAssertEqual(record.status, .waiting)
        XCTAssertEqual(record.tmuxWindowID, "@1")

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
    }

    // Tests updateAgentWindowStatus updates existing record.
    func testUpdateAgentWindowStatusUpdatesExistingRecord() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .done)

        XCTAssertEqual(updated.status, .done)

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
        XCTAssertEqual(allRecords[0].status, .done)
    }

    // Tests updateAgentWindowStatus can persist/update display label metadata for an existing agent row.
    func testUpdateAgentWindowStatusUpdatesExistingLabel() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, label: "Claude Code CLI", itermSessionID: "workspace-session", tmuxWindowID: "@1",
            status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", label: "Codex CLI",
            status: .spinning)

        XCTAssertEqual(updated.label, "Codex CLI")

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords[0].label, "Codex CLI")
    }

    // Tests agentWindows returns correct records.
    func testAgentWindowsReturnsCorrectRecords() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let (_, workspace2) = try makeProjectAndWorkspace(store: store, projectName: "proj2", workspaceName: "ws2")
        mockTmux.createSession(named: "muxy-\(workspace.id)")
        mockTmux.createSession(named: "muxy-\(workspace2.id)")
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "agent-1", index: 0, isActive: true)
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "agent-2", index: 1)
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace2.id)", id: "@3", name: "agent-3", index: 0, isActive: true)

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .idle)
        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@2", status: .spinning)
        // Different workspace - should not appear
        try orchestrator.registerAgentWindow(
            workspaceID: workspace2.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@3", status: .waiting)

        let records = try orchestrator.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.tmuxWindowID == "@1" })
        XCTAssertTrue(records.contains { $0.tmuxWindowID == "@2" })
    }

    // Tests provider detection defaults to iTerm2 for non-agent CLI context.
    func testProviderDetectionDefaultsToIterm2() {
        let env: [String: String] = ["ITERM_SESSION_ID": "some-session"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let provider: AgentProvider = bundleID == "com.googlecode.iterm2" ? .iterm2 : .iterm2
        XCTAssertEqual(provider, .iterm2)
    }

    // Tests Codex desktop bundle no longer resolves to a supported provider.
    func testProviderDetectionDoesNotResolveCodexDesktopBundle() {
        let env: [String: String] = ["__CFBundleIdentifier": "com.openai.codex"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let provider: AgentProvider? = bundleID == "com.googlecode.iterm2" ? .iterm2 : nil
        XCTAssertNil(provider)
    }

    // Tests inferCodingAgentProvider logic: returns nil when no known coding agent env var is set.
    func testInferCodingAgentProviderReturnsNilWithoutEnvVars() {
        let env: [String: String] = [:]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let claudeEntrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
        let provider: AgentProvider?
        if bundleID == "com.googlecode.iterm2", claudeEntrypoint != nil { provider = .iterm2 } else { provider = nil }
        XCTAssertNil(provider)
    }

    // Tests inferCodingAgentProvider logic: returns iterm2 when CLAUDE_CODE_ENTRYPOINT is set.
    func testInferCodingAgentProviderReturnsiterm2ForClaudeCode() {
        let env: [String: String] = ["__CFBundleIdentifier": "com.googlecode.iterm2", "CLAUDE_CODE_ENTRYPOINT": "cli"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let claudeEntrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
        let provider: AgentProvider?
        if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil {
            provider = .iterm2
        } else if claudeEntrypoint != nil {
            provider = .iterm2
        } else {
            provider = nil
        }
        XCTAssertEqual(provider, .iterm2)
    }

    // Tests inferCodingAgentProvider logic: returns iterm2 for Codex CLI shell env (so focus goes to terminal session).
    func testInferCodingAgentProviderReturnsIterm2ForCodexCLI() {
        let env: [String: String] = ["__CFBundleIdentifier": "com.googlecode.iterm2", "CODEX_THREAD_ID": "thread-123"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let claudeEntrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
        let provider: AgentProvider?
        if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil {
            provider = .iterm2
        } else if claudeEntrypoint != nil {
            provider = .iterm2
        } else {
            provider = nil
        }
        XCTAssertEqual(provider, .iterm2)
    }

    // Tests CODEX_THREAD_ID alone is not enough unless running under iTerm2 bundle.
    func testInferCodingAgentProviderDoesNotTreatNonItermCodexThreadAsCLI() {
        let env: [String: String] = ["CODEX_THREAD_ID": "thread-123"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let claudeEntrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
        let provider: AgentProvider?
        if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil {
            provider = .iterm2
        } else if claudeEntrypoint != nil {
            provider = .iterm2
        } else {
            provider = nil
        }
        XCTAssertNil(provider)
    }

    // Tests unsupported terminal hosts with Claude env markers are ignored (not auto-detected as iTerm2).
    func testInferCodingAgentProviderDoesNotTreatNonItermClaudeAsCLI() {
        let env: [String: String] = ["CLAUDE_CODE_ENTRYPOINT": "cli"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let claudeEntrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
        let provider: AgentProvider?
        if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil {
            provider = .iterm2
        } else if bundleID == "com.googlecode.iterm2", claudeEntrypoint != nil {
            provider = .iterm2
        } else {
            provider = nil
        }
        XCTAssertNil(provider)
    }

    // Tests that agent event "stop" type sets status to done (same as "done").
    func testAgentStopEventSetsStatusToDone() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .spinning)
        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", status: .done)
        XCTAssertEqual(updated.status, .done)

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords[0].status, .done)
    }

    // Tests updateAgentWindowStatus without an existing session creates a new terminal-backed record.
    func testUpdateAgentWindowStatusCreatesNewTerminalRecordWithoutSessionMatch() throws {
        let store = try makeTemporaryStore()
        let (orchestrator, _, mockTmux) = makeTmuxOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "workspace-session", tmuxWindowID: "@1", codexThreadID: "thread-xyz",
            status: .spinning)

        XCTAssertEqual(updated.status, .spinning)
        XCTAssertEqual(updated.codexThreadID, "thread-xyz")
        XCTAssertEqual(updated.tmuxWindowID, "@1")

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
        XCTAssertEqual(allRecords[0].status, .spinning)
    }

    // MARK: - Helpers

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

    private func makeTmuxOrchestrator(store: SQLiteStore) -> (MuxyOrchestrator, MockIterm2Adapter, MockTmuxAdapter) {
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)
        return (orchestrator, mockIterm, mockTmux)
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

        echo "unsupported yabai args: $args" >&2
        exit 1
        """
}
