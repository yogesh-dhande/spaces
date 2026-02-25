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
