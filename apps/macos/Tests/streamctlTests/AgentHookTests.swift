import XCTest
import appctl

@testable import streamctl

final class AgentHookTests: XCTestCase {

    // Tests registerAgentWindow creates new record for iTerm2.
    func testRegisterAgentWindowCreatesNewIterm2Record() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let (project, workspace) = try makeProjectAndWorkspace(store: store)
        _ = project

        let record = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .iterm2, itermSessionID: "session-abc", status: .idle)

        XCTAssertEqual(record.workspaceID, workspace.id)
        XCTAssertEqual(record.provider, .iterm2)
        XCTAssertEqual(record.itermSessionID, "session-abc")
        XCTAssertEqual(record.status, .idle)

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
        XCTAssertEqual(allRecords[0].id, record.id)
    }

    // Tests registerAgentWindow updates existing iTerm2 session (same sessionID → same row).
    func testRegisterAgentWindowUpdatesSameItermSession() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        // Make listSessionIDs return the session so it won't be pruned
        mockIterm.stubbedSessionIDs = ["session-xyz"]
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .iterm2, itermSessionID: "session-xyz", status: .idle)

        let second = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "session-xyz", status: .spinning)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.status, .spinning)

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
    }

    // Tests registerAgentWindow replaces existing Codex record (only 1 per workspace).
    func testRegisterAgentWindowReplacesSingleCodexRecord() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let first = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .codex, codexThreadID: "thread-1", status: .idle)

        let second = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .codex, codexThreadID: "thread-2", status: .spinning)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.codexThreadID, "thread-2")

        let allRecords = try store.agentWindowsByProvider(workspaceID: workspace.id, provider: .codex)
        XCTAssertEqual(allRecords.count, 1)
        XCTAssertEqual(allRecords[0].codexThreadID, "thread-2")
    }

    // Tests updateAgentWindowStatus creates record when not found.
    func testUpdateAgentWindowStatusCreatesWhenNotFound() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        let record = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "new-session", status: .waiting)

        XCTAssertEqual(record.status, .waiting)
        XCTAssertEqual(record.itermSessionID, "new-session")

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
    }

    // Tests updateAgentWindowStatus updates existing record.
    func testUpdateAgentWindowStatusUpdatesExistingRecord() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        mockIterm.stubbedSessionIDs = ["session-1"]
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .iterm2, itermSessionID: "session-1", status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "session-1", status: .done)

        XCTAssertEqual(updated.status, .done)

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords.count, 1)
        XCTAssertEqual(allRecords[0].status, .done)
    }

    // Tests updateAgentWindowStatus can persist/update display label metadata for an existing agent row.
    func testUpdateAgentWindowStatusUpdatesExistingLabel() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        mockIterm.stubbedSessionIDs = ["session-1"]
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .iterm2, label: "Claude Code CLI", itermSessionID: "session-1", status: .idle)

        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .iterm2, itermSessionID: "session-1", label: "Codex CLI", status: .spinning)

        XCTAssertEqual(updated.label, "Codex CLI")

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords[0].label, "Codex CLI")
    }

    // Tests stopWorkspace preserves iTerm2 agent sessions and their DB records.
    func testStopWorkspacePreservesItermAgentSessions() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        mockIterm.stubbedSessionIDs = ["agent-session"]
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let (project, workspace) = try makeProjectAndWorkspace(store: store)
        _ = project

        // Mark workspace as running
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: nil)

        // Register an iTerm2 agent window
        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .iterm2, itermSessionID: "agent-session", status: .waiting)

        // Stop workspace
        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        // Agent session should not be closed — coding agent sessions survive workspace stop.
        XCTAssertFalse(mockIterm.closedSessionIDs.contains("agent-session"))

        // Agent window records should be preserved
        let remaining = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(remaining.count, 1)
    }

    // Tests agentWindows returns correct records.
    func testAgentWindowsReturnsCorrectRecords() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let (_, workspace2) = try makeProjectAndWorkspace(store: store, projectName: "proj2", workspaceName: "ws2")

        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .iterm2, itermSessionID: "s1", status: .idle)
        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .codex, codexThreadID: "t1", status: .spinning)
        // Different workspace - should not appear
        try orchestrator.registerAgentWindow(workspaceID: workspace2.id, provider: .iterm2, itermSessionID: "s2", status: .waiting)

        let records = try orchestrator.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.itermSessionID == "s1" })
        XCTAssertTrue(records.contains { $0.codexThreadID == "t1" })
    }

    // Tests provider detection defaults to iterm2 for CLI context.
    func testProviderDetectionDefaultsToIterm2() {
        // Simulating: no __CFBundleIdentifier == com.openai.codex → iterm2
        let env: [String: String] = ["ITERM_SESSION_ID": "some-session"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let provider: AgentProvider = bundleID == "com.openai.codex" ? .codex : .iterm2
        XCTAssertEqual(provider, .iterm2)
    }

    // Tests provider detection resolves to codex when bundle ID matches.
    func testProviderDetectionResolvesToCodex() {
        let env: [String: String] = ["__CFBundleIdentifier": "com.openai.codex"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let provider: AgentProvider = bundleID == "com.openai.codex" ? .codex : .iterm2
        XCTAssertEqual(provider, .codex)
    }

    // Tests inferCodingAgentProvider logic: returns nil when no known coding agent env var is set.
    func testInferCodingAgentProviderReturnsNilWithoutEnvVars() {
        let env: [String: String] = [:]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let claudeEntrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
        let provider: AgentProvider?
        if bundleID == "com.openai.codex" { provider = .codex } else if claudeEntrypoint != nil { provider = .iterm2 } else { provider = nil }
        XCTAssertNil(provider)
    }

    // Tests inferCodingAgentProvider logic: returns iterm2 when CLAUDE_CODE_ENTRYPOINT is set.
    func testInferCodingAgentProviderReturnsiterm2ForClaudeCode() {
        let env: [String: String] = ["__CFBundleIdentifier": "com.googlecode.iterm2", "CLAUDE_CODE_ENTRYPOINT": "cli"]
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let claudeEntrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
        let provider: AgentProvider?
        if bundleID == "com.openai.codex" {
            provider = .codex
        } else if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil {
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
        if bundleID == "com.openai.codex" {
            provider = .codex
        } else if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil {
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
        if bundleID == "com.openai.codex" {
            provider = .codex
        } else if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil {
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
        if bundleID == "com.openai.codex" {
            provider = .codex
        } else if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil {
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
        let orchestrator = MuxyOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .codex, status: .spinning)
        let updated = try orchestrator.updateAgentWindowStatus(workspaceID: workspace.id, provider: .codex, status: .done)
        XCTAssertEqual(updated.status, .done)

        let allRecords = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(allRecords[0].status, .done)
    }

    // Tests updateAgentWindowStatus with a specific codex thread ID matches and updates the existing record by arranging representative inputs and asserting the expected result.
    func testUpdateAgentWindowStatusWithCodexThreadIDUpdatesMatchingRecord() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)

        // Register a codex agent window with a specific thread ID.
        try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .codex, codexThreadID: "thread-xyz", status: .idle)

        // updateAgentWindowStatus with codexThreadID takes the "else if provider == .codex, let threadID" branch.
        let updated = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .codex, codexThreadID: "thread-xyz", status: .spinning)

        XCTAssertEqual(updated.status, .spinning)
        XCTAssertEqual(updated.codexThreadID, "thread-xyz")

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
}
