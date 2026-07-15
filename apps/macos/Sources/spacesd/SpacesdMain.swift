import Dispatch
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesruntimecore
import spacesterminalcore
import spacesterminalghostty
import workspacecore

#if canImport(AppKit)
    import AppKit
#endif

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(spacesdeviceapi)
    import spacesdeviceapi
#endif

@MainActor private final class SpacesDaemonController {
    private static let ownerGatedTerminalCommands: Set<String> = ["send", "key", "clearScreen", "resize", "scroll"]
    private static let terminalLinkTransferAuthorizationTTL: TimeInterval = 10 * 60

    private struct TerminalLinkTransferAuthorization {
        let sessionID: String
        let resolvedPath: String
        let expiresAt: Date
    }

    private let socketPath: String
    /// Stable public path this daemon re-execs on an exec-in-place handoff — the raw invoked
    /// `argv[0]` absolutized at `main()` start (symlinks deliberately unresolved so the target stays
    /// the versioned-agnostic `~/.spaces/bin/spacesd`). Captured before anything can chdir.
    private let launchExecutablePath: String
    /// Consecutive-handoff counter carried across execs via the handoff table (0 on a fresh boot).
    /// Feeds the exec-loop generation guard together with `lastHandoffSourceVersion`.
    private var handoffGeneration = 0
    /// The `sourceVersion` of the daemon image that handed off to this one (nil on a fresh boot).
    /// The generation guard refuses another same-target handoff only while this keeps equalling `AppVersion.current`.
    private var lastHandoffSourceVersion: String?
    /// Monotonic process uptime when this image finished replaying an exec handoff. A daemon that
    /// remains stable beyond the guard window starts a fresh generation chain on its next update.
    private var lastHandoffResumeUptime: TimeInterval?
    /// True while `performExecHandoff()` is between its first await and exec; see its reentrancy guard.
    private var handoffInProgress = false
    private let instanceLock: TerminalServiceInstanceLock
    private let serverQueue = DispatchQueue(label: "spaces.terminal.service")
    private lazy var server = TerminalServiceServer(socketPath: socketPath, queue: serverQueue) { [weak self] request in
        Self.runOnMainActorSynchronously {
            guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .shuttingDown) }
            return self.handle(request)
        }
    }
    private lazy var daemonIdentityFingerprint: String? = (try? TerminalServiceTLSIdentityStore.loadOrCreate())?.certificateFingerprint
    private var sessionCores: [String: GhosttyEmbeddedSessionCore] = [:]
    private var terminalLinkTransferAuthorizations: [String: TerminalLinkTransferAuthorization] = [:]
    private var lifecycleTimer: Timer?
    #if os(Linux)
        private let databaseChangeSignalQueue = DispatchQueue(label: "spaces.database-change.signal")
    #endif
    private var worktreeDiscoveryService: WorktreeDiscoveryService?
    private var terminalForegroundAgentReconciler: TerminalForegroundAgentReconciler?
    private var remoteAgentWatchService: RemoteAgentWatchService?
    private var databaseChangeObserver: NSObjectProtocol?
    #if os(Linux)
        private var databaseChangeSignalReceiver: DatabaseChangeSignalReceiver?
    #endif
    #if os(macOS)
        private var databaseDistributedChangeObserver: NSObjectProtocol?
        private var caddyRouteRegistryDistributedChangeObserver: NSObjectProtocol?
        private var processExitMonitor: ProcessExitMonitorService?
        private var caddyRouterService: CaddyRouterService?
    #endif
    private lazy var deviceAPISupervisor = SpacesDaemonDeviceAPISupervisor(
        builtInTerminalSessionTerminator: { [weak self] sessionID in
            Self.runOnMainActorSynchronously { self?.terminateBuiltInTerminalSession(id: sessionID) }
        },
        builtInTerminalSessionLauncher: { [weak self] launchConfiguration in
            try Self.runOnMainActorSynchronously {
                Result {
                    guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                    return try self.launchBuiltInTerminalSession(launchConfiguration)
                }
            }.get()
        }, onRestartRequested: { [weak self] in Task { @MainActor in self?.requestDaemonRestart() } })
    private let git = RemoteWorkspaceGitClient()

    init(launchExecutablePath: String) throws {
        self.launchExecutablePath = launchExecutablePath
        instanceLock = try TerminalServiceInstanceLock.acquire(path: try TerminalServicePaths.instanceLockPath())
        socketPath = try TerminalServicePaths.socketPath()
    }

    /// Startup entry point. Async so the exec-in-place resume prologue can `await` each session core's
    /// `resumeFromHandoff` from a main-actor context while the main run loop stays free to pump the
    /// GhosttyKit ticks that replay depends on — a blocking synchronous resume on the main thread
    /// deadlocks inside replay. `main()` kicks this as a `Task { @MainActor }` and then runs the app
    /// run loop; shared services (the request-accepting socket server, device runtime services) start
    /// only after the resume completes, so a client can never observe a half-resumed daemon.
    func start() async throws {
        try await resumeSessionsFromHandoffIfNeeded()
        try recoverStaleSessions()
        try startSharedServices()
    }

    /// Starts the shared (non-per-session) services. Shared by the normal `start()` tail and the
    /// failed-`execv` fallback, which stopped them in `stopSharedServices()` before quiescing.
    private func startSharedServices() throws {
        try server.start()
        deviceAPISupervisor.start()
        startLifecycleTimer()
        startDeviceRuntimeServices()
    }

    /// Device-runtime work (worktree discovery, process-exit monitoring) is owned by
    /// the daemon, since it runs on every device — including headless remotes the
    /// thin-client GUI cannot reach. Each service reconciles the device's own
    /// filesystem/process state into the database; `databaseDidChange` reconciles
    /// their watcher/observer sets when projects or running processes change.
    private func startDeviceRuntimeServices() {
        installProcessWideOrchestratorHooks()
        guard let databasePath = try? DatabaseLocator.defaultPath() else {
            writeStandardError("spacesd device_runtime_error error=could not resolve database path\n")
            return
        }
        let worktreeService = WorktreeDiscoveryService(databasePath: databasePath) { error in
            writeStandardError("spacesd worktree_discovery_error error=\(error)\n")
        }
        worktreeService.start()
        worktreeDiscoveryService = worktreeService
        let foregroundAgentReconciler = TerminalForegroundAgentReconciler(databasePath: databasePath) { error in
            writeStandardError("spacesd terminal_foreground_agent_reconcile_error error=\(error)\n")
        }
        foregroundAgentReconciler.start()
        terminalForegroundAgentReconciler = foregroundAgentReconciler
        let remoteAgentWatch = RemoteAgentWatchService(
            databasePath: databasePath, clientApp: Self.daemonDeviceClientApp(),
            deliver: { [weak self] sessionID, line in
                guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                _ = try self.sendProfileTerminalInput(
                    TerminalServiceTerminalSendPayload(sessionID: sessionID, input: .text(line), appendNewline: true))
            }, logError: { writeStandardError($0) })
        remoteAgentWatch.start()
        remoteAgentWatchService = remoteAgentWatch
        #if os(macOS)
            // The router port is a Mac-only concept: only the macOS client runs Caddy, so only it
            // pins/consumes a real listening port. Seed it alongside the router service and never on
            // headless remote daemons, whose derived per-profile port would be a fabricated value the
            // browser never dials (see seedProfileRouterPortIfNeeded).
            seedProfileRouterPortIfNeeded(databasePath: databasePath)
            let monitor = ProcessExitMonitorService(databasePath: databasePath) { error in
                writeStandardError("spacesd process_exit_monitor_error error=\(error)\n")
            }
            monitor.start()
            processExitMonitor = monitor
            let caddyRouter = CaddyRouterService(databasePath: databasePath) { error in
                writeStandardError("spacesd caddy_router_error error=\(error)\n")
            }
            caddyRouter.start()
            caddyRouterService = caddyRouter
        #endif
        databaseChangeObserver = NotificationCenter.default.addObserver(forName: IPCNotification.databaseDidChange, object: nil, queue: nil) {
            [weak self] _ in Task { @MainActor in self?.handleDatabaseDidChangeForDeviceRuntime() }
        }
        #if os(Linux)
            do {
                let receiver = try DatabaseChangeSignalReceiver(socketPath: nil, queue: databaseChangeSignalQueue) {
                    NotificationCenter.default.post(name: IPCNotification.databaseDidChange, object: nil)
                }
                try receiver.start()
                databaseChangeSignalReceiver = receiver
            } catch { writeStandardError("spacesd database_change_signal_error error=\(error)\n") }
        #endif
        #if os(macOS)
            databaseDistributedChangeObserver = DistributedNotificationCenter.default().addObserver(
                forName: IPCNotification.databaseDidChange, object: try? IPCNotification.currentObject(), queue: nil
            ) { [weak self] _ in Task { @MainActor in self?.handleDatabaseDidChangeForDeviceRuntime() } }
            caddyRouteRegistryDistributedChangeObserver = DistributedNotificationCenter.default().addObserver(
                forName: IPCNotification.caddyRouteRegistryDidChange, object: try? IPCNotification.currentObject(), queue: nil
            ) { [weak self] _ in Task { @MainActor in self?.caddyRouterService?.reconcile() } }
        #endif
    }

    private func handleDatabaseDidChangeForDeviceRuntime() {
        worktreeDiscoveryService?.refreshWatchers()
        remoteAgentWatchService?.reconcile()
        #if os(macOS)
            processExitMonitor?.refreshObservers()
            caddyRouterService?.reconcile()
        #endif
    }

    /// Routes plain orchestrators built off the request path (the device-runtime
    /// services) through the daemon's in-process terminal launcher and a client-side
    /// notification deliverer. A bundle-less daemon cannot post OS notifications, so
    /// `notify` on-exit events are forwarded to the client to deliver.
    private func installProcessWideOrchestratorHooks() {
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher { [weak self] launchConfiguration in
            try Self.runOnMainActorSynchronously {
                Result {
                    guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                    return try self.launchBuiltInTerminalSession(launchConfiguration)
                }
            }.get()
        }
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator { [weak self] sessionID in
            Self.runOnMainActorSynchronously { self?.terminateBuiltInTerminalSession(id: sessionID) }
        }
        #if os(macOS)
            WorkspaceOrchestrator.setProcessWideNotificationDeliverer { title, body, subtitle in
                var userInfo = [IPCNotification.titleUserInfoKey: title, IPCNotification.detailUserInfoKey: body]
                if let subtitle { userInfo[IPCNotification.notificationSubtitleUserInfoKey] = subtitle }
                try? IPCNotification.post(IPCNotification.deliverUserNotification, userInfo: userInfo)
            }
        #endif
    }

    func shutdown() {
        stopSharedServices()
        terminateAllSessions()
    }

    /// Stops everything except the per-session cores: the lifecycle timer, database-change
    /// observers/receivers, device-runtime services, the Device API supervisor, and the main
    /// request-accepting socket server. Shared by `shutdown()` and the exec-in-place handoff, which
    /// stops intake here and then quiesces (rather than terminates) the session cores.
    private func stopSharedServices() {
        lifecycleTimer?.invalidate()
        lifecycleTimer = nil
        if let databaseChangeObserver {
            NotificationCenter.default.removeObserver(databaseChangeObserver)
            self.databaseChangeObserver = nil
        }
        #if os(Linux)
            databaseChangeSignalReceiver?.stop()
            databaseChangeSignalReceiver = nil
        #endif
        #if os(macOS)
            if let databaseDistributedChangeObserver {
                DistributedNotificationCenter.default().removeObserver(databaseDistributedChangeObserver)
                self.databaseDistributedChangeObserver = nil
            }
            if let caddyRouteRegistryDistributedChangeObserver {
                DistributedNotificationCenter.default().removeObserver(caddyRouteRegistryDistributedChangeObserver)
                self.caddyRouteRegistryDistributedChangeObserver = nil
            }
        #endif
        worktreeDiscoveryService?.stop()
        worktreeDiscoveryService = nil
        terminalForegroundAgentReconciler?.stop()
        terminalForegroundAgentReconciler = nil
        remoteAgentWatchService?.stop()
        remoteAgentWatchService = nil
        #if os(macOS)
            processExitMonitor?.stop()
            processExitMonitor = nil
            caddyRouterService?.stop()
            caddyRouterService = nil
        #endif
        deviceAPISupervisor.stop()
        server.stop()
    }

    private func terminateAllSessions() { for sessionID in Array(sessionCores.keys) { _ = terminateSession(id: sessionID) } }

    private func handle(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        // Socket shutdown is asynchronous, so a request accepted just before cancellation
        // can reach the main actor after handoff starts. Reject it here, at the mutation
        // boundary, so the session snapshot cannot gain or lose a core while quiescing.
        guard !handoffInProgress else {
            return TerminalServiceResponse(
                ok: false, message: "spacesd is handing off to an updated daemon.", errorCode: .shuttingDown, servicePID: getpid())
        }
        switch request.command {
        case .ping: return TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid(), daemonStatus: daemonStatus())
        case .shutdownIfIdle: return shutdownIfIdle()
        case .shutdown:
            writeStandardError("spacesd: terminal service shutdown requested\n")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                self.shutdownAndExit()
            }
            return TerminalServiceResponse(ok: true, message: "spacesd is shutting down.", servicePID: getpid())
        case .applyStagedUpdate:
            // Respond-then-act, mirroring `.shutdown`: acknowledge on the request path, then trigger the
            // exec-in-place handoff. `requestDaemonRestart()` is the single handoff trigger — if its
            // preflight or generation guard refuses, it logs and the daemon keeps running untouched (the
            // ok response was already sent, matching the frozen command's synchronous ok/error contract).
            requestDaemonRestart()
            return TerminalServiceResponse(ok: true, message: "spacesd is applying the staged update.", servicePID: getpid())
        case .create(let payload): return createSession(payload)
        case .prepareWorkspace(let payload):
            do {
                try prepareWorkspace(
                    runtimeManifest: payload.runtimeManifest, worktreeRefresh: payload.worktreeRefresh,
                    workingDirectory: payload.runtimeManifest.remotePath ?? payload.runtimeManifest.localPath)
                return TerminalServiceResponse(ok: true, message: "Workspace runtime is prepared.", servicePID: getpid())
            } catch { return Self.failureResponse(error) }
        case .runWorkspaceCommand(let payload): return runWorkspaceCommand(payload)
        case .terminate(let payload):
            guard !payload.sessionID.isEmpty else {
                return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument)
            }
            return terminateSession(id: payload.sessionID)
        case .list: return listSessions()
        case .state(let payload): return loadTerminalState(sessionID: payload.sessionID)
        case .subscribe(let payload): return subscribeTerminalState(sessionID: payload.sessionID)
        case .control(let payload): return handleTerminalControl(payload)
        case .agentSignal(let payload): return recordAgentSignal(payload)
        case .ackAgentSignals(let payload): return acknowledgeAgentSignals(payload)
        case .profileCommand(let command): return handleProfileCommand(command)
        case .resolveTerminalLink(let payload): return resolveTerminalLink(payload)
        case .readTerminalLinkChunk(let payload): return readTerminalLinkChunk(payload)
        }
    }

    private func daemonStatus() -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: AppVersion.current, installedVersion: InstalledSpacesVersion.current(), certificateFingerprint: daemonIdentityFingerprint,
            activeSessionCount: sessionCores.count)
    }

    // Exec-in-place update trigger: after a short grace so the already-sent RPC response can flush,
    // quiesce every live session, write the handoff table, and `execv` the staged binary at the same
    // pid so children (shells, agents, workspace processes) stay running and supervisors never notice.
    // On preflight/guard refusal or a returned `execv`, `performExecHandoff` logs and leaves the daemon
    // running; the RPC response was already sent (respond-then-act).
    func requestDaemonRestart() {
        writeStandardError("spacesd: daemon restart requested\n")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            await performExecHandoff()
        }
    }

    private func shutdownIfIdle() -> TerminalServiceResponse {
        let status = daemonStatus()
        guard status.activeSessionCount == 0 else {
            return TerminalServiceResponse(
                ok: false, message: "spacesd has \(status.activeSessionCount) active session(s).", errorCode: .busy, servicePID: getpid(),
                daemonStatus: status)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.shutdownAndExit()
        }
        return TerminalServiceResponse(ok: true, message: "spacesd is shutting down.", servicePID: getpid(), daemonStatus: status)
    }

    /// Explicit exit for daemon-initiated termination (shutdown commands, restart requests).
    /// Runs cleanup directly and exits rather than routing through `NSApp.terminate`, so the
    /// exit does not depend on AppKit termination machinery and the shutdown command reaps
    /// children identically on macOS and Linux. External NSApp-driven termination (e.g. logout)
    /// still reaches `shutdown()` through the app delegate.
    private func shutdownAndExit() -> Never {
        shutdown()
        exit(0)
    }

    // MARK: - Exec-in-place handoff

    /// Quiesce every live session and `execv` the staged binary at the same pid, keeping shells,
    /// agents, and workspace processes running across the daemon update. Every failure lands on "the
    /// old daemon keeps running": a refused generation guard or a failed preflight returns before
    /// anything is stopped; a failed table write or a returned `execv` resumes the quiesced sessions
    /// in place and restarts shared services. Runs on the main actor and awaits each core's quiesce so
    /// the main thread stays free to pump the ticks quiesce's output-fence drain depends on.
    private func performExecHandoff() async {
        // Reentrancy guard: the quiesce below suspends at await points, so a second trigger (another
        // paired device, or installer + app racing) could otherwise interleave a double-quiesce. The
        // flag is cleared only on the keep-running failure paths; on success execv replaces the image.
        guard !handoffInProgress else {
            writeStandardError("spacesd handoff_refused reason=already_in_progress\n")
            return
        }
        handoffInProgress = true
        defer { handoffInProgress = false }

        let currentUptime = ProcessInfo.processInfo.systemUptime
        let elapsedSinceLastHandoff = lastHandoffResumeUptime.map { Swift.max(0, currentUptime - $0) }
        guard
            let nextGeneration = DaemonHandoffDecision.nextHandoffGeneration(
                generation: handoffGeneration, lastSourceVersion: lastHandoffSourceVersion, currentVersion: AppVersion.current,
                stagedVersion: InstalledSpacesVersion.current(), elapsedSinceLastHandoff: elapsedSinceLastHandoff)
        else {
            writeStandardError(
                "spacesd handoff_refused reason=generation_guard generation=\(handoffGeneration) source=\(lastHandoffSourceVersion ?? "")\n")
            return
        }

        do { try DaemonHandoffPreflight.run(executablePath: launchExecutablePath, formatVersion: DaemonHandoffTable.currentFormatVersion) } catch {
            writeStandardError("spacesd handoff_preflight_failed error=\(error)\n")
            return
        }
        writeStandardError("spacesd handoff_preflight_ok\n")

        stopSharedServices()
        writeStandardError("spacesd handoff_intake_stopped\n")

        // Quiesce each live core. A nil return means the child already exited — finalize that session
        // through the normal dead-session teardown before exec so it lands `.exited`, not resumed.
        var records: [DaemonHandoffSessionRecord] = []
        var quiescedCores: [GhosttyEmbeddedSessionCore] = []
        // Snapshot the cores first: the nil-quiesce branch calls terminateSession, which mutates
        // sessionCores.
        do {
            for (sessionID, core) in Array(sessionCores) {
                // Add the core before quiescing so a transcript-persistence failure resumes the
                // core whose driver is still buffering, as well as every earlier quiesced core.
                quiescedCores.append(core)
                if let record = try await core.quiesceForHandoff() {
                    records.append(record)
                } else {
                    quiescedCores.removeLast()
                    _ = terminateSession(id: sessionID)
                }
            }
        } catch {
            writeStandardError("spacesd handoff_quiesce_failed error=\(error)\n")
            await resumeInPlaceAfterFailedHandoff(quiescedCores: quiescedCores)
            return
        }
        writeStandardError("spacesd handoff_quiesced sessions=\(records.count)\n")

        for record in records {
            do { try DaemonHandoffStore.prepareDescriptorForHandoff(record.masterFD) } catch {
                writeStandardError("spacesd handoff_prepare_descriptor_failed session=\(record.sessionID) error=\(error)\n")
                await resumeInPlaceAfterFailedHandoff(quiescedCores: quiescedCores)
                return
            }
        }

        let table = DaemonHandoffTable(generation: nextGeneration, pid: getpid(), sourceVersion: AppVersion.current, sessions: records)
        do { try DaemonHandoffStore.write(table) } catch {
            writeStandardError("spacesd handoff_table_write_failed error=\(error)\n")
            await resumeInPlaceAfterFailedHandoff(quiescedCores: quiescedCores)
            return
        }

        writeStandardError("spacesd handoff_exec path=\(launchExecutablePath) generation=\(nextGeneration) sessions=\(records.count)\n")
        var execErrno = Int32(0)
        do {
            try withValidatedHandoffOutputsForExec(ArraySlice(quiescedCores)) {
                execStagedBinary(path: launchExecutablePath)
                execErrno = errno
            }
        } catch {
            writeStandardError("spacesd handoff_output_persistence_failed error=\(error)\n")
            DaemonHandoffStore.deleteTable()
            await resumeInPlaceAfterFailedHandoff(quiescedCores: quiescedCores)
            return
        }

        // `execv` only returns on failure. The written table describes a handoff that never happened,
        // so delete it (a leftover would be adopted by a later respawn of this same pid), then rebind
        // the still-live sessions and restart shared services so the daemon is fully functional again.
        writeStandardError("spacesd handoff_exec_failed errno=\(execErrno)\n")
        DaemonHandoffStore.deleteTable()
        await resumeInPlaceAfterFailedHandoff(quiescedCores: quiescedCores)
    }

    /// Nests each session driver's sink lock around the final validation and exec.
    /// A PTY read can neither fail nor begin a transcript write after its session has
    /// validated; successful exec replaces the process, while a returned exec unwinds
    /// every lock before the in-place resume path runs.
    private func withValidatedHandoffOutputsForExec(_ cores: ArraySlice<GhosttyEmbeddedSessionCore>, operation: () throws -> Void) throws {
        guard let core = cores.first else {
            try operation()
            return
        }
        try core.withValidatedHandoffOutputForExec { try withValidatedHandoffOutputsForExec(cores.dropFirst(), operation: operation) }
    }

    /// Failed-`execv` fallback: rebind every quiesced core to its still-live PTY (nothing was freed —
    /// masters were never CLOEXEC, so no descriptor restore is needed) and restart shared services.
    private func resumeInPlaceAfterFailedHandoff(quiescedCores: [GhosttyEmbeddedSessionCore]) async {
        for core in quiescedCores { await core.resumeInPlaceAfterFailedExec() }
        do { try startSharedServices() } catch { writeStandardError("spacesd handoff_resume_in_place_failed error=\(error)\n") }
    }

    /// `execv`s `path` with this process's original argv verbatim. Original argv matters: the new
    /// image's `ghostty_init` consumes it. `execv` either replaces this image (never returning) or
    /// returns -1 on failure; the strdup'd argv is only freed on the failure path (a leak on the
    /// success path is irrelevant — the image is gone).
    private func execStagedBinary(path: String) {
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        path.withCString { pathPointer in _ = execv(pathPointer, &argv) }
        for pointer in argv where pointer != nil { free(pointer) }
    }

    /// Resume prologue for the staged image, run before `recoverStaleSessions()`. Consumes the handoff
    /// table (nil = fresh boot, unchanged startup) and adopts each surviving session. Awaited from the
    /// main actor so replay can pump ticks.
    private func resumeSessionsFromHandoffIfNeeded() async throws {
        guard let table = DaemonHandoffStore.consume() else { return }
        handoffGeneration = table.generation
        lastHandoffSourceVersion = table.sourceVersion
        writeStandardError("spacesd handoff_resume generation=\(table.generation) sessions=\(table.sessions.count)\n")
        for record in table.sessions { await resumeHandoffSession(record) }
        lastHandoffResumeUptime = ProcessInfo.processInfo.systemUptime
    }

    /// Adopts a single handoff record. Validates the inherited descriptor is still a PTY master and
    /// reaps/probes the child, then acts on the pure `DaemonHandoffResumeAction` decision: live
    /// sessions are rebuilt through the normal session-core factory and `resumeFromHandoff`; dead or
    /// unusable ones are finalized `.exited` (via the normal teardown path) so one bad session can
    /// never abort the resume of the rest.
    private func resumeHandoffSession(_ record: DaemonHandoffSessionRecord) async {
        let descriptorValid = DaemonHandoffStore.descriptorLooksLikePTYMaster(record.masterFD)
        // Reap-pass first so an already-exited child is collected before the liveness probe.
        var status: Int32 = 0
        _ = waitpid(record.childPID, &status, WNOHANG)
        let childAlive = Self.isProcessAlive(pid: Int(record.childPID))
        let action = DaemonHandoffDecision.resumeAction(descriptorLooksLikePTYMaster: descriptorValid, childIsAlive: childAlive)
        switch action {
        case .adopt:
            do {
                let paths = try TerminalSessionPaths.forSession(id: record.sessionID)
                let launchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
                let core = try sessionCore(for: launchConfiguration)
                try await core.resumeFromHandoff(record)
            } catch {
                writeStandardError("spacesd handoff_resume_session_failed session=\(record.sessionID) error=\(error)\n")
                sessionCores.removeValue(forKey: record.sessionID)
                close(record.masterFD)
                _ = terminateSession(id: record.sessionID)
            }
        case .finalizeExited:
            close(record.masterFD)
            _ = terminateSession(id: record.sessionID)
        case .discardInvalidDescriptor: _ = terminateSession(id: record.sessionID)
        }
    }

    private func createSession(_ request: TerminalServiceCreateRequest) -> TerminalServiceResponse {
        guard !handoffInProgress else {
            return TerminalServiceResponse(
                ok: false, message: "spacesd is handing off to an updated daemon.", errorCode: .shuttingDown, servicePID: getpid())
        }
        let launchConfiguration = request.launchConfiguration
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: launchConfiguration.workingDirectory)
            let sessionCore = try sessionCore(for: launchConfiguration)
            try sessionCore.startIfNeeded()
            return TerminalServiceResponse(
                ok: true, message: "Started terminal session \(launchConfiguration.sessionID).",
                session: try sessionSummaryAfterStart(for: launchConfiguration.sessionID))
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
    }

    private func runWorkspaceCommand(_ request: TerminalServiceRunWorkspaceCommandRequest) -> TerminalServiceResponse {
        let workspaceCommand = request.workspaceCommand
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: workspaceCommand.workingDirectory)
            let logPath = try workspaceCommandLogPath(workspaceCommand.logPath)
            let result = try runShellCommand(workspaceCommand, logPath: logPath, manifest: request.runtimeManifest)
            let message = result.exitCode == 0 ? "Workspace command completed." : "Workspace command exited with code \(result.exitCode)."
            return TerminalServiceResponse(ok: true, message: message, servicePID: getpid(), commandResult: result)
        } catch { return Self.failureResponse(error) }
    }

    private func prepareWorkspace(
        runtimeManifest: TerminalServiceWorkspaceRuntimeManifest?, worktreeRefresh: TerminalServiceWorktreeRefreshRequest?, workingDirectory: String?
    ) throws {
        if worktreeRefresh != nil, runtimeManifest == nil {
            throw SpacesRuntimeError.invalidArgument(message: "Workspace runtime manifest is required for worktree refresh.")
        }
        if let manifest = runtimeManifest {
            if let workingDirectory { try validateWorkspacePath(workingDirectory, manifest: manifest) }
            if manifest.location == .remote { try prepareRemoteWorktree(manifest: manifest, refreshRequest: worktreeRefresh) }
        }
        if let refreshRequest = worktreeRefresh {
            _ = try git.refreshWorktreeFastForwardOnly(path: refreshRequest.path, branch: refreshRequest.branch, hostName: refreshRequest.hostName)
        }
    }

    private func prepareRemoteWorktree(manifest: TerminalServiceWorkspaceRuntimeManifest, refreshRequest: TerminalServiceWorktreeRefreshRequest?)
        throws
    {
        guard let remotePath = manifest.remotePath?.trimmingCharacters(in: .whitespacesAndNewlines), !remotePath.isEmpty else {
            throw SpacesRuntimeError.invalidArgument(message: "Remote workspace path is missing.")
        }
        try validateWorkspacePath(remotePath, manifest: manifest)
        guard let branch = (refreshRequest?.branch ?? manifest.branch)?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else {
            return
        }
        let remotePathURL = URL(fileURLWithPath: remotePath, isDirectory: true)
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: remotePath, isDirectory: &isDirectory)
        if exists, git.isRepo(path: remotePath) { return }
        if exists, isDirectory.boolValue, try directoryIsEmpty(remotePathURL) {
            try cloneRemoteWorktree(manifest: manifest, branch: branch, remotePath: remotePath)
            return
        }
        if exists {
            throw RemoteWorkspaceRefreshBlock(
                hostName: refreshRequest?.hostName ?? "remote device", path: remotePath, branch: branch, reason: .checkoutFailed,
                detail: "Remote workspace path exists but is not an empty Git worktree.")
        }
        try FileManager.default.createDirectory(at: remotePathURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cloneRemoteWorktree(manifest: manifest, branch: branch, remotePath: remotePath)
    }

    private func cloneRemoteWorktree(manifest: TerminalServiceWorkspaceRuntimeManifest, branch: String, remotePath: String) throws {
        guard let remoteURL = manifest.gitRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteURL.isEmpty else {
            throw RemoteWorkspaceRefreshBlock(
                hostName: manifest.deviceID ?? "remote device", path: remotePath, branch: branch, reason: .fetchFailed,
                detail: "Remote workspace path is missing and no Git remote URL was provided.")
        }
        _ = try git.runGitAndCapture(["clone", "--branch", branch, "--single-branch", remoteURL, remotePath], timeout: 120)
    }

    private func validateWorkspacePath(_ path: String, manifest: TerminalServiceWorkspaceRuntimeManifest) throws {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let allowedRoots = manifest.allowedFileRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard allowedRoots.contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") }) else {
            throw SpacesRuntimeError.invalidArgument(message: "Path is outside the workspace runtime roots: \(path)")
        }
    }

    private func directoryIsEmpty(_ url: URL) throws -> Bool {
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return contents.isEmpty
    }

    private func workspaceCommandLogPath(_ requestedPath: String?) throws -> String {
        let root = try TerminalServicePaths.terminalRootDirectory().appendingPathComponent("workspace-commands", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let requestedPath = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedPath.isEmpty {
            let normalizedRoot = root.standardizedFileURL.path
            let normalizedPath = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
            guard normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/") else {
                throw SpacesRuntimeError.invalidArgument(message: "Workspace command log path must be under the daemon command log directory.")
            }
            return normalizedPath
        }
        return root.appendingPathComponent("\(UUID().uuidString).log", isDirectory: false).path
    }

    private func runShellCommand(
        _ workspaceCommand: TerminalServiceWorkspaceCommandRequest, logPath: String, manifest: TerminalServiceWorkspaceRuntimeManifest?
    ) throws -> TerminalServiceCommandResult {
        _ = FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", workspaceCommand.command]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceCommand.workingDirectory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        if let manifest { environment.merge(manifest.processEnvironment) { _, new in new } }
        environment.merge(workspaceCommand.environment) { _, new in new }
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()
        try? logHandle.synchronize()
        return TerminalServiceCommandResult(exitCode: Int(process.terminationStatus), logPath: logPath)
    }

    private func listSessions() -> TerminalServiceResponse {
        do {
            let configurations = try TerminalSessionPersistence.listKnownSessions()
            let sessions = try configurations.compactMap { configuration in try summaryIfLive(for: configuration) }
            return TerminalServiceResponse(ok: true, message: "Listed terminal sessions.", sessions: sessions)
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
    }

    private func loadTerminalState(sessionID: String) -> TerminalServiceResponse {
        guard !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument) }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            return TerminalServiceResponse(
                ok: true, message: "Loaded terminal state.", sessionState: try loadCurrentState(sessionID: sessionID),
                agentSignals: try TerminalSessionPersistence.pendingAgentSignals(sessionID: sessionID, paths: paths))
        } catch { return Self.failureResponse(error) }
    }

    private func recordAgentSignal(_ request: TerminalServiceAgentSignalRequest) -> TerminalServiceResponse {
        let event = request.event
        guard !event.sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument) }
        do {
            let paths = try TerminalSessionPaths.forSession(id: event.sessionID)
            try TerminalSessionPersistence.appendPendingAgentSignal(event, paths: paths)
            return TerminalServiceResponse(ok: true, message: "Queued agent signal.", agentSignals: [event])
        } catch { return Self.failureResponse(error) }
    }

    private func acknowledgeAgentSignals(_ request: TerminalServiceAgentSignalAcknowledgementRequest) -> TerminalServiceResponse {
        guard !request.sessionID.isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument)
        }
        do {
            try TerminalSessionPersistence.acknowledgeAgentSignals(
                ids: request.eventIDs, sessionID: request.sessionID, paths: try TerminalSessionPaths.forSession(id: request.sessionID),
                acknowledgedAt: nowISO8601())
            return TerminalServiceResponse(ok: true, message: "Acknowledged agent signals.")
        } catch { return Self.failureResponse(error) }
    }

    private func handleProfileCommand(_ command: TerminalServiceProfileCommand) -> TerminalServiceResponse {
        do {
            let profile = try runProfileCommand(command)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// Dispatches a decoded profile command. The typed union already enforced required fields (trim +
    /// reject empty) at the wire boundary, so this switch destructures payloads and only performs
    /// genuinely daemon-side validation (existence lookups, event-name recognition).
    private func runProfileCommand(_ command: TerminalServiceProfileCommand) throws -> TerminalServiceProfileCommandResponse {
        switch command {
        case .terminalList:
            let response = listSessions()
            guard response.ok else { throw SpacesRuntimeError.invalidArgument(message: response.message) }
            return TerminalServiceProfileCommandResponse(message: response.message, terminalSessions: response.sessions ?? [])
        case .terminalSend(let payload): return try sendProfileTerminalInput(payload)
        case .terminalTail(let payload): return try tailProfileTerminalOutput(payload)
        case .projectList:
            let orchestrator = try makeProfileOrchestrator()
            let projects = try orchestrator.listProjects().map(profileProjectSummary)
            return TerminalServiceProfileCommandResponse(message: "Listed projects.", projects: projects)
        case .workspaceList(let payload):
            let orchestrator = try makeProfileOrchestrator()
            let includeArchived = payload.includeArchived
            let workspaces: [WorkspaceRecord]
            if let projectID = normalizedProfileArgument(payload.projectID) {
                workspaces = try orchestrator.store.workspaces(projectID: projectID, includeArchived: includeArchived)
            } else {
                workspaces = try orchestrator.store.projects().flatMap {
                    try orchestrator.store.workspaces(projectID: $0.id, includeArchived: includeArchived)
                }
            }
            return TerminalServiceProfileCommandResponse(message: "Listed workspaces.", workspaces: workspaces.map(profileWorkspaceRecord))
        case .workspaceCreate(let payload):
            let orchestrator = try makeProfileOrchestrator()
            guard let project = try orchestrator.store.project(id: payload.projectID) else {
                throw SpacesRuntimeError.invalidArgument(message: "Project not found for id \(payload.projectID).")
            }
            let workspace = try orchestrator.createWorkspaceOnDevice(
                projectID: project.id, branch: payload.branch, baseBranch: payload.baseBranch, allowExistingBranchReuse: payload.existingBranch)
            return TerminalServiceProfileCommandResponse(message: "Created workspace.", workspace: profileWorkspaceRecord(workspace))
        case .workspaceStart(let workspaceID):
            let orchestrator = try makeProfileOrchestrator()
            try orchestrator.upWorkspace(workspaceID: workspaceID, restartIfRunning: false, background: true)
            let workspace = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
            return TerminalServiceProfileCommandResponse(message: "Workspace is running.", workspace: profileWorkspaceRecord(workspace))
        case .workspaceRestart(let workspaceID):
            let orchestrator = try makeProfileOrchestrator()
            try orchestrator.upWorkspace(workspaceID: workspaceID, restartIfRunning: true, background: true)
            let workspace = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
            return TerminalServiceProfileCommandResponse(message: "Workspace restarted.", workspace: profileWorkspaceRecord(workspace))
        case .agentSignal(let payload):
            let orchestrator = try makeProfileOrchestrator()
            return try recordProfileAgentSignal(payload, orchestrator: orchestrator)
        case .agentList(let payload):
            let orchestrator = try makeProfileOrchestrator()
            let rows = try orchestrator.agentSessionRows(
                workspaceID: normalizedProfileArgument(payload.workspaceID), sessionID: normalizedProfileArgument(payload.sessionID))
            return TerminalServiceProfileCommandResponse(message: "Listed agent sessions.", agentSessions: rows)
        case .agentAnnotate(let payload):
            let orchestrator = try makeProfileOrchestrator()
            return try annotateProfileAgentSession(payload, orchestrator: orchestrator)
        case .agentSpawn(let payload):
            let orchestrator = try makeProfileOrchestrator()
            return try spawnProfileAgentSession(payload, orchestrator: orchestrator)
        case .agentKill(let payload):
            let orchestrator = try makeProfileOrchestrator()
            return try killProfileAgentSession(payload.sessionID, orchestrator: orchestrator)
        case .agentSubscribe(let payload):
            let orchestrator = try makeProfileOrchestrator()
            return try subscribeProfileAgentSession(payload, orchestrator: orchestrator)
        case .agentUnsubscribe(let payload):
            let orchestrator = try makeProfileOrchestrator()
            if let deviceID = payload.deviceID {
                // A cross-device edge keys on the child's terminal session id, so it drops without a remote
                // call — unsubscribing works even when the device is offline.
                try orchestrator.store.deleteAgentRemoteSubscription(
                    subscriberTerminalSessionID: payload.subscriberTerminalSessionID, deviceID: deviceID, agentSessionID: payload.agentSessionID)
                remoteAgentWatchService?.reconcile()
                return TerminalServiceProfileCommandResponse(
                    message: "Unsubscribed from agent session \(payload.agentSessionID) on device \(deviceID).")
            }
            try orchestrator.store.deleteAgentSubscription(
                subscriberTerminalSessionID: payload.subscriberTerminalSessionID, agentSessionID: payload.agentSessionID)
            return TerminalServiceProfileCommandResponse(message: "Unsubscribed from agent session.")
        case .terminalCommand(let payload):
            let orchestrator = try makeProfileOrchestrator()
            let workspaceID = try orchestrator.resolveWorkspaceIDForTerminalCommand(explicitWorkspaceID: payload.workspaceID, cwd: payload.cwd)
            let session = try orchestrator.createWorkspaceTerminalSession(workspaceID: workspaceID, title: payload.title, command: payload.command)
            return TerminalServiceProfileCommandResponse(message: "Started terminal session.", terminalSession: session)
        }
    }

    private func sendProfileTerminalInput(_ payload: TerminalServiceTerminalSendPayload) throws -> TerminalServiceProfileCommandResponse {
        let text: String?
        let bytes: Data?
        switch payload.input {
        case .text(let value): (text, bytes) = (value, nil)
        case .bytes(let value): (text, bytes) = (nil, value)
        }
        let controlResponse = try sendProfileTerminalControl(
            sessionID: payload.sessionID,
            request: TerminalControlRequest(
                command: .send(
                    TerminalControlSendPayload(text: text, bytes: bytes, clientID: nil, ownerEpoch: nil, appendNewline: payload.appendNewline))))
        guard controlResponse.ok else { throw SpacesRuntimeError.invalidArgument(message: controlResponse.message) }
        return TerminalServiceProfileCommandResponse(message: controlResponse.message)
    }

    private func sendProfileTerminalControl(sessionID: String, request: TerminalControlRequest) throws -> TerminalControlResponse {
        if let liveCore = sessionCores[sessionID] { return liveCore.handleControlRequest(request) }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return TerminalControlResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.")
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return TerminalControlResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.")
        }
        return try TerminalControlClient.send(request: request, socketPath: paths.controlSocketPath)
    }

    private func tailProfileTerminalOutput(_ payload: TerminalServiceTerminalTailPayload) throws -> TerminalServiceProfileCommandResponse {
        let sessionID = payload.sessionID
        let lineCount = max(payload.lineCount ?? 20, 1)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.outputPath) else {
            throw SpacesRuntimeError.invalidArgument(message: "Terminal session '\(sessionID)' has no output yet.")
        }
        let output = try TerminalOutputTail.tail(path: paths.outputPath, lineCount: lineCount)
        return TerminalServiceProfileCommandResponse(message: "Read terminal output.", terminalOutput: output)
    }

    /// Pins this profile's Caddy router port on first daemon start. Called only on macOS, since
    /// Caddy is a Mac-client-only service (`CaddyRouterService` is `#if os(macOS)`); a headless
    /// remote daemon has no router to pin and must not seed a per-profile derived port, which would
    /// be a fabricated value no browser ever dials. Remote daemons leave the port unset, so their
    /// browser-facing service URLs fall back to the canonical `AppConfig.defaultRouterPort` as a
    /// client-facing host/origin identity that the Mac client rewrites to its own live Caddy port.
    ///
    /// The installed/production profile keeps the well-known 7391; dev/worktree profiles derive a
    /// distinct deterministic port so concurrent Spaces instances (multiple worktrees, or the
    /// installed app plus a dev build) don't all try to bind one port — where only the first wins
    /// and every other instance's Caddy silently fails to start, breaking its workspace-service
    /// routing. Seeds only when unset, so an explicit override still wins, and service URLs then
    /// read the pinned port.
    #if os(macOS)
        private func seedProfileRouterPortIfNeeded(databasePath: String) {
            do {
                let store = try SQLiteStore(path: databasePath)
                guard try store.storedRouterPort() == nil else { return }
                var config = try store.appConfig()
                config.routerPort = try SpacesProfile.current().defaultRouterPort
                try store.setAppConfig(config)
            } catch { writeStandardError("spacesd router_port_seed_error error=\(error)\n") }
        }
    #endif

    private func makeProfileOrchestrator() throws -> WorkspaceOrchestrator {
        let store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalSessionTerminator: { [weak self] sessionID in
                Self.runOnMainActorSynchronously { self?.terminateBuiltInTerminalSession(id: sessionID) }
            },
            builtInTerminalSessionLauncher: { [weak self] launchConfiguration in
                try Self.runOnMainActorSynchronously {
                    Result {
                        guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                        return try self.launchBuiltInTerminalSession(launchConfiguration)
                    }
                }.get()
            })
        _ = try orchestrator.syncConfig()
        return orchestrator
    }

    private func terminateBuiltInTerminalSession(id sessionID: String) {
        guard !handoffInProgress else { return }
        _ = terminateSession(id: sessionID)
    }

    private func launchBuiltInTerminalSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
        let response = createSession(TerminalServiceCreateRequest(launchConfiguration: launchConfiguration))
        guard response.ok else { throw Self.requestFailedError(response.message) }
        guard let session = response.session else { throw Self.requestFailedError("spacesd did not return a session summary.") }
        return session
    }

    private static func requestFailedError(_ message: String) -> NSError {
        NSError(domain: "spacesd", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func profileProjectSummary(_ value: ProjectSummary) -> TerminalServiceProfileProjectSummary {
        TerminalServiceProfileProjectSummary(
            id: value.id, name: value.name, dir: value.dir, isGitRepo: value.isGitRepo, defaultBranch: value.defaultBranch)
    }

    private func profileWorkspaceRecord(_ value: WorkspaceRecord) -> TerminalServiceProfileWorkspaceRecord {
        TerminalServiceProfileWorkspaceRecord(
            id: value.id, projectID: value.projectID, dir: value.dir, dirname: value.dirname, branch: value.branch, baseBranch: value.baseBranch,
            isDefault: value.isDefault, isArchived: value.isArchived, isHidden: value.isHidden, isRunning: value.isRunning,
            lastLaunchedAt: value.lastLaunchedAt, notes: value.notes)
    }

    private func requiredProfileWorkspace(id: String, orchestrator: WorkspaceOrchestrator) throws -> WorkspaceRecord {
        guard let workspace = try orchestrator.store.workspace(id: id) else {
            throw SpacesRuntimeError.invalidArgument(message: "Workspace not found for id \(id).")
        }
        return workspace
    }

    /// Normalizes an optional daemon-side string argument. Required profile-command fields are already
    /// enforced at wire decode; this stays for the genuinely optional cases the daemon reads (the
    /// `workspaceList` project filter and agent-window labels).
    private func normalizedProfileArgument(_ value: String?) -> String? { normalizedNonEmpty(value) }

    private enum ProfileAgentEventType: String {
        case `init` = "init"
        case working = "working"
        case blocked = "blocked"
        case done = "done"
        case exit = "exit"

        var status: AgentWindowStatus {
            switch self {
            case .`init`: .idle
            case .working: .spinning
            case .blocked: .waiting
            case .done: .done
            case .exit: .idle
            }
        }

        var establishesAgentFromEvidence: Bool {
            switch self {
            case .working, .blocked, .done: true
            case .`init`, .exit: false
            }
        }

        /// The subscriber notification this transition produces, or `nil` when it produces none. Only
        /// blocked/done/exit wake a watcher; init and working are silent.
        var childNotificationTransition: AgentNotificationEngine.ChildTransition? {
            switch self {
            case .blocked: .blocked
            case .done: .done
            case .exit: .exited
            case .`init`, .working: nil
            }
        }

        /// Whether this transition leaves the signaling terminal's own agent row idle/done, which is the
        /// cue to flush any notifications that queued while it was busy. Mirrors `status ∈ {idle, done}`.
        var leavesSubscriberIdle: Bool {
            switch self {
            case .`init`, .done, .exit: true
            case .working, .blocked: false
            }
        }
    }

    private func recordProfileAgentSignal(_ payload: TerminalServiceProfileAgentSignalPayload, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        let workspaceID = payload.workspaceID
        let sessionID = payload.terminalSessionID
        let eventValue = payload.event
        guard let type = ProfileAgentEventType(rawValue: eventValue) else {
            throw SpacesRuntimeError.invalidArgument(message: "Unsupported agent event '\(eventValue)'.")
        }
        _ = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
        let existingAgent = try matchingProfileAgentWindow(workspaceID: workspaceID, sessionID: sessionID, orchestrator: orchestrator)
        let signalLabel = profileAgentRuntimeLabel(sessionID: sessionID) ?? normalizedProfileArgument(existingAgent?.label)
        let canRecordSignal = existingAgent != nil || type == .`init` || (type.establishesAgentFromEvidence && signalLabel != nil)
        if !canRecordSignal { return TerminalServiceProfileCommandResponse(message: "Agent \(type.rawValue) ignored.") }

        let environmentKeys = [WorkspaceOrchestrator.terminalTrackingIDEnvVar]
        let engine = makeAgentNotificationEngine(orchestrator: orchestrator)
        switch type {
        case .`init`:
            try orchestrator.registerAgentWindow(
                workspaceID: workspaceID, provider: .spaces, label: signalLabel, terminalTrackingID: sessionID,
                status: existingAgent?.status ?? .idle, eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys
            )
        case .working:
            try orchestrator.updateAgentWindowStatus(
                workspaceID: workspaceID, provider: .spaces, terminalTrackingID: sessionID, label: signalLabel, status: type.status,
                eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys)
        case .blocked, .done:
            let updated = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspaceID, provider: .spaces, terminalTrackingID: sessionID, label: signalLabel, status: type.status,
                eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys)
            if let transition = type.childNotificationTransition { try engine.childDidTransition(agent: updated, transition: transition) }
        case .exit:
            guard let existingAgent else { return TerminalServiceProfileCommandResponse(message: "Agent exit ignored.") }
            // Render and enqueue/deliver the exit notification before handleAgentExit deletes an ad-hoc
            // agent row: that deletion cascades the subscription edges away, and the pending row (no FK)
            // is what carries the notice past it.
            try engine.childDidTransition(agent: existingAgent, transition: .exited)
            try orchestrator.handleAgentExit(
                existingAgent, eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys)
        }
        // A signal that leaves this terminal's own agent row idle/done is the cue to flush notifications
        // that queued while it was busy (including, on exit, cleaning up its now-undeliverable queue).
        if type.leavesSubscriberIdle { try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: sessionID) }
        postAgentEventNotification()
        return TerminalServiceProfileCommandResponse(message: "Agent \(type.rawValue) recorded.")
    }

    private func matchingProfileAgentWindow(workspaceID: String, sessionID: String, orchestrator: WorkspaceOrchestrator) throws -> AgentWindowRecord?
    { try orchestrator.agentWindows(workspaceID: workspaceID).first { $0.provider == .spaces && $0.terminalTrackingID == sessionID } }

    /// Builds the notification engine bound to the real terminal-send path: delivery is the same
    /// `sendProfileTerminalInput` plumbing a `terminal send` uses, appending a newline so the injected
    /// line is submitted. A send failure throws, which the engine reads as the subscriber having
    /// vanished (dead session) and tears the watch edge down.
    private func makeAgentNotificationEngine(orchestrator: WorkspaceOrchestrator) -> AgentNotificationEngine {
        AgentNotificationEngine(
            store: orchestrator.store,
            deliver: { [weak self] sessionID, line in
                guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                _ = try self.sendProfileTerminalInput(
                    TerminalServiceTerminalSendPayload(sessionID: sessionID, input: .text(line), appendNewline: true))
            }, logError: { writeStandardError($0) })
    }

    private func profileAgentRuntimeLabel(sessionID: String) -> String? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return nil }
        if let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths), launchConfiguration.kind == .agent {
            return normalizedProfileArgument(launchConfiguration.title)
        }
        guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), let kind = runtimeState.foregroundDetectedAgentKind
        else { return nil }
        return normalizedProfileArgument(runtimeState.foregroundDisplayLabel) ?? kind.displayLabel
    }

    private func annotateProfileAgentSession(_ payload: TerminalServiceAgentAnnotatePayload, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        let updated = try orchestrator.annotateAgentSession(terminalSessionID: payload.sessionID, note: payload.note)
        return TerminalServiceProfileCommandResponse(
            message: updated.note == nil ? "Cleared agent note." : "Annotated agent session.", agentSessions: [updated])
    }

    /// Spawns a coding-agent terminal session after gating the command against the supported-agent hook
    /// set: the command must launch a supported coding agent whose hooks are installed and current,
    /// otherwise the spawned session would never report the lifecycle signal `spaces agent spawn` blocks
    /// on. The session summary is returned so the CLI can poll readiness against its terminal id.
    private func spawnProfileAgentSession(_ payload: TerminalServiceAgentSpawnPayload, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        do { _ = try AgentSpawnCommandGate.resolveSpawnableAgent(command: payload.command, statuses: AgentHookInstaller.status()) } catch let error
            as AgentSpawnCommandGate.GateError
        { throw SpacesRuntimeError.invalidArgument(message: error.errorDescription ?? "Agent spawn command is not supported.") }
        let workspaceID = try orchestrator.resolveWorkspaceIDForTerminalCommand(explicitWorkspaceID: payload.workspaceID, cwd: payload.cwd)
        let session = try orchestrator.createWorkspaceAgentSession(workspaceID: workspaceID, command: payload.command, title: payload.title)
        return TerminalServiceProfileCommandResponse(message: "Started agent session.", terminalSession: session)
    }

    /// Terminates a coding-agent session addressed by its terminal session id. When a Spaces agent row
    /// is bound to the session, the coding-agent stop path terminates the terminal and deletes the row;
    /// before the first hook signal no agent row exists yet, so the terminal session itself is
    /// terminated. A session that is neither an agent row nor a live terminal is a loud error.
    private func killProfileAgentSession(_ sessionID: String, orchestrator: WorkspaceOrchestrator) throws -> TerminalServiceProfileCommandResponse {
        if let match = try orchestrator.resolveSpacesAgentSession(terminalSessionID: sessionID) {
            try orchestrator.stopCodingAgent(workspaceID: match.workspaceID, agentID: match.record.id)
            return TerminalServiceProfileCommandResponse(message: "Killed agent session \(sessionID).")
        }
        guard sessionCores[sessionID] != nil || profileTerminalSessionExists(sessionID) else {
            throw SpacesRuntimeError.invalidArgument(message: "No agent session for terminal \(sessionID).")
        }
        _ = terminateSession(id: sessionID)
        return TerminalServiceProfileCommandResponse(message: "Killed agent session \(sessionID).")
    }

    private func profileTerminalSessionExists(_ sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        return (try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)) != nil
    }

    /// Persists a subscription edge. Same-device: validate (in the orchestrator) that the watched agent
    /// exists and the edge keeps the subscription graph acyclic — a self-edge or any cycle-closing edge is
    /// a loud error, since a cycle would let injected notifications chase each other around a loop.
    /// Cross-device (`deviceID` set): validate the device is paired and the child has an agent session on
    /// it (one `listAgentSessions` call), then record a cross-device edge keyed on the child's terminal
    /// session id and nudge the watch service to open/refresh that device's stream. Cross-device cycle
    /// detection is impossible locally — the remote's own subscription graph is not queryable — so only
    /// the same-device acyclic invariant is enforced.
    private func subscribeProfileAgentSession(_ payload: TerminalServiceAgentSubscriptionPayload, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        if let deviceID = payload.deviceID {
            let clientApp = Self.daemonDeviceClientApp()
            try RemoteAgentSubscriptionValidation.validate(
                deviceID: deviceID, childTerminalSessionID: payload.agentSessionID,
                resolveDevice: { try SpacesClientDatabase.defaultDatabase().pairedDevice(id: $0) }, deviceName: { $0.name },
                fetchRows: { try SpacesDeviceClient.listAgentSessions(sessionID: payload.agentSessionID, device: $0, clientApp: clientApp) })
            try orchestrator.store.insertAgentRemoteSubscription(
                subscriberTerminalSessionID: payload.subscriberTerminalSessionID, deviceID: deviceID, agentSessionID: payload.agentSessionID,
                createdAt: nowISO8601())
            remoteAgentWatchService?.reconcile()
            return TerminalServiceProfileCommandResponse(message: "Subscribed to agent session \(payload.agentSessionID) on device \(deviceID).")
        }
        try orchestrator.validateAgentSubscription(
            subscriberTerminalSessionID: payload.subscriberTerminalSessionID, agentSessionID: payload.agentSessionID)
        try orchestrator.store.insertAgentSubscription(
            subscriberTerminalSessionID: payload.subscriberTerminalSessionID, agentSessionID: payload.agentSessionID, createdAt: nowISO8601())
        return TerminalServiceProfileCommandResponse(message: "Subscribed to agent session.")
    }

    /// The daemon's own Device API client identity when it acts as a device client (subscribe validation
    /// and the watch service). Reads paired-device credentials the same way the CLI and Mac app do.
    private static func daemonDeviceClientApp() -> SpacesDeviceClientApp { SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short) }

    private func postAgentEventNotification() {
        #if os(macOS)
            try? IPCNotification.post(IPCNotification.agentEventFired)
        #endif
    }

    private func handleTerminalControl(_ request: TerminalServiceControlCommandRequest) -> TerminalServiceResponse {
        let sessionID = request.sessionID
        let controlRequest = request.controlRequest
        let command = controlRequest.commandValue
        guard !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument) }
        if command.requiresOwnerClientID, controlRequest.clientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return TerminalServiceResponse(ok: false, message: "Missing device client ID.", errorCode: .invalidArgument)
        }
        if let liveCore = sessionCores[sessionID] {
            let response = liveCore.handleControlRequest(controlRequest)
            return terminalControlResponse(
                sessionID: sessionID, controlResponse: response, includeSessionState: command.includesSessionStateOnSuccess)
        }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                return TerminalServiceResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.", errorCode: .sessionNotRunning)
            }
            guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
                return TerminalServiceResponse(
                    ok: false, message: "Terminal session '\(sessionID)' is not available.", errorCode: .sessionNotAvailable)
            }
            let response = try TerminalControlClient.send(request: controlRequest, socketPath: paths.controlSocketPath)
            return terminalControlResponse(
                sessionID: sessionID, controlResponse: response, includeSessionState: command.includesSessionStateOnSuccess)
        } catch { return Self.failureResponse(error) }
    }

    private func terminalControlResponse(sessionID: String, controlResponse response: TerminalControlResponse, includeSessionState: Bool)
        -> TerminalServiceResponse
    {
        let sessionState = response.ok && includeSessionState ? try? loadCurrentState(sessionID: sessionID) : nil
        return TerminalServiceResponse(
            ok: response.ok, message: response.message, errorCode: response.errorCode, sessionState: sessionState, controlResponse: response)
    }

    private func resolveTerminalLink(_ request: TerminalServiceTerminalLinkResolveRequest) -> TerminalServiceResponse {
        let link = request.terminalLink
        guard !request.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument)
        }
        let sessionID = request.sessionID
        do {
            pruneTerminalLinkTransferAuthorizations(now: Date())
            let metadata: SpacesDeviceTerminalLinkMetadata
            if canResolveTerminalLinkWithoutLocalState(link) {
                metadata = try SpacesDeviceTerminalLinkResolver.resolve(sessionID: sessionID, link: link, workingDirectory: nil, workspaceRoots: [])
            } else {
                // Unlike SpacesDeviceAPIServer's workspaceRoots (loaded from every project/workspace in the
                // DB), this daemon only ever authorizes a single extra root: the session's own working
                // directory. So the lookup is still attempted for absolute/tilde/file:// links too (best
                // effort, via `try?`) to keep authorizing paths under that root exactly as before; only a
                // relative link's *requirement* for a working directory still hard-fails resolution (with
                // the informative unknownSession error) when session launch/runtime state is unavailable.
                let workingDirectory: String?
                do { workingDirectory = try terminalWorkingDirectory(sessionID: sessionID) } catch {
                    guard !SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: link) else { throw error }
                    workingDirectory = nil
                }
                metadata = try SpacesDeviceTerminalLinkResolver.resolve(
                    sessionID: sessionID, link: link, workingDirectory: workingDirectory, workspaceRoots: workingDirectory.map { [$0] } ?? [])
            }
            if metadata.source == .localFile {
                let resolvedPath = try SpacesDeviceTerminalLinkResolver.resolvedLocalFilePath(linkID: metadata.id)
                authorizeTerminalLinkTransfer(linkID: metadata.id, sessionID: sessionID, resolvedPath: resolvedPath, now: Date())
            }
            return TerminalServiceResponse(ok: true, message: "Resolved terminal link.", terminalLinkMetadata: terminalServiceLinkMetadata(metadata))
        } catch { return Self.failureResponse(error) }
    }

    private func readTerminalLinkChunk(_ request: TerminalServiceTerminalLinkChunkRequest) -> TerminalServiceResponse {
        guard !request.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument)
        }
        let sessionID = request.sessionID
        do {
            guard let linkID = request.terminalLinkID?.trimmingCharacters(in: .whitespacesAndNewlines), !linkID.isEmpty else {
                throw SpacesDeviceTerminalLinkResolverError.invalidLinkID
            }
            guard let authorization = try terminalLinkTransferAuthorization(linkID: linkID, sessionID: sessionID, now: Date()) else {
                throw SpacesDeviceTerminalLinkResolverError.invalidLinkID
            }
            let chunk = try SpacesDeviceTerminalLinkResolver.readChunk(
                sessionID: sessionID, linkID: linkID, offset: request.offset, limit: request.limit, workspaceRoots: [authorization.resolvedPath])
            authorizeTerminalLinkTransfer(linkID: linkID, sessionID: sessionID, resolvedPath: authorization.resolvedPath, now: Date())
            return TerminalServiceResponse(ok: true, message: "Read terminal link chunk.", terminalLinkChunk: terminalServiceLinkChunk(chunk))
        } catch { return Self.failureResponse(error) }
    }

    private func terminateSession(id sessionID: String) -> TerminalServiceResponse {
        do {
            if let sessionCore = sessionCores.removeValue(forKey: sessionID) {
                sessionCore.terminate()
                return TerminalServiceResponse(
                    ok: true, message: "Stopped terminal session \(sessionID).", session: try? sessionSummary(for: sessionID))
            }

            if let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(
                paths: try TerminalSessionPaths.forSession(id: sessionID))
            {
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let now = ISO8601DateFormatter().string(from: Date())
                let runtimeState =
                    (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
                    ?? TerminalSessionRuntimeState(
                        sessionID: sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: now, exitedAt: now, title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory)
                if runtimeState.servicePID != getpid(), Self.isLive(runtimeState), Self.isProcessAlive(pid: Int(runtimeState.servicePID)) {
                    return TerminalServiceResponse(
                        ok: false, message: "Terminal session \(sessionID) is owned by another process and was not stopped by spacesd.")
                }
                let exitedState = TerminalSessionRuntimeState(
                    sessionID: runtimeState.sessionID, backend: runtimeState.backend, servicePID: runtimeState.servicePID,
                    childPID: runtimeState.childPID, state: .exited, updatedAt: now, exitedAt: now,
                    title: runtimeState.title ?? launchConfiguration.title,
                    workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                    rows: runtimeState.rows)
                try? TerminalSessionPersistence.writeRuntimeState(exitedState, paths: paths)
                try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
                try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
            }
            return TerminalServiceResponse(ok: true, message: "Terminal session \(sessionID) is not active.")
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
    }

    private func sessionCore(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> GhosttyEmbeddedSessionCore {
        if let existing = sessionCores[launchConfiguration.sessionID] { return existing }
        let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
        let created = GhosttyEmbeddedSessionCore(
            launchConfiguration: launchConfiguration, paths: paths,
            onSessionClosed: { [weak self] closedCore in
                let sessionID = closedCore.launchConfiguration.sessionID
                guard self?.sessionCores[sessionID] === closedCore else { return }
                self?.sessionCores.removeValue(forKey: sessionID)
            })
        sessionCores[launchConfiguration.sessionID] = created
        return created
    }

    private func sessionSummary(for sessionID: String) throws -> TerminalServiceSessionSummary {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let launchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        return try summary(for: launchConfiguration, paths: paths)
    }

    private func sessionSummaryAfterStart(for sessionID: String) throws -> TerminalServiceSessionSummary {
        let deadline = Date().addingTimeInterval(1)
        var lastError: (any Error)?
        repeat {
            do { return try sessionSummary(for: sessionID) } catch {
                lastError = error
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        } while Date() < deadline
        throw lastError ?? CocoaError(.fileReadUnknown)
    }

    private func summaryIfLive(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary? {
        let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
        guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return nil }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else { return nil }
        guard runtimeState.state == .starting || runtimeState.state == .running else { return nil }
        guard Self.isProcessAlive(pid: Int(runtimeState.servicePID)) else { return nil }
        return try summary(for: launchConfiguration, paths: paths)
    }

    private func summary(for launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) throws
        -> TerminalServiceSessionSummary
    {
        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        return TerminalServiceSessionSummary(
            id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
            workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
            lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
            childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath,
            launchConfiguration: launchConfiguration, runtimeState: runtimeState,
            attachmentSnapshot: (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot(),
            hasFinalRender: (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.renderSnapshot != nil)
    }

    private func loadCurrentState(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let liveCore = sessionCores[sessionID],
            let payload = liveCore.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.stateChange)
        {
            return payload
        }
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            if let finalState = try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) { return finalState }
            return try endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState)
        }
        guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
            throw NSError(
                domain: "SpacesDaemonController", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' has no live state stream."])
        }

        let socketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
        defer {
            Self.shutdownSocket(socketFD)
            close(socketFD)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socketFD, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
            if let newlineIndex = data.firstIndex(of: 0x0A) {
                data.removeSubrange(newlineIndex..<data.endIndex)
                break
            }
        }

        guard !data.isEmpty else {
            throw NSError(
                domain: "SpacesDaemonController", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' did not return a state payload."])
        }
        return try GhosttyRemoteSessionStateCodec.decodeLine(data)
    }

    private func subscribeTerminalState(sessionID: String) -> TerminalServiceResponse {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument)
        }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                return TerminalServiceResponse(ok: false, message: "Terminal session '\(sessionID)' is not live.", errorCode: .sessionNotRunning)
            }
            guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
                return TerminalServiceResponse(
                    ok: false, message: "Terminal session '\(sessionID)' has no live state stream.", errorCode: .sessionNotAvailable)
            }
            return TerminalServiceResponse(ok: true, message: "Subscribed to terminal state.", streamSocketPath: paths.subscriptionSocketPath)
        } catch { return Self.failureResponse(error) }
    }

    private func endedStatePayload(sessionID: String, paths: TerminalSessionPaths, runtimeState: TerminalSessionRuntimeState) throws
        -> GhosttyRemoteSessionStatePayload
    {
        let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot()
        let emittedAt = runtimeState.exitedAt ?? runtimeState.updatedAt
        return GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
            title: runtimeState.title ?? launchConfiguration?.title ?? sessionID,
            workingDirectory: runtimeState.workingDirectory ?? launchConfiguration?.workingDirectory ?? paths.rootDirectory, outputByteCount: nil)
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try setNoSIGPIPE(socketFD)
        var address = try makeUnixSocketAddress(path: path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        return socketFD
    }

    private func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
        }
        return address
    }

    private func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        #if canImport(Darwin)
            var yes: Int32 = 1
            guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        #else
            _ = fileDescriptor
        #endif
    }

    private var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }

    private func authorizeTerminalLinkTransfer(linkID: String, sessionID: String, resolvedPath: String, now: Date) {
        terminalLinkTransferAuthorizations[linkID] = TerminalLinkTransferAuthorization(
            sessionID: sessionID, resolvedPath: resolvedPath, expiresAt: now.addingTimeInterval(Self.terminalLinkTransferAuthorizationTTL))
    }

    private func terminalLinkTransferAuthorization(linkID: String, sessionID: String, now: Date) throws -> TerminalLinkTransferAuthorization? {
        pruneTerminalLinkTransferAuthorizations(now: now)
        guard let authorization = terminalLinkTransferAuthorizations[linkID] else { return nil }
        guard authorization.sessionID == sessionID else { throw SpacesDeviceTerminalLinkResolverError.sessionMismatch }
        return authorization
    }

    private func pruneTerminalLinkTransferAuthorizations(now: Date) {
        terminalLinkTransferAuthorizations = terminalLinkTransferAuthorizations.filter { $0.value.expiresAt > now }
    }

    private func canResolveTerminalLinkWithoutLocalState(_ value: String?) -> Bool {
        guard let link = normalizedString(value), let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return scheme != "file"
    }

    private func terminalWorkingDirectory(sessionID: String) throws -> String {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        // Prefer the live cwd of the session's foreground process (falling back to its child shell).
        // The tracked runtime-state working directory only advances when the shell reports a new PWD
        // through Ghostty shell integration (OSC 7), which many shells never emit — so it is stale
        // after a plain `cd`. The owning process's real cwd is always current, anchoring relative
        // links (e.g. `./statement.pdf`) in the directory the shell is actually sitting in.
        if let liveWorkingDirectory = normalizedString(Self.liveTerminalWorkingDirectory(runtimeState: runtimeState)) { return liveWorkingDirectory }
        if let workingDirectory = normalizedString(runtimeState?.workingDirectory) { return workingDirectory }
        return try TerminalSessionPersistence.readLaunchConfiguration(paths: paths).workingDirectory
    }

    private static func liveTerminalWorkingDirectory(runtimeState: TerminalSessionRuntimeState?) -> String? {
        guard let runtimeState else { return nil }
        if let foregroundPID = runtimeState.foregroundPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: foregroundPID) {
            return cwd
        }
        if let childPID = runtimeState.childPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: childPID) { return cwd }
        return nil
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func terminalServiceLinkMetadata(_ metadata: SpacesDeviceTerminalLinkMetadata) -> TerminalServiceTerminalLinkMetadata {
        TerminalServiceTerminalLinkMetadata(
            id: metadata.id, source: metadata.source.rawValue, originalLink: metadata.originalLink, displayName: metadata.displayName,
            contentType: metadata.contentType, artifactKind: metadata.artifactKind?.rawValue, byteCount: metadata.byteCount,
            externalURL: metadata.externalURL)
    }

    private func terminalServiceLinkChunk(_ chunk: SpacesDeviceTerminalLinkChunk) -> TerminalServiceTerminalLinkChunk {
        TerminalServiceTerminalLinkChunk(
            linkID: chunk.linkID, offset: chunk.offset, byteCount: chunk.byteCount, isFinal: chunk.isFinal, base64Data: chunk.base64Data)
    }

    private func startLifecycleTimer() {
        lifecycleTimer?.invalidate()
        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reapInactiveSessions() }
        }
        if let lifecycleTimer { RunLoop.main.add(lifecycleTimer, forMode: .common) }
    }

    private func reapInactiveSessions() {
        for (sessionID, sessionCore) in sessionCores {
            guard sessionCore.launchConfiguration.lifetimePolicy == .whileAttached else { continue }
            guard let liveAttachments = try? TerminalSessionPersistence.liveAttachments(paths: sessionCore.paths), liveAttachments.isEmpty else {
                continue
            }
            _ = terminateSession(id: sessionID)
        }
    }

    private func recoverStaleSessions() throws {
        for launchConfiguration in try TerminalSessionPersistence.listKnownSessions() {
            let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
            guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { continue }
            guard runtimeState.state == .starting || runtimeState.state == .running else { continue }
            guard !Self.isProcessAlive(pid: Int(runtimeState.servicePID)) else { continue }

            let now = ISO8601DateFormatter().string(from: Date())
            let failedState = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: runtimeState.childPID,
                state: .failed, updatedAt: now, exitedAt: now, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                rows: runtimeState.rows)
            try? TerminalSessionPersistence.writeRuntimeState(failedState, paths: paths)
            try? TerminalSessionPersistence.detachActiveClients(paths: paths, detachedAt: now)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
        }
    }

    private static func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private static func isLive(_ runtimeState: TerminalSessionRuntimeState) -> Bool {
        runtimeState.state == .starting || runtimeState.state == .running
    }

    private static func errorMessage(_ error: any Error) -> String {
        if let localizedError = error as? any LocalizedError, let description = localizedError.errorDescription { return description }
        return String(describing: error)
    }

    /// Machine-readable failure category for a thrown error at the terminal-service flatten points,
    /// mirroring the `WorkspaceError` mapping used by the Device API server so both wire surfaces
    /// classify the same failures identically.
    private static func errorCode(_ error: any Error) -> SpacesDeviceErrorCode {
        if let workspaceError = error as? WorkspaceError {
            switch workspaceError {
            case .missingProject, .missingWorkspace, .missingTrackedWindow: return .notFound
            case .invalidArgument, .invalidWorkspace, .projectAlreadyExists, .workspaceAlreadyExists: return .invalidArgument
            case .gitCommandFailed, .dependencyMissing, .configError, .databaseMigrationFailed: return .internalError
            }
        }
        if case SpacesRuntimeError.invalidArgument = error { return .invalidArgument }
        if error is DecodingError { return .invalidArgument }
        return .internalError
    }

    /// Flattens a thrown error into a failure response, pairing the localized message with its
    /// machine-readable category. Used at handler catch sites so clients can branch on the code.
    private static func failureResponse(_ error: any Error) -> TerminalServiceResponse {
        TerminalServiceResponse(ok: false, message: errorMessage(error), errorCode: errorCode(error))
    }

    private static func shutdownSocket(_ fileDescriptor: Int32) {
        #if canImport(Darwin)
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        #elseif canImport(Glibc)
            Glibc.shutdown(fileDescriptor, Int32(SHUT_RDWR))
        #endif
    }

    private func nowISO8601() -> String { GhosttyRemoteSessionStateTimestamp.string(from: Date()) }

    private nonisolated static func runOnMainActorSynchronously<T: Sendable>(_ work: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        let box = MainActorSyncBox<T>()
        DispatchQueue.main.sync { box.value = MainActor.assumeIsolated { work() } }
        guard let value = box.value else { preconditionFailure("spacesd main-actor work did not return a value.") }
        return value
    }
}

private final class MainActorSyncBox<T>: @unchecked Sendable { var value: T? }

@MainActor private final class SpacesDaemonDeviceAPISupervisor {
    #if canImport(spacesdeviceapi)
        private let supervisor: SpacesDeviceAPISupervisor
    #endif

    init(
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil, onRestartRequested: (@Sendable () -> Void)? = nil
    ) {
        #if canImport(spacesdeviceapi)
            supervisor = SpacesDeviceAPISupervisor(
                builtInTerminalSessionTerminator: builtInTerminalSessionTerminator, builtInTerminalSessionLauncher: builtInTerminalSessionLauncher,
                onRestartRequested: onRestartRequested)
        #endif
    }

    func start() {
        #if canImport(spacesdeviceapi)
            supervisor.start()
        #endif
    }

    func stop() {
        #if canImport(spacesdeviceapi)
            supervisor.stop()
        #endif
    }
}

#if canImport(AppKit)
    @MainActor private final class SpacesDaemonAppDelegate: NSObject, NSApplicationDelegate {
        private let controller: SpacesDaemonController

        init(controller: SpacesDaemonController) { self.controller = controller }

        func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
    }
#endif

@main struct SpacesDaemonMain {
    static func main() {
        // Capture the exec target from raw argv[0] before anything can chdir; this is the path we
        // re-exec on an exec-in-place handoff.
        let launchExecutablePath = absoluteLaunchExecutablePath()

        // The old daemon runs the staged binary once as `spacesd --handoff-check <formatVersion>` to
        // confirm it can read the table about to be written. Answer that here before any startup work.
        if let code = DaemonHandoffPreflight.respondsToCheck(arguments: CommandLine.arguments) { exit(code) }

        configureProcessSignals()
        configureCLISearchPath()

        if environmentValue("SPACESD_PRINT_CERTIFICATE_FINGERPRINT") == "1" {
            do {
                print(try TerminalServiceTLSIdentityStore.loadOrCreate().certificateFingerprint)
                return
            } catch {
                writeStandardError("spacesd: \(error)\n")
                exit(1)
            }
        }

        #if canImport(AppKit)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)

            do {
                let controller = try MainActor.assumeIsolated { try SpacesDaemonController(launchExecutablePath: launchExecutablePath) }
                let delegate = SpacesDaemonAppDelegate(controller: controller)
                app.delegate = delegate
                // Kick startup as a main-actor Task and then run the app run loop: `start()` awaits the
                // exec-in-place resume, which needs the run loop pumping ticks, and the request-accepting
                // server starts only after the resume completes.
                Task { @MainActor in
                    do { try await controller.start() } catch {
                        writeStandardError("spacesd: \(error)\n")
                        exit(1)
                    }
                }
                app.run()
            } catch {
                writeStandardError("spacesd: \(error)\n")
                exit(1)
            }
        #else
            do {
                let controller = try MainActor.assumeIsolated { try SpacesDaemonController(launchExecutablePath: launchExecutablePath) }
                let signalSources = installTerminationSignalHandlers(controller: controller)
                Task { @MainActor in
                    do { try await controller.start() } catch {
                        writeStandardError("spacesd: \(error)\n")
                        exit(1)
                    }
                }
                withExtendedLifetime(signalSources) { RunLoop.main.run() }
                MainActor.assumeIsolated { controller.shutdown() }
            } catch {
                writeStandardError("spacesd: \(error)\n")
                exit(1)
            }
        #endif
    }

    /// Absolutizes the raw invoked `argv[0]` against the current directory when relative, WITHOUT
    /// resolving symlinks — the exec target must stay the stable public `~/.spaces/bin/spacesd`
    /// symlink, not the versioned real binary `SpacesProfile.currentExecutablePath` would resolve to.
    /// Must be called at `main()` start, before anything can change the working directory.
    private static func absoluteLaunchExecutablePath() -> String {
        let argv0 = CommandLine.arguments.first ?? ""
        if argv0.hasPrefix("/") { return argv0 }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argv0).standardizedFileURL.path
    }

    private static func configureProcessSignals() {
        #if canImport(Glibc)
            _ = signal(SIGPIPE, SIG_IGN)
            _ = signal(SIGHUP, SIG_IGN)
        #endif
    }

    /// spacesd is the parent of every terminal shell, workspace runtime process, and
    /// coding-agent hook it spawns, and those children resolve `spaces` from this
    /// process's PATH. Prepend the daemon executable's own directory (which ships the
    /// version-matched CLI) so children inherit a PATH that resolves `spaces` without
    /// root-owned symlinks or daemon-specific shell-profile edits. This must run before
    /// anything snapshots the environment.
    private static func configureCLISearchPath() {
        guard
            let path = SpacesCLISearchPath.pathPrependingSiblingCLIDirectory(
                executablePath: SpacesProfile.currentExecutablePath(currentDirectoryPath: FileManager.default.currentDirectoryPath),
                currentPATH: environmentValue("PATH"))
        else { return }
        setenv("PATH", path, 1)
    }

    #if canImport(Glibc)
        private static func installTerminationSignalHandlers(controller: SpacesDaemonController) -> [DispatchSourceSignal] {
            [SIGTERM, SIGINT].map { signalNumber in
                _ = signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
                source.setEventHandler {
                    writeStandardError("spacesd: received \(signalName(signalNumber)); shutting down\n")
                    Task { @MainActor in
                        controller.shutdown()
                        exit(0)
                    }
                }
                source.resume()
                return source
            }
        }

        private static func signalName(_ signalNumber: Int32) -> String {
            switch signalNumber {
            case SIGTERM: "SIGTERM"
            case SIGINT: "SIGINT"
            default: "signal \(signalNumber)"
            }
        }
    #else
        private static func installTerminationSignalHandlers(controller _: SpacesDaemonController) -> [DispatchSourceSignal] { [] }
    #endif
}

private func writeStandardError(_ message: String) { FileHandle.standardError.write(Data(message.utf8)) }

private func environmentValue(_ name: String) -> String? {
    guard let rawValue = getenv(name) else { return nil }
    return String(cString: rawValue)
}
