// DispatchSourceProcess (kqueue NOTE_EXIT) is Darwin-only; the daemon also builds
// for Linux, where this monitor is unused, so keep it out of non-macOS targets.
#if os(macOS)

    import Dispatch
    import Foundation
    import spacesterminalcore

    /// Device-runtime process-exit monitoring, owned by the daemon.
    ///
    /// Configured workspace processes are spawned by `spacesd`, so detecting their
    /// exit and applying the on-exit policy (notify/restart) is device-runtime work
    /// and belongs in the daemon — it runs on every device, including headless
    /// remotes the thin-client GUI cannot reach. A `DispatchSourceProcess` per
    /// running pid runs the orchestrator's status reconcile on exit; the reconcile
    /// writes through `SQLiteStore`, which announces `databaseDidChange`, so the GUI
    /// sidebar and remote overview subscribers refresh without coupling here.
    ///
    /// The reconcile builds a plain `WorkspaceOrchestrator`, so restart and notify
    /// resolve through the process-wide overrides the daemon installs (its in-process
    /// terminal launcher, and a notification deliverer that forwards to the client).
    ///
    /// Exit events and runtime-state changes arrive as fast as terminal output does, so both kinds of
    /// database work this does (the status reconcile, and the running-pid read that reattaches observers)
    /// share one long-lived connection owned by `DaemonReconcileStore` (see its doc comment for why a
    /// connection per pass is not used, and why the passes are serialized onto its queue).
    @MainActor public final class ProcessExitMonitorService {
        private let onError: (@Sendable (any Error) -> Void)?
        private let reconcileStore: DaemonReconcileStore
        private var observers: [Int: DispatchSourceProcess] = [:]
        private var runtimeStateObserver: NSObjectProtocol?
        private var reconcileInFlight = false
        private var pendingReconcileIgnoresStartupGrace: Bool?
        // Pids recorded running but already dead before an observer could attach are
        // reconciled once; a pid the reconcile keeps running is not reconciled again,
        // avoiding a loop. Cleared when the pid leaves the running set.
        private var reconciledDeadPIDs: Set<Int> = []
        private var started = false

        public init(databasePath: String, onError: (@Sendable (any Error) -> Void)? = nil) {
            self.onError = onError
            reconcileStore = DaemonReconcileStore(label: "spaces.daemon.process-exit-reconcile", databasePath: databasePath)
        }

        /// Reconciles once on startup (catching exits that happened while the daemon
        /// was down) and installs exit observers for currently-running children.
        public func start() {
            guard !started else { return }
            started = true
            runtimeStateObserver = NotificationCenter.default.addObserver(forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.reconcileThenRefresh() }
            }
            requestReconcileThenRefresh(ignoreStartupGracePeriod: false)
            refreshObservers()
        }

        /// Awaited half of the stop: releases the database connection and takes its final WAL checkpoint,
        /// and does not return until that has happened. Call it only after `stop()`, which is what makes
        /// the close the last thing this monitor's store ever does.
        public func releaseStore() async { await reconcileStore.close() }

        public func stop() {
            started = false
            if let runtimeStateObserver {
                NotificationCenter.default.removeObserver(runtimeStateObserver)
                self.runtimeStateObserver = nil
            }
            for source in observers.values { source.cancel() }
            observers.removeAll()
            reconciledDeadPIDs.removeAll()
            pendingReconcileIgnoresStartupGrace = nil
            reconcileInFlight = false
        }

        /// Reconciles the installed observers to the currently-running owned pids.
        /// The daemon calls this on `databaseDidChange`, since launches and stops
        /// change the running set.
        public func refreshObservers() {
            guard started else { return }
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                let runningPIDs = await self.runningOwnedProcessPIDs()
                // Checked before the read is judged: a stop that landed during the read has released the
                // store, and its nil is the service ending, not a failed read.
                guard self.started else { return }
                guard let runningPIDs else {
                    // Transient read failure: keep existing observers rather than
                    // dropping them all, which would leave exits undetected.
                    self.onError?(ProcessExitMonitorError.couldNotReadRunningProcesses)
                    return
                }
                for (pid, source) in self.observers where !runningPIDs.contains(pid) {
                    source.cancel()
                    self.observers[pid] = nil
                }
                self.reconciledDeadPIDs.formIntersection(runningPIDs)
                var hasUnreconciledDeadPID = false
                for pid in runningPIDs where self.observers[pid] == nil {
                    if Self.isProcessAlive(pid: pid) {
                        self.installObserver(pid: pid)
                    } else if !self.reconciledDeadPIDs.contains(pid) {
                        // Recorded running but already dead with no exit event coming
                        // (it died before its observer was installed). Reconcile once,
                        // ignoring the startup grace, so it is marked exited and its
                        // on-exit policy runs.
                        self.reconciledDeadPIDs.insert(pid)
                        hasUnreconciledDeadPID = true
                    }
                }
                if hasUnreconciledDeadPID { self.reconcileThenRefresh() }
            }
        }

        private func installObserver(pid: Int) {
            let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .global(qos: .utility))
            // The handler runs on a background dispatch queue, so it must be a
            // non-isolated @Sendable closure that hops to the main actor; otherwise
            // the closure inherits this method's @MainActor isolation and dispatch
            // trips a `dispatch_assert_queue` SIGTRAP when it invokes it off-main.
            source.setEventHandler { @Sendable [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.observers[pid]?.cancel()
                    self.observers[pid] = nil
                    // The kernel told us this pid exited, so reconcile authoritatively,
                    // ignoring the startup grace that would otherwise skip a process
                    // that exited within its first 10s.
                    self.reconcileThenRefresh()
                }
            }
            source.resume()
            observers[pid] = source
        }

        private func reconcileThenRefresh() { requestReconcileThenRefresh(ignoreStartupGracePeriod: true) }

        private func requestReconcileThenRefresh(ignoreStartupGracePeriod: Bool) {
            guard started else { return }
            if reconcileInFlight {
                pendingReconcileIgnoresStartupGrace = (pendingReconcileIgnoresStartupGrace ?? false) || ignoreStartupGracePeriod
                return
            }
            reconcileInFlight = true
            Task { @MainActor [weak self] in
                var ignoresStartupGrace = ignoreStartupGracePeriod
                while true {
                    guard let self else { return }
                    await self.reconcile(ignoreStartupGracePeriod: ignoresStartupGrace)
                    guard self.started else { return }
                    guard let pendingIgnoresStartupGrace = self.pendingReconcileIgnoresStartupGrace else {
                        self.reconcileInFlight = false
                        // The reconcile may have applied restart/exit policies that changed the
                        // running set, so reattach observers to the current children.
                        self.refreshObservers()
                        return
                    }
                    self.pendingReconcileIgnoresStartupGrace = nil
                    ignoresStartupGrace = pendingIgnoresStartupGrace
                }
            }
        }

        private func reconcile(ignoreStartupGracePeriod: Bool) async {
            do {
                _ = try await reconcileStore.run { store in
                    try WorkspaceOrchestrator(store: store).checkAndUpdateProcessStatuses(ignoreStartupGracePeriod: ignoreStartupGracePeriod)
                }
            } catch { onError?(error) }
        }

        /// Returns nil on a transient store error so the caller can distinguish "no
        /// processes are running" from "could not read" and avoid tearing down live
        /// observers on a failed read. A read after the store is released reads nil for
        /// the same reason: there is nothing to observe once this service has stopped.
        private func runningOwnedProcessPIDs() async -> Set<Int>? {
            do { return try await reconcileStore.run { try WorkspaceOrchestrator(store: $0).runningOwnedProcessPIDs() } } catch { return nil }
        }

        private nonisolated static func isProcessAlive(pid: Int) -> Bool {
            guard pid > 0 else { return false }
            return kill(pid_t(pid), 0) == 0 || errno == EPERM
        }
    }

    private enum ProcessExitMonitorError: LocalizedError {
        case couldNotReadRunningProcesses

        var errorDescription: String? {
            switch self {
            case .couldNotReadRunningProcesses: "Could not read running processes to refresh process-exit observers."
            }
        }
    }

#endif
