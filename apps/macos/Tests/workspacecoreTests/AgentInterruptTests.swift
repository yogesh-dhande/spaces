import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Behavior coverage for the lifecycle transition `spaces agent interrupt` records. Interrupting cancels
/// the agent's turn and returns it to an idle prompt, but no supported agent reports that as a hook
/// signal (Codex fires no `Stop` on ESC), so Spaces records it for the action it just took — otherwise
/// the row keeps claiming the agent is working until its next completed turn, which for an abandoned
/// agent never comes and leaves an orchestrator polling `agent status` waiting on an idle child forever.
///
/// Drives the orchestrator method the daemon's `.agentInterrupt` handler calls, with a recorder standing
/// in for the real terminal-send delivery of held child notifications.
final class AgentInterruptTests: XCTestCase {
    /// Records delivered notification lines, standing in for the daemon's terminal-send path.
    private final class DeliveryRecorder: @unchecked Sendable {
        var delivered: [(sessionID: String, line: String)] = []
        func deliver(_ sessionID: String, _ line: String) throws { delivered.append((sessionID: sessionID, line: line)) }
    }

    /// The reported bug: a spinning agent that is interrupted leaves `spinning` without any further hook
    /// signal, and the transition is logged like a signal so `agent status` and Alerts agree with the pane.
    func testInterruptingSpinningAgentRecordsIdle() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try makeWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)

        let updated = try orchestrator.recordAgentInterrupt(
            terminalSessionID: "child-session", notifications: makeEngine(store: store, recorder: recorder))

        XCTAssertEqual(updated?.id, agent.id)
        XCTAssertEqual(
            try store.agentWindow(id: agent.id)?.status, .idle, "An interrupted agent must not stay spinning while it sits at an idle prompt.")
        XCTAssertEqual(
            try interruptEventCount(store: store, agentID: agent.id), 1,
            "The interrupt must be logged as a lifecycle event like any signal-driven transition.")
    }

    /// An interrupt answers a permission prompt the same way it cancels a turn: the agent stops waiting.
    /// Any held "is blocked" line for that child is withdrawn, since delivering it after the interrupt
    /// would tell the subscriber the child is still blocked.
    func testInterruptingBlockedAgentRecordsIdleAndWithdrawsHeldBlockedLine() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try makeWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder)
        // A busy orchestrator terminal watching a child that goes blocked: the line is held, not delivered.
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Orchestrator", terminalTrackingID: "orchestrator-session", status: .spinning)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .waiting)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")
        try engine.childDidTransition(agent: child, transition: .blocked)
        XCTAssertEqual(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orchestrator-session").count, 1)

        try orchestrator.recordAgentInterrupt(terminalSessionID: "child-session", notifications: engine)

        XCTAssertEqual(try store.agentWindow(id: child.id)?.status, .idle)
        XCTAssertTrue(
            try store.pendingAgentNotifications(subscriberTerminalSessionID: "orchestrator-session").isEmpty,
            "A held blocked line for an interrupted child is misinformation and must be withdrawn.")
        XCTAssertTrue(recorder.delivered.isEmpty, "An interrupt notifies nobody: idle is not a transition subscribers are told about.")
    }

    /// The interrupted terminal is back at an idle composer, so the child events held while it was busy
    /// are delivered right away instead of waiting for its own next hook signal.
    func testInterruptFlushesEventsHeldForTheInterruptedTerminal() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try makeWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let engine = makeEngine(store: store, recorder: recorder)
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Orchestrator", terminalTrackingID: "orchestrator-session", status: .spinning)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)
        try store.insertAgentSubscription(subscriberTerminalSessionID: "orchestrator-session", agentSessionID: child.id, createdAt: "t")
        try engine.childDidTransition(agent: child, transition: .done)
        XCTAssertTrue(recorder.delivered.isEmpty, "The busy orchestrator holds the line rather than receiving it mid-task.")

        try orchestrator.recordAgentInterrupt(terminalSessionID: "orchestrator-session", notifications: engine)

        XCTAssertEqual(recorder.delivered.map(\.sessionID), ["orchestrator-session"])
        XCTAssertTrue(try store.pendingAgentNotifications(subscriberTerminalSessionID: "orchestrator-session").isEmpty)
    }

    /// An interrupt only cancels a turn in progress. A finished agent keeps `done` — clearing it would
    /// silently drop the completion's Alerts attention — and an exited agent stays exited rather than
    /// being resurrected as a live idle row.
    func testInterruptLeavesDoneAndExitedRowsUnchanged() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try makeWorkspace(store: store)
        let recorder = DeliveryRecorder()
        let done = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Finished", terminalTrackingID: "done-session", status: .done)
        // `registerAgentWindow` resets `.exited` to `.idle` (restart reuse), so the exited row is reached
        // the way the product does: a live agent whose process ended.
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Gone", terminalTrackingID: "exited-session", status: .spinning)
        let exited = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "exited-session", status: .exited, eventType: "exit")

        XCTAssertNil(
            try orchestrator.recordAgentInterrupt(terminalSessionID: "done-session", notifications: makeEngine(store: store, recorder: recorder)))
        XCTAssertNil(
            try orchestrator.recordAgentInterrupt(terminalSessionID: "exited-session", notifications: makeEngine(store: store, recorder: recorder)))

        XCTAssertEqual(try store.agentWindow(id: done.id)?.status, .done)
        XCTAssertEqual(try store.agentWindow(id: exited.id)?.status, .exited)
    }

    /// Interrupting a terminal with no agent row — an agent that has not emitted its first hook signal, or
    /// a plain shell — records nothing. The ESC still goes out; an interrupt is no evidence an agent is
    /// running, so it must never establish a row.
    func testInterruptWithoutAgentRowRecordsNothing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try makeWorkspace(store: store)
        let recorder = DeliveryRecorder()

        XCTAssertNil(
            try orchestrator.recordAgentInterrupt(
                terminalSessionID: "unsignaled-session", notifications: makeEngine(store: store, recorder: recorder)))

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
    }

    /// The interrupt hands its busy-state condition to the status chokepoint instead of pre-checking it,
    /// so the condition is evaluated against the same row read the write is built from. This drives that
    /// chokepoint with the row state a hook signal committing in the gap would leave behind: the newer
    /// status stands and the interrupt writes nothing, rather than the interrupt overwriting a transition
    /// it never saw. (The concurrency window itself is not reproduced here — that would need a thread
    /// race; this pins the decision the chokepoint makes when it sees the raced-in state.)
    func testGatedStatusUpdateLeavesANewerStatusIntact() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try makeWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)
        // The hook signal that lands first: the agent finished its turn on its own.
        _ = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .done, eventType: "done",
            eventSource: "spaces_agent_signal")

        let applied = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .idle,
            whenCurrentStatusIs: [.spinning, .waiting], eventType: "interrupt", eventSource: "spaces_agent_interrupt")

        XCTAssertNil(applied, "A transition whose condition no longer holds must not be applied.")
        XCTAssertEqual(try store.agentWindow(id: agent.id)?.status, .done, "The hook signal's status must survive.")
        XCTAssertEqual(try interruptEventCount(store: store, agentID: agent.id), 0, "A skipped transition must log no lifecycle event.")
    }

    /// The same chokepoint, driven with the state an `exit` that finalized and deleted the row leaves
    /// behind: the interrupt records nothing and — the point of gating inside the chokepoint — creates no
    /// row. Agent rows are created by hook signals and destroyed through the termination chokepoint; an
    /// interrupt writing a status must never be able to bring a finalized row back.
    func testGatedStatusUpdateNeverRecreatesAFinalizedRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let workspace = try makeWorkspace(store: store)
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "child-session", status: .spinning)
        try store.deleteAgentWindow(id: agent.id)

        let applied = try orchestrator.updateAgentWindowStatus(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: "child-session", status: .idle,
            whenCurrentStatusIs: [.spinning, .waiting], eventType: "interrupt", eventSource: "spaces_agent_interrupt")

        XCTAssertNil(applied)
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "A gated transition must never register a row.")
    }

    // MARK: - Fixtures

    private func interruptEventCount(store: SQLiteStore, agentID: String) throws -> Int {
        let row = try store.queryRow(
            sql:
                "SELECT COUNT(*) FROM agent_session_events WHERE agent_session_id = ? AND event_type = 'interrupt' AND source = 'spaces_agent_interrupt'",
            bindings: [agentID])
        return Int(row?.first ?? "0") ?? 0
    }

    private func makeEngine(store: SQLiteStore, recorder: DeliveryRecorder) -> AgentNotificationEngine {
        AgentNotificationEngine(store: store, deliver: recorder.deliver, resolveAgentKind: { _ in "codex" }, logError: { _ in }, now: { "t" })
    }

    private func makeWorkspace(store: SQLiteStore) throws -> WorkspaceRecord {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        return workspace
    }
}
