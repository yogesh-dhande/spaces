import XCTest

@testable import workspacecore

/// The path hook signals and OSC 7501 reports share into agent rows and notifications, and the rule
/// that an agent's own report outranks the status its hooks derive.
extension OrchestratorTests {
    private struct StatusSignalFixture {
        let store: SQLiteStore
        let orchestrator: WorkspaceOrchestrator
        let workspaceID: String
        let delivered = AgentNotificationSubmitterRecorder()
        let reporting = ProgramStatusReportingSessions()

        func record(
            _ signal: AgentStatusSignal, _ origin: AgentStatusSignalOrigin, sessionKey: AgentSessionKeyUpdate = .keep, detectedLabel: String? = "Codex"
        ) throws -> AgentStatusSignalOutcome {
            // The daemon marks a session as reporting before it queues the report's write.
            if origin == .programStatus { reporting.insert(sessionID: "agent-terminal") }
            return try orchestrator.recordAgentStatusSignal(
                signal, origin: origin, workspaceID: workspaceID, terminalSessionID: "agent-terminal", sessionKey: sessionKey,
                detectedAgentLabel: detectedLabel, programStatusSessions: reporting,
                makeNotificationEngine: {
                    AgentNotificationEngine(store: store, deliver: { try delivered.submit($0, $1) }, logError: { _ in })
                })
        }

        var agent: AgentWindowRecord? { try? store.agentWindows(workspaceID: workspaceID).first }
    }

    private func makeStatusSignalFixture() throws -> StatusSignalFixture {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory().path
        let project = makeProjectRecord(dir: projectDir)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: projectDir)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        return StatusSignalFixture(store: store, orchestrator: makeTestOrchestrator(store: store), workspaceID: workspace.id)
    }

    /// A report must raise the same blocked/done notice a hook does, so watchers need no knowledge of
    /// where the status came from.
    func testProgramStatusDoneWritesADoneRowAndNotifiesSubscribers() throws {
        let fixture = try makeStatusSignalFixture()
        let child = try fixture.orchestrator.registerAgentWindow(
            workspaceID: fixture.workspaceID, provider: .spaces, label: "Codex", terminalTrackingID: "agent-terminal", status: .spinning)
        try fixture.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-terminal", agentSessionID: child.id, createdAt: "t")

        XCTAssertEqual(try fixture.record(.done, .programStatus), .recorded)

        XCTAssertEqual(fixture.agent?.status, .done)
        XCTAssertEqual(fixture.delivered.delivered.map(\.sessionID), ["watcher-terminal"])
        XCTAssertTrue(try XCTUnwrap(fixture.delivered.delivered.first).line.contains("done"))
        XCTAssertNotNil(try fixture.store.lastAgentSignalAt(agentSessionID: child.id), "a report is lifecycle evidence like a hook signal")
    }

    func testProgramStatusBlockedNotifiesAndWorkingResumesIt() throws {
        let fixture = try makeStatusSignalFixture()
        let child = try fixture.orchestrator.registerAgentWindow(
            workspaceID: fixture.workspaceID, provider: .spaces, label: "Codex", terminalTrackingID: "agent-terminal", status: .spinning)
        try fixture.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-terminal", agentSessionID: child.id, createdAt: "t")

        XCTAssertEqual(try fixture.record(.blocked, .programStatus), .recorded)
        XCTAssertEqual(fixture.agent?.status, .waiting)
        XCTAssertTrue(try XCTUnwrap(fixture.delivered.delivered.first).line.contains("blocked"))

        XCTAssertEqual(try fixture.record(.working, .programStatus), .recorded)
        XCTAssertEqual(fixture.agent?.status, .spinning)
    }

    /// A report queued behind notification delivery can land after its agent ended; it must not write
    /// status or revive the finalized row.
    func testAReportLandingAfterItsAgentEndedChangesNothing() throws {
        let fixture = try makeStatusSignalFixture()
        let child = try fixture.orchestrator.registerAgentWindow(
            workspaceID: fixture.workspaceID, provider: .spaces, label: "Codex", terminalTrackingID: "agent-terminal", status: .spinning)
        try fixture.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-terminal", agentSessionID: child.id, createdAt: "t")

        fixture.reporting.remove(sessionID: "agent-terminal")
        XCTAssertEqual(
            try fixture.orchestrator.recordAgentStatusSignal(
                .done, origin: .programStatus, workspaceID: fixture.workspaceID, terminalSessionID: "agent-terminal", sessionKey: .keep,
                detectedAgentLabel: "Codex", programStatusSessions: fixture.reporting,
                makeNotificationEngine: { AgentNotificationEngine(store: fixture.store, deliver: { _, _ in }, logError: { _ in }) }),
            .ignored)
        XCTAssertEqual(fixture.agent?.status, .spinning)

        try fixture.store.updateAgentWindowStatus(id: child.id, status: .exited, updatedAt: "2000-01-01T00:00:00Z")
        XCTAssertEqual(try fixture.record(.done, .programStatus), .ignored)
        XCTAssertEqual(fixture.agent?.status, .exited)
        XCTAssertTrue(fixture.delivered.delivered.isEmpty)
    }

    func testAReportEstablishesARowOnlyForADetectedAgent() throws {
        let fixture = try makeStatusSignalFixture()

        XCTAssertEqual(try fixture.record(.working, .programStatus, detectedLabel: nil), .ignored)
        XCTAssertNil(fixture.agent)

        XCTAssertEqual(try fixture.record(.working, .programStatus, detectedLabel: "Codex"), .recorded)
        XCTAssertEqual(fixture.agent?.status, .spinning)
    }

    /// Hooks keep owning the conversation id even after the agent reports its own status: only a hook
    /// can learn it.
    func testAfterAReportHookStatusIsIgnoredButItsSessionKeyStillLands() throws {
        let fixture = try makeStatusSignalFixture()
        _ = try fixture.record(.done, .programStatus)
        fixture.reporting.insert(sessionID: "agent-terminal")

        XCTAssertEqual(try fixture.record(.working, .hook), .ignored)
        XCTAssertEqual(fixture.agent?.status, .done)

        XCTAssertEqual(try fixture.record(.working, .hook, sessionKey: .set("conversation-9")), .recorded)
        XCTAssertEqual(fixture.agent?.status, .done, "the hook's status write is skipped")
        XCTAssertEqual(fixture.agent?.sessionKey, "conversation-9")

        // The agent went away: the next agent in this terminal starts on hook status again.
        fixture.reporting.remove(sessionID: "agent-terminal")
        XCTAssertEqual(try fixture.record(.working, .hook), .recorded)
        XCTAssertEqual(fixture.agent?.status, .spinning)
    }

    /// Alerts are keyed by the row's `updatedAt`, so a hook that repeats the conversation id on every tool
    /// call must not make a dismissed done alert reappear.
    func testAHookRepeatingTheSameSessionKeyAfterAReportChangesNothing() throws {
        let fixture = try makeStatusSignalFixture()
        _ = try fixture.record(.working, .hook, sessionKey: .set("conversation-1"))
        _ = try fixture.record(.done, .programStatus)
        fixture.reporting.insert(sessionID: "agent-terminal")
        let id = try XCTUnwrap(fixture.agent?.id)
        try fixture.store.updateAgentWindowStatus(id: id, status: .done, updatedAt: "2000-01-01T00:00:00Z")

        XCTAssertEqual(try fixture.record(.working, .hook, sessionKey: .set("conversation-1")), .unchanged)

        XCTAssertEqual(fixture.agent?.status, .done)
        XCTAssertEqual(fixture.agent?.updatedAt, "2000-01-01T00:00:00Z")
        XCTAssertEqual(fixture.agent?.sessionKey, "conversation-1")
    }

    func testAHookWithANewSessionKeyAfterAReportKeepsStatusAndUpdatedAt() throws {
        let fixture = try makeStatusSignalFixture()
        _ = try fixture.record(.working, .hook, sessionKey: .set("conversation-1"))
        _ = try fixture.record(.done, .programStatus)
        fixture.reporting.insert(sessionID: "agent-terminal")
        let id = try XCTUnwrap(fixture.agent?.id)
        try fixture.store.updateAgentWindowStatus(id: id, status: .done, updatedAt: "2000-01-01T00:00:00Z")

        XCTAssertEqual(try fixture.record(.working, .hook, sessionKey: .set("conversation-2")), .recorded)

        XCTAssertEqual(fixture.agent?.sessionKey, "conversation-2")
        XCTAssertEqual(fixture.agent?.status, .done)
        XCTAssertEqual(fixture.agent?.updatedAt, "2000-01-01T00:00:00Z")
    }

    /// The key-only update re-reads the row in its own transaction, so an exit that finalized the row
    /// after the caller read it is not undone.
    func testAKeyOnlyUpdateNeitherRevivesNorRecreatesAFinalizedRow() throws {
        let fixture = try makeStatusSignalFixture()
        _ = try fixture.record(.working, .hook, sessionKey: .set("conversation-1"))
        let id = try XCTUnwrap(fixture.agent?.id)

        try fixture.store.updateAgentWindowStatus(id: id, status: .exited, updatedAt: "2000-01-01T00:00:00Z")
        XCTAssertFalse(try fixture.orchestrator.updateAgentWindowSessionKey(id: id, sessionKey: .set("conversation-2"), eventSource: "test"))
        XCTAssertEqual(fixture.agent?.status, .exited)
        XCTAssertEqual(fixture.agent?.sessionKey, "conversation-1")

        try fixture.store.deleteAgentWindow(id: id)
        XCTAssertFalse(try fixture.orchestrator.updateAgentWindowSessionKey(id: id, sessionKey: .set("conversation-2"), eventSource: "test"))
        XCTAssertNil(fixture.agent)
    }

    func testAHookBlockedAfterAReportNotifiesNoOne() throws {
        let fixture = try makeStatusSignalFixture()
        let child = try fixture.orchestrator.registerAgentWindow(
            workspaceID: fixture.workspaceID, provider: .spaces, label: "Codex", terminalTrackingID: "agent-terminal", status: .spinning)
        try fixture.store.insertAgentSubscription(subscriberTerminalSessionID: "watcher-terminal", agentSessionID: child.id, createdAt: "t")
        fixture.reporting.insert(sessionID: "agent-terminal")

        XCTAssertEqual(try fixture.record(.blocked, .hook), .ignored)

        XCTAssertEqual(fixture.agent?.status, .spinning)
        XCTAssertTrue(fixture.delivered.delivered.isEmpty)
    }
}
