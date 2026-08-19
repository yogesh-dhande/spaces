import Foundation

/// Derives the placeholder port reservations this process should hold from the database and makes
/// `PortReserver` match: every assigned service port of every workspace that is not running.
///
/// A stopped workspace holds its pinned ports so nothing else claims them before its next launch; a
/// running workspace's ports belong to its own servers, which bind them without `SO_REUSEPORT` and
/// would fail with `EADDRINUSE` against a placeholder.
///
/// Reservations are derived state rather than something each lifecycle transition maintains, because
/// the transitions and the descriptors live in different processes: workspaces are created, deleted,
/// started, stopped, and re-assigned ports from the app, the CLI, and remote clients, while only the
/// daemon binds placeholders, and no process can close another's descriptors. Recomputing from the
/// database is what lets a placeholder outlive the record that justified it for at most one pass.
public struct PortReservationReconciler {
    private let store: SQLiteStore

    public init(store: SQLiteStore) { self.store = store }

    public func reconcile() throws {
        var stoppedWorkspaceIDs: Set<String> = []
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id) where !workspace.isRunning { stoppedWorkspaceIDs.insert(workspace.id) }
        }
        let assignmentsByWorkspace = try store.workspacePortsNamedByWorkspace()
        var desiredPorts: Set<Int> = []
        for workspaceID in stoppedWorkspaceIDs {
            for assignment in assignmentsByWorkspace[workspaceID] ?? [] { desiredPorts.insert(assignment.port) }
        }
        PortReserver.shared.sync(desiredPorts: desiredPorts)
    }
}
