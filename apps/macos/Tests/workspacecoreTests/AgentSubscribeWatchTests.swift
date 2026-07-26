import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Behavior coverage for `subscribeAgentWatch`/`unsubscribeAgentWatch`, the orchestrator methods that
/// record a same-device watch edge addressed by the child's *terminal session id* (the id CLI and device
/// callers hold). A device-qualified subscribe naming the local device is normalized onto this path, so
/// these methods must enforce the same acyclic invariant a plain local watch does — a self-edge or a
/// cycle-closing edge must be rejected instead of silently recorded.
final class AgentSubscribeWatchTests: XCTestCase {
    /// Failing-first equivalent of the bug: `spaces agent subscribe <session> --device local` used to take
    /// the cross-device branch and call `insertAgentRemoteSubscription`, which runs no cycle detection, so a
    /// terminal could subscribe to its own agent. Routed through `subscribeAgentWatch`, the self-edge is a
    /// loud error.
    func testSubscribeAgentWatchToOwnAgentByTerminalIDThrowsSelfEdge() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Claude", terminalTrackingID: "term-A", status: .idle)

        XCTAssertThrowsError(
            try orchestrator.subscribeAgentWatch(subscriberTerminalSessionID: "term-A", childTerminalSessionID: "term-A")
        ) { error in
            XCTAssertTrue(isInvalidArgument(error), "A terminal subscribing to its own agent must fail with invalidArgument.")
        }
        XCTAssertTrue(try store.agentSubscriptions(subscriberTerminalSessionID: "term-A").isEmpty, "No edge should be recorded on rejection.")
    }

    /// Closing an A↔B loop by terminal session id is rejected: A already watches B, so B watching A would
    /// let injected notifications chase each other around the cycle.
    func testSubscribeAgentWatchClosingCycleByTerminalIDThrows() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Agent A", terminalTrackingID: "term-A", status: .idle)
        _ = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Agent B", terminalTrackingID: "term-B", status: .idle)

        // A watches B — a normal edge.
        try orchestrator.subscribeAgentWatch(subscriberTerminalSessionID: "term-A", childTerminalSessionID: "term-B")

        // B watching A would close the cycle and must be rejected.
        XCTAssertThrowsError(
            try orchestrator.subscribeAgentWatch(subscriberTerminalSessionID: "term-B", childTerminalSessionID: "term-A")
        ) { error in
            XCTAssertTrue(isInvalidArgument(error), "A cycle-closing subscribe must fail with invalidArgument.")
        }
        XCTAssertTrue(try store.agentSubscriptions(subscriberTerminalSessionID: "term-B").isEmpty, "No edge should be recorded on rejection.")
    }

    /// A valid subscribe resolves the child's agent row from its terminal session id and records a normal
    /// local edge keyed on the resolved row id (visible through the store).
    func testSubscribeAgentWatchByTerminalIDRecordsLocalEdge() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Child", terminalTrackingID: "term-child", status: .idle)

        try orchestrator.subscribeAgentWatch(subscriberTerminalSessionID: "term-orchestrator", childTerminalSessionID: "term-child")

        XCTAssertEqual(
            try store.agentSubscriptions(agentSessionID: child.id).map(\.subscriberTerminalSessionID), ["term-orchestrator"],
            "The edge must be keyed on the resolved agent row id, not the child terminal session id.")
        XCTAssertEqual(try store.agentSubscriptions(subscriberTerminalSessionID: "term-orchestrator").map(\.agentSessionID), [child.id])
    }

    /// Subscribing to a terminal that has no agent session yet is a loud error — there is no row to watch.
    func testSubscribeAgentWatchUnknownTerminalThrows() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        _ = try makeProjectAndWorkspace(store: store)

        XCTAssertThrowsError(
            try orchestrator.subscribeAgentWatch(subscriberTerminalSessionID: "term-orchestrator", childTerminalSessionID: "missing-term")
        ) { error in
            XCTAssertTrue(isInvalidArgument(error), "Subscribing to a terminal with no agent session must fail with invalidArgument.")
        }
    }

    /// Unsubscribe by terminal session id resolves the child's agent row and drops only the matching edge.
    func testUnsubscribeAgentWatchByTerminalIDRemovesEdge() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let child = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, label: "Child", terminalTrackingID: "term-child", status: .idle)
        try orchestrator.subscribeAgentWatch(subscriberTerminalSessionID: "term-orchestrator", childTerminalSessionID: "term-child")

        try orchestrator.unsubscribeAgentWatch(subscriberTerminalSessionID: "term-orchestrator", childTerminalSessionID: "term-child")

        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: child.id).isEmpty)
    }

    /// Unsubscribing a terminal with no agent row succeeds quietly: a local edge FK-cascades away with its
    /// agent row, so there is nothing left to delete.
    func testUnsubscribeAgentWatchUnknownTerminalSucceedsQuietly() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        _ = try makeProjectAndWorkspace(store: store)

        XCTAssertNoThrow(
            try orchestrator.unsubscribeAgentWatch(subscriberTerminalSessionID: "term-orchestrator", childTerminalSessionID: "missing-term"))
    }

    // MARK: - Fixtures

    private func makeProjectAndWorkspace(store: SQLiteStore) throws -> (ProjectRecord, WorkspaceRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }

    private func isInvalidArgument(_ error: Error) -> Bool {
        if case WorkspaceError.invalidArgument = error { return true }
        return false
    }
}
