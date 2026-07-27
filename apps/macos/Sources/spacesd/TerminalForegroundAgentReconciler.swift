import Foundation
import spacesterminalcore
import workspacecore

/// Reconciles ad-hoc foreground coding-agent classifications when a terminal's
/// runtime state changes (the foreground process is part of runtime state).
///
/// The daemon hosts the terminal session cores, which post
/// `.spacesTerminalRuntimeStateDidChange` in-process on a runtime-state change, so
/// this classification — device-runtime work — runs in `spacesd` rather than the
/// thin-client GUI. The reconcile writes through `SQLiteStore`, so the GUI sidebar
/// and remote overview refresh on `databaseDidChange`.
///
/// Foreground changes can arrive faster than a reconcile completes, so events that
/// land mid-flight collapse into a single trailing re-run.
///
/// Terminal runtime state changes with terminal output, so this is one of the daemon's
/// hottest notification loops. Its database connection is therefore long-lived and owned
/// by `DaemonReconcileStore` — a connection per pass made routine terminal output pay a
/// WAL checkpoint and fsync per pass. Each pass builds its own `WorkspaceOrchestrator`
/// (cheap, and its per-instance lifecycle gates stay pass-scoped).
@MainActor final class TerminalForegroundAgentReconciler {
    private let reconcileStore: DaemonReconcileStore
    private let onError: (@Sendable (any Error) -> Void)?
    private var observer: NSObjectProtocol?
    private var inFlight = false
    private var pending = false
    /// Latched by `beginStop()`. Removing the observer is not enough on its own: a notification posted
    /// just before the stop can still be waiting to be delivered on the main queue, and a reconcile
    /// task created just before the stop has not necessarily begun its first pass.
    private var stopped = false

    init(databasePath: String, onError: (@Sendable (any Error) -> Void)? = nil) {
        self.onError = onError
        reconcileStore = DaemonReconcileStore(label: "spaces.daemon.foreground-agent-reconcile", databasePath: databasePath) { store in
            _ = try WorkspaceOrchestrator(store: store).reconcileTerminalForegroundAgentClassifications()
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    /// Latching half of the stop, and deliberately synchronous. Every gate the loop consults is on the
    /// main actor along with this, so once `stopped` is set no further pass can be submitted: not by a
    /// notification whose delivery was already queued, and not by a reconcile task that was committed but
    /// has not begun its first pass.
    ///
    /// Split from `releaseStore()` so the daemon's shutdown can latch every service that produces work
    /// before it suspends on any drain. A combined stop would leave the loops that come later in the
    /// teardown still live across the earlier ones' suspensions.
    func beginStop() {
        stopped = true
        pending = false
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Awaited half of the stop: releases the database connection, taking its final WAL checkpoint, and
    /// does not return until that has happened. Call it only after `beginStop()`, which is what makes the
    /// close the last thing this loop's store ever does.
    ///
    /// Awaiting the close is what establishes the release: returning from here means this loop's
    /// connection is gone and its final checkpoint taken, so whatever the daemon does next — including
    /// re-execing a replacement against the same database — starts after that. Awaiting rather than
    /// blocking also matters: the pass this close may be queued behind can hop synchronously onto the
    /// terminal engine actor, which is allowed to hop synchronously back to main, so the main actor has
    /// to stay free while the store's queue drains.
    func releaseStore() async { await reconcileStore.close() }

    private func reconcile() {
        guard !stopped else { return }
        guard !inFlight else {
            pending = true
            return
        }
        inFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.stopped {
                self.pending = false
                do { try await self.reconcileStore.runPass() } catch { self.onError?(error) }
                guard self.pending else { break }
            }
            self.inFlight = false
        }
    }
}
