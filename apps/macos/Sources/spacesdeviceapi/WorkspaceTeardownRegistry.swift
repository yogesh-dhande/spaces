import Foundation

/// The set of workspaces whose teardown the daemon currently owns, published on every overview so a
/// client can tell "this delete failed" from "this delete is still running" (see
/// `SpacesDeviceOverviewPayload.workspaceIDsWithTeardownInFlight`).
final class WorkspaceTeardownRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var workspaceIDs: [String: Int] = [:]

    /// Registered before the teardown does any work and released in the caller's `defer`, so a teardown
    /// that throws cannot leak an id and leave a workspace permanently reported as being torn down.
    /// Reference-counted because a workspace can be covered by two overlapping registrations — a project
    /// delete claims all of its workspaces while an archive of one of them may already be queued — and the
    /// first release must not drop the other's claim.
    func register(workspaceIDs ids: [String]) {
        lock.lock()
        for id in ids { workspaceIDs[id, default: 0] += 1 }
        lock.unlock()
    }

    func release(workspaceIDs ids: [String]) {
        lock.lock()
        for id in ids {
            guard let count = workspaceIDs[id] else { continue }
            if count <= 1 { workspaceIDs.removeValue(forKey: id) } else { workspaceIDs[id] = count - 1 }
        }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return workspaceIDs.keys.sorted()
    }
}
