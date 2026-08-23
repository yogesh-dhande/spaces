import Foundation
import workspacecore

/// Keeps this daemon's placeholder port reservations aligned with the database.
///
/// `spacesd` is the only process that binds placeholder sockets on workspace service ports, so it is
/// also the only one that can release them: a workspace can be deleted, started, stopped, or given
/// different ports from the app, the CLI, or a remote client, and none of those can close a descriptor
/// this process holds. Each pass recomputes the wanted set from the store and closes or binds the
/// difference (`PortReservationReconciler`).
///
/// Every device runs this, headless Linux daemons included: they assign workspace service ports
/// exactly as the Mac does.
///
/// Reconciliation is driven by the daemon's `databaseDidChange` notifications — the writes that change
/// which ports should be held are exactly what raise them — plus an initial pass at startup, over a
/// long-lived connection owned by `DaemonReconcileStore` (see its doc comment for why a per-pass
/// connection is not used).
@MainActor final class PortReservationService {
    private let onError: @Sendable (String) -> Void
    private let reconcileStore: DaemonReconcileStore
    private var reconcileTask: Task<Void, Never>?
    private var pending = false
    /// Latched by `beginStop()`. A reconcile task created just before the stop has not necessarily begun
    /// its first pass, so clearing the task handle alone would not stop it from submitting one.
    private var stopped = false

    init(databasePath: String, onError: @escaping @Sendable (String) -> Void) {
        self.onError = onError
        reconcileStore = DaemonReconcileStore(label: "spaces.daemon.port-reservation-reconcile", databasePath: databasePath)
    }

    func start() { reconcile() }

    func reconcile() {
        guard !stopped else { return }
        guard reconcileTask == nil else {
            pending = true
            return
        }
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.stopped {
                self.pending = false
                do {
                    _ = try await self.reconcileStore.run { try PortReservationReconciler(store: $0).reconcile() }
                } catch { self.onError("\(error)") }
                guard self.pending else { break }
            }
            self.reconcileTask = nil
        }
    }

    /// Latching half of the stop, and deliberately synchronous. Every gate the loop consults is on the
    /// main actor along with this, so once `stopped` is set no further pass can be submitted, including
    /// by a reconcile task that was already committed and is still looping.
    ///
    /// Split from `releaseStore()` so the daemon's shutdown can latch every service that produces work
    /// before it suspends on any drain.
    func beginStop() {
        stopped = true
        pending = false
        reconcileTask = nil
    }

    /// Awaited half of the stop: releases the database connection, taking its final WAL checkpoint, and
    /// does not return until that has happened. Call it only after `beginStop()`, which is what makes
    /// the close the last thing this loop's store ever does.
    ///
    /// The placeholder sockets themselves are deliberately left held here. They are process-lifetime
    /// state: an ordinary exit closes them, and the update handoff's `execv` closes them too because
    /// every placeholder descriptor is `FD_CLOEXEC`, so the successor daemon rebinds the set it wants on
    /// its own first pass.
    func releaseStore() async { await reconcileStore.close() }
}
