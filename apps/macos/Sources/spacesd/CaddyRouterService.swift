#if os(macOS)
    import Foundation
    import spacesdatabase
    import spacesterminalcore
    import workspacecore

    /// Runs and reconciles the Caddy router on the local macOS daemon. Caddy reverse-proxies
    /// `<service>.<workspace-slug>.localhost` hosts to each local workspace's assigned port. The
    /// daemon owns the store and runs on the Mac where the browser lives, so it is the natural owner;
    /// remote (Linux) daemons never build this service.
    ///
    /// Reconciliation is driven by the daemon's existing database-change notifications (workspace
    /// create/start/stop allocate or change ports) plus an initial pass at startup. Every pass asks
    /// CaddyService to ensure the router is still alive, so service URLs recover even if Caddy exits
    /// between route changes.
    ///
    /// Database writes are themselves what raise `databaseDidChange`, so this loop runs often enough
    /// that a connection per pass made every pass pay a WAL checkpoint and fsync on close. Its
    /// connection is therefore long-lived and owned by `DaemonReconcileStore`, which also serializes
    /// the passes onto the one queue allowed to touch it.
    @MainActor final class CaddyRouterService {
        private let onError: @Sendable (String) -> Void
        private let lifecycle = CaddyRouterLifecycle()
        private let reconcileStore: DaemonReconcileStore
        private var reconcileTask: Task<Void, Never>?
        private var pending = false
        /// Latched by `stop()`. A reconcile task created just before the stop has not necessarily
        /// begun its first pass, and `runPass` is not cancellable, so clearing the task handle alone
        /// would not stop it from submitting one.
        private var stopped = false

        init(databasePath: String, onError: @escaping @Sendable (String) -> Void) {
            self.onError = onError
            let lifecycle = lifecycle
            reconcileStore = DaemonReconcileStore(label: "spaces.daemon.caddy-router-reconcile", databasePath: databasePath) { store in
                let orchestrator = WorkspaceOrchestrator(store: store)
                let routes = CaddyRouteRegistry.mergedRoutes(
                    localRoutes: try orchestrator.caddyRouteTable(),
                    registryRoutes: try CaddyRouteRegistry.routes(path: try CaddyService.routeRegistryPath()))
                let routerPort = (try? orchestrator.appConfig().routerPort) ?? AppConfig.defaultRouterPort
                let adminSocketPath = try CaddyService.adminSocketPath()
                let configJSON = CaddyConfigBuilder.makeJSON(routes: routes, listenPort: routerPort, adminSocketPath: adminSocketPath)
                try lifecycle.ensureRunning(configJSON: configJSON)
            }
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
                    do { try await self.reconcileStore.runPass() } catch { self.onError("\(error)") }
                    guard self.pending else { break }
                }
                self.reconcileTask = nil
            }
        }

        /// Quiesces the loop and releases the database connection, taking its final WAL checkpoint.
        /// Every gate the loop consults is on the main actor along with this, so once `stopped` is
        /// set no further pass can be submitted and the close is the last thing the store ever does.
        func stop() {
            stopped = true
            pending = false
            reconcileTask = nil
            lifecycle.stop()
            reconcileStore.close()
        }
    }

    /// Serializes Caddy process mutations so shutdown cannot race an in-flight reconcile restart.
    final class CaddyRouterLifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        func ensureRunning(configJSON: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            try CaddyService.ensureRunning(configJSON: configJSON)
        }

        func stop() {
            lock.lock()
            stopped = true
            defer { lock.unlock() }
            CaddyService.stop()
        }
    }
#endif
