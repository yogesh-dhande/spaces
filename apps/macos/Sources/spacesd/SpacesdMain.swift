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

/// Thread-safe snapshot of the daemon facts a liveness `.ping` reports, shared between the main actor
/// (which writes them) and the socket connection worker (which reads them off-actor). Keeping this off
/// the main actor is what lets a busy daemon answer pings promptly instead of queuing them behind an
/// in-flight session `.create` — the core of the issue #188 relaunch-race fix.
final class DaemonLivenessState: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionCount = 0
    private var certificateFingerprint: String?
    /// Mirrors the main actor's `handoffInProgress` flag. Without this, the fast ping path would report
    /// the daemon live for the entire up-to-10s exec-handoff preflight window during which `handle(_:)`
    /// is already rejecting every real request with `.shuttingDown` — a client polling liveness would
    /// see "ok" and adopt a daemon that refuses everything else.
    private var handoffInProgress = false

    func storeSessionCount(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        sessionCount = value
    }

    func storeFingerprint(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        certificateFingerprint = value
    }

    func storeHandoffInProgress(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        handoffInProgress = value
    }

    func snapshot() -> (sessionCount: Int, certificateFingerprint: String?, handoffInProgress: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (sessionCount, certificateFingerprint, handoffInProgress)
    }

    /// Builds the liveness `.ping` response entirely off the main actor. It carries the same
    /// `TerminalServiceDaemonStatus` shape as the controller's `daemonStatus()` (version, installed
    /// version, fingerprint, and an eventually-consistent session count) so wire-compatibility
    /// negotiation works identically, but it never blocks on the main actor — the point of the fast
    /// path. While a handoff is in progress it instead mirrors `handle(_:)`'s own rejection exactly, so
    /// a ping never reports the daemon live while every other request is being turned away.
    func pingResponse() -> TerminalServiceResponse {
        let snapshot = snapshot()
        guard !snapshot.handoffInProgress else {
            return TerminalServiceResponse(
                ok: false, message: "spacesd is handing off to an updated daemon.", errorCode: .shuttingDown, servicePID: getpid())
        }
        let status = TerminalServiceDaemonStatus(
            version: AppVersion.current, installedVersion: InstalledSpacesVersion.current(),
            certificateFingerprint: snapshot.certificateFingerprint, activeSessionCount: snapshot.sessionCount)
        return TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid(), daemonStatus: status)
    }
}

/// The routing contract that keeps the daemon deadlock-free: which profile commands MUST run off the
/// main actor. A command must be peeled off main when its orchestrator call graph can reach the built-in
/// terminal launcher or terminator closures, both of which enter the terminal engine actor via
/// `TerminalEngineActor.runSynchronously` — a synchronous engine hop that traps from the main actor (the
/// one-way rule). `dispatch(_:)` peels exactly these onto the transport thread; every other profile
/// command runs its bulk on the main actor. Kept as a pure, `internal` classifier (not buried in
/// `dispatch`) so the routing contract is unit-testable without standing up a daemon, and so
/// `profileCommandOffMain` can assert against the single source of truth.
enum SpacesDaemonProfileCommandRouting {
    static func requiresOffMainExecution(_ command: TerminalServiceProfileCommand) -> Bool {
        switch command {
        // Launcher-reaching: session create/send and workspace start/restart (`upWorkspace` launches
        // and tears down workspace terminals). Terminator-reaching: agent kill's stop chokepoint, and an
        // agent-signal `exit` whose `finalizeAgentRow`/`handleAgentExit` terminates the backing terminal.
        case .terminalSend, .terminalCommand, .agentSpawn, .workspaceStart, .workspaceRestart, .agentKill, .agentSignal:
            true
        // Engine-free: pure store/disk reads and metadata writes with no launcher/terminator reach.
        case .terminalList, .terminalTail, .projectList, .workspaceList, .workspaceCreate, .agentList, .agentAnnotate, .agentSubscribe,
            .agentUnsubscribe, .agentConsumePendingEvents:
            false
        }
    }
}

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
    /// Backed by `livenessState` (rather than a plain stored property) so that single flag is also the
    /// one the off-actor ping fast path reads — there is exactly one source of truth for "is a handoff
    /// in progress", read from both the main actor and the socket worker.
    /// `nonisolated`: its storage (`livenessState`) is already a lock-guarded, off-actor box, and this flag
    /// is read from every isolation domain in the daemon — main (`handle`, `performExecHandoff`), the
    /// engine actor (`createSession`/`startSessionCoreResponse`'s mutation-boundary re-check,
    /// `terminateBuiltInTerminalSession`), and the transport thread (every off-main handler, via
    /// `livenessState.snapshot()` directly).
    private nonisolated var handoffInProgress: Bool {
        get { livenessState.snapshot().handoffInProgress }
        set { livenessState.storeHandoffInProgress(newValue) }
    }
    private let instanceLock: TerminalServiceInstanceLock
    private let serverQueue = DispatchQueue(label: "spaces.terminal.service")
    private lazy var server = TerminalServiceServer(
        socketPath: socketPath, queue: serverQueue,
        // Liveness `.ping` is answered off the main actor from `livenessState`, so a client's health probe
        // stays fast even while the main actor is saturated by concurrent session `.create`s. Everything
        // else still funnels through `handle` on the main actor.
        livenessResponder: { [weak self] in
            guard let self else { return TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid()) }
            return self.livenessState.pingResponse()
        }
    ) { [weak self] request in
        guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .shuttingDown) }
        // Classify off the main actor (this closure runs on `serverQueue`). The blocking request classes
        // run their unbounded work here on the transport thread and hop to the main actor only for the
        // narrow sections that touch `sessionCores`/Ghostty; everything else runs wholly on the main actor.
        return self.dispatch(request)
    }
    private lazy var daemonIdentityFingerprint: String? = (try? TerminalServiceTLSIdentityStore.loadOrCreate())?.certificateFingerprint
    /// Off-actor snapshot the liveness `.ping` responder reads without touching the main actor. The main
    /// actor writes the certificate fingerprint once at startup and the session count on every
    /// `sessionCores` mutation; the socket worker reads both under the box's lock.
    private nonisolated let livenessState = DaemonLivenessState()
    /// Isolated to the terminal engine actor: every `GhosttyEmbeddedSessionCore` runs on
    /// `TerminalEngineActor`, so the dictionary that owns them (and the members that read/mutate it)
    /// move there too, off the main actor. The `didSet` mirror into `livenessState` still runs on the
    /// engine — `DaemonLivenessState` is `@unchecked Sendable` and lock-guarded, so a cross-actor write
    /// into it is safe without a hop.
    @TerminalEngineActor private var sessionCores: [String: GhosttyEmbeddedSessionCore] = [:] {
        didSet { livenessState.storeSessionCount(sessionCores.count) }
    }
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
        // Both closures run on the Device API server's own dedicated connection-handling queue (never
        // main), so hopping onto the engine actor here — including for the launcher's session CREATE — is
        // deadlock-safe: the calling thread is never blocked waiting on the main actor.
        builtInTerminalSessionTerminator: { [weak self] sessionID in
            TerminalEngineActor.runSynchronously { self?.terminateBuiltInTerminalSession(id: sessionID) }
        },
        builtInTerminalSessionLauncher: { [weak self] launchConfiguration in
            guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
            return try self.launchBuiltInTerminalSession(launchConfiguration)
        },
        // Routes the remote `killAgentSession` Device API command through the same notify-then-stop flow
        // as the local `.agentKill` (`agentKillOffMain`): `killAgentSession` routes through the stop
        // chokepoint that tells the child's subscribers it exited before deleting its row, which
        // terminates the backing terminal through the orchestrator's terminator closure
        // (`TerminalEngineActor.runSynchronously`). This closure runs on the Device API server's own
        // connection-handling queue (never main), so it drives the whole flow directly off the main actor:
        // the engine hop is deadlock-safe here (main stays free) and the subscriber notification the
        // chokepoint enqueues takes `submitAgentNotificationLine`'s direct off-main send path. Hopping onto
        // the main actor instead would trip `runSynchronously`'s `!isMainThread` precondition and abort the
        // daemon (see `TerminalEngineActor`'s one-way rule).
        agentSessionKiller: { [weak self] sessionID in
            guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
            // Admit against handoff before the kill runs its stop chokepoint (which deletes the agent row and
            // terminates its backing terminal): the other off-main handlers gate at entry the same way, and
            // without this the Device API `killAgentSession` path had no handoff check at all.
            guard !self.handoffInProgress else { throw WorkspaceError.daemonHandoffInProgress }
            let orchestrator = try self.makeProfileOrchestrator()
            return try orchestrator.killAgentSession(terminalSessionID: sessionID)
        }, onRestartRequested: { [weak self] in Task { @MainActor in self?.requestDaemonRestart() } })
    /// `nonisolated` so the off-main request handlers can drive git subprocesses from the transport
    /// thread. `RemoteWorkspaceGitClient` is `Sendable` (immutable, subprocess-per-call), so sharing the
    /// one instance across threads is safe.
    private nonisolated let git = RemoteWorkspaceGitClient()

    /// Serial background queue onto which a main-actor caller of `submitAgentNotificationLine` defers the
    /// terminal-send: the send reaches a live session core through `TerminalEngineActor.runSynchronously`,
    /// which the main actor must never synchronously wait on (the one-way rule). Being serial preserves
    /// cross-notification submission order. `nonisolated` so it is reachable from the nonisolated submitter.
    private nonisolated let agentNotificationDeliveryQueue = DispatchQueue(label: "spaces.agent-notification.delivery")

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
        // Seed the off-actor liveness snapshot before the socket accepts connections so the very first
        // `.ping` already carries this daemon's identity. Runs on both fresh start and handoff resume.
        livenessState.storeFingerprint(daemonIdentityFingerprint)
        // The session count is already mirrored into `livenessState` by `sessionCores.didSet` on every
        // mutation (including the handoff-resume inserts that ran before this), so there is nothing to seed
        // here — and reading `sessionCores` from this main-actor context would be an illegal sync wait on
        // the engine actor.
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
            databasePath: databasePath, transport: .live(clientApp: Self.daemonDeviceClientApp()),
            deliver: { [weak self] sessionID, line in
                guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                try self.submitAgentNotificationLine(sessionID: sessionID, line: line)
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
        // The device-runtime reconcilers (worktree discovery, foreground-agent reconciliation) that
        // consume these overrides run on their own detached tasks/queues, never main, so hopping onto the
        // engine actor here — including for the launcher's session CREATE — is deadlock-safe.
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher { [weak self] launchConfiguration in
            guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
            return try self.launchBuiltInTerminalSession(launchConfiguration)
        }
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator { [weak self] sessionID in
            TerminalEngineActor.runSynchronously { self?.terminateBuiltInTerminalSession(id: sessionID) }
        }
        // The device-runtime reconcilers detect coding-agent exits that never fired a session-end hook
        // (codex/opencode, SIGKILL'd claude) and notify subscribers through this submitter. They run on
        // detached tasks/queues, never main, so `submitAgentNotificationLine` takes its off-main direct
        // send path here (it only defers onto the delivery queue when invoked on the main actor).
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { [weak self] sessionID, line in
            guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
            try self.submitAgentNotificationLine(sessionID: sessionID, line: line)
        }
        #if os(macOS)
            WorkspaceOrchestrator.setProcessWideNotificationDeliverer { title, body, subtitle in
                var userInfo = [IPCNotification.titleUserInfoKey: title, IPCNotification.detailUserInfoKey: body]
                if let subtitle { userInfo[IPCNotification.notificationSubtitleUserInfoKey] = subtitle }
                try? IPCNotification.post(IPCNotification.deliverUserNotification, userInfo: userInfo)
            }
        #endif
    }

    func shutdown() async {
        stopSharedServices()
        // `terminateAllSessions` is engine-isolated (it drives `terminateSession`/Ghostty per core). Hop
        // with the ASYNC `run` — a main-actor context must never sync-wait on the engine (the one-way
        // rule). `terminate()` no longer blocks (PTY teardown is deferred), so this returns promptly after
        // flushing each core's transcript. Snapshot the cores in the same hop so we retain references to the
        // ones `terminateSession` removes from `sessionCores`.
        let terminatedCores = await TerminalEngineActor.run { () -> [GhosttyEmbeddedSessionCore] in
            let cores = Array(self.sessionCores.values)
            self.terminateAllSessions()
            return cores
        }
        // `terminate()` only ENQUEUES the exited runtime-state, detach-all, terminated payload, and durable-end
        // writes onto each core's serial persistence queue; `shutdownAndExit`'s `exit(0)` would destroy any
        // still queued. Await each core's drain so those writes commit before we exit — otherwise a session's
        // durable runtime row stays stuck at `.running`. This is a cold path; the writes are bounded by
        // SQLite's busy timeout plus the bounded exited-state retry, so a blocking drain is acceptable.
        for core in terminatedCores { await core.drainPersistenceForShutdown() }
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

    @TerminalEngineActor private func terminateAllSessions() { for sessionID in Array(sessionCores.keys) { _ = terminateSession(id: sessionID) } }

    /// The response every command returns while an exec-in-place handoff is underway. Read from both the
    /// main actor (`handle`) and the off-main handlers (via `livenessState`), it mirrors the rejection the
    /// fast ping path emits so no request is served while the daemon is handing off.
    private nonisolated static func handoffInProgressResponse() -> TerminalServiceResponse {
        TerminalServiceResponse(
            ok: false, message: "spacesd is handing off to an updated daemon.", errorCode: .shuttingDown, servicePID: getpid())
    }

    /// Off-main request classifier, run on `serverQueue` (the transport thread), not the main actor.
    /// The unbounded/blocking request classes — arbitrary shell exec, git-driven workspace prep, session
    /// create's git prep, and the socket-fallback state/control/terminal-send reads — run their blocking
    /// work here on the transport thread and hop to the main actor only for the narrow sections that touch
    /// `sessionCores`/Ghostty. Every other command funnels through `handle` wholly on the main actor,
    /// exactly as before. Keeping the blocking classes off the main actor is what lets embedded terminals
    /// keep ticking (the main actor pumps `ghostty_app_tick`) while a slow RPC is in flight. The serial
    /// transport contract is unchanged — one RPC is processed at a time; this only moves where it blocks.
    private nonisolated func dispatch(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        switch request.command {
        case .runWorkspaceCommand(let payload): return runWorkspaceCommandOffMain(payload)
        case .prepareWorkspace(let payload): return prepareWorkspaceOffMain(payload)
        case .create(let payload): return createSessionOffMain(payload)
        case .state(let payload): return loadTerminalStateOffMain(sessionID: payload.sessionID)
        case .control(let payload): return handleTerminalControlOffMain(payload)
        // `.terminate` now touches the engine-isolated `sessionCores` cluster (Step 1), so it is peeled
        // off main here too — mirroring `.create` — rather than falling through to `handle`'s on-main
        // fallback, which would force the main actor to synchronously wait on the engine actor.
        case .terminate(let payload): return terminateSessionOffMain(payload)
        // The terminal-send profile variant is peeled off main here — its live-core send hops the engine
        // actor and its socket round-trip is the one blocking path in the profile-command family — via a
        // dedicated synchronous off-main handler that never touches agent-row finalization.
        case .profileCommand(.terminalSend(let payload)): return terminalSendOffMain(payload)
        // The two session-CREATING profile commands must run off the main actor: creating a session hops
        // the engine actor synchronously onto the main actor (NSView/NSScreen), so driving it from a
        // main-blocked context would deadlock (see the one-way rule).
        case .profileCommand(.terminalCommand(let payload)): return terminalCommandOffMain(payload)
        case .profileCommand(.agentSpawn(let payload)): return agentSpawnOffMain(payload)
        // Workspace start/restart and agent kill/signal are peeled off main for the SAME reason as the
        // three cases above: their orchestrator call graph reaches the built-in terminal launcher (start/
        // restart) or terminator (agent kill's stop chokepoint, and an agent-signal `exit` whose
        // `handleAgentExit` tears down an already-dead backing terminal), and both closures enter the
        // terminal engine actor via `TerminalEngineActor.runSynchronously` — which traps when called from
        // the main actor (the one-way rule). `SpacesDaemonProfileCommandRouting.requiresOffMainExecution`
        // is the single source of truth for this classification; `profileCommandOffMain` asserts against it.
        case .profileCommand(.workspaceStart(let workspaceID)): return workspaceStartOffMain(workspaceID: workspaceID, restartIfRunning: false)
        case .profileCommand(.workspaceRestart(let workspaceID)): return workspaceStartOffMain(workspaceID: workspaceID, restartIfRunning: true)
        case .profileCommand(.agentKill(let payload)): return agentKillOffMain(payload)
        case .profileCommand(.agentSignal(let payload)): return agentSignalOffMain(payload)
        // Every remaining profile command (listings, workspace/agent metadata, subscriptions) touches no
        // engine state, so it keeps running the *bulk* of its work on the main actor (through
        // `handleProfileCommand`/`runProfileCommand`, unchanged main-actor methods) — only the calling
        // thread here (never main) blocks on `profileCommandOffMain`'s bridge while that runs.
        case .profileCommand(let command): return profileCommandOffMain(command)
        default: return Self.runOnMainActorSynchronously { self.handle(request) }
        }
    }

    /// Bridges the transport thread onto the main-actor `handleProfileCommand` for every profile command
    /// not already peeled out above. See the `dispatch(_:)` case comment for why this exists instead of
    /// calling `handleProfileCommand` inline through `handle`.
    private nonisolated func profileCommandOffMain(_ command: TerminalServiceProfileCommand) -> TerminalServiceResponse {
        // Only engine-free profile commands may run their bulk on the main actor. An engine-touching
        // command reaching here means `dispatch(_:)` failed to peel it off main, which would trap inside
        // `TerminalEngineActor.runSynchronously`; fail loudly at the seam instead.
        precondition(
            !SpacesDaemonProfileCommandRouting.requiresOffMainExecution(command),
            "engine-touching profile command reached the main-actor bridge; peel it off main in dispatch(_:)")
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        return Self.runOnMainActorSynchronously { [weak self] in
            guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .shuttingDown) }
            return self.handleProfileCommand(command)
        }
    }

    private func handle(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        // Socket shutdown is asynchronous, so a request accepted just before cancellation
        // can reach the main actor after handoff starts. Reject it here, at the mutation
        // boundary, so the session snapshot cannot gain or lose a core while quiescing.
        guard !handoffInProgress else { return Self.handoffInProgressResponse() }
        switch request.command {
        case .ping: return TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid(), daemonStatus: daemonStatus())
        case .shutdownIfIdle: return shutdownIfIdle()
        case .shutdown:
            writeStandardError("spacesd: terminal service shutdown requested\n")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                await self.shutdownAndExit()
            }
            return TerminalServiceResponse(ok: true, message: "spacesd is shutting down.", servicePID: getpid())
        case .applyStagedUpdate:
            // Respond-then-act, mirroring `.shutdown`: acknowledge on the request path, then trigger the
            // exec-in-place handoff. `requestDaemonRestart()` is the single handoff trigger — if its
            // preflight or generation guard refuses, it logs and the daemon keeps running untouched (the
            // ok response was already sent, matching the frozen command's synchronous ok/error contract).
            requestDaemonRestart()
            return TerminalServiceResponse(ok: true, message: "spacesd is applying the staged update.", servicePID: getpid())
        // These five (and the `.terminalSend` profile variant below) are normally peeled off the main
        // actor by `dispatch`. They remain here for the main-actor fallback: the off-main handlers run
        // correctly on main too (their internal `runOnMainActorSynchronously` hops are no-ops there), so
        // there is exactly one implementation of each.
        case .create(let payload): return createSessionOffMain(payload)
        case .prepareWorkspace(let payload): return prepareWorkspaceOffMain(payload)
        case .runWorkspaceCommand(let payload): return runWorkspaceCommandOffMain(payload)
        // Same dual-listing as `.create`/`.prepareWorkspace` above: `dispatch` normally peels `.terminate`
        // off main, but the on-main fallback (a request that reached `handle` directly) routes through the
        // identical off-main implementation rather than calling the now-engine-isolated `terminateSession`
        // directly, which would force this main-actor method to synchronously wait on the engine actor.
        case .terminate(let payload): return terminateSessionOffMain(payload)
        case .list: return listSessions()
        case .state(let payload): return loadTerminalStateOffMain(sessionID: payload.sessionID)
        case .subscribe(let payload): return subscribeTerminalState(sessionID: payload.sessionID)
        case .control(let payload): return handleTerminalControlOffMain(payload)
        case .agentSignal(let payload): return recordAgentSignal(payload)
        case .ackAgentSignals(let payload): return acknowledgeAgentSignals(payload)
        // Delegates to the same `profileCommandOffMain` bridge `dispatch` uses rather than calling
        // `handleProfileCommand` inline, matching the `.terminate`/`.control` pattern above: the bridge
        // owns the handoff-progress gate and the transport-thread→main-actor hop in one place.
        case .profileCommand(let command): return profileCommandOffMain(command)
        case .resolveTerminalLink(let payload): return resolveTerminalLink(payload)
        case .readTerminalLinkChunk(let payload): return readTerminalLinkChunk(payload)
        }
    }

    private func daemonStatus() -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: AppVersion.current, installedVersion: InstalledSpacesVersion.current(), certificateFingerprint: daemonIdentityFingerprint,
            // Reads the off-actor liveness mirror rather than the now engine-isolated `sessionCores`
            // directly, so this main-actor status read never needs to hop onto the engine actor.
            activeSessionCount: livenessState.snapshot().sessionCount)
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
            await self.shutdownAndExit()
        }
        return TerminalServiceResponse(ok: true, message: "spacesd is shutting down.", servicePID: getpid(), daemonStatus: status)
    }

    /// Explicit exit for daemon-initiated termination (shutdown commands, restart requests).
    /// Runs cleanup directly and exits rather than routing through `NSApp.terminate`, so the
    /// exit does not depend on AppKit termination machinery and the shutdown command reaps
    /// children identically on macOS and Linux. External NSApp-driven termination (e.g. logout)
    /// still reaches `shutdown()` through the app delegate.
    private func shutdownAndExit() async -> Never {
        await shutdown()
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

        // Flush agent-notification lines already enqueued from main-actor callers (RemoteAgentWatchService
        // delivery) before quiescing, so an accepted-but-not-yet-sent line reaches its still-live core
        // instead of being lost across exec. Drain by awaiting a trailing block on the serial delivery
        // queue: because the queue is serial, that block runs only after every prior enqueued send. It is
        // AWAITED (not `.sync`-blocked): the main actor stays free, so a drained send's live-core engine hop
        // — and any engine→main hop underneath it — can complete instead of deadlocking against a blocked
        // main thread. Intake is already stopped, so nothing new enqueues after this.
        await withCheckedContinuation { continuation in agentNotificationDeliveryQueue.async { continuation.resume() } }
        writeStandardError("spacesd handoff_delivery_drained\n")

        // Quiesce each live core. A nil return means the child already exited — finalize that session
        // through the normal dead-session teardown before exec so it lands `.exited`, not resumed.
        var records: [DaemonHandoffSessionRecord] = []
        var quiescedCores: [GhosttyEmbeddedSessionCore] = []
        // Snapshot the cores on the engine actor first: the nil-quiesce branch calls the engine-isolated
        // `terminateSession`, which mutates `sessionCores`, so the snapshot must be taken before the loop
        // starts mutating. The loop itself stays on the main actor between iterations — `quiesceForHandoff`
        // is an async call directly on the (engine-isolated) core, legal from any actor — and only the
        // `terminateSession` nil-branch call hops back onto the engine per iteration.
        let cores = await TerminalEngineActor.run { Array(self.sessionCores) }
        do {
            for (sessionID, core) in cores {
                // Add the core before quiescing so a transcript-persistence failure resumes the
                // core whose driver is still buffering, as well as every earlier quiesced core.
                quiescedCores.append(core)
                if let record = try await core.quiesceForHandoff() {
                    records.append(record)
                } else {
                    quiescedCores.removeLast()
                    // Nil quiesce returns BEFORE its own persistence drain, so `terminateSession` here only
                    // ENQUEUES the exited/detach/payload/durable-end writes. Drain this core before continuing
                    // to `execv`: exec destroys anything still queued, and — because exec keeps the same pid —
                    // a dropped exited write would leave the `.running` row that `recoverStaleSessions` skips
                    // forever (the pid is still alive), stranding the session.
                    _ = await TerminalEngineActor.run { self.terminateSession(id: sessionID) }
                    await core.drainPersistenceForShutdown()
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
            // `withValidatedHandoffOutputsForExec` is engine-isolated (it recurses through each core's own
            // engine-isolated sink lock) and its `operation` closure runs `execv` synchronously inside those
            // locks. This must run on the engine, and this is a main-actor context, so it hops with the
            // ASYNC `run` (never a sync wait on the engine from main — see the one-way rule). The whole
            // validated-exec runs synchronously inside the `run` body; on success `execv` replaces the image.
            try await TerminalEngineActor.run {
                try self.withValidatedHandoffOutputsForExec(ArraySlice(quiescedCores)) {
                    self.execStagedBinary(path: self.launchExecutablePath)
                    execErrno = errno
                }
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
    /// every lock before the in-place resume path runs. Isolated to the terminal engine actor because it
    /// recurses through each core's (engine-isolated) `withValidatedHandoffOutputForExec`.
    @TerminalEngineActor private func withValidatedHandoffOutputsForExec(_ cores: ArraySlice<GhosttyEmbeddedSessionCore>, operation: () throws -> Void)
        throws
    {
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
    /// success path is irrelevant — the image is gone). `nonisolated`: it touches no daemon state (only
    /// `CommandLine`/`execv`), and `performExecHandoff` calls it from inside the engine-isolated
    /// `withValidatedHandoffOutputsForExec`'s `operation` closure.
    private nonisolated func execStagedBinary(path: String) {
        // POSIX exec preserves the calling THREAD's signal mask, and this runs on the terminal engine
        // executor — a libdispatch worker, which blocks the terminal signals (SIGTERM/SIGHUP/SIGINT) so
        // they are delivered to the main thread instead. Without resetting the mask here the replacement
        // daemon would start with those signals blocked and ignore graceful shutdown (they would stay
        // pending, never handled). Reset to an empty mask immediately before `execv`, exactly as the PTY
        // child path does before its own exec (HostManagedPTYTerminalSessionDriver.resetSignalDispositionsForExec).
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        sigprocmask(SIG_SETMASK, &emptyMask, nil)
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
                // `sessionCore(for:)` is engine-isolated; `run` hops onto the engine asynchronously (this
                // is a main-actor async context, so it uses the async hop rather than `runSynchronously`).
                let core = try await TerminalEngineActor.run { try self.sessionCore(for: launchConfiguration) }
                try await core.resumeFromHandoff(record)
            } catch {
                writeStandardError("spacesd handoff_resume_session_failed session=\(record.sessionID) error=\(error)\n")
                // `sessionCore(for:)` already inserted the core into `sessionCores`, and the local `core`
                // binding is out of scope here, so the dictionary holds the last reference. When the failure
                // landed AFTER `resumeFromHandoff` adopted the PTY (e.g. the control- or state-stream server
                // throws), the driver's `hasLiveResources` is true; simply removing that last reference would
                // release the driver and trip its deinit precondition, aborting the whole staged daemon
                // before cleanup. Route teardown through `terminateSession`, which keeps its own local
                // reference while it calls the driver's `terminate()` and drops it only afterwards — so the
                // live resources are always freed before the final release.
                //
                // The inherited master fd is intentionally NOT closed here. Once adopted, the driver's read
                // loop owns that fd and closes it when its read returns (see HostManagedPTYTerminalSessionDriver);
                // closing it from this context would race that close and double-close a descriptor the kernel
                // may have reused. A resume that fails BEFORE adoption (a rare pre-adopt error such as a disk
                // failure) leaks that one descriptor, which is preferable to the reuse hazard and there is no
                // cross-platform signal here to distinguish the two cases without reaching into the engine core.
                _ = await TerminalEngineActor.run { self.terminateSession(id: record.sessionID) }
            }
        case .finalizeExited:
            close(record.masterFD)
            _ = await TerminalEngineActor.run { self.terminateSession(id: record.sessionID) }
        case .discardInvalidDescriptor: _ = await TerminalEngineActor.run { self.terminateSession(id: record.sessionID) }
        }
    }

    /// RPC `.create` handler. The git-driven workspace prep is unbounded (it can `git clone` with a 120s
    /// timeout), so it runs off the main actor on the transport thread; only the session-core creation and
    /// start — which mutate `sessionCores` and drive Ghostty — hop to the engine actor via
    /// `startSessionCoreResponse`, whose on-engine `handoffInProgress` re-check is the real mutation-boundary
    /// guard (the off-actor check below is an early-out, not the authority). The summary poll
    /// (`sessionSummaryAfterStart`) runs here, after the engine hop returns, on this transport thread —
    /// never on the engine actor (its `RunLoop`-free serial queue would stall every other live session's
    /// PTY I/O for up to a second) and never on the main actor (would stall Ghostty's ticks the same way).
    private nonisolated func createSessionOffMain(_ request: TerminalServiceCreateRequest) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        let launchConfiguration = request.launchConfiguration
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: launchConfiguration.workingDirectory)
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
        let startResponse = TerminalEngineActor.runSynchronously { self.startSessionCoreResponse(for: launchConfiguration) }
        guard startResponse.ok else { return startResponse }
        do {
            return TerminalServiceResponse(ok: true, message: startResponse.message, session: try sessionSummaryAfterStart(for: launchConfiguration.sessionID))
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
    }

    /// Engine-isolated create used by the in-process launch callers (built-in terminal launcher /
    /// orchestrator hooks), which reach the engine via `TerminalEngineActor.runSynchronously` from their
    /// own (never-main) calling threads. Runs the workspace prep and the core start inline; like
    /// `startSessionCoreResponse`, it returns without a session summary — the summary poll cannot run here
    /// (no run loop on the engine, and it would stall every other session's I/O) so `launchBuiltInTerminalSession`
    /// adds it after this hop returns.
    @TerminalEngineActor private func createSession(_ request: TerminalServiceCreateRequest) -> TerminalServiceResponse {
        guard !handoffInProgress else { return Self.handoffInProgressResponse() }
        let launchConfiguration = request.launchConfiguration
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: launchConfiguration.workingDirectory)
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
        return startSessionCoreResponse(for: launchConfiguration)
    }

    /// The engine-isolated tail of session create: creating the session core and starting it. Re-checks
    /// `handoffInProgress` on the engine actor so a create that raced a handoff cannot add a core after the
    /// quiesce snapshot — this is now the real mutation-boundary guard, serialized against the handoff
    /// quiesce loop (`performExecHandoff`), which also runs on the engine. Returns without a session summary
    /// on success; every caller adds the summary itself, off the engine, via `sessionSummaryAfterStart`.
    @TerminalEngineActor private func startSessionCoreResponse(for launchConfiguration: TerminalSessionLaunchConfiguration) -> TerminalServiceResponse {
        guard !handoffInProgress else { return Self.handoffInProgressResponse() }
        do {
            let sessionCore = try sessionCore(for: launchConfiguration)
            try sessionCore.startIfNeeded()
            return TerminalServiceResponse(ok: true, message: "Started terminal session \(launchConfiguration.sessionID).")
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
    }

    /// RPC `.runWorkspaceCommand` handler. Runs an arbitrary `/bin/bash -lc` command to completion — an
    /// unbounded block — plus the git-driven workspace prep, entirely off the main actor on the transport
    /// thread. Touches no main-actor state, so there is no main hop at all.
    private nonisolated func runWorkspaceCommandOffMain(_ request: TerminalServiceRunWorkspaceCommandRequest) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
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

    /// RPC `.prepareWorkspace` handler. Chains git subprocesses (fetch/checkout/merge, and `git clone`
    /// with a 120s timeout) with no main-actor state, so it runs wholly off the main actor.
    private nonisolated func prepareWorkspaceOffMain(_ payload: TerminalServicePrepareWorkspaceRequest) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        do {
            try prepareWorkspace(
                runtimeManifest: payload.runtimeManifest, worktreeRefresh: payload.worktreeRefresh,
                workingDirectory: payload.runtimeManifest.remotePath ?? payload.runtimeManifest.localPath)
            return TerminalServiceResponse(ok: true, message: "Workspace runtime is prepared.", servicePID: getpid())
        } catch { return Self.failureResponse(error) }
    }

    // `prepareWorkspace` and its git/filesystem helpers are `nonisolated`: they touch no main-actor state
    // (only the `Sendable` `git` client, `FileManager`, and static persistence APIs), so they run on the
    // transport thread for the off-main handlers and inline on the main actor for the in-process callers.
    private nonisolated func prepareWorkspace(
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

    private nonisolated func prepareRemoteWorktree(
        manifest: TerminalServiceWorkspaceRuntimeManifest, refreshRequest: TerminalServiceWorktreeRefreshRequest?
    ) throws {
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

    private nonisolated func cloneRemoteWorktree(manifest: TerminalServiceWorkspaceRuntimeManifest, branch: String, remotePath: String) throws {
        guard let remoteURL = manifest.gitRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteURL.isEmpty else {
            throw RemoteWorkspaceRefreshBlock(
                hostName: manifest.deviceID ?? "remote device", path: remotePath, branch: branch, reason: .fetchFailed,
                detail: "Remote workspace path is missing and no Git remote URL was provided.")
        }
        _ = try git.runGitAndCapture(["clone", "--branch", branch, "--single-branch", remoteURL, remotePath], timeout: 120)
    }

    private nonisolated func validateWorkspacePath(_ path: String, manifest: TerminalServiceWorkspaceRuntimeManifest) throws {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let allowedRoots = manifest.allowedFileRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard allowedRoots.contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") }) else {
            throw SpacesRuntimeError.invalidArgument(message: "Path is outside the workspace runtime roots: \(path)")
        }
    }

    private nonisolated func directoryIsEmpty(_ url: URL) throws -> Bool {
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return contents.isEmpty
    }

    private nonisolated func workspaceCommandLogPath(_ requestedPath: String?) throws -> String {
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

    private nonisolated func runShellCommand(
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

    /// RPC `.state` handler. A live in-process core's state read is a narrow main hop
    /// (`loadCurrentStateOffMain`); when the session is not live, the unix-socket connect+read (2s timeout)
    /// and the disk reads run off the main actor on the transport thread.
    private nonisolated func loadTerminalStateOffMain(sessionID: String) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        guard !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument) }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            return TerminalServiceResponse(
                ok: true, message: "Loaded terminal state.", sessionState: try loadCurrentStateOffMain(sessionID: sessionID),
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

    /// Runs a profile command on the main actor. `dispatch(_:)` peels the three engine-touching commands
    /// (`.terminalSend`, `.terminalCommand`, `.agentSpawn`) off main into their own synchronous off-main
    /// handlers; every remaining profile command reaches here through `profileCommandOffMain`, which hops
    /// the transport thread onto the main actor. Running on main is safe because the only main→engine work
    /// any of these commands trigger is an agent-row finalization's subscriber notification, and
    /// `submitAgentNotificationLine` defers that terminal-send off the main actor rather than blocking on
    /// the engine (see `TerminalEngineActor`'s one-way rule).
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
        // The three engine-touching profile commands are peeled off the main actor by `dispatch(_:)` into
        // dedicated synchronous off-main handlers (`terminalSendOffMain`, `terminalCommandOffMain`,
        // `agentSpawnOffMain`); they can never reach this main-actor switch, where creating or sending to a
        // session would force a forbidden main→engine synchronous wait (see `TerminalEngineActor`'s one-way
        // rule). Kept in the switch for exhaustiveness and to fail loudly if that peeling ever regresses.
        case .terminalSend: preconditionFailure("`.terminalSend` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
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
        // Workspace start/restart and agent kill/signal are peeled off main by `dispatch(_:)` into their
        // dedicated synchronous off-main handlers (`workspaceStartOffMain`, `agentKillOffMain`,
        // `agentSignalOffMain`) because their call graph reaches the launcher/terminator, whose engine hop
        // would trap on the main-actor `runProfileCommand` switch (see `SpacesDaemonProfileCommandRouting`).
        // Kept in the switch for exhaustiveness and to fail loudly if that peeling ever regresses.
        case .workspaceStart: preconditionFailure("`.workspaceStart` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .workspaceRestart: preconditionFailure("`.workspaceRestart` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .agentSignal: preconditionFailure("`.agentSignal` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .agentList(let payload):
            let orchestrator = try makeProfileOrchestrator()
            let rows = try orchestrator.agentSessionRows(
                workspaceID: normalizedProfileArgument(payload.workspaceID), sessionID: normalizedProfileArgument(payload.sessionID))
            return TerminalServiceProfileCommandResponse(message: "Listed agent sessions.", agentSessions: rows)
        case .agentAnnotate(let payload):
            let orchestrator = try makeProfileOrchestrator()
            return try annotateProfileAgentSession(payload, orchestrator: orchestrator)
        case .agentSpawn: preconditionFailure("`.agentSpawn` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .agentKill: preconditionFailure("`.agentKill` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .agentSubscribe(let payload):
            let orchestrator = try makeProfileOrchestrator()
            return try subscribeProfileAgentSession(payload, orchestrator: orchestrator)
        case .agentUnsubscribe(let payload):
            let orchestrator = try makeProfileOrchestrator()
            if let deviceID = payload.deviceID {
                // Symmetry with subscribe: a device-qualified request naming this machine drops the *local*
                // edge, resolving the agent row from the child's terminal session id (the device-qualified
                // payload shape). No agent row means nothing to delete — a local edge FK-cascades with its
                // row — so it succeeds quietly.
                if deviceID == SpacesPairedDeviceRecord.localDeviceID {
                    try orchestrator.unsubscribeAgentWatch(
                        subscriberTerminalSessionID: payload.subscriberTerminalSessionID, childTerminalSessionID: payload.agentSessionID)
                    return TerminalServiceProfileCommandResponse(message: "Unsubscribed from agent session.")
                }
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
        case .agentConsumePendingEvents(let subscriberTerminalSessionID):
            // The MCP piggyback drain: atomically read-and-delete this subscriber's held notifications so a
            // busy orchestrator receives them on its next tool result. Injection (the idle path) is untouched.
            let orchestrator = try makeProfileOrchestrator()
            let events = try orchestrator.store.consumePendingAgentNotifications(subscriberTerminalSessionID: subscriberTerminalSessionID)
            return TerminalServiceProfileCommandResponse(
                message: events.isEmpty ? "No pending agent events." : "Consumed \(events.count) pending agent event(s).",
                pendingAgentEvents: events.isEmpty ? nil : events)
        case .terminalCommand: preconditionFailure("`.terminalCommand` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        }
    }

    /// RPC `.profileCommand(.terminalSend)` handler. The one blocking path in the profile-command family:
    /// its control-socket round-trip (5s timeout) is peeled off the main actor by `dispatch`. A live
    /// in-process core still sends in a narrow main hop; otherwise the socket send runs on the transport
    /// thread. Mirrors `sendProfileTerminalInput` + `handleProfileCommand`'s success/failure wrapping.
    private nonisolated func terminalSendOffMain(_ payload: TerminalServiceTerminalSendPayload) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        let text: String?
        let bytes: Data?
        switch payload.input {
        case .text(let value): (text, bytes) = (value, nil)
        case .bytes(let value): (text, bytes) = (nil, value)
        }
        let request = TerminalControlRequest(
            command: .send(TerminalControlSendPayload(text: text, bytes: bytes, clientID: nil, ownerEpoch: nil, appendNewline: payload.appendNewline)))
        do {
            let controlResponse = try sendProfileTerminalControlOffMain(sessionID: payload.sessionID, request: request)
            guard controlResponse.ok else { throw SpacesRuntimeError.invalidArgument(message: controlResponse.message) }
            let profile = TerminalServiceProfileCommandResponse(message: controlResponse.message)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.profileCommand(.terminalCommand)` handler. Creates a workspace terminal session, so it runs
    /// on the transport thread: the orchestrator's launcher hops to the engine actor, whose create-time
    /// engine→main hop is safe because the transport thread (not main) is what waits. Mirrors the
    /// `handleProfileCommand` success/failure envelope.
    private nonisolated func terminalCommandOffMain(_ payload: TerminalServiceTerminalCommandPayload) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        do {
            let orchestrator = try makeProfileOrchestrator()
            let workspaceID = try orchestrator.resolveWorkspaceIDForTerminalCommand(explicitWorkspaceID: payload.workspaceID, cwd: payload.cwd)
            let session = try orchestrator.createWorkspaceTerminalSession(workspaceID: workspaceID, title: payload.title, command: payload.command)
            let profile = TerminalServiceProfileCommandResponse(message: "Started terminal session.", terminalSession: session)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.profileCommand(.agentSpawn)` handler. Creates a coding-agent session, so it runs off main for
    /// the same reason as `terminalCommandOffMain`.
    private nonisolated func agentSpawnOffMain(_ payload: TerminalServiceAgentSpawnPayload) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        do {
            let orchestrator = try makeProfileOrchestrator()
            let profile = try spawnProfileAgentSession(payload, orchestrator: orchestrator)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.profileCommand(.workspaceStart/.workspaceRestart)` handler. `upWorkspace` launches (and, on
    /// restart, first tears down) workspace terminals through the orchestrator's launcher/terminator
    /// closures, which hop the engine actor via `TerminalEngineActor.runSynchronously`; that traps if
    /// driven from the main actor (the one-way rule), so this runs on the transport thread where the
    /// synchronous engine hop is safe. Mirrors the `handleProfileCommand` success/failure envelope.
    private nonisolated func workspaceStartOffMain(workspaceID: String, restartIfRunning: Bool) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        do {
            let orchestrator = try makeProfileOrchestrator()
            try orchestrator.upWorkspace(workspaceID: workspaceID, restartIfRunning: restartIfRunning, background: true)
            let workspace = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
            let profile = TerminalServiceProfileCommandResponse(
                message: restartIfRunning ? "Workspace restarted." : "Workspace is running.", workspace: profileWorkspaceRecord(workspace))
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.profileCommand(.agentKill)` handler. `killAgentSession` finalizes the agent row through the
    /// stop chokepoint, which terminates the backing terminal via the orchestrator's terminator closure
    /// (`TerminalEngineActor.runSynchronously`) — a forbidden synchronous engine wait from the main actor
    /// — so it runs on the transport thread. The subscriber "exited" notice the chokepoint enqueues sends
    /// through `submitAgentNotificationLine`, which on this off-main thread takes its direct send path.
    private nonisolated func agentKillOffMain(_ payload: TerminalServiceAgentKillPayload) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        do {
            let orchestrator = try makeProfileOrchestrator()
            let profile = try killProfileAgentSession(payload.sessionID, orchestrator: orchestrator)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.profileCommand(.agentSignal)` handler. An `exit` signal can finalize the agent row, whose
    /// `handleAgentExit` terminates an already-dead backing terminal through the orchestrator's terminator
    /// closure (`TerminalEngineActor.runSynchronously`) — forbidden from the main actor — so it runs on the
    /// transport thread. Every subscriber notification it produces goes direct (off-main) through
    /// `submitAgentNotificationLine`. Mirrors the `handleProfileCommand` success/failure envelope.
    private nonisolated func agentSignalOffMain(_ payload: TerminalServiceProfileAgentSignalPayload) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        do {
            let orchestrator = try makeProfileOrchestrator()
            let profile = try recordProfileAgentSignal(payload, orchestrator: orchestrator)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// Off-main terminal-send: a narrow engine hop for the live in-process core, else the control-socket
    /// round-trip on the transport thread.
    private nonisolated func sendProfileTerminalControlOffMain(sessionID: String, request: TerminalControlRequest) throws -> TerminalControlResponse {
        if let live = TerminalEngineActor.runSynchronously({ self.liveCoreControlResponse(sessionID: sessionID, request: request) }) { return live }
        return try controlSocketResponse(sessionID: sessionID, request: request)
    }

    /// The live in-process core's control response, or nil when there is no live core. Touches
    /// `sessionCores`/Ghostty, so it is isolated to the terminal engine actor.
    @TerminalEngineActor private func liveCoreControlResponse(sessionID: String, request: TerminalControlRequest) -> TerminalControlResponse? {
        guard let liveCore = sessionCores[sessionID] else { return nil }
        return liveCore.handleControlRequest(request)
    }

    /// The control-socket round-trip (5s timeout) for a non-live session. No main-actor state, so it is
    /// `nonisolated` and runs on the transport thread for the off-main terminal-send/send paths.
    private nonisolated func controlSocketResponse(sessionID: String, request: TerminalControlRequest) throws -> TerminalControlResponse {
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

    /// `nonisolated` so the off-main session-creating profile handlers (`terminalCommandOffMain`,
    /// `agentSpawnOffMain`) can build an orchestrator on the transport thread. The launcher/terminator
    /// closures hop to the engine actor: reached from a transport thread the engine's create-time
    /// engine→main hop is deadlock-safe (main stays free); the session-creating profile commands are
    /// peeled off main in `dispatch` precisely so this launcher is never invoked from a main-blocked
    /// context.
    private nonisolated func makeProfileOrchestrator() throws -> WorkspaceOrchestrator {
        let store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalSessionTerminator: { [weak self] sessionID in
                TerminalEngineActor.runSynchronously { self?.terminateBuiltInTerminalSession(id: sessionID) }
            },
            builtInTerminalSessionLauncher: { [weak self] launchConfiguration in
                guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                return try self.launchBuiltInTerminalSession(launchConfiguration)
            },
            // Lets `stopWorkspaceUnlocked` veto its destructive row deletes at the mutation boundary when a
            // handoff races the stop. Reads the off-actor, lock-guarded flag, so it is safe to poll from the
            // orchestrator's transport-thread call graph. See `daemonHandoffInProgress`'s doc on the terminator
            // no-op divergence this closes.
            daemonHandoffInProgress: { [weak self] in self?.handoffInProgress ?? false })
        _ = try orchestrator.syncConfig()
        return orchestrator
    }

    @TerminalEngineActor private func terminateBuiltInTerminalSession(id sessionID: String) {
        guard !handoffInProgress else { return }
        _ = terminateSession(id: sessionID)
    }

    /// `nonisolated`: bridges the synchronous `@Sendable` `BuiltInTerminalSessionLauncher` closure type
    /// (Device API supervisor, the process-wide orchestrator override, and the profile-command
    /// orchestrator) onto the engine actor. `createSession` runs on the engine via
    /// `TerminalEngineActor.runSynchronously`; the summary poll (`sessionSummaryAfterStart`) then runs
    /// here, on whichever thread called this launcher, and never on the engine queue itself — polling
    /// there would stall every other live session's PTY I/O for the length of the poll.
    private nonisolated func launchBuiltInTerminalSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws
        -> TerminalServiceSessionSummary
    {
        let response = TerminalEngineActor.runSynchronously { self.createSession(TerminalServiceCreateRequest(launchConfiguration: launchConfiguration)) }
        guard response.ok else { throw Self.requestFailedError(response.message) }
        return try sessionSummaryAfterStart(for: launchConfiguration.sessionID)
    }

    private nonisolated static func requestFailedError(_ message: String) -> NSError {
        NSError(domain: "spacesd", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func profileProjectSummary(_ value: ProjectSummary) -> TerminalServiceProfileProjectSummary {
        TerminalServiceProfileProjectSummary(
            id: value.id, name: value.name, dir: value.dir, isGitRepo: value.isGitRepo, defaultBranch: value.defaultBranch)
    }

    private nonisolated func profileWorkspaceRecord(_ value: WorkspaceRecord) -> TerminalServiceProfileWorkspaceRecord {
        TerminalServiceProfileWorkspaceRecord(
            id: value.id, projectID: value.projectID, dir: value.dir, dirname: value.dirname, branch: value.branch, baseBranch: value.baseBranch,
            isDefault: value.isDefault, isArchived: value.isArchived, isHidden: value.isHidden, isRunning: value.isRunning,
            lastLaunchedAt: value.lastLaunchedAt, notes: value.notes)
    }

    private nonisolated func requiredProfileWorkspace(id: String, orchestrator: WorkspaceOrchestrator) throws -> WorkspaceRecord {
        guard let workspace = try orchestrator.store.workspace(id: id) else {
            throw SpacesRuntimeError.invalidArgument(message: "Workspace not found for id \(id).")
        }
        return workspace
    }

    /// Normalizes an optional daemon-side string argument. Required profile-command fields are already
    /// enforced at wire decode; this stays for the genuinely optional cases the daemon reads (the
    /// `workspaceList` project filter and agent-window labels).
    private nonisolated func normalizedProfileArgument(_ value: String?) -> String? { normalizedNonEmpty(value) }

    private enum ProfileAgentEventType: String {
        case `init` = "init"
        case working = "working"
        case blocked = "blocked"
        case done = "done"
        case exit = "exit"

        /// The status each signal maps its agent row to. The `.exit` value is not consumed on the exit
        /// path — `handleAgentExit` owns that decision (delete, `.done`, or `.exited`) — but reads
        /// `.exited` so the mapping stays honest.
        var status: AgentWindowStatus {
            switch self {
            case .`init`: .idle
            case .working: .spinning
            case .blocked: .waiting
            case .done: .done
            case .exit: .exited
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
    }

    /// `nonisolated`: driven off main by `agentSignalOffMain` on the transport thread, since an `exit`
    /// signal can reach the terminator (agent-row finalization → `handleAgentExit`), whose engine hop
    /// must not run from the main actor. Its notification sends therefore take `submitAgentNotificationLine`'s
    /// direct off-main path rather than the deferred main-actor path.
    private nonisolated func recordProfileAgentSignal(_ payload: TerminalServiceProfileAgentSignalPayload, orchestrator: WorkspaceOrchestrator) throws
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

        // Per-tool hooks (PreToolUse / tool.execute.before) fire `working` on every tool call. When the
        // agent is already working the signal changes nothing, so return before building the engine or
        // posting the GUI-refresh notification; the orchestrator enforces the same duplicate-working
        // suppression at the store layer for every other signal surface.
        if type == .working, existingAgent?.status == type.status {
            return TerminalServiceProfileCommandResponse(message: "Agent \(type.rawValue) recorded.")
        }

        let environmentKeys = [WorkspaceOrchestrator.terminalTrackingIDEnvVar]
        let engine = makeAgentNotificationEngine(orchestrator: orchestrator)
        // Whether this signal leaves the signaling terminal's own agent row idle/done, the single
        // authority for the flush decision below. Gated on the RESULTING row status, not the event type:
        // an `init` preserves a live busy agent's status (a reconnecting hook, or Claude Code's
        // SessionStart on auto-compact), so flushing on the event alone would deliver queued child events
        // into a still-working agent. `.exit` always flushes to drain its now-undeliverable queue.
        // `.exit` never flushes: its finalization chokepoint already tore down the signaling terminal's
        // inbound queue, so nothing remains to flush.
        let shouldFlushQueuedNotifications: Bool
        switch type {
        case .`init`:
            let registered = try orchestrator.registerAgentWindow(
                workspaceID: workspaceID, provider: .spaces, label: signalLabel, terminalTrackingID: sessionID,
                status: existingAgent?.status ?? .idle, eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys
            )
            // A restart-init on a previously exited row resets to idle (registerAgentWindow) and flushes;
            // a reconnect on a live busy row stays spinning/waiting and must not.
            shouldFlushQueuedNotifications = registered.status.leavesSubscriberIdle
        case .working:
            // The first `working` after `blocked` is the resume that follows a permission approval —
            // approvals fire no hook of their own, so this transition is also what withdraws any held
            // "is blocked" line for this child before a subscriber can receive stale misinformation.
            let resumedFromBlocked = existingAgent?.status == .waiting
            let updated = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspaceID, provider: .spaces, terminalTrackingID: sessionID, label: signalLabel, status: type.status,
                eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys)
            if resumedFromBlocked { try engine.childDidResumeWorking(agentSessionID: updated.id) }
            shouldFlushQueuedNotifications = updated.status.leavesSubscriberIdle
        case .blocked, .done:
            let updated = try orchestrator.updateAgentWindowStatus(
                workspaceID: workspaceID, provider: .spaces, terminalTrackingID: sessionID, label: signalLabel, status: type.status,
                eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys)
            if let transition = type.childNotificationTransition { try engine.childDidTransition(agent: updated, transition: transition) }
            shouldFlushQueuedNotifications = updated.status.leavesSubscriberIdle
        case .exit:
            guard let existingAgent else { return TerminalServiceProfileCommandResponse(message: "Agent exit ignored.") }
            // The exit routes through the orchestrator's finalization chokepoint, which renders/enqueues the
            // exited notice to subscribers before finalizing the row (delegating the delete-vs-`.exited`
            // decision to `handleAgentExit`), then tears down the signaling terminal's own subscriber state:
            // its now-undeliverable inbound queue and every outgoing watch edge it held. The signaling
            // terminal is a bare shell (or gone) after an exit, so nothing more is flushed or discarded here.
            try orchestrator.finalizeAgentRow(
                existingAgent, reason: .exited(eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys))
            shouldFlushQueuedNotifications = false
        }
        if shouldFlushQueuedNotifications {
            try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: sessionID)
        }
        postAgentEventNotification()
        return TerminalServiceProfileCommandResponse(message: "Agent \(type.rawValue) recorded.")
    }

    private nonisolated func matchingProfileAgentWindow(workspaceID: String, sessionID: String, orchestrator: WorkspaceOrchestrator) throws
        -> AgentWindowRecord?
    { try orchestrator.agentWindows(workspaceID: workspaceID).first { $0.provider == .spaces && $0.terminalTrackingID == sessionID } }

    /// Builds the notification engine bound to the real terminal-send path: delivery is the same
    /// `sendProfileTerminalInput` plumbing a `terminal send` uses, via `submitAgentNotificationLine` so
    /// the line submits reliably. A send failure throws, which the engine reads as the subscriber having
    /// vanished (dead session) and tears the watch edge down.
    private nonisolated func makeAgentNotificationEngine(orchestrator: WorkspaceOrchestrator) -> AgentNotificationEngine {
        AgentNotificationEngine(
            store: orchestrator.store,
            deliver: { [weak self] sessionID, line in
                guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                try self.submitAgentNotificationLine(sessionID: sessionID, line: line)
            },
            // The `(<kind>)` parenthetical is the detected agent kind (claude/codex/opencode) from the
            // child's persisted runtime state — the same identity `agentRuntimeKind` puts in an
            // orchestration row's `agent:` field, kept off the launch title so the label is not
            // duplicated (`smoke-hello (smoke-hello)`). Reads disk, so it works at exit time too (the row
            // is rendered before deletion).
            resolveAgentKind: { agent in
                guard let terminalSessionID = agent.terminalTrackingID, let paths = try? TerminalSessionPaths.forSession(id: terminalSessionID),
                    let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
                else { return nil }
                return runtimeState.foregroundDetectedAgentKind?.displayLabel
            }, logError: { writeStandardError($0) })
    }

    /// Delivers a rendered notification line into a subscriber terminal and submits it with a single
    /// `appendNewline: true` send. Submit-safety lives at the session-host send chokepoint
    /// (`GhosttyEmbeddedSessionHost`/`GhosttyLinuxHeadlessSessionCore`): for a text payload with
    /// `appendNewline` it writes the text and the carriage return as separate spaced writes, so an agent
    /// TUI reads the CR as a distinct Enter keystroke and submits the line rather than treating the whole
    /// burst as an unsubmitted paste. This helper is the shared chokepoint used by the local notification
    /// engine wiring and the cross-device `RemoteAgentWatchService` so both submit identically.
    ///
    /// The send reaches a live in-process session core through the terminal engine actor
    /// (`sendProfileTerminalControlOffMain` → `TerminalEngineActor.runSynchronously`), which the main
    /// actor must never synchronously wait on (see `TerminalEngineActor`'s one-way rule). Callers already
    /// off the main actor (the daemon's device-runtime reconcilers on detached tasks) send directly and
    /// receive a throw when the subscriber has vanished. A main-actor caller (local agent-row finalization,
    /// `RemoteAgentWatchService` delivery) instead DEFERS the send onto `agentNotificationDeliveryQueue`:
    /// the enqueue returns immediately so the main actor never blocks on the engine, and the queued block
    /// performs the send off-main. The queue is serial, so notifications keep their submission order across
    /// sessions; per-session ordering additionally holds via each session's `TerminalControlInputSequencer`
    /// at the send chokepoint. Because a deferred send is fire-and-forget, a vanished subscriber discovered
    /// on the main path is logged rather than propagated back to `AgentNotificationEngine.deliverOrQueue`,
    /// so that path's synchronous dead-subscriber teardown (`subscriberDidExit`) is skipped for the failed
    /// send; the subscriber's edges are still torn down through its own later exit finalization.
    ///
    /// Accepted risk (deliberate, not a bug): for a main-originated send the enqueue itself is the ack —
    /// `AgentNotificationEngine.deliverOrQueue` treats the deferred submit as delivered and does not learn
    /// of a later send failure. The only consequence of that skipped signal is the dead-subscriber cleanup
    /// above, which self-heals when the vanished subscriber runs its own exit finalization
    /// (`subscriberDidExit`). The one remaining loss window — lines enqueued but not yet flushed when the
    /// daemon exec-hands-off — is bounded by `performExecHandoff`'s pre-quiesce drain of this queue, so an
    /// already-enqueued send flushes through a live core before the image is replaced.
    private nonisolated func submitAgentNotificationLine(sessionID: String, line: String) throws {
        if Thread.isMainThread {
            agentNotificationDeliveryQueue.async { [weak self] in
                guard let self else { return }
                do { try self.deliverAgentNotificationLineOffMain(sessionID: sessionID, line: line) } catch {
                    writeStandardError("spacesd agent_notification_delivery_error session=\(sessionID) error=\(error)\n")
                }
            }
            return
        }
        try deliverAgentNotificationLineOffMain(sessionID: sessionID, line: line)
    }

    /// The off-main send backing `submitAgentNotificationLine`: builds the single `appendNewline: true`
    /// `terminal send` and drives the engine through the off-main control path. Must run off the main
    /// actor (it calls `TerminalEngineActor.runSynchronously`). Throws when the send fails, which the
    /// direct (off-main) caller reads as the subscriber having vanished.
    private nonisolated func deliverAgentNotificationLineOffMain(sessionID: String, line: String) throws {
        let request = TerminalControlRequest(
            command: .send(TerminalControlSendPayload(text: line, bytes: nil, clientID: nil, ownerEpoch: nil, appendNewline: true)))
        let controlResponse = try sendProfileTerminalControlOffMain(sessionID: sessionID, request: request)
        guard controlResponse.ok else { throw SpacesRuntimeError.invalidArgument(message: controlResponse.message) }
    }

    private nonisolated func profileAgentRuntimeLabel(sessionID: String) -> String? {
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

    /// Spawns a coding-agent terminal session after gating the command against the supported-agent set:
    /// the command must launch a supported coding agent (claude, codex, or opencode) so spawn readiness
    /// knows which foreground kind to await. Hooks are not a prerequisite — readiness is
    /// foreground-detection-based, polled CLI-side against the session's terminal id.
    private nonisolated func spawnProfileAgentSession(_ payload: TerminalServiceAgentSpawnPayload, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        do { _ = try AgentSpawnCommandGate.resolveSpawnableAgent(command: payload.command) } catch let error as AgentSpawnCommandGate.GateError {
            throw SpacesRuntimeError.invalidArgument(message: error.errorDescription ?? "Agent spawn command is not supported.")
        }
        let workspaceID = try orchestrator.resolveWorkspaceIDForTerminalCommand(explicitWorkspaceID: payload.workspaceID, cwd: payload.cwd)
        let session = try orchestrator.createWorkspaceAgentSession(workspaceID: workspaceID, command: payload.command, title: payload.title)
        return TerminalServiceProfileCommandResponse(message: "Started agent session.", terminalSession: session)
    }

    /// Terminates a coding-agent session addressed by its terminal session id. The orchestrator owns
    /// the flow (`killAgentSession`): a hook-signaled child stops through the coding-agent stop path
    /// with its subscribers told it exited first, and a not-yet-signaled session is terminated only
    /// when it was launched as a coding agent. A session that is neither is a loud error.
    private nonisolated func killProfileAgentSession(_ sessionID: String, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        guard try orchestrator.killAgentSession(terminalSessionID: sessionID)
        else { throw SpacesRuntimeError.invalidArgument(message: "No agent session for terminal \(sessionID).") }
        return TerminalServiceProfileCommandResponse(message: "Killed agent session \(sessionID).")
    }

    /// Persists a subscription edge. Same-device: validate (in the orchestrator) that the watched agent
    /// exists and the edge keeps the subscription graph acyclic — a self-edge or any cycle-closing edge is
    /// a loud error, since a cycle would let injected notifications chase each other around a loop.
    /// A device-qualified request naming *this* machine (`deviceID == localDeviceID`) is normalized onto
    /// the same-device path: it is a local watch expressed with the local device's id or name, so it is
    /// validated like any local watch rather than recorded as a cross-device edge (which skips cycle
    /// detection). The payload shape differs — on the device-qualified path `agentSessionID` is the
    /// child's terminal session id — so the orchestrator resolves the agent row from that terminal id.
    /// Cross-device (`deviceID` set to a remote device): validate the device is paired and the child has
    /// an agent session on it (one `listAgentSessions` call), then record a cross-device edge keyed on the
    /// child's terminal session id and nudge the watch service to open/refresh that device's stream.
    /// Cross-device cycle detection is impossible locally — the remote's own subscription graph is not
    /// queryable — so only the same-device acyclic invariant is enforced.
    private func subscribeProfileAgentSession(_ payload: TerminalServiceAgentSubscriptionPayload, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        if let deviceID = payload.deviceID {
            if deviceID == SpacesPairedDeviceRecord.localDeviceID {
                try orchestrator.subscribeAgentWatch(
                    subscriberTerminalSessionID: payload.subscriberTerminalSessionID, childTerminalSessionID: payload.agentSessionID)
                return TerminalServiceProfileCommandResponse(message: "Subscribed to agent session.")
            }
            let clientApp = Self.daemonDeviceClientApp()
            let validatedRow = try RemoteAgentSubscriptionValidation.validate(
                deviceID: deviceID, childTerminalSessionID: payload.agentSessionID,
                resolveDevice: { try SpacesClientDatabase.defaultDatabase().pairedDevice(id: $0) }, deviceName: { $0.name },
                fetchRows: { try SpacesDeviceClient.listAgentSessions(sessionID: payload.agentSessionID, device: $0, clientApp: clientApp) })
            try orchestrator.store.insertAgentRemoteSubscription(
                subscriberTerminalSessionID: payload.subscriberTerminalSessionID, deviceID: deviceID, agentSessionID: payload.agentSessionID,
                createdAt: nowISO8601())
            // Seed the watch baseline with the row validation just fetched *before* the stream's first
            // listing can land, so a transition — or an exit — in the connect gap (seconds-to-minutes on
            // a cold stream) is diffed against a real prior state instead of being silently absorbed.
            // Seed before reconcile: both run synchronously on the main actor, so the seed is in place
            // before any pull's continuation resumes (see `seedBaseline`), and reconcile then opens or
            // refreshes the stream that pulls that first listing.
            remoteAgentWatchService?.seedBaseline(
                deviceID: deviceID, childTerminalSessionID: payload.agentSessionID, row: validatedRow)
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

    private nonisolated func postAgentEventNotification() {
        #if os(macOS)
            try? IPCNotification.post(IPCNotification.agentEventFired)
        #endif
    }

    /// RPC `.control` handler. A live in-process core handles the request in a narrow main hop
    /// (`liveControlResponse` touches Ghostty); when the session is not live, the control-socket round-trip
    /// (5s timeout) and any session-state read run off the main actor on the transport thread.
    private nonisolated func handleTerminalControlOffMain(_ request: TerminalServiceControlCommandRequest) -> TerminalServiceResponse {
        guard !livenessState.snapshot().handoffInProgress else { return Self.handoffInProgressResponse() }
        let sessionID = request.sessionID
        let controlRequest = request.controlRequest
        let command = controlRequest.commandValue
        guard !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument) }
        if command.requiresOwnerClientID, controlRequest.clientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return TerminalServiceResponse(ok: false, message: "Missing device client ID.", errorCode: .invalidArgument)
        }
        if let liveResponse = TerminalEngineActor.runSynchronously({
            self.liveControlResponse(sessionID: sessionID, controlRequest: controlRequest, includeSessionState: command.includesSessionStateOnSuccess)
        }) {
            return liveResponse
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
            // The session is not live, so any state read falls through to the persisted/socket path off main —
            // never back onto the main actor.
            let sessionState = response.ok && command.includesSessionStateOnSuccess ? try? loadPersistedOrSocketState(sessionID: sessionID) : nil
            return TerminalServiceResponse(
                ok: response.ok, message: response.message, errorCode: response.errorCode, sessionState: sessionState, controlResponse: response)
        } catch { return Self.failureResponse(error) }
    }

    /// The live in-process core control response, or nil when there is no live core (the off-main handler
    /// then falls back to the control socket). Touches `sessionCores`/Ghostty, so it is isolated to the
    /// terminal engine actor. The session-state payload is built inline from the same `liveCore` handle
    /// rather than by delegating to a shared main-actor helper: this function already runs on the engine
    /// (reached via `TerminalEngineActor.runSynchronously` from the transport thread), and a live core's
    /// current state is always `liveCore.currentRemoteStatePayload` — the same fact a main-actor helper
    /// would have to hop back onto the engine to read. Building it here avoids that round trip, which
    /// would otherwise nest an engine→main hop inside this already-engine-isolated call and deadlock
    /// against the engine's own serial queue.
    @TerminalEngineActor private func liveControlResponse(sessionID: String, controlRequest: TerminalControlRequest, includeSessionState: Bool)
        -> TerminalServiceResponse?
    {
        guard let liveCore = sessionCores[sessionID] else { return nil }
        let response = liveCore.handleControlRequest(controlRequest)
        let sessionState =
            response.ok && includeSessionState ? liveCore.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.stateChange) : nil
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

    /// RPC `.terminate` handler, run off the main actor. `terminateSession` is engine-isolated (Step 1),
    /// so this hops onto the engine via `TerminalEngineActor.runSynchronously` from the transport thread —
    /// safe because the calling context is never the main actor here (`dispatch` calls this directly on
    /// `serverQueue`, and `handle`'s on-main fallback also routes through this same nonisolated function
    /// rather than calling `terminateSession` inline).
    private nonisolated func terminateSessionOffMain(_ payload: TerminalServiceSessionRequest) -> TerminalServiceResponse {
        guard !payload.sessionID.isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument)
        }
        return TerminalEngineActor.runSynchronously {
            // Re-check the handoff barrier on the engine actor, the same mutation-boundary guard
            // `startSessionCoreResponse` applies to create. `performExecHandoff` sets `handoffInProgress`
            // on the main actor BEFORE its engine-actor snapshot of `sessionCores`, and this hop is
            // serialized against that snapshot/quiesce loop on the one engine queue: any terminate that
            // reaches the engine after the snapshot therefore sees the flag set and is rejected, so a
            // request accepted just before handoff can never remove/terminate a core the quiesce loop has
            // already snapshotted (which would leave `quiesceForHandoff` building a record around a closed
            // resource). A terminate that wins the race and runs before the snapshot is harmless — the
            // snapshot then simply excludes the core it removed. The internal handoff/shutdown/resume paths
            // call `terminateSession` directly, bypassing this RPC-only barrier.
            guard !self.handoffInProgress else { return Self.handoffInProgressResponse() }
            return self.terminateSession(id: payload.sessionID)
        }
    }

    @TerminalEngineActor private func terminateSession(id sessionID: String) -> TerminalServiceResponse {
        do {
            if let sessionCore = sessionCores.removeValue(forKey: sessionID) {
                sessionCore.terminate()
                // The exited-state write is asynchronous on the core's persistence queue, so this
                // best-effort summary can still read `.running` for a moment after terminate(). `ok` and the
                // message are the authoritative stop acknowledgment; consumers of durable state converge via
                // the runtime-state notification the queue posts after the exited write commits.
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

    @TerminalEngineActor private func sessionCore(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> GhosttyEmbeddedSessionCore {
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

    /// `nonisolated`: reads only `TerminalSessionPersistence` (disk), so it runs correctly regardless of
    /// caller — including `sessionSummaryAfterStart` on a transport thread and `terminateSession` on the
    /// engine actor.
    private nonisolated func sessionSummary(for sessionID: String) throws -> TerminalServiceSessionSummary {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let launchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        return try summary(for: launchConfiguration, paths: paths)
    }

    /// Polls disk for the session's first runtime-state write after `startIfNeeded()` returns. Only reads
    /// via `TerminalSessionPersistence`/`sessionSummary`, so it stays `nonisolated` and runs on whichever
    /// transport thread drove the create (`createSessionOffMain`, or `launchBuiltInTerminalSession`'s
    /// caller) — never on the engine actor (no run loop there, and it would stall every other live
    /// session's PTY I/O for the length of the poll) and never on the main actor (would stall Ghostty's
    /// ticks the same way). A plain sleep replaces the old `RunLoop.current.run(until:)` spin, which
    /// required a run loop this caller may not have.
    private nonisolated func sessionSummaryAfterStart(for sessionID: String) throws -> TerminalServiceSessionSummary {
        let deadline = Date().addingTimeInterval(1)
        var lastError: (any Error)?
        repeat {
            do { return try sessionSummary(for: sessionID) } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
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

    private nonisolated func summary(for launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) throws
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

    /// Off-main state read for the `.state` handler. Only the live in-process core lookup is a narrow
    /// engine hop; the disk reads and the unix-socket connect+read (2s timeout) run on the transport thread.
    private nonisolated func loadCurrentStateOffMain(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
        if let payload = TerminalEngineActor.runSynchronously({ self.liveCoreRemoteStatePayload(sessionID: sessionID) }) { return payload }
        return try loadPersistedOrSocketState(sessionID: sessionID)
    }

    /// The live in-process core's current state payload, or nil when there is no live core (or it has no
    /// payload yet) — either way the caller falls back to the persisted/socket read. Touches `sessionCores`,
    /// so it is isolated to the terminal engine actor.
    @TerminalEngineActor private func liveCoreRemoteStatePayload(sessionID: String) -> GhosttyRemoteSessionStatePayload? {
        guard let liveCore = sessionCores[sessionID] else { return nil }
        return liveCore.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.stateChange)
    }

    /// The non-live state read: persisted final/ended state, or a live unix-socket connect+read against the
    /// session's subscription socket (2s timeout). No main-actor state, so it is `nonisolated` and runs on
    /// the transport thread for the off-main `.state`/`.control` handlers.
    private nonisolated func loadPersistedOrSocketState(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
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

    private nonisolated func endedStatePayload(sessionID: String, paths: TerminalSessionPaths, runtimeState: TerminalSessionRuntimeState) throws
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

    private nonisolated func connectUnixSocket(path: String) throws -> Int32 {
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

    private nonisolated func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
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

    private nonisolated func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        #if canImport(Darwin)
            var yes: Int32 = 1
            guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        #else
            _ = fileDescriptor
        #endif
    }

    private nonisolated var streamSocketType: Int32 {
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
            // `reapInactiveSessions` is engine-isolated (Step 1), so this hops onto the engine actor
            // directly rather than the main actor the timer callback fires on.
            Task { @TerminalEngineActor [weak self] in self?.reapInactiveSessions() }
        }
        if let lifecycleTimer { RunLoop.main.add(lifecycleTimer, forMode: .common) }
    }

    @TerminalEngineActor private func reapInactiveSessions() {
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

    private nonisolated static func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private nonisolated static func isLive(_ runtimeState: TerminalSessionRuntimeState) -> Bool {
        runtimeState.state == .starting || runtimeState.state == .running
    }

    private nonisolated static func errorMessage(_ error: any Error) -> String {
        if let localizedError = error as? any LocalizedError, let description = localizedError.errorDescription { return description }
        return String(describing: error)
    }

    /// Machine-readable failure category for a thrown error at the terminal-service flatten points,
    /// mirroring the `WorkspaceError` mapping used by the Device API server so both wire surfaces
    /// classify the same failures identically.
    private nonisolated static func errorCode(_ error: any Error) -> SpacesDeviceErrorCode {
        if let workspaceError = error as? WorkspaceError {
            switch workspaceError {
            case .missingProject, .missingWorkspace, .missingTrackedWindow: return .notFound
            case .invalidArgument, .invalidWorkspace, .projectAlreadyExists, .workspaceAlreadyExists: return .invalidArgument
            case .gitCommandFailed, .dependencyMissing, .configError, .databaseMigrationFailed: return .internalError
            case .daemonHandoffInProgress: return .shuttingDown
            }
        }
        if case SpacesRuntimeError.invalidArgument = error { return .invalidArgument }
        if error is DecodingError { return .invalidArgument }
        return .internalError
    }

    /// Flattens a thrown error into a failure response, pairing the localized message with its
    /// machine-readable category. Used at handler catch sites so clients can branch on the code.
    private nonisolated static func failureResponse(_ error: any Error) -> TerminalServiceResponse {
        TerminalServiceResponse(ok: false, message: errorMessage(error), errorCode: errorCode(error))
    }

    private nonisolated static func shutdownSocket(_ fileDescriptor: Int32) {
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
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil,
        agentSessionKiller: (@Sendable (String) throws -> Bool)? = nil, onRestartRequested: (@Sendable () -> Void)? = nil
    ) {
        #if canImport(spacesdeviceapi)
            supervisor = SpacesDeviceAPISupervisor(
                builtInTerminalSessionTerminator: builtInTerminalSessionTerminator, builtInTerminalSessionLauncher: builtInTerminalSessionLauncher,
                agentSessionKiller: agentSessionKiller, onRestartRequested: onRestartRequested)
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

        func applicationWillTerminate(_ notification: Notification) {
            // OS-driven termination (e.g. logout). `shutdown()` is async now, and AppKit does not await it,
            // so without waiting here the process could exit before the per-core transcript flush and
            // attachment finalization complete. Drive it to completion, but never block this thread (the
            // main actor's executor) on the semaphore while the `Task { @MainActor }` shutdown runs — its
            // main-actor continuations would deadlock against the blocked executor. Instead pump the main
            // run loop (legal inside applicationWillTerminate), which services the main-actor executor, so
            // the shutdown task's continuations run and it signals. `shutdown()` awaits the engine actor
            // only asynchronously (no engine→main sync wait), so this is not the forbidden main→engine
            // bridge. Bound the pump so a stuck cleanup cannot hang logout.
            let shutdownComplete = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await controller.shutdown()
                shutdownComplete.signal()
            }
            let deadline = Date(timeIntervalSinceNow: 5)
            while shutdownComplete.wait(timeout: .now()) == .timedOut, Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
        }
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
                // The run loop has returned (process teardown); drive the async shutdown to completion
                // before returning. This thread IS the main actor's executor, so it must NOT block on the
                // semaphore while a `Task { @MainActor }` shutdown runs — the task's main-actor
                // continuations would target this blocked executor and never resume (a permanent hang).
                // Instead keep pumping the run loop, which services the main-actor executor exactly as it
                // does for `controller.start()` above, until the async shutdown signals completion. The
                // shutdown only awaits the engine actor asynchronously (no engine→main sync wait), so this
                // is not the forbidden main→engine bridge.
                let shutdownComplete = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    await controller.shutdown()
                    shutdownComplete.signal()
                }
                while shutdownComplete.wait(timeout: .now()) == .timedOut {
                    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
                }
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
                        await controller.shutdown()
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
