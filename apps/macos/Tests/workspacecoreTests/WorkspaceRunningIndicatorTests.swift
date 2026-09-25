import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// What keeps a workspace reading Running. A terminal pane Spaces hosts, and the coding-agent row bound to
/// it, count only while their session is live: both rows outlive the session on purpose, so the ended pane
/// stays listed and reopenable and the ended agent stays listed until a reconciler pass finalizes it, and
/// the workspace they belong to has to read stopped once nothing live is left in it. This matters most on
/// the home workspace, which refuses Stop outright and so could never be cleared by hand.
extension OrchestratorTests {

    private struct RunningIndicatorFixture {
        let orchestrator: WorkspaceOrchestrator
        let store: SQLiteStore
        let workspace: WorkspaceRecord
    }

    /// A running workspace under a plain (non-git, unconfigured) project, with no runtime of its own yet.
    private func makeRunningIndicatorFixture() throws -> RunningIndicatorFixture {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = try makeTempDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-09-24T00:00:00Z")
        return RunningIndicatorFixture(orchestrator: orchestrator, store: store, workspace: workspace)
    }

    /// One ad hoc shell pane: the terminal session in `state` plus the `runtime_targets` row that lists it.
    /// `servicePID` names the daemon the session claims, which the startup stale-session repair reads: a
    /// foreign pid is what a crashed predecessor leaves behind.
    private func seedShellPane(
        orchestrator: WorkspaceOrchestrator, store: SQLiteStore, workspace: WorkspaceRecord, sessionID: String, state: TerminalSessionState,
        orderIndex: Int = 200, servicePID: Int32 = getpid()
    ) throws {
        try writeTerminalSessionFixture(
            sessionID: sessionID, workspace: workspace, kind: .shell,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: servicePID, childPID: 4321, state: state,
                updatedAt: "2026-09-24T00:00:00Z", exitedAt: state.isInteractive ? nil : "2026-09-24T00:01:00Z", title: sessionID,
                workingDirectory: workspace.dir))
        try store.upsert(
            window: WindowRecord(
                id: "window-\(sessionID)", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: sessionID, detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: orderIndex, lastSeenAt: "2026-09-24T00:00:00Z"))
    }

    /// The shell a user typed `exit` into: its pane row is kept so the ended pane stays reopenable, and the
    /// workspace reads stopped because that kept row no longer stands for anything alive.
    func testWorkspaceReadsStoppedAfterItsOnlyShellExitsNaturally() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "ad-hoc-shell", state: .exited)

        try fixture.orchestrator.clearWorkspaceRunningAfterTerminalSessionExit(sessionID: "ad-hoc-shell")

        XCTAssertFalse(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
        XCTAssertEqual(
            try fixture.store.windows(workspaceID: fixture.workspace.id).map(\.terminalTrackingID), ["ad-hoc-shell"],
            "the ended pane stays listed so it can be reopened")
        let status = try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id)
        XCTAssertEqual(status.lifecycleState, .stopped)
        XCTAssertFalse(status.hasTrackedRuntimeIndicators, "an ended pane is not a runtime leftover to report")
    }

    /// The finding this rule was written for: the home workspace refuses Stop, so a shell that ends on its
    /// own is the only thing that can ever bring the `~` row back down.
    func testHomeWorkspaceReadsStoppedAfterItsOnlyShellExitsNaturally() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-09-24T00:00:00Z")
        try seedShellPane(orchestrator: orchestrator, store: store, workspace: workspace, sessionID: "home-shell", state: .exited)

        try orchestrator.clearWorkspaceRunningAfterTerminalSessionExit(sessionID: "home-shell")

        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).map(\.terminalTrackingID), ["home-shell"])
        XCTAssertEqual(try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id).lifecycleState, .stopped)
    }

    /// One shell ending does not take the workspace down while another is still live.
    func testWorkspaceStaysRunningWhileAnotherShellIsLive() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "ended-shell", state: .exited)
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "live-shell", state: .running,
            orderIndex: 201)

        try fixture.orchestrator.clearWorkspaceRunningAfterTerminalSessionExit(sessionID: "ended-shell")

        XCTAssertTrue(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
        XCTAssertTrue(try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id).hasTrackedRuntimeIndicators)
    }

    /// A mutation holding the workspace lifecycle gate without touching the running flag (hiding the
    /// workspace, editing its settings, stood in for here by holding the gate directly) must not cost the
    /// workspace its reconcile: a natural exit gets no second chance, so the reconcile waits for the gate
    /// and lands once the holder leaves.
    func testNaturalExitReconcileWaitsForAContendedLifecycleGate() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "gated-shell", state: .exited)
        let holder = makeTestOrchestrator(store: fixture.store)
        let workspaceID = fixture.workspace.id

        let gateHeld = expectation(description: "a workspace mutation holds the lifecycle gate")
        let releaseGate = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? holder.withWorkspaceLifecycleLock(workspaceID: workspaceID) {
                gateHeld.fulfill()
                releaseGate.wait()
            }
        }
        wait(for: [gateHeld], timeout: 5)

        // Signalled only once the reconcile returns, so the wait below reads whether it gave up on the held
        // gate without this thread touching the store while the reconcile owns it.
        let reconcileFinished = DispatchSemaphore(value: 0)
        let orchestrator = fixture.orchestrator
        Thread.detachNewThread {
            do { try orchestrator.clearWorkspaceRunningAfterTerminalSessionExit(sessionID: "gated-shell") } catch {
                XCTFail("the reconcile failed: \(error)")
            }
            reconcileFinished.signal()
        }
        XCTAssertEqual(
            reconcileFinished.wait(timeout: .now() + 0.3), .timedOut, "a held gate makes the reconcile wait rather than return unreconciled")

        releaseGate.signal()
        XCTAssertEqual(reconcileFinished.wait(timeout: .now() + 5), .success)

        XCTAssertFalse(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
        XCTAssertEqual(try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id).lifecycleState, .stopped)
    }

    /// An agent row follows the same rule as the pane it sits in: the shell ended, so the row it left
    /// behind is not something alive. The row itself is deliberately kept here (only a reconciler pass
    /// finalizes it), so this is the workspace reading stopped with the row still in the database.
    func testWorkspaceReadsStoppedAfterItsOnlyShellExitsNaturallyWithAnAgentRowStillOnIt() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "agent-shell", state: .exited)
        let agent = try fixture.orchestrator.registerAgentWindow(
            workspaceID: fixture.workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "agent-shell", status: .waiting)

        try fixture.orchestrator.clearWorkspaceRunningAfterTerminalSessionExit(sessionID: "agent-shell")

        XCTAssertFalse(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
        XCTAssertNotNil(try fixture.store.agentWindow(id: agent.id), "the exit reconcile reads the row, it does not remove it")
        let status = try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id)
        XCTAssertEqual(status.lifecycleState, .stopped)
        XCTAssertFalse(status.hasTrackedRuntimeIndicators, "an agent row on an ended session is not a runtime leftover to report")
        XCTAssertEqual(
            status.waitingAgentWindowCount, 1,
            "the waiting count reports the rows that exist; it is what the row says, not whether the row counts as runtime")
    }

    /// The other half of the rule: an agent whose terminal is still live is live runtime, so the workspace
    /// keeps reading Running.
    func testWorkspaceStaysRunningWhileItsAgentSessionIsLive() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "live-agent-shell", state: .running)
        try fixture.orchestrator.registerAgentWindow(
            workspaceID: fixture.workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "live-agent-shell", status: .spinning)

        try fixture.orchestrator.clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: fixture.workspace.id)

        XCTAssertTrue(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
        XCTAssertTrue(try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id).hasTrackedRuntimeIndicators)
    }

    /// The exit that no reconcile ever saw: the session ended while the daemon was down, so nothing called
    /// the natural-exit reconcile on the way back up and the flag is still set. The foreground pass is what
    /// finalizes such a row, and finalizing it is what has to bring the workspace down with it.
    func testForegroundReconcilePassClearsRunningWhenItFinalizesTheLastAgentRow() throws {
        let root = try makeTempDirectory()
        let dbPath = root.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try seedShellPane(orchestrator: orchestrator, store: store, workspace: workspace, sessionID: "downed-daemon-shell", state: .exited)
            let agent = try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: .spaces, label: "Codex CLI", terminalTrackingID: "downed-daemon-shell", status: .waiting)
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-09-24T00:00:00Z")

            XCTAssertTrue(try orchestrator.reconcileTerminalForegroundAgentClassifications())

            XCTAssertNil(try store.agentWindow(id: agent.id), "the pass finalizes a row whose session ended")
            XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)
            XCTAssertEqual(try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id).lifecycleState, .stopped)
        }
    }

    /// The other exit no reconcile ever saw: the daemon died without finalizing anything, so the session's
    /// row still claims `.running` under the pid of a process that is gone. Startup's stale-session repair
    /// is what rewrites the row, and it builds no session core, so no closed-core callback follows it. The
    /// repair has to bring the workspace down with it, or the flag stays true until a Stop the home
    /// workspace does not offer.
    func testStartupStaleSessionRecoveryClearsRunningForTheWorkspaceItRepairs() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "crashed-daemon-shell",
            state: .running, servicePID: 999_999)

        let result = try fixture.orchestrator.recoverStaleTerminalSessions(
            adoptedSessionIDs: [], resumedFromHandoff: false, isProcessAlive: { _ in false })

        XCTAssertEqual(result.finalized.map(\.sessionID), ["crashed-daemon-shell"])
        XCTAssertEqual(result.finalized.map(\.state), [.failed], "a daemon that vanished without finalizing the row did not end cleanly")
        XCTAssertFalse(
            try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning,
            "the repaired session is the workspace's last runtime indicator, so the workspace reads stopped")
        XCTAssertEqual(
            try fixture.store.windows(workspaceID: fixture.workspace.id).map(\.terminalTrackingID), ["crashed-daemon-shell"],
            "the repair keeps the pane listed, as every ended pane stays listed")
        let status = try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id)
        XCTAssertEqual(status.lifecycleState, .stopped)
        XCTAssertFalse(status.hasTrackedRuntimeIndicators)
    }

    /// The exit whose reconcile died with the daemon: the session ended on its own and its `.exited` state
    /// committed, and the daemon stopped before the reconcile that follows such an exit could clear the
    /// flag. Startup's repair pass finds nothing to rewrite in a row that already reads ended, so the flag
    /// heals only because the pass reconciles every workspace that still claims to be running.
    func testStartupStaleSessionRecoveryClearsRunningForASessionThatAlreadyEnded() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "exited-before-shutdown",
            state: .exited)

        let result = try fixture.orchestrator.recoverStaleTerminalSessions(
            adoptedSessionIDs: [], resumedFromHandoff: false, isProcessAlive: { _ in false })

        XCTAssertTrue(result.finalized.isEmpty, "a row that already reads ended has nothing to repair")
        XCTAssertFalse(
            try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning,
            "the workspace holds no live runtime, so the startup sweep brings it down")
        XCTAssertEqual(
            try fixture.store.windows(workspaceID: fixture.workspace.id).map(\.terminalTrackingID), ["exited-before-shutdown"],
            "the ended pane stays listed so it can be reopened")
        XCTAssertEqual(try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id).lifecycleState, .stopped)
    }

    /// The sweep is one rule, not a special case: a second pane whose session is still live keeps its
    /// workspace running.
    func testStartupStaleSessionRecoveryLeavesRunningWhileAnotherSessionIsLive() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "crashed-shell", state: .running,
            servicePID: 999_999)
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "adopted-shell", state: .running,
            orderIndex: 201)

        let result = try fixture.orchestrator.recoverStaleTerminalSessions(
            adoptedSessionIDs: ["adopted-shell"], resumedFromHandoff: true, isProcessAlive: { _ in false })

        XCTAssertEqual(result.finalized.map(\.sessionID), ["crashed-shell"], "an adopted session is live under this daemon and is not repaired")
        XCTAssertTrue(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
        XCTAssertTrue(try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id).hasTrackedRuntimeIndicators)
    }

    /// A browser target has no session of its own, so it keeps counting exactly as it always has.
    func testBrowserWindowKeepsWorkspaceRunning() throws {
        let fixture = try makeRunningIndicatorFixture()
        try fixture.store.upsert(
            window: WindowRecord(
                id: "browser-window", workspaceID: fixture.workspace.id, app: "Google Chrome", name: "app", detail: nil,
                targetURL: "http://localhost:3000", terminalTrackingID: nil, role: "browser", orderIndex: 100, lastSeenAt: "2026-09-24T00:00:00Z"))

        try fixture.orchestrator.clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: fixture.workspace.id)

        XCTAssertTrue(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
        XCTAssertTrue(try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id).hasTrackedRuntimeIndicators)
    }

    /// A pane whose launch is still in flight: its runtime-state write is queued behind the per-core
    /// persistence queue, so the session has no state on disk yet and reads exactly like a purged one. The
    /// pending-launch registry is what separates the two, and the reconcile that a sibling's exit triggers
    /// must not take the workspace down under a terminal that is coming up, because the launch marks the
    /// workspace running before its state write lands and nothing re-asserts the flag afterwards.
    func testWorkspaceStaysRunningWhileAnotherPanesLaunchIsPending() throws {
        let fixture = try makeRunningIndicatorFixture()
        try seedShellPane(
            orchestrator: fixture.orchestrator, store: fixture.store, workspace: fixture.workspace, sessionID: "ended-shell", state: .exited)
        let pendingSessionID = "launching-shell"
        try fixture.store.upsert(
            window: WindowRecord(
                id: "window-\(pendingSessionID)", workspaceID: fixture.workspace.id, app: TerminalHost.spaces.appName, name: pendingSessionID,
                detail: nil, targetURL: nil, terminalTrackingID: pendingSessionID, role: "terminal", orderIndex: 201,
                lastSeenAt: "2026-09-24T00:00:00Z"))
        let generation = TerminalSessionPendingLaunchRegistry.shared.recordPending(
            TerminalSessionLaunchConfiguration(
                sessionID: pendingSessionID, backend: .ghosttyEmbedded, title: pendingSessionID, workingDirectory: fixture.workspace.dir,
                shell: "/bin/zsh", command: nil, createdAt: TerminalSessionTimestamp.string(from: Date()), workspaceID: fixture.workspace.id,
                kind: .shell))
        var registryEntryStands = true
        defer { if registryEntryStands { TerminalSessionPendingLaunchRegistry.shared.clear(sessionID: pendingSessionID, generation: generation) } }

        try fixture.orchestrator.clearWorkspaceRunningAfterTerminalSessionExit(sessionID: "ended-shell")

        XCTAssertTrue(
            try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning,
            "a pane whose launch is still pending is live runtime, not an ended session")
        XCTAssertTrue(try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id).hasTrackedRuntimeIndicators)

        // The launch failed: its entry is cleared with no runtime state ever recorded, which leaves the
        // pane naming a session that never came up, and the next reconcile takes the workspace down.
        TerminalSessionPendingLaunchRegistry.shared.clear(sessionID: pendingSessionID, generation: generation)
        registryEntryStands = false

        try fixture.orchestrator.clearWorkspaceRunningAfterTerminalSessionExit(sessionID: "ended-shell")

        XCTAssertFalse(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
        XCTAssertEqual(try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: fixture.workspace.id).lifecycleState, .stopped)
    }

    /// A pane whose session was already purged by retention garbage collection reads the same as an ended
    /// one: there is nothing left to be live.
    func testWorkspaceReadsStoppedWhenItsPaneNamesAPurgedSession() throws {
        let fixture = try makeRunningIndicatorFixture()
        try fixture.store.upsert(
            window: WindowRecord(
                id: "window-purged", workspaceID: fixture.workspace.id, app: TerminalHost.spaces.appName, name: "shell", detail: nil, targetURL: nil,
                terminalTrackingID: "purged-session", role: "terminal", orderIndex: 200, lastSeenAt: "2026-09-24T00:00:00Z"))

        try fixture.orchestrator.clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: fixture.workspace.id)

        XCTAssertFalse(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
    }
}
