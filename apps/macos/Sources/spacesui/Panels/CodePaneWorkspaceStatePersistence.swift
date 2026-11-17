import Dispatch
import Foundation

/// The one ordered write-behind path for Editor recovery documents. Controllers are short-lived and
/// can overlap while a global Editor retargets A → B → A, so coordinating per controller would let
/// their independent queues race the same durable document. This coordinator serializes the actual
/// write, while retaining only the latest self-contained snapshot for each workspace.
///
/// Workspace deletion goes through the same serial queue, so the SQLite delete is ordered after every
/// write already running or queued ahead of it and the caller never waits on a write. `lock` guards
/// only in-memory bookkeeping and is never held across SQLite work, so the main actor never blocks
/// behind a multi-megabyte write. A deleted key stays fenced for the rest of the launch: `enqueue`
/// drops its writes and `deletedKeys` rejects them, so no write can recreate the document after the
/// delete.
private final class CodePaneWorkspaceStatePersistenceCoordinator: @unchecked Sendable {
    private struct PendingWrite: Sendable {
        let state: CodePaneWorkspaceState
        let storageKey: String
        let workspaceID: String
        let write: @Sendable (String, String) -> Void
    }

    static let shared = CodePaneWorkspaceStatePersistenceCoordinator()

    private let queue = DispatchQueue(label: "spaces.code-pane.workspace-state", qos: .utility)
    private let lock = NSLock()
    private var pendingWrites: [String: PendingWrite] = [:]
    private var pendingOrder: [String] = []
    private var draining = false
    private var deletedKeys: Set<String> = []
    /// The newest authoritative live set per storage home. Only ids fenced at call time are deleted
    /// without re-checking it: a workspace id is minted once and an authoritative overview that drops
    /// it fences it for the launch, so a fenced id never legitimately becomes live again.
    private var latestLiveWorkspaceIDs: [String: Set<String>] = [:]

    func enqueue(
        _ state: CodePaneWorkspaceState, storageKey: String, workspaceID: String,
        write: @escaping @Sendable (String, String) -> Void
    ) {
        let writeKey = key(storageKey: storageKey, workspaceID: workspaceID)
        lock.lock()
        guard !deletedKeys.contains(writeKey) else {
            lock.unlock()
            return
        }
        if pendingWrites[writeKey] == nil { pendingOrder.append(writeKey) }
        pendingWrites[writeKey] = PendingWrite(state: state, storageKey: storageKey, workspaceID: workspaceID, write: write)
        guard !draining else {
            lock.unlock()
            return
        }
        draining = true
        lock.unlock()
        queue.async { self.drain() }
    }

    func drainForTermination() {
        queue.sync {}
    }

    /// Resumes once every write and delete queued before this call has finished. Unlike
    /// `drainForTermination`, the caller suspends instead of blocking its thread.
    func waitForQueuedWork() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func isDeleted(storageKey: String, workspaceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deletedKeys.contains(key(storageKey: storageKey, workspaceID: workspaceID))
    }

    /// Fences and then deletes the recovery documents of every workspace in `candidateIDs` (plus any
    /// with a queued write) that the authoritative overview no longer lists. The fence and the
    /// removal of queued writes happen synchronously under `lock`, so nothing enqueued afterwards can
    /// survive. The SQLite work runs on the serial queue behind any write already in flight, which is
    /// also where durable documents unknown to the caller (left by an earlier launch) are discovered:
    /// reading them off-main keeps the caller from waiting on the database connection a write holds.
    /// A workspace with no cached snapshot, no queued write and no place in the previous overview
    /// cannot have been written this launch, so discovering it on the queue leaves no gap.
    func deleteMissingWorkspaces(
        storageKey: String, candidateIDs: Set<String>, liveWorkspaceIDs: Set<String>,
        persistedWorkspaceIDs: @escaping @Sendable () -> [String], delete: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        let queued = pendingWrites.values.lazy.filter { $0.storageKey == storageKey }.map(\.workspaceID)
        latestLiveWorkspaceIDs[storageKey] = liveWorkspaceIDs
        let fenced = candidateIDs.union(queued).subtracting(liveWorkspaceIDs)
        for workspaceID in fenced {
            let deletedKey = key(storageKey: storageKey, workspaceID: workspaceID)
            deletedKeys.insert(deletedKey)
            if pendingWrites.removeValue(forKey: deletedKey) != nil { pendingOrder.removeAll { $0 == deletedKey } }
        }
        lock.unlock()
        queue.async { [self] in
            let persisted = Set(persistedWorkspaceIDs())
            lock.lock()
            // Judged against the newest overview, not the one this call carried: a workspace a newer
            // overview introduced may have written its document while this block waited in the queue.
            let discovered = persisted.subtracting(latestLiveWorkspaceIDs[storageKey] ?? liveWorkspaceIDs).subtracting(fenced)
            for workspaceID in discovered { deletedKeys.insert(key(storageKey: storageKey, workspaceID: workspaceID)) }
            lock.unlock()
            for workspaceID in fenced.union(discovered) { delete(workspaceID) }
        }
    }

    private func drain() {
        while let pending = takePendingWrite() {
            autoreleasepool {
                guard let data = try? JSONEncoder().encode(pending.state), let stateJSON = String(data: data, encoding: .utf8) else { return }
                pending.write(stateJSON, pending.workspaceID)
            }
        }
    }

    private func takePendingWrite() -> PendingWrite? {
        lock.lock()
        defer { lock.unlock() }
        guard let writeKey = pendingOrder.first else {
            draining = false
            return nil
        }
        pendingOrder.removeFirst()
        return pendingWrites.removeValue(forKey: writeKey)
    }

    private func key(storageKey: String, workspaceID: String) -> String { "\(storageKey)\u{1f}\(workspaceID)" }
}

/// Serial write-behind facade for one Editor workspace document. Snapshot construction stays on the
/// main actor, but JSON encoding and SQLite happen on the shared coordinator so a large dirty buffer
/// never stalls interaction. A burst keeps only its newest complete document.
final class CodePaneWorkspaceStatePersistence: @unchecked Sendable {
    private let storageKey: String
    private let write: @Sendable (String, String) -> Void

    init(
        label _: String, storageKey: String, write: @escaping @Sendable (String, String) -> Void
    ) {
        self.storageKey = storageKey
        self.write = write
    }

    /// This method does no encoding, allocation proportional to the editor contents, or I/O on its
    /// caller's executor.
    func enqueue(_ state: CodePaneWorkspaceState, workspaceID: String) {
        CodePaneWorkspaceStatePersistenceCoordinator.shared.enqueue(
            state, storageKey: storageKey, workspaceID: workspaceID, write: write)
    }

    /// Used only while the process is terminating. Regular pane close deliberately leaves the write
    /// behind: blocking the main actor to encode a multi-megabyte recovery document would make normal
    /// Editor navigation visibly stall. App termination has no later opportunity to finish the write.
    func drainForTermination() {
        CodePaneWorkspaceStatePersistenceCoordinator.shared.drainForTermination()
    }

    /// Suspends until every write and delete queued so far has finished, without blocking the caller.
    static func waitForQueuedWork() async {
        await CodePaneWorkspaceStatePersistenceCoordinator.shared.waitForQueuedWork()
    }

    /// The app-wide termination fence. A pane can be removed from `PanelCoordinator` while its
    /// close collector is still live, so termination must wait on the global collector registry,
    /// then drain the one shared write-behind queue exactly once.
    @MainActor static func finishTermination(_ completion: @escaping () -> Void) {
        CodePaneWorkspaceStateHandoff.waitForAllCollectors {
            CodePaneWorkspaceStatePersistenceCoordinator.shared.drainForTermination()
            completion()
        }
    }
}

/// The recovery document's in-process mirror makes an immediate workspace retarget see the same
/// snapshot even while its durable write is still encoding off-main. It is intentionally only a
/// launch-local cache: app restart always reloads from the client database.
@MainActor enum CodePaneWorkspaceStateCache {
    private static var states: [String: CodePaneWorkspaceState] = [:]

    static func state(storageKey: String, workspaceID: String) -> CodePaneWorkspaceState? {
        states[key(storageKey: storageKey, workspaceID: workspaceID)]
    }

    static func store(_ state: CodePaneWorkspaceState, storageKey: String, workspaceID: String) {
        guard !CodePaneWorkspaceStatePersistenceCoordinator.shared.isDeleted(storageKey: storageKey, workspaceID: workspaceID) else { return }
        states[key(storageKey: storageKey, workspaceID: workspaceID)] = state
    }

    static func remove(storageKey: String, workspaceID: String) {
        states.removeValue(forKey: key(storageKey: storageKey, workspaceID: workspaceID))
    }

    private static func workspaceIDs(storageKey: String) -> Set<String> {
        let prefix = "\(storageKey)\u{1f}"
        return Set(states.keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count))
        })
    }

    /// Reconciles recovery documents against one device's authoritative workspace overview. The
    /// fenced set includes in-process snapshots, pending off-main writes, and workspace ids from the
    /// prior overview: the last category closes the interval where a pane had collected state but its
    /// write had not reached either cache or SQLite yet. Durable documents are discovered and every
    /// delete runs on the persistence queue, so this returns without waiting on SQLite; once it
    /// returns, no controller or queued write from a deleted workspace can reinsert its document
    /// during this launch.
    static func deleteStateForMissingWorkspaces(
        storageKey: String,
        liveWorkspaceIDs: Set<String>,
        previousWorkspaceIDs: Set<String>,
        persistedWorkspaceIDs: @escaping @Sendable () -> [String],
        delete: @escaping @Sendable (String) -> Void
    ) {
        let candidates = workspaceIDs(storageKey: storageKey).union(previousWorkspaceIDs)
        CodePaneWorkspaceStatePersistenceCoordinator.shared.deleteMissingWorkspaces(
            storageKey: storageKey, candidateIDs: candidates, liveWorkspaceIDs: liveWorkspaceIDs,
            persistedWorkspaceIDs: persistedWorkspaceIDs, delete: delete)
        for workspaceID in candidates where !liveWorkspaceIDs.contains(workspaceID) {
            remove(storageKey: storageKey, workspaceID: workspaceID)
        }
    }

    private static func key(storageKey: String, workspaceID: String) -> String { "\(storageKey)\u{1f}\(workspaceID)" }
}

/// Serializes one workspace's outgoing page collector with the next controller's initial restore.
/// A rapid A → B → A retarget may create the returning A before the first A's asynchronous collector
/// replies; the returning page waits here, then reads the collector-updated cache as its one init
/// payload. This is deliberately a handoff gate, not a second persistence path.
@MainActor enum CodePaneWorkspaceStateHandoff {
    struct Owner: Equatable {
        fileprivate let key: String
        fileprivate let generation: Int
    }

    private struct OwnerState {
        var generation = 0
        var activeOwnerGeneration: Int?
        var currentOwnerPersistedState = false
    }

    private static var outstandingCollectors: [String: Int] = [:]
    private static var waiters: [String: [() -> Void]] = [:]
    private static var terminationWaiters: [() -> Void] = []
    private static var owners: [String: OwnerState] = [:]

    /// Gives a replacement controller ownership before it can write state. An outgoing collector is
    /// still allowed to hand off its final snapshot until this replacement actually writes anything;
    /// after that, the replacement's state is authoritative and the stale collector is discarded.
    static func claimOwner(storageKey: String, workspaceID: String) -> Owner {
        let key = key(storageKey: storageKey, workspaceID: workspaceID)
        var state = owners[key] ?? OwnerState()
        state.generation += 1
        state.activeOwnerGeneration = state.generation
        state.currentOwnerPersistedState = false
        owners[key] = state
        return Owner(key: key, generation: state.generation)
    }

    static func ownerMayPersistState(_ owner: Owner) -> Bool {
        guard var state = owners[owner.key], state.generation == owner.generation,
            state.activeOwnerGeneration == owner.generation
        else { return false }
        state.currentOwnerPersistedState = true
        owners[owner.key] = state
        return true
    }

    static func outgoingCollectorMayPersistState(_ owner: Owner) -> Bool {
        guard let state = owners[owner.key] else { return false }
        return state.generation == owner.generation || !state.currentOwnerPersistedState
    }

    static func releaseOwner(_ owner: Owner) {
        guard var state = owners[owner.key], state.generation == owner.generation,
            state.activeOwnerGeneration == owner.generation
        else { return }
        state.activeOwnerGeneration = nil
        owners[owner.key] = state
        removeOwnershipIfUnclaimedAndCollectorFree(key: owner.key)
    }

    static func collectorStarted(storageKey: String, workspaceID: String) {
        let key = key(storageKey: storageKey, workspaceID: workspaceID)
        outstandingCollectors[key, default: 0] += 1
    }

    static func collectorFinished(storageKey: String, workspaceID: String) {
        let key = key(storageKey: storageKey, workspaceID: workspaceID)
        guard let count = outstandingCollectors[key] else { return }
        if count > 1 {
            outstandingCollectors[key] = count - 1
            return
        }
        outstandingCollectors.removeValue(forKey: key)
        removeOwnershipIfUnclaimedAndCollectorFree(key: key)
        let readyWaiters = waiters.removeValue(forKey: key) ?? []
        for waiter in readyWaiters { waiter() }
        finishTerminationWaitersIfPossible()
    }

    static func waitForAllCollectors(_ completion: @escaping () -> Void) {
        guard !outstandingCollectors.isEmpty else {
            completion()
            return
        }
        terminationWaiters.append(completion)
    }

    static func waitUntilCollectorFinishes(storageKey: String, workspaceID: String, _ waiter: @escaping () -> Void) -> Bool {
        let key = key(storageKey: storageKey, workspaceID: workspaceID)
        guard outstandingCollectors[key] != nil else { return false }
        waiters[key, default: []].append(waiter)
        return true
    }

    /// A pre-ready navigation request must not turn a replacement into the authoritative writer
    /// while its outgoing page can still hand off a newer complete snapshot. The replacement keeps
    /// the requested mode in memory and merges it only after this becomes false.
    static func hasOutstandingCollector(storageKey: String, workspaceID: String) -> Bool {
        outstandingCollectors[key(storageKey: storageKey, workspaceID: workspaceID)] != nil
    }

    private static func finishTerminationWaitersIfPossible() {
        guard outstandingCollectors.isEmpty else { return }
        let readyWaiters = terminationWaiters
        terminationWaiters.removeAll()
        for waiter in readyWaiters { waiter() }
    }

    /// A just-closed replacement can report `__uninstalled__` while an older page still has a
    /// collector in flight. Keep the replacement generation's no-write marker through that interval:
    /// it is the proof that the older collector may still supply the newest complete snapshot. Once
    /// no live controller or collector remains, ownership has no further effect and is discarded.
    private static func removeOwnershipIfUnclaimedAndCollectorFree(key: String) {
        guard outstandingCollectors[key] == nil, owners[key]?.activeOwnerGeneration == nil else { return }
        owners.removeValue(forKey: key)
    }

    private static func key(storageKey: String, workspaceID: String) -> String { "\(storageKey)\u{1f}\(workspaceID)" }
}
