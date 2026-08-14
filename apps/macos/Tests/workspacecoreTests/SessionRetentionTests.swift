import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Behavior coverage for `WorkspaceOrchestrator.releaseEndedTerminalSessionReferences` — the product-row
/// release path the daemon's session garbage collector calls to age out a long-ended terminal session.
/// After a release the session must no longer be referenced by any product row, so the collector may
/// reclaim its on-disk state.
final class SessionRetentionTests: XCTestCase {
    /// An exited agent row that references the ended session is deleted through the finalization
    /// chokepoint, which first drops its inbound `agent_subscriptions` edge (ON DELETE RESTRICT). Seeding
    /// a subscription edge proves the release does not bypass the chokepoint: a raw delete would throw
    /// under RESTRICT.
    func testReleaseDeletesExitedAgentRowAndItsSubscriptionEdges() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "ended-agent-session"
        let agent = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, status: .idle)
        try store.updateAgentWindowStatus(id: agent.id, status: .exited, updatedAt: "2026-07-14T00:00:00Z")

        // An inbound watch edge: a bypass delete of the watched row would fail loudly under RESTRICT, so a
        // successful release proves the row went through the chokepoint that drops the edge first.
        try store.insertAgentSubscription(subscriberTerminalSessionID: "watcher", agentSessionID: agent.id, createdAt: "2026-07-14T00:01:00Z")
        XCTAssertTrue(try store.terminalSessionIsReferencedByProduct(sessionID))

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: sessionID)

        XCTAssertNil(try store.agentWindow(id: agent.id))
        XCTAssertTrue(try store.agentSubscriptions(agentSessionID: agent.id).isEmpty)
        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(sessionID))
    }

    /// A `.destroyed` release deletes the agent row regardless of its status: even a live-looking
    /// `.spinning` row is released, because the caller has established the backing terminal is gone.
    func testReleaseDeletesAgentRowRegardlessOfStatus() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "spinning-agent-session"
        let agent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, status: .spinning)

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: sessionID)

        XCTAssertNil(try store.agentWindow(id: agent.id))
        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(sessionID))
    }

    /// An exited running-process row that references the ended session is deleted along with its tracked
    /// terminal window, while a second process (and its window) on a different live session in the same
    /// workspace is untouched.
    func testReleaseDeletesProcessRowAndTrackedWindowLeavingOthers() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let endedSession = "ended-process-session"
        let liveSession = "live-process-session"

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "proc-ended", workspaceID: workspace.id, templateName: "api", command: "zsh", terminalApp: TerminalHost.spaces.appName,
                terminalTrackingID: endedSession, pid: 123, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "proc-live", workspaceID: workspace.id, templateName: "web", command: "zsh", terminalApp: TerminalHost.spaces.appName,
                terminalTrackingID: liveSession, pid: 456, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Upserting each process created its tracked runtime_targets window (id == process id).
        XCTAssertTrue(try store.terminalSessionIsReferencedByProduct(endedSession))
        XCTAssertEqual(Set(try store.windows(workspaceID: workspace.id).map(\.id)), ["proc-ended", "proc-live"])

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: endedSession)

        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(endedSession))
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.id), ["proc-live"])
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).map(\.id), ["proc-live"])
        // The live process's own session is still referenced.
        XCTAssertTrue(try store.terminalSessionIsReferencedByProduct(liveSession))
    }

    /// A session referenced only by a bare `runtime_targets` focus row (an ad-hoc terminal pane, no
    /// process or agent) is released by deleting that window row.
    func testReleaseDeletesBareRuntimeTargetRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let sessionID = "ad-hoc-pane-session"
        try store.upsert(
            window: WindowRecord(
                id: "pane-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell", detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: 300, lastSeenAt: "now"))
        XCTAssertTrue(try store.terminalSessionIsReferencedByProduct(sessionID))

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: sessionID)

        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(sessionID))
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    /// A bare terminal (no agent row of its own — just a `runtime_targets` focus row) that is itself a
    /// SUBSCRIBER of another workspace's live agent must have its outgoing watch edges torn down on release,
    /// even though it owns no agent row to route through the finalization chokepoint. Subscribing does not
    /// require an agent row, so `finalizeAgentRow` (which only runs for agent-row owners) never sees this
    /// session; the release must retire it as a subscriber unconditionally, or the edge and its pending
    /// queue survive the session's purge and keep targeting a dead session. The watched agent, being in
    /// another workspace and still live, must be left untouched.
    func testReleaseTearsDownSubscriberEdgesOfBareTerminalWithNoAgentRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, subscriberWorkspace) = try makeProjectAndWorkspace(store: store)
        let (_, watchedWorkspace) = try makeProjectAndWorkspace(store: store)

        // The expired bare terminal: referenced only by a runtime_targets focus row, no agent row of its own.
        let subscriberSession = "bare-subscriber-session"
        try store.upsert(
            window: WindowRecord(
                id: "subscriber-pane", workspaceID: subscriberWorkspace.id, app: TerminalHost.spaces.appName, name: "shell", detail: nil,
                targetURL: nil, terminalTrackingID: subscriberSession, role: "terminal", orderIndex: 300, lastSeenAt: "now"))

        // A live agent in ANOTHER workspace that the bare terminal watches.
        let watchedAgent = try orchestrator.registerAgentWindow(
            workspaceID: watchedWorkspace.id, provider: .spaces, terminalTrackingID: "watched-agent-session", status: .spinning)
        try store.insertAgentSubscription(
            subscriberTerminalSessionID: subscriberSession, agentSessionID: watchedAgent.id, createdAt: "2026-07-14T00:01:00Z")

        XCTAssertTrue(try store.terminalSessionIsReferencedByProduct(subscriberSession))
        XCTAssertFalse(try store.agentSubscriptions(subscriberTerminalSessionID: subscriberSession).isEmpty)

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: subscriberSession)

        // The subscriber's outgoing watch edges are gone, the watched agent survives, and the session is
        // no longer referenced by any product row.
        XCTAssertTrue(try store.agentSubscriptions(subscriberTerminalSessionID: subscriberSession).isEmpty)
        XCTAssertNotNil(try store.agentWindow(id: watchedAgent.id), "The watched agent in another workspace must survive the subscriber's release.")
        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(subscriberSession))
    }

    /// Releasing a session that nothing references is a no-op that does not throw.
    func testReleaseUnreferencedSessionIsNoOp() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        _ = try makeProjectAndWorkspace(store: store)

        XCTAssertNoThrow(try orchestrator.releaseEndedTerminalSessionReferences(sessionID: "never-existed"))
    }

    /// Rows referencing a DIFFERENT session are left intact — the release is scoped to the given session id.
    func testReleaseLeavesRowsReferencingOtherSessionsIntact() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        let target = "target-session"
        let other = "other-session"

        let targetAgent = try orchestrator.registerAgentWindow(
            workspaceID: workspace.id, provider: .spaces, terminalTrackingID: target, status: .idle)
        let otherAgent = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: other, status: .idle)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "proc-other", workspaceID: workspace.id, templateName: "api", command: "zsh", terminalApp: TerminalHost.spaces.appName,
                terminalTrackingID: other, pid: 789, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: target)

        XCTAssertNil(try store.agentWindow(id: targetAgent.id))
        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(target))
        // Everything bound to the other session survives.
        XCTAssertNotNil(try store.agentWindow(id: otherAgent.id))
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).map(\.id), ["proc-other"])
        XCTAssertTrue(try store.terminalSessionIsReferencedByProduct(other))
    }

    /// A workspace whose ONLY tracked runtime indicator is an agent row bound to the expired session must
    /// be marked stopped after release. `finalizeAgentRow` (used in step 1) deliberately does not recompute
    /// the workspace's running flag itself — its interactive callers do that at their own call sites — so
    /// the release path must do it for GC-driven deletes, or the workspace would stay `isRunning` forever
    /// once its last runtime row is gone.
    func testReleaseClearsRunningFlagForAgentOnlyWorkspace() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let sessionID = "agent-only-session"
        let agent = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .spaces, terminalTrackingID: sessionID, status: .exited)
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: sessionID)

        XCTAssertNil(try store.agentWindow(id: agent.id))
        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)
    }

    /// A workspace whose ONLY tracked runtime indicator is a bare `runtime_targets` window (an ad-hoc
    /// terminal pane, no process or agent row) referencing the expired session must be marked stopped after
    /// release. `store.deleteWindow` (used in step 3) does not recompute the workspace's running flag, so
    /// the release path must do it explicitly for the workspace the deleted window belonged to.
    func testReleaseClearsRunningFlagForAdHocTerminalOnlyWorkspace() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let (_, workspace) = try makeProjectAndWorkspace(store: store)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let sessionID = "ad-hoc-only-session"
        try store.upsert(
            window: WindowRecord(
                id: "ad-hoc-only-pane", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "shell", detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: 300, lastSeenAt: "now"))
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: sessionID)

        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)
    }

    // MARK: - Automation attribution

    /// An automation run listed in the Runs tab offers its terminal for read-only replay, so a session
    /// stamped with that run's id must read as referenced for as long as the run row exists, even with no
    /// process, agent, or window row of its own, which is exactly an exited automation session after its live
    /// workspace runtime target is detached.
    /// Deleting the run (retention pruning, or automation deletion) is what makes it collectable.
    func testRunAttributedSessionIsReferencedUntilItsRunRowIsDeleted() throws {
        let store = try makeTemporaryStore()
        let sessionID = "automation-run-session"
        let run = try seedAutomationRunWithAttributedSession(store: store, sessionID: sessionID)

        XCTAssertTrue(try store.terminalSessionIsReferencedByProduct(sessionID), "a retained run keeps its terminal replayable")

        try store.deleteAutomationRun(id: run.id)

        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(sessionID), "once the run is gone nothing replays the session")
    }

    /// A stamp left pointing at a run row that no longer exists pins nothing: the reference check JOINs
    /// `automation_runs`, so a dangling attribution can never keep a session out of the collector's reach.
    func testDanglingAutomationAttributionDoesNotReferenceTheSession() throws {
        let store = try makeTemporaryStore()
        let sessionID = "dangling-attribution-session"
        let run = try seedAutomationRunWithAttributedSession(store: store, sessionID: sessionID)
        try store.deleteAutomationRun(id: run.id)

        XCTAssertEqual(try store.terminalSessionIDs(automationRunID: run.id), [sessionID], "the stamp itself survives the run row")
        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(sessionID))
    }

    /// Age expiry and budget eviction must reach automation sessions on the same terms as ended panes, so
    /// the release drops the run attribution too. The run row itself is left alone: the Runs tab still
    /// lists the run, it just no longer has a transcript to replay.
    func testReleaseDropsAutomationAttributionAndLeavesTheRunRow() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let sessionID = "expired-automation-session"
        let run = try seedAutomationRunWithAttributedSession(store: store, sessionID: sessionID)

        try orchestrator.releaseEndedTerminalSessionReferences(sessionID: sessionID)

        XCTAssertFalse(try store.terminalSessionIsReferencedByProduct(sessionID))
        XCTAssertTrue(try store.terminalSessionIDs(automationRunID: run.id).isEmpty, "the attribution is cleared")
        XCTAssertNotNil(try store.automationRun(id: run.id), "the run stays in history without its replay")
    }

    /// The daemon's published keep-set (what stops a client closing an open replay pane) reads the same
    /// automation attribution the collector does, and drops a session as soon as its run is gone.
    func testAttributedKeepSetTracksTheRunRow() throws {
        let store = try makeTemporaryStore()
        let sessionID = "keep-set-session"
        let run = try seedAutomationRunWithAttributedSession(store: store, sessionID: sessionID)

        XCTAssertEqual(try store.terminalSessionIDsAttributedToExistingAutomationRuns(), [sessionID])

        try store.deleteAutomationRun(id: run.id)

        XCTAssertTrue(try store.terminalSessionIDsAttributedToExistingAutomationRuns().isEmpty)
    }

    /// An agent child inherits the automation-run attribution but is not the run's terminal. Replay must
    /// use the exact session named by `automation_runs.terminal_session_id`, not the first attributed
    /// session in another workspace.
    func testAutomationRunWorkspaceMappingUsesItsOwnTerminalRatherThanAnEarlierAttributedChild() throws {
        let store = try makeTemporaryStore()
        let (_, ownWorkspace) = try makeProjectAndWorkspace(store: store)
        let (_, childWorkspace) = try makeProjectAndWorkspace(store: store)
        let automation = Automation(
            id: "automation-workspace", name: "Nightly", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "true",
            workspaceID: ownWorkspace.id, timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce, nextFireTime: nil,
            createdAt: Date(), updatedAt: Date())
        try store.upsertAutomation(automation)
        let run = AutomationRun(
            id: "run-workspace", automationID: automation.id, kind: .script, status: .succeeded, skipReason: nil, trigger: .manual, exitCode: 0,
            terminalSessionID: "own-terminal", startedAt: Date(), endedAt: Date(), createdAt: Date())
        try store.insertAutomationRun(run)

        let childPaths = try TerminalSessionPaths.forSession(id: "child-terminal")
        try childPaths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "child-terminal", title: "Child", workingDirectory: childWorkspace.dir, shell: "/bin/zsh", command: "codex",
                createdAt: "2026-01-01T00:00:00Z", workspaceID: childWorkspace.id, kind: .agent, automationRunID: run.id), paths: childPaths)
        let ownPaths = try TerminalSessionPaths.forSession(id: "own-terminal")
        try ownPaths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            .init(
                sessionID: "own-terminal", title: "Nightly", workingDirectory: ownWorkspace.dir, shell: "/bin/zsh", command: "true",
                createdAt: "2026-01-02T00:00:00Z", workspaceID: ownWorkspace.id, kind: .automation, automationRunID: run.id), paths: ownPaths)

        XCTAssertEqual(try store.workspaceID(automationRunID: run.id), ownWorkspace.id)
        XCTAssertEqual(try store.workspaceIDs(automationRunIDs: [run.id, "missing-run"]), [run.id: ownWorkspace.id])
    }

    // MARK: - Fixtures

    /// A terminal run with one workspace-bound `.automation` terminal session stamped to it: the shape a
    /// finished script run leaves behind, with no process, agent, or window row referencing the session.
    @discardableResult private func seedAutomationRunWithAttributedSession(store: SQLiteStore, sessionID: String) throws -> AutomationRun {
        let automation = Automation(
            id: UUID().uuidString, name: "Nightly", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "true",
            workspaceID: "workspace-1", timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce, nextFireTime: nil,
            createdAt: Date(), updatedAt: Date())
        try store.upsertAutomation(automation)
        let run = AutomationRun(
            id: UUID().uuidString, automationID: automation.id, kind: .script, status: .succeeded, skipReason: nil, trigger: .manual, exitCode: 0,
            terminalSessionID: sessionID, startedAt: Date(), endedAt: Date(), createdAt: Date())
        try store.insertAutomationRun(run)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: "Nightly", workingDirectory: "/tmp", shell: "/bin/zsh", command: "true",
                createdAt: "2026-06-06T00:00:00Z", workspaceID: "workspace-1", kind: .automation, automationRunID: run.id), paths: paths)
        return run
    }

    private func makeProjectAndWorkspace(store: SQLiteStore) throws -> (ProjectRecord, WorkspaceRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: dir)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: dir + "/ws")
        try store.upsert(workspace: workspace)
        return (project, workspace)
    }
}
