import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Placeholder port reservations across the launch paths that are not configured processes: ad-hoc
/// terminals, coding-agent sessions, and automation sessions, plus the stop that has to leave a
/// workspace's pinned ports held again.
///
/// These assert `PortReserver` bookkeeping rather than plain binds, because the ports here come from the
/// workspace port range the allocator assigns from, which a real daemon on this machine may also hold.
extension OrchestratorTests {

    /// A launch releases the placeholders and holds the ports, marks the workspace running, and the
    /// workspace stops again before any reconcile pass observes the running state. The port never leaves
    /// the reconciler's desired set, so nothing in `sync` would retire the hold, and without the stop
    /// clearing it the stopped workspace's pinned ports stay unheld until some later observed running
    /// transition or a daemon restart.
    func testStoppingAWorkspaceRightAfterALaunchLeavesItsPinnedPortsHeld() throws {
        let (orchestrator, store, workspace, assignedPorts) = try makePortReservationWorkspace()
        let reconciler = PortReservationReconciler(store: store)
        try reconciler.reconcile()
        XCTAssertTrue(PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts))

        _ = try orchestrator.createWorkspaceAgentSession(workspaceID: workspace.id, command: "claude", title: nil)
        XCTAssertTrue(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertTrue(PortReserver.shared.reservedPorts().isDisjoint(with: assignedPorts))

        // The running state is coalesced away: the stop lands before a pass ever sees it.
        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        try reconciler.reconcile()

        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts),
            "A stopped workspace must hold its pinned ports again even when no pass observed the launch's running state.")
    }

    /// An agent session's environment carries the workspace's `$SPACES_<NAME>_PORT` values, so a command
    /// that binds one immediately would meet the placeholder with EADDRINUSE. The release has to happen
    /// before the child is created, not on the reconciler's next asynchronous pass.
    func testAgentSessionReleasesPlaceholderPortsBeforeTheChildIsCreated() throws {
        let reservedAtSpawn = LockedBox<Set<Int>?>(nil)
        let (orchestrator, store, workspace, assignedPorts) = try makePortReservationWorkspace(onLaunch: { _ in
            reservedAtSpawn.set(PortReserver.shared.reservedPorts())
        })
        try PortReservationReconciler(store: store).reconcile()
        XCTAssertTrue(PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts))

        _ = try orchestrator.createWorkspaceAgentSession(workspaceID: workspace.id, command: "claude", title: nil)

        XCTAssertTrue(
            try XCTUnwrap(reservedAtSpawn.get()).isDisjoint(with: assignedPorts),
            "An agent session must be spawned with its workspace's assigned ports already released.")
    }

    /// Same release for an automation session, and the failure rule a configured process launch follows:
    /// the workspace was stopped, nothing took the ports, so the placeholders come straight back rather
    /// than waiting for a pass.
    func testFailedAutomationSessionRestoresPlaceholderPortsForAStoppedWorkspace() throws {
        struct TerminalLaunchFailure: Error {}
        let reservedAtSpawn = LockedBox<Set<Int>?>(nil)
        let (orchestrator, store, workspace, assignedPorts) = try makePortReservationWorkspace(onLaunch: { _ in
            reservedAtSpawn.set(PortReserver.shared.reservedPorts())
            throw TerminalLaunchFailure()
        })
        try PortReservationReconciler(store: store).reconcile()
        XCTAssertTrue(PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts))

        XCTAssertThrowsError(
            try orchestrator.createWorkspaceAutomationSession(workspaceID: workspace.id, runID: "run-1", title: "Nightly", command: "echo hi"))

        XCTAssertTrue(
            try XCTUnwrap(reservedAtSpawn.get()).isDisjoint(with: assignedPorts),
            "An automation session must be spawned with its workspace's assigned ports already released.")
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts),
            "A failed command session must leave the stopped workspace's pinned ports held.")
    }

    /// The app's ad-hoc terminal launch is split in two: the reservation builds the environment and marks
    /// the workspace running, and a later, off-queue half spawns the child from it. The release belongs to
    /// the reserving half, which is the one that runs before the child exists.
    func testReservingAnAdHocTerminalLaunchReleasesPlaceholderPortsBeforeTheChildIsCreated() throws {
        let (orchestrator, store, workspace, assignedPorts) = try makePortReservationWorkspace()
        try PortReservationReconciler(store: store).reconcile()
        XCTAssertTrue(PortReserver.shared.reservedPorts().isSuperset(of: assignedPorts))

        _ = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspace.id)

        XCTAssertTrue(
            PortReserver.shared.reservedPorts().isDisjoint(with: assignedPorts),
            "A reserved ad-hoc terminal launch must release the workspace's assigned ports before it is spawned.")
    }

    /// A stopped workspace with one assigned service port and a stubbed terminal launcher. `onLaunch` runs
    /// at the moment the child would be created, which is where the release has to have happened already.
    private func makePortReservationWorkspace(onLaunch: @escaping @Sendable (TerminalSessionLaunchConfiguration) throws -> Void = { _ in }) throws
        -> (WorkspaceOrchestrator, SQLiteStore, WorkspaceRecord, [Int])
    {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _, _ in },
            builtInTerminalSessionLauncher: { configuration in
                try onLaunch(configuration)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                    launchConfiguration: configuration)
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.ports = [ServiceDefinition(name: "web")] }
        let assignedPorts = try store.workspacePorts(workspaceID: workspace.id)
        XCTAssertFalse(assignedPorts.isEmpty)
        addTeardownBlock { clearPortReservationsForTest(assignedPorts) }
        XCTAssertFalse(try XCTUnwrap(try store.workspace(id: workspace.id)).isRunning)
        return (orchestrator, store, workspace, assignedPorts)
    }
}
