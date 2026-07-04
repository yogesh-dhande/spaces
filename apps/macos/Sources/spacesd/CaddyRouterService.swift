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
    @MainActor final class CaddyRouterService {
        private let databasePath: String
        private let onError: @Sendable (String) -> Void
        private let lifecycle = CaddyRouterLifecycle()
        private var reconcileTask: Task<Void, Never>?
        private var pending = false

        init(databasePath: String, onError: @escaping @Sendable (String) -> Void) {
            self.databasePath = databasePath
            self.onError = onError
        }

        func start() { reconcile() }

        func reconcile() {
            guard reconcileTask == nil else {
                pending = true
                return
            }
            let databasePath = databasePath
            let lifecycle = lifecycle
            let onError = onError
            reconcileTask = Task { @MainActor [weak self] in
                guard let self else { return }
                repeat {
                    self.pending = false
                    await Task.detached(priority: .utility) { @Sendable in
                        do {
                            let store = try SQLiteStore(path: databasePath)
                            let orchestrator = WorkspaceOrchestrator(store: store)
                            let routes = CaddyRouteRegistry.mergedRoutes(
                                localRoutes: try orchestrator.caddyRouteTable(),
                                registryRoutes: try CaddyRouteRegistry.routes(path: try CaddyService.routeRegistryPath()))
                            let routerPort = (try? orchestrator.appConfig().routerPort) ?? AppConfig.defaultRouterPort
                            let adminSocketPath = try CaddyService.adminSocketPath()
                            let configJSON = CaddyConfigBuilder.makeJSON(routes: routes, listenPort: routerPort, adminSocketPath: adminSocketPath)
                            try lifecycle.ensureRunning(configJSON: configJSON)
                        } catch { onError("\(error)") }
                    }.value
                } while self.pending
                self.reconcileTask = nil
            }
        }

        func stop() {
            reconcileTask?.cancel()
            reconcileTask = nil
            pending = false
            lifecycle.stop()
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
