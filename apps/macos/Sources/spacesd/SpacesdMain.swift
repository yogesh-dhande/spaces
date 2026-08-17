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
    /// is already rejecting every real request with `.handingOff` — a client polling liveness would
    /// see "ok" and adopt a daemon that refuses everything else.
    private var handoffInProgress = false
    /// Mirrors the main actor's `shutdownInProgress` flag. `shutdown()` sets it BEFORE it stops shared
    /// services and takes its engine-actor snapshot of `sessionCores`, so every session-create admission
    /// gate can refuse after that point — otherwise a `.create` accepted onto the serial work queue just
    /// before shutdown could spend up to 120s in git prep and then insert a core AFTER the shutdown
    /// snapshot, one `shutdown()` never terminates or drains and `exit(0)` abandons (a leaked
    /// HUP-immune child plus a `.running` row that lingers until the next daemon start's stale-session
    /// repair). Monotonic: the process exits, so it is never cleared.
    private var shutdownInProgress = false
    /// The host string the Device API is configured to bind on (typically the wildcard address),
    /// cached once at startup (see `startSharedServices()`). This setting doesn't change during a
    /// daemon's lifetime, unlike the *live addresses* it resolves to (e.g. Tailscale connecting or
    /// disconnecting), which is why only the setting is cached — `currentDeviceAPIAddresses()` still
    /// recomputes the live interface walk fresh on every call.
    private var deviceAPIBoundHost: String?

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

    func storeShutdownInProgress(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        shutdownInProgress = value
    }

    func storeDeviceAPIBoundHost(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        deviceAPIBoundHost = value
    }

    func snapshot() -> (sessionCount: Int, certificateFingerprint: String?, handoffInProgress: Bool, shutdownInProgress: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (sessionCount, certificateFingerprint, handoffInProgress, shutdownInProgress)
    }

    /// The addresses this daemon is currently reachable at, in the same order a pairing link would
    /// advertise them (LAN first, then Tailscale) — see `TerminalServiceDaemonStatus.deviceAPIAddresses`.
    /// Computed fresh on every call: the interface walk is a cheap syscall with no disk or network I/O,
    /// so recomputing it here (rather than caching it alongside `deviceAPIBoundHost`) is what lets this
    /// off-actor fast path reflect a network change (e.g. Tailscale connecting) without ever touching
    /// the main actor. Returns `[]` — "reported nothing" — before the bound host is learned (a ping that
    /// races daemon startup) or when spacesdeviceapi is unavailable on this platform.
    func currentDeviceAPIAddresses() -> [String] {
        lock.lock()
        let boundHost = deviceAPIBoundHost
        lock.unlock()
        #if canImport(spacesdeviceapi)
            guard let boundHost else { return [] }
            return SpacesDeviceAPINetworkInterfaces.pairingLinkHosts(boundHost: boundHost)
        #else
            return []
        #endif
    }

    /// Admission decision consulted by EVERY command gate in the daemon: `handle(_:)`'s first line, every
    /// off-main handler (`runWorkspaceCommandOffMain`, `prepareWorkspaceOffMain`, `terminalSendOffMain`,
    /// the control/state/terminate/profile-command handlers), the session-CREATING gates
    /// (`createSessionOffMain`/`createSession`/`startSessionCoreResponse`), and the liveness `.ping`
    /// responder (`pingResponse`). Returns the rejection response to send, or `nil` to admit.
    ///
    /// An in-progress exec handoff and an in-progress shutdown both mean "refuse the request" to every
    /// command gate, so admission is folded into one predicate here rather than replicated per guard: a
    /// future third teardown reason is added once, on this function, instead of risking one guard
    /// remembering it and several others not (see issue #325, which is exactly that drift —
    /// `shutdownInProgress` originally fed only the session-create gate while `handoffInProgress` reached
    /// every command).
    ///
    /// The two latches carry distinct wire codes, though, because they mean different things to a
    /// *waiting* caller: `.handingOff` tells `TerminalService.isTransitionalHandoffPing` that a successor
    /// is about to rebind the socket, worth waiting `handoffTransitionTimeout` (15s) for; `.shuttingDown`
    /// tells it no successor is coming, so it must fall straight through to spawning a fresh daemon
    /// instead of stalling out that same 15s for nothing (issue #334's sibling problem, on the local
    /// transport). Every other consumer of this response treats both codes identically ("this daemon is
    /// going away, refuse the request") and needs no change — see `LocalDaemonReachabilityProbe`, which
    /// treats any non-`ok` ping as "did not answer" without inspecting the code at all.
    ///
    /// The session-CREATE family is the one caller that also re-checks this on the terminal engine actor
    /// after its own git-prep/off-actor early-out — see `startSessionCoreResponse`'s doc for why create
    /// alone needs a second, later check at the true mutation boundary.
    ///
    /// Centralized on the box that owns both flags so "may this daemon still do work" has one source of
    /// truth, testable without standing up the (private) controller.
    func teardownRejection() -> TerminalServiceResponse? {
        let snapshot = snapshot()
        if snapshot.shutdownInProgress {
            return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .shuttingDown, servicePID: getpid())
        }
        if snapshot.handoffInProgress {
            return TerminalServiceResponse(
                ok: false, message: "spacesd is handing off to an updated daemon.", errorCode: .handingOff, servicePID: getpid())
        }
        return nil
    }

    /// Builds the liveness `.ping` response entirely off the main actor. It carries the same
    /// `TerminalServiceDaemonStatus` shape as the controller's `daemonStatus()` (version, installed
    /// version, fingerprint, and an eventually-consistent session count) so wire-compatibility
    /// negotiation works identically, but it never blocks on the main actor — the point of the fast
    /// path. While either teardown latch is set it instead returns `teardownRejection()`'s answer
    /// verbatim, mirroring `handle(_:)`'s own rejection exactly, so a ping never reports the daemon live
    /// while every other request is being turned away.
    func pingResponse() -> TerminalServiceResponse {
        if let rejection = teardownRejection() { return rejection }
        let snapshot = snapshot()
        let status = TerminalServiceDaemonStatus(
            version: AppVersion.current, installedVersion: InstalledSpacesVersion.current(), certificateFingerprint: snapshot.certificateFingerprint,
            activeSessionCount: snapshot.sessionCount, protocolVersion: SpacesWireProtocol.version,
            timeZoneIdentifier: TerminalServiceDaemonStatus.currentTimeZoneIdentifier, deviceAPIAddresses: currentDeviceAPIAddresses())
        return TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid(), daemonStatus: status)
    }
}

/// Lock-guarded holder for the one live `AutomationService`, shared between the main actor (which creates
/// and clears it across the service's lifecycle) and the off-main automation handlers — the profile-command
/// `automationCommandOffMain` and the Device API `AutomationOperations` — that resolve it from the transport
/// thread. The service is queue-confined and must never be entered synchronously from the main actor (see
/// `AutomationService`), so its handlers run off main and read the reference through this box rather than
/// through the main-actor `automationService` property.
final class AutomationServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var service: AutomationService?
    func get() -> AutomationService? {
        lock.lock()
        defer { lock.unlock() }
        return service
    }
    func set(_ newValue: AutomationService?) {
        lock.lock()
        service = newValue
        lock.unlock()
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
        // `.terminalList` reaches `listSessionsOffMain`, which merges in-memory core summaries via
        // `TerminalEngineActor.runSynchronously`, so it belongs in this group too.
        case .terminalSend, .terminalCommand, .agentSpawn, .workspaceStart, .workspaceStop, .workspaceRestart, .agentKill, .agentSignal,
            .terminalList:
            true
        // Every automation command is peeled off main for two reasons. First, trigger/cancel/end-agents/delete
        // reach the automation executor's launcher/terminator call graph directly (starting or tearing down a
        // run's terminal/agent session), which hops the engine actor. Second, ALL of them — create/update/list/
        // runs-list included — enter the queue-confined `AutomationService`, whose serial queue can be mid-tick
        // behind an engine→main hop; bridging any automation command onto the main actor could block main behind
        // that hop (a transitive one-way-rule violation). So the whole family runs on the transport thread.
        case .automationCreate, .automationUpdate, .automationDelete, .automationList, .automationRunsList, .automationTrigger, .automationRunCancel,
            .automationEndAgents:
            true
        // Engine-free: pure store/disk reads and metadata writes with no launcher/terminator reach.
        case .terminalTail, .projectList, .workspaceList, .workspaceCreate, .agentList, .agentAnnotate, .agentSubscribe, .agentUnsubscribe,
            .agentConsumePendingEvents:
            false
        }
    }
}

/// Maps a thrown error to its machine-readable `SpacesDeviceErrorCode` for the profile (terminal-service)
/// transport. Factored out of the daemon controller so it is unit-testable and stays byte-for-byte aligned
/// with the Device API server's `SpacesDeviceAPIServer.errorCode(for:)`: both wire surfaces must classify
/// the same failure identically, so a client sees one code for one cause regardless of transport.
enum SpacesDaemonErrorClassification {
    static func errorCode(_ error: any Error) -> SpacesDeviceErrorCode {
        if let workspaceError = error as? WorkspaceError {
            switch workspaceError {
            case .missingProject, .missingWorkspace, .missingTrackedWindow: return .notFound
            case .invalidArgument, .invalidWorkspace, .projectAlreadyExists, .workspaceAlreadyExists: return .invalidArgument
            case .gitCommandFailed, .gitCommandTimedOut, .dependencyMissing, .configError, .databaseMigrationFailed: return .internalError
            // Only ever thrown by the handoff-only admission guard (`Orchestrator`'s
            // `daemonHandoffInProgress` predicate) — never by a shutdown — so it always carries the
            // handoff code, not the generic teardown one.
            case .daemonHandoffInProgress: return .handingOff
            }
        }
        if case SpacesRuntimeError.invalidArgument = error { return .invalidArgument }
        // Automation boundary rejections (bad cron, empty field, unknown enum, missing automation/run) are
        // well-formed-request client errors, so they surface as invalidArgument with their descriptive
        // message rather than a generic internal error.
        if error is AutomationValidationError { return .invalidArgument }
        if error is AutomationCronScheduleError { return .invalidArgument }
        if error is DecodingError { return .invalidArgument }
        return .internalError
    }
}

@MainActor private final class SpacesDaemonController {
    private static let ownerGatedTerminalCommands: Set<String> = ["send", "key", "clearScreen", "resize", "scroll", "mouseButton"]
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
    /// Monotonic "the daemon is shutting down" flag, backed by `livenessState` for the same reason as
    /// `handoffInProgress`: it is read from the transport thread (`createSessionOffMain`'s early-out) and
    /// the engine actor (`startSessionCoreResponse`'s create-admission authority), and set from the main
    /// actor (`shutdown()`). `shutdown()` sets it BEFORE stopping shared services and taking its engine
    /// snapshot of `sessionCores`, so any create that lands on the engine after the snapshot observes it
    /// and is refused rather than inserting an orphaned core `exit(0)` would abandon. Never cleared —
    /// `shutdownAndExit` follows `shutdown()` with `exit(0)`.
    private nonisolated var shutdownInProgress: Bool {
        get { livenessState.snapshot().shutdownInProgress }
        set { livenessState.storeShutdownInProgress(newValue) }
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
    /// Throttles the ended-session garbage-collection sweep to a coarse cadence: the lifecycle timer fires
    /// every second for attachment reaping, but collecting removed sessions scans every known session and
    /// need not run that often. `nil` until the first sweep.
    /// Engine-isolated: touched only from the garbage-collection sweep (which reads `sessionCores`) and
    /// seeded on the engine actor at lifecycle-timer start.
    @TerminalEngineActor private var lastSessionGarbageCollectionAt: Date?
    private nonisolated static let sessionGarbageCollectionInterval: TimeInterval = 600
    #if os(Linux)
        private let databaseChangeSignalQueue = DispatchQueue(label: "spaces.database-change.signal")
    #endif
    private var worktreeDiscoveryService: WorktreeDiscoveryService?
    private var terminalForegroundAgentReconciler: TerminalForegroundAgentReconciler?
    private var remoteAgentWatchService: RemoteAgentWatchService?
    private var automationService: AutomationService?
    /// The same live `AutomationService` as `automationService`, held in a lock-guarded box so the off-main
    /// automation handlers (profile-command `automationCommandOffMain`, Device API `AutomationOperations`)
    /// can resolve it from the transport thread without touching the main actor. Set and cleared alongside
    /// `automationService` in the service lifecycle.
    private nonisolated let automationServiceBox = AutomationServiceBox()
    private var automationTimer: Timer?
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
        },
        // The Device API automation handlers route through these closures to the one live queue-confined
        // `AutomationService`, resolved from the lock-guarded box off the main actor, so a remote automation
        // command drives the exact scheduler state a local profile command would — the "one implementation,
        // two transports" seam. Both closures run on the Device API connection queue (never main), and the
        // service serializes internally, so calling it directly is deadlock-safe (the one-way rule).
        automationOperations: Self.makeAutomationOperations { [weak self] in
            guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
            guard let service = self.automationServiceBox.get() else {
                throw SpacesRuntimeError.invalidArgument(message: "Automations are unavailable on this daemon.")
            }
            return service
        }, onRestartRequested: { [weak self] in Task { @MainActor in self?.requestDaemonRestart() } },
        // Same queue guarantee as the closures above (the Device API's own connection-handling queue, never
        // main), so the engine hop is deadlock-safe. Lets a Device API `.state` read — one per pane attach —
        // be answered from the live core instead of dialing that core's own subscription socket.
        liveTerminalSessionStateProvider: { [weak self] sessionID in
            TerminalEngineActor.runSynchronously { self?.liveCoreOneShotStatePayload(sessionID: sessionID) }
        },
        // Same queue guarantee again: runs on the Device API's own queues, never main, so the engine hop
        // is deadlock-safe. In-memory cores are the authority for a session's existence (lifecycle rows
        // are write-behind), so the overview merges these entries to keep a freshly created session
        // visible before its rows commit, matching listSessionsOffMain's merge for the CLI list.
        liveInMemoryTerminalSessionsProvider: { [weak self] in
            TerminalEngineActor.runSynchronously { self?.sessionCores.values.compactMap { $0.inMemoryCatalogEntry() } } ?? []
        })
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
        // First, before anything concurrent exists: the trim reads, truncates, and rewrites the daemon's
        // own launchd-redirected stdout/stderr files, and that sequence is only atomic against other
        // writers by not having any. Here no server, Device API, or timer has started, so nothing else
        // can append mid-trim; moved any later, a request handler's diagnostic write could land between
        // the tail snapshot and the rewrite and be lost.
        #if os(macOS)
            trimOversizedRuntimeLogs()
        #endif
        // Startup is the one lifecycle transition NOT excluded against teardown (issue #391). A signal
        // landing in the adoption suspension below runs `shutdownOnce()` concurrently, so cores adopted
        // after its engine snapshot escape termination and `startSharedServices()` can restart services
        // the stop phase already stopped. Deferred rather than fixed here because both residues self-heal:
        // an unterminated session's row falls to `recoverStaleSessions`' dead-pid branch at the next
        // daemon start, and an orphaned Caddy is adopted through its live admin socket by the next
        // daemon's `ensureRunning`. The window is also only the successor image's post-handoff adoption —
        // `resumeSessionsFromHandoffIfNeeded` returns without suspending on a fresh boot.
        let adoptedSessionIDs = try await resumeSessionsFromHandoffIfNeeded()
        // Reconcile stale runtime rows AFTER handoff adoption so the adopted sessions are exempt: the
        // sweep repairs any live-state row that claims this pid but was not adopted, which is the backstop
        // for a predecessor's exited-state write that was dropped across `execv` (see recoverStaleSessions).
        try recoverStaleSessions(adoptedSessionIDs: adoptedSessionIDs)
        try startSharedServices()
    }

    /// Starts the shared (non-per-session) services. Shared by the normal `start()` tail and the
    /// failed-`execv` fallback, which stopped them in `stopSharedServices()` before quiescing.
    private func startSharedServices() throws {
        // Seed the off-actor liveness snapshot before the socket accepts connections so the very first
        // `.ping` already carries this daemon's identity. Runs on both fresh start and handoff resume.
        livenessState.storeFingerprint(daemonIdentityFingerprint)
        // Seed the Device API's configured bind host so `livenessState.currentDeviceAPIAddresses()` can
        // report real addresses from its very first call. Read directly from the settings store (not
        // through `deviceAPISupervisor`, which is main-actor-isolated) because this value must be usable
        // from the liveness ping's off-actor fast path; it does not require the Device API server to be
        // running yet, only its configured host.
        #if canImport(spacesdeviceapi)
            livenessState.storeDeviceAPIBoundHost((try? SpacesDeviceAPISettingsStore().loadOrCreate())?.host)
        #endif
        // The session count is already mirrored into `livenessState` by `sessionCores.didSet` on every
        // mutation (including the handoff-resume inserts that ran before this), so there is nothing to seed
        // here — and reading `sessionCores` from this main-actor context would be an illegal sync wait on
        // the engine actor.
        // Installed before either server accepts a request: the orchestrator a request builds resolves
        // these overrides at construction time, so a request that lands before the install would run
        // against the no-op defaults (a nil foreground sample reads as a bare shell, a handoff reads as
        // not in progress).
        installProcessWideOrchestratorHooks()
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
        guard let databasePath = try? DatabaseLocator.defaultPath() else {
            writeStandardError("spacesd device_runtime_error error=could not resolve database path\n")
            return
        }
        sweepOrphanedWorkspaceSetupDirectories(databasePath: databasePath)
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
        startAutomationService()
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

    /// Starts the scheduled-automation scheduler/executor: reconciles runs missed while the daemon was
    /// down, then drives its poll-based `tick` from a periodic timer. The command's PATH is seeded with the
    /// running daemon's own binary directory so an automation's `spaces` invocations resolve to the sibling
    /// CLI. Runs on every device, including headless remotes, since automations are daemon-owned.
    private func startAutomationService() {
        do {
            let orchestrator = try makeProfileOrchestrator()
            let binaryDirectory = URL(fileURLWithPath: launchExecutablePath, isDirectory: false).deletingLastPathComponent().path
            let service = AutomationService(
                store: orchestrator.store, orchestrator: orchestrator, binaryDirectory: binaryDirectory,
                // Foundation caches the system zone, so re-read it fresh each tick: reset the cache, then
                // return the current zone. This is what lets a running daemon notice a device zone change and
                // recompute cron anchors without a restart.
                timeZone: {
                    NSTimeZone.resetSystemTimeZone()
                    return TimeZone.current
                },
                // The teardown latches are re-checked inside the service queue: scheduler work that passed
                // its outer gate but was scheduled late no-ops during handoff or final shutdown.
                ticksSuspended: { [livenessState] in
                    let snapshot = livenessState.snapshot()
                    return snapshot.handoffInProgress || snapshot.shutdownInProgress
                }, logError: { writeStandardError("spacesd automation_error \($0)\n") })
            WorkspaceOrchestrator.setProcessWideAutomationWorkspaceTeardown { workspaceID in
                try service.deleteAutomationsTargetingWorkspaceDuringTeardown(workspaceID: workspaceID)
            }
            WorkspaceOrchestrator.setProcessWideAutomationWorkspaceCancellation { workspaceID, orchestration in
                try service.cancelRunsForWorkspaceStop(workspaceID: workspaceID, orchestration: orchestration)
            }
            // Set the main-actor identity immediately (the lifecycle/identity guard below depends on it) but
            // publish the off-main box only after reconciliation. Transports (Device API listeners already
            // opened by `startSharedServices`) may reach the service through the box, so exposing it before
            // startup catch-up would let an early update/disable request recompute or clear an overdue cron
            // automation's anchor before the missed-run policy is applied, silently losing the catch-up. An
            // early request instead gets the same "Automations are unavailable" rejection as a failed service
            // start — honest and transient.
            automationService = service
            // Startup catch-up must strictly precede the first tick, but `reconcileMissedRunsOnStart` enters
            // the service's serial queue whose executor hops the engine actor (and thus main): running it on
            // main would deadlock (the one-way rule). Run it on a detached task, then publish the box and
            // create the timer only after it returns. The timer callback likewise fires `tick()` off main via
            // a detached task; the service's serial queue serializes any overlapping fires.
            Task.detached(priority: .utility) { [weak self] in
                service.reconcileMissedRunsOnStart()
                await MainActor.run { [weak self] in
                    guard let self, self.automationService === service else { return }
                    // Publish the off-main box inside the identity guard so a shutdown during reconciliation
                    // (which nils `automationService`) can never resurrect the gate.
                    self.automationServiceBox.set(service)
                    // Capture the off-actor liveness box so the timer can gate on it without hopping the main
                    // actor: a tick observing quiesced cores mid-handoff would misread preserved sessions as
                    // dead and falsely finalize their runs, so skip ticking while a handoff is in progress.
                    // `performExecHandoff` drains any tick already in flight before quiescing.
                    let livenessState = self.livenessState
                    let tickCoalescer = AutomationTickCoalescer { service.tick() }
                    let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                        guard !livenessState.snapshot().handoffInProgress else { return }
                        tickCoalescer.submit()
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    self.automationTimer = timer
                }
            }
        } catch { writeStandardError("spacesd automation_service_error error=\(error)\n") }
    }

    /// One-shot startup maintenance: removes `workspace-setup` run directories that no longer belong
    /// to any workspace in the store (see `WorkspaceSetupDirectorySweep`, issue #423). Best-effort —
    /// this is diagnostic-file cleanup, not part of the daemon's operational path, so a failure here
    /// only gets logged.
    private func sweepOrphanedWorkspaceSetupDirectories(databasePath: String) {
        do {
            let store = try SQLiteStore(path: databasePath)
            let knownWorkspaceIDs = Set(try store.projects().flatMap { project in try store.workspaces(projectID: project.id).map(\.id) })
            let setupDirectory = URL(fileURLWithPath: try SpacesProfile.current().runtimeDirectory, isDirectory: true).appendingPathComponent(
                "workspace-setup", isDirectory: true
            ).path
            WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: setupDirectory, knownWorkspaceIDs: knownWorkspaceIDs)
        } catch { writeStandardError("spacesd workspace_setup_sweep_error error=\(error)\n") }
    }

    #if os(macOS)
        /// One-shot startup maintenance: trims launchd's stdout/stderr redirects back to a bounded tail
        /// once either exceeds `RuntimeLogTrimming.maximumSizeBeforeTrimBytes` (issue #469) — nothing
        /// else ever rotates them, so they otherwise grow for the life of the profile. Only macOS runs
        /// spacesd under launchd, so this is macOS-only. `TerminalPerformance`'s perf.log has the same
        /// unbounded-growth problem but is deliberately excluded: it is not written through an O_APPEND
        /// descriptor, so `RuntimeLogTrimming`'s in-place-truncate safety argument does not hold for it
        /// (see that type's doc comment).
        private func trimOversizedRuntimeLogs() {
            guard let runtimeDirectory = try? SpacesProfile.current().runtimeDirectory else { return }
            let runtimeDirectoryURL = URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
            for name in ["spacesd.launchd.out.log", "spacesd.launchd.err.log"] {
                RuntimeLogTrimming.trimIfOversized(path: runtimeDirectoryURL.appendingPathComponent(name, isDirectory: false).path)
            }
        }
    #endif

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
    ///
    /// Also installs the process-wide handoff predicate. The handoff gate must be process-wide, not
    /// confined to `makeProfileOrchestrator`: every transient daemon orchestrator — the worktree-discovery
    /// scan (which archives workspaces and deletes their process/window/agent rows), the runtime reconcilers,
    /// and the Device API request handlers — is built without an explicit predicate and would otherwise get
    /// the `{ false }` default, letting its destructive `stopWorkspaceUnlocked` row deletes proceed during an
    /// exec-in-place handoff while the terminator no-ops. That would leave the successor daemon adopting a
    /// still-live terminal whose workspace tracking was deleted.
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
        // The conditional ad-hoc stop (`stopWorkspaceTerminalIfBareShell`) reads a session's foreground
        // through this rather than from persisted runtime state, whose foreground sample can be a second
        // old, long enough for a command the user launched right before closing the pane to be invisible
        // to a decision that would then kill it.
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalForegroundProcessSampler { [weak self] sessionID in
            TerminalEngineActor.runSynchronously { self?.currentForegroundReading(sessionID: sessionID) }
        }
        // The ad-hoc stop's owner check reads through this rather than the durable attachment rows, whose
        // matching detach write can still be queued behind a contended lock when the close request arrives.
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalLiveOwnerAttachmentProber { [weak self] sessionID in
            TerminalEngineActor.runSynchronously { self?.sessionCores[sessionID]?.hasLiveOwnerAttachment() }
        }
        // Tracked-window pruning reads through this instead of the durable attachment rows, whose mirror
        // write can still be queued.
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalLiveActiveAttachmentProber { [weak self] sessionID in
            TerminalEngineActor.runSynchronously { self?.sessionCores[sessionID]?.hasLiveAttachments() }
        }
        // The device-runtime reconcilers detect coding-agent exits that never fired a session-end hook
        // (a supported coding agent exiting without signaling, or being SIGKILL'd) and notify subscribers
        // through this submitter. They run on detached tasks/queues, never main, so
        // `submitAgentNotificationLine` takes its off-main direct send path here (it only defers onto the
        // delivery queue when invoked on the main actor).
        WorkspaceOrchestrator.setProcessWideAgentNotificationLineSubmitter { [weak self] sessionID, line in
            guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
            try self.submitAgentNotificationLine(sessionID: sessionID, line: line)
        }
        // The automation executor delivers an agent-kind automation's seed prompt through this writer. It
        // sends with `appendNewline: false` because the executor issues the submitting CR as its own
        // separate byte write (the provider-neutral two-write submit), routing through the same off-main
        // send path the `.terminalSend` profile command uses (`terminalSendOffMain`). The executor runs on
        // the automation service's own serial queue, never main, so the engine hop inside that send path
        // is deadlock-safe (the one-way rule).
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionInputWriter { [weak self] sessionID, input, appendNewline in
            guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
            let response = self.terminalSendOffMain(
                TerminalServiceTerminalSendPayload(sessionID: sessionID, input: input, appendNewline: appendNewline))
            guard response.ok else { throw Self.requestFailedError(response.message) }
        }
        // Same off-actor, lock-guarded flag `makeProfileOrchestrator` reads: safe to poll from any
        // orchestrator's transport-thread/detached-task call graph. This is what makes the transient
        // daemon orchestrators refuse workspace stops during a handoff.
        WorkspaceOrchestrator.setProcessWideDaemonHandoffInProgress { [weak self] in self?.handoffInProgress ?? false }
        #if os(macOS)
            WorkspaceOrchestrator.setProcessWideNotificationDeliverer { title, body, subtitle in
                var userInfo = [IPCNotification.titleUserInfoKey: title, IPCNotification.detailUserInfoKey: body]
                if let subtitle { userInfo[IPCNotification.notificationSubtitleUserInfoKey] = subtitle }
                try? IPCNotification.post(IPCNotification.deliverUserNotification, userInfo: userInfo)
            }
        #endif
    }

    func shutdown() async {
        // Close the create-admission window BEFORE anything else. `server.stop()` (in
        // `stopSharedServices`) only cancels the accept source — a `.create` already on the serial work
        // queue keeps running and can spend up to 120s in git prep, then hop the engine to insert a core
        // AFTER the snapshot below. Setting this first, on the main actor and before the engine snapshot,
        // means every create landing on the engine after the snapshot sees it (they serialize on the one
        // engine queue) and is refused instead of leaking a child `exit(0)` never reaps. Monotonic: the
        // process exits, so it is never cleared.
        shutdownInProgress = true
        await stopSharedServices()
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

    private var shutdownTask: Task<Void, Never>?
    private var handoffCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Single entry point for every termination path — the SIGTERM/SIGINT handler, AppKit's
    /// `applicationWillTerminate`, and the control socket's `shutdownAndExit`. Any of them can fire
    /// while another is mid-teardown (launchd sends SIGTERM to a daemon that may also be quitting),
    /// and running `shutdown()` twice would re-drive per-core teardown against already-terminated
    /// cores. Main-actor isolation makes the check-and-store atomic (no suspension between them), and
    /// a late caller AWAITS the in-flight task rather than returning early — otherwise a signal
    /// handler's `exit(0)` could fire out from under a teardown still flushing transcripts.
    ///
    /// The handoff wait lives INSIDE the stored task, not before it: a suspension between the
    /// `shutdownTask` read and its store would let two callers each start a teardown.
    func shutdownOnce() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { @MainActor in
            await self.awaitHandoffCompletion()
            await self.shutdown()
        }
        shutdownTask = task
        await task.value
    }

    /// Suspends until no exec-in-place handoff is in flight, so a termination signal cannot interleave
    /// teardown with one. `performExecHandoff` suspends at every quiesce and drain, so without this a
    /// signal-handler task lands between them and `terminateAllSessions()` closes a master descriptor
    /// the handoff is still about to hand to `prepareDescriptorForHandoff` — the quiesce-versus-
    /// terminate exclusion `HostManagedPTYTerminalSessionDriver.terminate()` documents as an invariant
    /// its callers uphold. The handoff's own keep-running failure path is the second reason: it calls
    /// `startSharedServices()`, which would relaunch the router and reopen the socket a moment before
    /// `exit(0)` — orphaning exactly the Caddy the graceful shutdown exists to reap.
    ///
    /// Waiting rather than refusing is what keeps the signal honest on the path that matters: a handoff
    /// that fails leaves the daemon running, and a refused signal would strand a `launchctl stop`
    /// against a daemon that never goes away. `while` rather than `if` because a fresh handoff can
    /// start between the waiters being resumed and this task being scheduled; each iteration suspends,
    /// so it cannot spin.
    ///
    /// Accepted: a handoff that reaches `execv` replaces the image, so this task and its continuation
    /// die with the old image and the signal is dropped — the successor keeps running under the same
    /// pid, and the caller has to signal again. Honoring it instead would mean either aborting a
    /// handoff past its point of no return or persisting the request across exec for the successor to
    /// act on, and both add a failure path to the update mechanism to serve a race that needs a signal
    /// inside the quiesce window AND a successful exec, and that a second signal resolves immediately.
    private func awaitHandoffCompletion() async {
        while handoffInProgress { await withCheckedContinuation { continuation in handoffCompletionWaiters.append(continuation) } }
    }

    /// Called from `performExecHandoff`'s `defer` — see `awaitHandoffCompletion()`.
    private func resumeHandoffCompletionWaiters() {
        let waiters = handoffCompletionWaiters
        handoffCompletionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Stops everything except the per-session cores: the lifecycle timer, database-change
    /// observers/receivers, device-runtime services, the Device API supervisor, and the main
    /// request-accepting socket server. Shared by `shutdown()` and the exec-in-place handoff, which
    /// stops intake here and then quiesces (rather than terminates) the session cores.
    ///
    /// Runs in two phases, and the split is the point. Draining a reconcile loop's database connection
    /// suspends the main actor for as long as a pass takes, so any service still live across that
    /// suspension can start fresh work into a daemon that is about to `exit(0)` or `execv` — a request
    /// launching an arbitrary command, or a process-status reconcile committing an exit whose `onExit:
    /// restart` the handoff gate then refuses, losing the restart. So: latch every producer of new work
    /// first, and only then wait.
    ///
    /// `stopWorkProducers()` is not `async`, which is what enforces phase 1 rather than leaving it to the
    /// reader — nothing in it can suspend, so nothing can slip between two latches. A service added later
    /// belongs there by default; only a teardown that genuinely must be awaited goes in phase 2, and by
    /// then everything is already latched.
    private func stopSharedServices() async {
        // Capture before phase 1 clears both published references. This also includes startup
        // reconciliation, for which `automationService` is set before the off-main box is published.
        let automationServiceToDrain = automationService
        stopWorkProducers()
        // Teardown is latched before this wait. A scheduler pass still queued on the service no-ops; one
        // already executing finishes before session teardown takes its runtime snapshot.
        if let automationServiceToDrain { await automationServiceToDrain.waitUntilIdle() }
        await releaseReconcileStores()
    }

    /// Phase 1: latch everything that could introduce new work. Synchronous by contract — see
    /// `stopSharedServices()`.
    private func stopWorkProducers() {
        // Intake first: `shutdownInProgress` gates session CREATES only, so during a shutdown every other
        // request kind — `.runWorkspaceCommand` can launch an arbitrary command — is admitted right up
        // until the acceptors stop. (An exec handoff does not depend on this: it latches
        // `handoffInProgress` before calling here, and that flag makes `handle` reject every command.)
        // This narrows the window rather than closing it: `acceptSource.cancel()` propagates
        // asynchronously, which is exactly why the create path has an admission gate as well.
        deviceAPISupervisor.stop()
        server.stop()
        lifecycleTimer?.invalidate()
        lifecycleTimer = nil
        automationTimer?.invalidate()
        automationTimer = nil
        automationService = nil
        automationServiceBox.set(nil)
        WorkspaceOrchestrator.setProcessWideAutomationWorkspaceTeardown(nil)
        WorkspaceOrchestrator.setProcessWideAutomationWorkspaceCancellation(nil)
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
        remoteAgentWatchService?.stop()
        remoteAgentWatchService = nil
        terminalForegroundAgentReconciler?.beginStop()
        #if os(macOS)
            processExitMonitor?.stop()
            processExitMonitor = nil
            caddyRouterService?.beginStop()
        #endif
    }

    /// Phase 2: wait for each reconcile loop's database connection to be released and take its final WAL
    /// checkpoint. Safe to suspend in here precisely because phase 1 has already run: nothing left alive
    /// can submit work, and neither reconcile pass depends on a service phase 1 tore down — each builds
    /// its own orchestrator over the store confined to its own queue.
    private func releaseReconcileStores() async {
        await terminalForegroundAgentReconciler?.releaseStore()
        terminalForegroundAgentReconciler = nil
        #if os(macOS)
            await caddyRouterService?.releaseStore()
            caddyRouterService = nil
        #endif
    }

    @TerminalEngineActor private func terminateAllSessions() { for sessionID in Array(sessionCores.keys) { _ = terminateSession(id: sessionID) } }

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
        // `.list` builds its DB-derived pass from disk (no main-actor state) and only needs a narrow engine
        // hop to merge in-memory core summaries (see `listSessionsOffMain`), so it is peeled off main here
        // too — mirroring `.state` — rather than falling through to `handle`'s on-main fallback, which would
        // force the main actor to synchronously wait on the engine actor.
        case .list: return listSessionsOffMain()
        // The profile-command listing variant shares the same in-memory merge, so it is peeled off main for
        // the same reason as `.list` above rather than falling through to `handleProfileCommand`'s on-main
        // bulk, which would trap `listSessionsOffMain`'s engine hop.
        case .profileCommand(.terminalList): return terminalListOffMain()
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
        // Workspace start/stop/restart and agent kill/signal are peeled off main for the SAME reason as the
        // three cases above: their orchestrator call graph reaches the built-in terminal launcher (start/
        // restart) or terminator (agent kill's stop chokepoint, and an agent-signal `exit` whose
        // `handleAgentExit` tears down an already-dead backing terminal), and both closures enter the
        // terminal engine actor via `TerminalEngineActor.runSynchronously` — which traps when called from
        // the main actor (the one-way rule). `SpacesDaemonProfileCommandRouting.requiresOffMainExecution`
        // is the single source of truth for this classification; `profileCommandOffMain` asserts against it.
        case .profileCommand(.workspaceStart(let payload)): return workspaceStartOffMain(payload: payload, restartIfRunning: false)
        case .profileCommand(.workspaceStop(let workspaceID)): return workspaceStopOffMain(workspaceID: workspaceID)
        case .profileCommand(.workspaceRestart(let payload)): return workspaceStartOffMain(payload: payload, restartIfRunning: true)
        case .profileCommand(.agentKill(let payload)): return agentKillOffMain(payload)
        case .profileCommand(.agentSignal(let payload)): return agentSignalOffMain(payload)
        // The whole automation command family is peeled off main: trigger/cancel/end-agents/delete reach the
        // executor's launcher/terminator (engine hop), and every automation command enters the queue-confined
        // `AutomationService`, which a main-actor caller must never block on behind an engine→main tick hop
        // (see `SpacesDaemonProfileCommandRouting.requiresOffMainExecution`).
        case .profileCommand(.automationCreate(let payload)): return automationCommandOffMain(.automationCreate(payload))
        case .profileCommand(.automationUpdate(let payload)): return automationCommandOffMain(.automationUpdate(payload))
        case .profileCommand(.automationDelete(let id)): return automationCommandOffMain(.automationDelete(id: id))
        case .profileCommand(.automationList): return automationCommandOffMain(.automationList)
        case .profileCommand(.automationRunsList(let payload)): return automationCommandOffMain(.automationRunsList(payload))
        case .profileCommand(.automationTrigger(let id)): return automationCommandOffMain(.automationTrigger(id: id))
        case .profileCommand(.automationRunCancel(let runID)): return automationCommandOffMain(.automationRunCancel(runID: runID))
        case .profileCommand(.automationEndAgents(let runID)): return automationCommandOffMain(.automationEndAgents(runID: runID))
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
        if let rejection = livenessState.teardownRejection() { return rejection }
        return Self.runOnMainActorSynchronously { [weak self] in
            guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .shuttingDown) }
            return self.handleProfileCommand(command)
        }
    }

    private func handle(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        // Socket shutdown is asynchronous, so a request accepted just before cancellation can reach the
        // main actor after a handoff or a final shutdown starts. Reject it here, at the mutation boundary,
        // so the session snapshot cannot gain or lose a core while quiescing or terminating.
        if let rejection = livenessState.teardownRejection() { return rejection }
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
        // Same dual-listing as `.terminate` above: `dispatch` normally peels `.list` off main, but the
        // on-main fallback (a request that reached `handle` directly) routes through the identical off-main
        // implementation rather than a main-actor-only listing, so the in-memory-summary merge always runs.
        case .list: return listSessionsOffMain()
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
            activeSessionCount: livenessState.snapshot().sessionCount, protocolVersion: SpacesWireProtocol.version,
            timeZoneIdentifier: TerminalServiceDaemonStatus.currentTimeZoneIdentifier,
            // Same off-actor helper the liveness ping uses, so both status paths agree on this daemon's
            // addresses without duplicating the bound-host cache.
            deviceAPIAddresses: livenessState.currentDeviceAPIAddresses())
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
    /// children identically on macOS and Linux. External termination — a SIGTERM/SIGINT, or
    /// NSApp-driven termination such as logout — still reaches `shutdown()` through the signal
    /// handler or the app delegate; `shutdownOnce()` is what keeps those from re-entering
    /// teardown if they race this path.
    private func shutdownAndExit() async -> Never {
        await shutdownOnce()
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
        // The other half of the teardown/handoff exclusion `awaitHandoffCompletion()` establishes: that
        // one covers a signal arriving during a handoff, this one covers a handoff starting during a
        // teardown. `requestDaemonRestart()` fires this on a 150ms timer, which is easily long enough to
        // land inside a `shutdown()` suspended on a service or core drain, and quiescing — or exec'ing,
        // which would replace the image and discard the shutdown outright — against a daemon already
        // tearing down races the same descriptor teardown. `shutdownTask` rather than
        // `shutdownInProgress` is the flag to read: `shutdownOnce()` stores it synchronously before it
        // suspends, whereas `shutdownInProgress` is not set until `shutdown()` itself begins, leaving a
        // window this guard would miss.
        guard shutdownTask == nil else {
            writeStandardError("spacesd handoff_refused reason=shutting_down\n")
            return
        }
        handoffInProgress = true
        // Registered after the refusal guard above, so a refused second trigger neither clears the flag
        // nor releases waiters belonging to the handoff that is actually running.
        defer {
            handoffInProgress = false
            resumeHandoffCompletionWaiters()
        }

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

        // Capture the automation service before `stopSharedServices()` nils its box, so its in-flight tick can
        // be drained below. `resumeInPlaceAfterFailedHandoff` restarts shared services and rebuilds a fresh
        // automation service, so nothing needs re-arming here on a failed handoff.
        let automationServiceToDrain = automationServiceBox.get()
        await stopSharedServices()
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

        // Drain a possibly in-flight automation tick before quiescing cores. `handoffInProgress` is already set,
        // so the timer gate stops new ticks; this awaits the one that may already be running so it cannot land
        // mid-quiesce and misread preserved sessions as dead. The drain also immediately SIGKILLs any process
        // group whose timeout/cancel escalation was pending: exec preserves those children but replaces the
        // service's in-memory pending table, so carrying the grace across the image boundary would lose it.
        // AWAITED (not `.sync`-blocked) for the same one-way-rule reason as the delivery drain above: the tick's
        // executor hops the terminal engine actor (and thus main), so a blocked main thread would deadlock it.
        if let automationServiceToDrain { await automationServiceToDrain.completePendingTerminationsForHandoff() }
        writeStandardError("spacesd handoff_automation_drained\n")

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
                    // a dropped exited write would leave a `.running` row whose `service_pid` matches the
                    // successor image. The drain is the primary guard; the successor's post-resume
                    // stale-session sweep (`recoverStaleSessions`, own-pid-not-adopted case) is the backstop
                    // that finalizes such a row `.exited` if the drain's bounded retries were still exhausted.
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

        // Release the terminal database now that every session has quiesced and drained, so its final WAL
        // checkpoint runs here rather than being lost when `execv` replaces this image. The shared services
        // that hold their own long-lived connections were already stopped before quiescing, and this is the
        // last one left. A straggler write reopens it, which is why the release is not latched: the exec
        // path below can fail and resume this daemon in place.
        TerminalSessionPersistence.closeDatabaseConnection()

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
    @TerminalEngineActor private func withValidatedHandoffOutputsForExec(
        _ cores: ArraySlice<GhosttyEmbeddedSessionCore>, operation: () throws -> Void
    ) throws {
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
    private func resumeSessionsFromHandoffIfNeeded() async throws -> Set<String> {
        guard let table = DaemonHandoffStore.consume() else { return [] }
        handoffGeneration = table.generation
        lastHandoffSourceVersion = table.sourceVersion
        writeStandardError("spacesd handoff_resume generation=\(table.generation) sessions=\(table.sessions.count)\n")
        var adoptedSessionIDs: Set<String> = []
        for record in table.sessions { if let adoptedSessionID = await resumeHandoffSession(record) { adoptedSessionIDs.insert(adoptedSessionID) } }
        lastHandoffResumeUptime = ProcessInfo.processInfo.systemUptime
        return adoptedSessionIDs
    }

    /// Adopts a single handoff record. Validates the inherited descriptor is still a PTY master and
    /// reaps/probes the child, then acts on the pure `DaemonHandoffResumeAction` decision: live
    /// sessions are rebuilt through the normal session-core factory and `resumeFromHandoff`; dead or
    /// unusable ones are finalized `.exited` (via the normal teardown path) so one bad session can
    /// never abort the resume of the rest.
    ///
    /// Returns the session ID only when the record was successfully adopted (rebuilt and resumed and
    /// therefore live under this pid). A failed adoption, a finalized-exited record, or an
    /// invalid-descriptor record returns nil, so the post-resume stale-session sweep is NOT exempted
    /// from them — if a failed-adoption teardown's exited write is also dropped, the sweep repairs it.
    private func resumeHandoffSession(_ record: DaemonHandoffSessionRecord) async -> String? {
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
                return record.sessionID
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
                return nil
            }
        case .finalizeExited:
            close(record.masterFD)
            _ = await TerminalEngineActor.run { self.terminateSession(id: record.sessionID) }
            return nil
        case .discardInvalidDescriptor:
            _ = await TerminalEngineActor.run { self.terminateSession(id: record.sessionID) }
            return nil
        }
    }

    /// RPC `.create` handler. The git-driven workspace prep is unbounded (it can `git clone` with a 120s
    /// timeout), so it runs off the main actor on the transport thread; only the session-core creation and
    /// start — which mutate `sessionCores` and drive Ghostty — hop to the engine actor via a single
    /// `startSessionCoreResponse` call, whose on-engine create-admission re-check (`handoffInProgress` and
    /// `shutdownInProgress`) is the real mutation-boundary guard (the off-actor check below is an early-out,
    /// not the authority). That one engine hop both starts the core and builds the post-start summary from
    /// the core's in-memory state (never the durable mirror), so a create can report the running session even
    /// while the first runtime-state write is still queued behind a contended DB write lock — and a
    /// fast-exiting command's PTY-close job cannot interleave to strand the summary (see
    /// `startSessionCoreResponse`).
    private nonisolated func createSessionOffMain(_ request: TerminalServiceCreateRequest) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
        let launchConfiguration = request.launchConfiguration
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: launchConfiguration.workingDirectory)
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
        return TerminalEngineActor.runSynchronously { self.startSessionCoreResponse(for: launchConfiguration) }
    }

    /// Engine-isolated create used by the in-process launch callers (built-in terminal launcher /
    /// orchestrator hooks), which reach the engine via `TerminalEngineActor.runSynchronously` from their
    /// own (never-main) calling threads. Runs the workspace prep and the core start inline and returns
    /// `startSessionCoreResponse`'s result, whose success response already carries the session summary from
    /// the live core's in-memory state.
    @TerminalEngineActor private func createSession(_ request: TerminalServiceCreateRequest) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
        let launchConfiguration = request.launchConfiguration
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: launchConfiguration.workingDirectory)
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
        return startSessionCoreResponse(for: launchConfiguration)
    }

    /// The engine-isolated tail of session create: creating the session core, starting it, and serving the
    /// post-start summary — all in one serial engine block. Re-checks the create-admission flags
    /// (`handoffInProgress` and `shutdownInProgress`, via `livenessState.teardownRejection()`) on the
    /// engine actor so a create that raced a handoff or a shutdown cannot add a core after the
    /// quiesce/shutdown snapshot — this is the real mutation-boundary guard, serialized against both the
    /// handoff quiesce loop (`performExecHandoff`) and `shutdown()`'s terminate snapshot, which also run on
    /// the engine. Both set their flag on the main actor BEFORE their engine snapshot, so any create reaching
    /// the engine after the snapshot observes it and is refused.
    ///
    /// The success response carries the session summary in `session`, built from the just-started core's
    /// in-memory state (`inMemorySessionSummary()`) in this same block — never from the durable mirror. Two
    /// properties make that safe and race-free:
    ///
    ///   - `startIfNeeded()` advanced the core's in-memory runtime state synchronously, so
    ///     `inMemorySessionSummary()` returns the running session immediately, independent of when the first
    ///     runtime-state write commits to SQLite. That first write is enqueued on the per-core persistence
    ///     queue, so under writer contention (e.g. an agent hook's `spaces agent signal` burst holding the
    ///     write lock up to SQLite's busy timeout) it can lag; a disk-polling summary would then fail for a
    ///     session that was live and running.
    ///   - The summary is read here, in the same serial engine block that started the core, off the LOCAL
    ///     `sessionCore` reference. A fast-exiting command (e.g. `true`) enqueues its PTY-close job — which
    ///     removes the core from `sessionCores` via `onSessionClosed` — onto this same engine queue, so that
    ///     job cannot interleave between the start and the summary within one block, and the local reference
    ///     stays valid regardless of the `sessionCores` removal. The core keeps its terminal in-memory
    ///     runtime state after close, so the summary reports the true exited result rather than a ghost
    ///     failure that would leave a live, untracked agent process behind.
    ///
    /// A nil summary is unreachable after a successful `startIfNeeded()` (the core holds
    /// `latestRuntimeState`/`lastRuntimeState` by then), so the defensive branch returns a plain
    /// `internalError` without any core-terminate rollback: the summary is in-memory and the core is a live
    /// local reference, so there is nothing meaningful a disk-fallback rollback could reconcile.
    @TerminalEngineActor private func startSessionCoreResponse(for launchConfiguration: TerminalSessionLaunchConfiguration) -> TerminalServiceResponse
    {
        if let rejection = livenessState.teardownRejection() { return rejection }
        do {
            let sessionCore = try sessionCore(for: launchConfiguration)
            try sessionCore.startIfNeeded()
            guard let summary = sessionCore.inMemorySessionSummary() else {
                return TerminalServiceResponse(
                    ok: false, message: "Terminal session \(launchConfiguration.sessionID) started but produced no summary.",
                    errorCode: .internalError)
            }
            return TerminalServiceResponse(ok: true, message: "Started terminal session \(launchConfiguration.sessionID).", session: summary)
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
    }

    /// RPC `.runWorkspaceCommand` handler. Runs an arbitrary `/bin/bash -lc` command to completion — an
    /// unbounded block — plus the git-driven workspace prep, entirely off the main actor on the transport
    /// thread. Touches no main-actor state, so there is no main hop at all.
    private nonisolated func runWorkspaceCommandOffMain(_ request: TerminalServiceRunWorkspaceCommandRequest) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
        let workspaceCommand = request.workspaceCommand
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: workspaceCommand.workingDirectory)
            let logPath = try workspaceCommandLogPath(workspaceCommand.logPath)
            // Re-check at the launch boundary: the entry check above only proves the request was admitted
            // before `prepareWorkspace` started, but that call can spend up to 120s in git fetch/clone/merge,
            // and a shutdown or handoff can latch at any point during that window. Without this recheck a
            // teardown that lands mid-prep would never be observed, and `runShellCommand` below spawns an
            // arbitrary `/bin/bash -lc` child that the daemon has no further chance to refuse. This handler
            // runs nonisolated on the transport thread with no engine-queue serialization (unlike the
            // create path's `startSessionCoreResponse` recheck), so this only narrows the race to the
            // instant between this check and the spawn a few lines below — it does not close it.
            if let rejection = livenessState.teardownRejection() { return rejection }
            let result = try runShellCommand(workspaceCommand, logPath: logPath, manifest: request.runtimeManifest)
            let message = result.exitCode == 0 ? "Workspace command completed." : "Workspace command exited with code \(result.exitCode)."
            return TerminalServiceResponse(ok: true, message: message, servicePID: getpid(), commandResult: result)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.prepareWorkspace` handler. Chains git subprocesses (fetch/checkout/merge, and `git clone`
    /// with a 120s timeout) with no main-actor state, so it runs wholly off the main actor.
    private nonisolated func prepareWorkspaceOffMain(_ payload: TerminalServicePrepareWorkspaceRequest) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
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

    /// RPC `.list` handler, callable off the main actor (peeled by `dispatch`, and reused verbatim by
    /// `handle`'s main-actor fallback). Builds the DB-derived pass first, purely from disk state via
    /// `summaryIfLive`, then makes a single narrow engine hop to merge in each live core's in-memory summary.
    ///
    /// In-memory cores are the authority for a session's existence, matching what `startSessionCoreResponse`
    /// already serves on create (see its doc comment): session lifecycle SQLite writes are write-behind on a
    /// per-core persistence queue, so a session started moments ago can have `terminal_sessions`/
    /// `terminal_runtime_states` rows that have not committed yet — up to tens of seconds under DB
    /// contention. Without this merge, a freshly created live session would silently disappear from CLI/
    /// device list responses until those queued writes land. Only interactive (`starting`/`running`) cores
    /// not already covered by the DB-derived pass are appended, so ordering stays stable: DB-derived entries
    /// first, then the in-memory-only ones.
    private nonisolated func listSessionsOffMain() -> TerminalServiceResponse {
        // Peeled handlers do not pass through `handle`'s teardown gate, so each one re-checks it first;
        // this single check also covers `terminalListOffMain`, which wraps this listing.
        if let rejection = livenessState.teardownRejection() { return rejection }
        do {
            let knownSessions = try TerminalSessionPersistence.listKnownSessions()
            var sessions = try knownSessions.compactMap { knownSession in try summaryIfLive(for: knownSession) }
            let knownSessionIDs = Set(sessions.map(\.id))
            let inMemorySummaries = TerminalEngineActor.runSynchronously { self.sessionCores.values.compactMap { $0.inMemorySessionSummary() } }
            for summary in inMemorySummaries where summary.state.isInteractive && !knownSessionIDs.contains(summary.id) { sessions.append(summary) }
            return TerminalServiceResponse(ok: true, message: "Listed terminal sessions.", sessions: sessions)
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error), errorCode: Self.errorCode(error)) }
    }

    /// RPC `.profileCommand(.terminalList)` handler. Wraps `listSessionsOffMain`'s in-memory-merged listing
    /// into the profile-command envelope. Peeled off main by `dispatch(_:)` — like `.terminalSend` and its
    /// siblings — because `listSessionsOffMain` now makes a narrow engine hop to merge live core summaries,
    /// which traps if driven from the main actor (the one-way rule); `runProfileCommand`'s `.terminalList`
    /// case fails loudly if a request ever reaches it directly instead.
    private nonisolated func terminalListOffMain() -> TerminalServiceResponse {
        let response = listSessionsOffMain()
        guard response.ok else { return response }
        let profile = TerminalServiceProfileCommandResponse(message: response.message, terminalSessions: response.sessions ?? [])
        return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
    }

    /// RPC `.state` handler. A live in-process core's state read is a narrow main hop
    /// (`loadCurrentStateOffMain`); when the session is not live, the unix-socket connect+read (2s timeout)
    /// and the disk reads run off the main actor on the transport thread.
    private nonisolated func loadTerminalStateOffMain(sessionID: String) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
        guard !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument) }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            // A pending launch-registry entry does not imply the session row is absent: a daemon handoff resume
            // re-enqueues the launch write and re-records the registry entry even though the row and real
            // unacknowledged signal rows already exist from before the handoff. So the read is attempted first,
            // or those signals would be hidden. Only when that read throws unknownSession while the launch
            // write is still queued (first launch, or a relaunch whose new row has not replaced the old one
            // yet) do we report no pending signals, and that is exact, not an approximation: any signal recorded
            // in that window is queued behind the launch write on the core's own serial persistence queue and
            // has not committed either.
            //
            // The registry is consulted only after the read above throws, and the launch write can commit and
            // clear the registry entry in the gap between that read observing no row and the registry check
            // that follows it. The entry is cleared only after the row commits, so when the registry already
            // reads empty, one re-read settles which case this is: either it finds the row a commit landed in
            // during that gap, or it throws unknownSession again for a session that is genuinely unknown, and
            // that second throw is left to propagate out of this do/catch to the function's own catch below.
            let agentSignals: [TerminalServiceAgentSignalEvent]
            do {
                agentSignals = try TerminalSessionPersistence.pendingAgentSignals(sessionID: sessionID, paths: paths)
            } catch TerminalSessionPersistenceError.unknownSession {
                if TerminalSessionPendingLaunchRegistry.shared.pendingLaunchConfiguration(sessionID: sessionID) != nil {
                    agentSignals = []
                } else {
                    agentSignals = try TerminalSessionPersistence.pendingAgentSignals(sessionID: sessionID, paths: paths)
                }
            }
            return TerminalServiceResponse(
                ok: true, message: "Loaded terminal state.", sessionState: try loadCurrentStateOffMain(sessionID: sessionID),
                agentSignals: agentSignals)
        } catch { return Self.failureResponse(error) }
    }

    private func recordAgentSignal(_ request: TerminalServiceAgentSignalRequest) -> TerminalServiceResponse {
        let event = request.event
        guard !event.sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument) }
        do {
            let paths = try TerminalSessionPaths.forSession(id: event.sessionID)
            // The launch-configuration row for this session is still queued behind the persistence queue, so a
            // direct append here would throw unknownSession and drop a real lifecycle event (the previous
            // synchronous launch write made the row exist before the child process could ever signal);
            // enqueueing on the live core's own serial queue restores that ordering. The response below is
            // optimistic (the append commits asynchronously); the signal surfaces to state polls once it lands.
            if TerminalSessionPendingLaunchRegistry.shared.pendingLaunchConfiguration(sessionID: event.sessionID) != nil {
                Task { @TerminalEngineActor [weak self] in
                    guard let core = self?.sessionCores[event.sessionID] else {
                        // The core died between the registry check above and this hop, but its persistence
                        // queue outlives it, so the launch write may still be queued. An immediate append would
                        // throw unknownSession and silently drop a real event, so wait for the registry entry to
                        // resolve before appending. The registry entry always resolves: the write closure clears
                        // it on commit, and the write's own onFailure clears it core-independently on final
                        // failure. The 60 second bound below is double the roughly 26 seconds a launch write can
                        // spend exhausting five attempts against the 5 second SQLite busy timeout, kept bounded
                        // only as a backstop so a detached task can never spin forever. After resolution the
                        // append succeeds if the row committed; if the launch write finally failed, the session
                        // never durably existed and the signal has nothing to land on. Detached off the engine
                        // actor: a DB write must never run inline on the engine, which is the whole point of
                        // this branch.
                        Task.detached {
                            var waits = 0
                            while waits < 600,
                                TerminalSessionPendingLaunchRegistry.shared.pendingLaunchConfiguration(sessionID: event.sessionID) != nil
                            {
                                waits += 1
                                try? await Task.sleep(nanoseconds: 100_000_000)
                            }
                            try? TerminalSessionPersistence.appendPendingAgentSignal(event, paths: paths)
                        }
                        return
                    }
                    core.enqueueAgentSignalAppend(event)
                }
                return TerminalServiceResponse(ok: true, message: "Queued agent signal.", agentSignals: [event])
            }
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
        // `.terminalList` and the three engine-touching profile commands are peeled off the main actor by
        // `dispatch(_:)` into dedicated synchronous off-main handlers (`terminalListOffMain`,
        // `terminalSendOffMain`, `terminalCommandOffMain`, `agentSpawnOffMain`); they can never reach this
        // main-actor switch, where listing (its in-memory merge) or creating/sending to a session would force
        // a forbidden main→engine synchronous wait (see `TerminalEngineActor`'s one-way rule). Kept in the
        // switch for exhaustiveness and to fail loudly if that peeling ever regresses.
        case .terminalList: preconditionFailure("`.terminalList` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .terminalSend: preconditionFailure("`.terminalSend` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .terminalTail(let payload): return try tailProfileTerminalOutput(payload)
        case .projectList:
            let orchestrator = try makeProfileOrchestrator()
            let projects = try orchestrator.listProjects().map(profileProjectSummary)
            return TerminalServiceProfileCommandResponse(message: "Listed projects.", projects: projects)
        case .workspaceList(let payload):
            let orchestrator = try makeProfileOrchestrator()
            let workspaces: [WorkspaceRecord]
            if let projectID = normalizedProfileArgument(payload.projectID) {
                workspaces = try orchestrator.store.workspaces(projectID: projectID)
            } else {
                workspaces = try orchestrator.store.projects().flatMap { try orchestrator.store.workspaces(projectID: $0.id) }
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
        // Workspace start/stop/restart and agent kill/signal are peeled off main by `dispatch(_:)` into their
        // dedicated synchronous off-main handlers (`workspaceStartOffMain`, `workspaceStopOffMain`, `agentKillOffMain`,
        // `agentSignalOffMain`) because their call graph reaches the launcher/terminator, whose engine hop
        // would trap on the main-actor `runProfileCommand` switch (see `SpacesDaemonProfileCommandRouting`).
        // Kept in the switch for exhaustiveness and to fail loudly if that peeling ever regresses.
        case .workspaceStart: preconditionFailure("`.workspaceStart` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .workspaceStop: preconditionFailure("`.workspaceStop` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
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
        // The whole automation family is peeled off main by `dispatch(_:)` into `automationCommandOffMain`,
        // because it enters the queue-confined `AutomationService` (and, for trigger/cancel/end-agents/delete,
        // the executor's launcher/terminator engine hop) — a main-actor caller blocking on that service could
        // deadlock behind an engine→main tick hop (the one-way rule). Kept in the switch for exhaustiveness and
        // to fail loudly if that peeling ever regresses.
        case .automationCreate: preconditionFailure("`.automationCreate` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .automationUpdate: preconditionFailure("`.automationUpdate` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .automationDelete: preconditionFailure("`.automationDelete` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .automationList: preconditionFailure("`.automationList` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .automationRunsList: preconditionFailure("`.automationRunsList` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .automationTrigger: preconditionFailure("`.automationTrigger` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .automationRunCancel:
            preconditionFailure("`.automationRunCancel` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        case .automationEndAgents:
            preconditionFailure("`.automationEndAgents` is peeled off main by dispatch(_:); it must not reach runProfileCommand")
        }
    }

    /// RPC automation profile-command handler. The whole automation family is peeled off main by `dispatch(_:)`
    /// because it enters the queue-confined `AutomationService` (and, for trigger/cancel/end-agents/delete, the
    /// executor's launcher/terminator engine hop): a main-actor caller blocking on that service could deadlock
    /// behind an engine→main tick hop (the one-way rule). Runs on the transport thread, resolving the one live
    /// service from the lock-guarded box, and mirrors the `handleProfileCommand` success/failure envelope.
    private nonisolated func automationCommandOffMain(_ command: TerminalServiceProfileCommand) -> TerminalServiceResponse {
        precondition(
            SpacesDaemonProfileCommandRouting.requiresOffMainExecution(command),
            "non-automation profile command reached automationCommandOffMain; route it in dispatch(_:)")
        if let rejection = livenessState.teardownRejection() { return rejection }
        do {
            guard let service = automationServiceBox.get() else {
                throw SpacesRuntimeError.invalidArgument(message: "Automations are unavailable on this daemon.")
            }
            let profile = try runAutomationCommand(command, service: service)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// The per-command automation logic, identical for both transports. Runs on the caller's thread (the
    /// transport thread for `automationCommandOffMain`); the service serializes internally.
    private nonisolated func runAutomationCommand(_ command: TerminalServiceProfileCommand, service: AutomationService) throws
        -> TerminalServiceProfileCommandResponse
    {
        switch command {
        case .automationCreate(let payload):
            let automation = try service.createAutomation(automationDraft(from: payload))
            return TerminalServiceProfileCommandResponse(message: "Created automation.", automations: [TerminalServiceAutomationSummary(automation)])
        case .automationUpdate(let payload):
            let automation = try service.updateAutomation(id: payload.id, draft: automationDraft(from: payload.fields))
            return TerminalServiceProfileCommandResponse(message: "Updated automation.", automations: [TerminalServiceAutomationSummary(automation)])
        case .automationDelete(let id):
            try service.deleteAutomationCommand(id: id)
            return TerminalServiceProfileCommandResponse(message: "Deleted automation.")
        case .automationList:
            let summaries = try service.listAutomations().map(TerminalServiceAutomationSummary.init)
            return TerminalServiceProfileCommandResponse(message: "Listed automations.", automations: summaries)
        case .automationRunsList(let payload):
            let runs = try service.listAutomationRuns(automationID: normalizedProfileArgument(payload.automationID))
            return TerminalServiceProfileCommandResponse(message: "Listed automation runs.", automationRuns: try automationRunSummaries(runs))
        case .automationTrigger(let id):
            let run = try service.triggerAutomation(id: id)
            return TerminalServiceProfileCommandResponse(message: "Triggered automation.", automationRuns: try automationRunSummaries([run]))
        case .automationRunCancel(let runID):
            let run = try service.cancelAutomationRun(runID: runID)
            return TerminalServiceProfileCommandResponse(message: "Canceled automation run.", automationRuns: try automationRunSummaries([run]))
        case .automationEndAgents(let runID):
            let run = try service.endAttributedAgents(runID: runID)
            return TerminalServiceProfileCommandResponse(message: "Ended automation run agents.", automationRuns: try automationRunSummaries([run]))
        default: preconditionFailure("runAutomationCommand received a non-automation profile command")
        }
    }

    private nonisolated func automationDraft(from fields: TerminalServiceAutomationFields) throws -> AutomationDraft {
        guard let triggerKind = AutomationTriggerKind(rawValue: fields.triggerKind) else {
            throw SpacesRuntimeError.invalidArgument(message: "Unsupported automation trigger kind '\(fields.triggerKind)'.")
        }
        guard let kind = AutomationKind(rawValue: fields.kind) else {
            throw SpacesRuntimeError.invalidArgument(message: "Unsupported automation kind '\(fields.kind)'.")
        }
        guard let concurrencyPolicy = AutomationConcurrencyPolicy(rawValue: fields.concurrencyPolicy) else {
            throw SpacesRuntimeError.invalidArgument(message: "Unsupported automation concurrency policy '\(fields.concurrencyPolicy)'.")
        }
        guard let missedRunPolicy = AutomationMissedRunPolicy(rawValue: fields.missedRunPolicy) else {
            throw SpacesRuntimeError.invalidArgument(message: "Unsupported automation missed-run policy '\(fields.missedRunPolicy)'.")
        }
        return AutomationDraft(
            name: fields.name, enabled: fields.enabled, triggerKind: triggerKind, cronExpression: fields.cronExpression, kind: kind,
            script: fields.script, agentCommand: fields.agentCommand, agentPrompt: fields.agentPrompt, workspaceID: fields.workspaceID,
            timeoutSeconds: fields.timeoutSeconds, concurrencyPolicy: concurrencyPolicy, missedRunPolicy: missedRunPolicy)
    }

    /// Maps runs to wire summaries, denormalizing each run's automation name and its attributed coding-agent
    /// breakdown (built once for the whole listing against the daemon's current live-session set).
    private nonisolated func automationRunSummaries(_ runs: [AutomationRun]) throws -> [TerminalServiceAutomationRunSummary] {
        guard !runs.isEmpty else { return [] }
        let store = try makeProfileOrchestrator().store
        // Every caller of this function runs off the main actor (the automation-command family is peeled
        // off main in `dispatch(_:)`), so the in-memory merge's engine hop is deadlock-safe here, same as
        // `listSessionsOffMain`'s merge for the CLI list.
        let inMemoryEntries = TerminalEngineActor.runSynchronously { self.sessionCores.values.compactMap { $0.inMemoryCatalogEntry() } }
        let liveSessions = TerminalSessionCatalog.mergingLiveInMemorySessions(
            (try? TerminalSessionCatalog.listLiveSessions()) ?? [], inMemory: inMemoryEntries)
        let attributedAgentsByRunID = try AutomationAttributedAgents.summariesByRunID(runs: runs, store: store, liveSessions: liveSessions)
        let workspaceIDsByRunID = try store.workspaceIDs(automationRunIDs: runs.map(\.id))
        var namesByAutomationID: [String: String] = [:]
        return try runs.map { run in
            let name: String?
            if let cached = namesByAutomationID[run.automationID] {
                name = cached
            } else {
                let resolved = try store.automation(id: run.automationID)?.name
                if let resolved { namesByAutomationID[run.automationID] = resolved }
                name = resolved
            }
            return TerminalServiceAutomationRunSummary(
                run, automationName: name, workspaceID: workspaceIDsByRunID[run.id], attributedAgents: attributedAgentsByRunID[run.id] ?? [])
        }
    }

    /// RPC `.profileCommand(.terminalSend)` handler. The one blocking path in the profile-command family:
    /// its control-socket round-trip (5s timeout) is peeled off the main actor by `dispatch`. A live
    /// in-process core still sends in a narrow main hop; otherwise the socket send runs on the transport
    /// thread. Mirrors `sendProfileTerminalInput` + `handleProfileCommand`'s success/failure wrapping.
    private nonisolated func terminalSendOffMain(_ payload: TerminalServiceTerminalSendPayload) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
        let text: String?
        let bytes: Data?
        switch payload.input {
        case .text(let value): (text, bytes) = (value, nil)
        case .bytes(let value): (text, bytes) = (nil, value)
        }
        let request = TerminalControlRequest(
            command: .send(TerminalControlSendPayload(text: text, bytes: bytes, clientID: nil, ownerEpoch: nil, appendNewline: payload.appendNewline))
        )
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
        if let rejection = livenessState.teardownRejection() { return rejection }
        do {
            let orchestrator = try makeProfileOrchestrator()
            let workspaceID = try orchestrator.resolveWorkspaceID(explicitWorkspaceID: payload.workspaceID, cwd: payload.cwd)
            let session = try orchestrator.createWorkspaceTerminalSession(workspaceID: workspaceID, title: payload.title, command: payload.command)
            let profile = TerminalServiceProfileCommandResponse(message: "Started terminal session.", terminalSession: session)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.profileCommand(.agentSpawn)` handler. Creates a coding-agent session, so it runs off main for
    /// the same reason as `terminalCommandOffMain`.
    private nonisolated func agentSpawnOffMain(_ payload: TerminalServiceAgentSpawnPayload) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
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
    private nonisolated func workspaceStartOffMain(payload: TerminalServiceWorkspaceLifecyclePayload, restartIfRunning: Bool)
        -> TerminalServiceResponse
    {
        if let rejection = livenessState.teardownRejection() { return rejection }
        do {
            let orchestrator = try makeProfileOrchestrator()
            let workspaceID = try orchestrator.resolveWorkspaceID(explicitWorkspaceID: payload.workspaceID, cwd: payload.cwd)
            try orchestrator.upWorkspace(workspaceID: workspaceID, restartIfRunning: restartIfRunning, background: true)
            let workspace = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
            let profile = TerminalServiceProfileCommandResponse(
                message: restartIfRunning ? "Workspace restarted." : "Workspace is running.", workspace: profileWorkspaceRecord(workspace))
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.profileCommand(.workspaceStop)` handler. Stop reaches automation cancellation and terminal
    /// termination, both daemon-owned and potentially engine-touching, so the synchronous profile route
    /// stays off the main actor just like workspace start/restart.
    private nonisolated func workspaceStopOffMain(workspaceID: String) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
        do {
            let orchestrator = try makeProfileOrchestrator()
            _ = try orchestrator.stopWorkspace(workspaceID: workspaceID)
            let workspace = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
            let profile = TerminalServiceProfileCommandResponse(message: "Workspace stopped.", workspace: profileWorkspaceRecord(workspace))
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return Self.failureResponse(error) }
    }

    /// RPC `.profileCommand(.agentKill)` handler. `killAgentSession` finalizes the agent row through the
    /// stop chokepoint, which terminates the backing terminal via the orchestrator's terminator closure
    /// (`TerminalEngineActor.runSynchronously`) — a forbidden synchronous engine wait from the main actor
    /// — so it runs on the transport thread. The subscriber "exited" notice the chokepoint enqueues sends
    /// through `submitAgentNotificationLine`, which on this off-main thread takes its direct send path.
    private nonisolated func agentKillOffMain(_ payload: TerminalServiceAgentKillPayload) -> TerminalServiceResponse {
        if let rejection = livenessState.teardownRejection() { return rejection }
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
        if let rejection = livenessState.teardownRejection() { return rejection }
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

    /// The live foreground process of a session this daemon hosts, paired with whether the session's own
    /// shell is holding any child process. A session it does not host answers nil, which the conditional
    /// stop reads as nothing left to protect. A hosted session whose foreground pid cannot be inspected (a
    /// zombie process-group leader in the instant before the shell reaps it) still answers with a reading
    /// whose `process` is nil, so the child check below keeps standing on its own instead of being skipped
    /// along with the unreadable foreground.
    @TerminalEngineActor private func currentForegroundReading(sessionID: String) -> BuiltInTerminalForegroundReading? {
        guard let core = sessionCores[sessionID] else { return nil }
        let shellHasChildProcesses = core.childPID().map { TerminalForegroundProcessInspector.hasChildProcesses(pid: $0) } ?? false
        return BuiltInTerminalForegroundReading(process: core.currentForegroundProcess(), shellHasChildProcesses: shellHasChildProcesses)
    }

    @TerminalEngineActor private func terminateBuiltInTerminalSession(id sessionID: String) {
        guard !handoffInProgress else { return }
        _ = terminateSession(id: sessionID)
    }

    /// `nonisolated`: bridges the synchronous `@Sendable` `BuiltInTerminalSessionLauncher` closure type
    /// (Device API supervisor, the process-wide orchestrator override, and the profile-command
    /// orchestrator) onto the engine actor. `createSession` runs on the engine via
    /// `TerminalEngineActor.runSynchronously` and returns a success response already carrying the post-start
    /// summary from the live core's in-memory state. This path is what the agent-spawn / workspace-command
    /// launch (`Orchestrator.launchWorkspaceCommandSession`) flows through, so serving the summary from
    /// memory keeps a contended first runtime-state write — or a fast-exiting command's PTY-close job — from
    /// reporting a ghost failure that would leave a live, untracked agent process behind.
    private nonisolated func launchBuiltInTerminalSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws
        -> TerminalServiceSessionSummary
    {
        let response = TerminalEngineActor.runSynchronously {
            self.createSession(TerminalServiceCreateRequest(launchConfiguration: launchConfiguration))
        }
        guard response.ok else { throw Self.requestFailedError(response.message) }
        guard let summary = response.session else {
            throw Self.requestFailedError("Terminal session \(launchConfiguration.sessionID) started but produced no summary.")
        }
        return summary
    }

    private nonisolated static func requestFailedError(_ message: String) -> NSError {
        NSError(domain: "spacesd", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Wraps the live automation scheduler as a Device API `AutomationOperations` bundle: each op resolves the
    /// same queue-confined `AutomationService` the profile-command handlers use and calls it directly, so both
    /// transports share one scheduler. `service` resolves that instance from the off-main box (throwing during
    /// shutdown). No main-actor hop: the Device API connection queue is never main and the service serializes
    /// internally, so entering it directly is deadlock-safe (a main-actor caller blocking on it could deadlock
    /// behind an engine→main tick hop — the one-way rule).
    private static func makeAutomationOperations(_ service: @escaping @Sendable () throws -> AutomationService) -> AutomationOperations {
        AutomationOperations(
            create: { draft in try service().createAutomation(draft) }, update: { id, draft in try service().updateAutomation(id: id, draft: draft) },
            delete: { id in try service().deleteAutomationCommand(id: id) }, list: { try service().listAutomations() },
            runs: { automationID in try service().listAutomationRuns(automationID: automationID) },
            trigger: { id in try service().triggerAutomation(id: id) }, cancelRun: { runID in try service().cancelAutomationRun(runID: runID) },
            endAgents: { runID in try service().endAttributedAgents(runID: runID) })
    }

    private func profileProjectSummary(_ value: ProjectSummary) -> TerminalServiceProfileProjectSummary {
        TerminalServiceProfileProjectSummary(
            id: value.id, name: value.name, dir: value.dir, isGitRepo: value.isGitRepo, defaultBranch: value.defaultBranch)
    }

    private nonisolated func profileWorkspaceRecord(_ value: WorkspaceRecord) -> TerminalServiceProfileWorkspaceRecord {
        TerminalServiceProfileWorkspaceRecord(
            id: value.id, projectID: value.projectID, dir: value.dir, dirname: value.dirname, branch: value.branch, baseBranch: value.baseBranch,
            isDefault: value.isDefault, isHidden: value.isHidden, isRunning: value.isRunning, lastLaunchedAt: value.lastLaunchedAt, notes: value.notes
        )
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

        // Per-tool hooks fire `working` as each tool starts and again as it completes. When the
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
        if shouldFlushQueuedNotifications { try engine.subscriberDidBecomeIdle(subscriberTerminalSessionID: sessionID) }
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
            // The `(<kind>)` parenthetical is the detected agent kind (see `CodingAgent`) the row
            // carries — the same identity an orchestration row's `agent:` field reports, kept off the
            // launch title so the label is not duplicated (`smoke-hello (smoke-hello)`). Resolved through
            // the orchestrator so this path and the reconcilers' own engine name a kind identically,
            // including at exit, when live foreground state no longer reports one.
            resolveAgentKind: { agent in orchestrator.resolvedAgentKind(agent) }, logError: { writeStandardError($0) })
    }

    /// Delivers a rendered notification line into a subscriber terminal and submits it with a single
    /// `appendNewline: true` send. Submit-safety lives at the session-host send chokepoint
    /// (`GhosttyEmbeddedSessionHost`/`GhosttyLinuxHeadlessSessionCore`): for a text payload with
    /// `appendNewline` it writes the text as a paste and the carriage return as its own write, so an agent
    /// TUI reads the framed text and then a distinct Enter keystroke and submits the line rather than
    /// treating the whole burst as an unsubmitted paste. This helper is the shared chokepoint used by the
    /// local notification engine wiring and the cross-device `RemoteAgentWatchService` so both submit
    /// identically.
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
    /// the command must launch a supported coding agent (see `CodingAgent`) so spawn readiness
    /// knows which foreground kind to await. Hooks are not a prerequisite — readiness is
    /// foreground-detection-based, polled CLI-side against the session's terminal id.
    private nonisolated func spawnProfileAgentSession(_ payload: TerminalServiceAgentSpawnPayload, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        do { _ = try AgentSpawnCommandGate.resolveSpawnableAgent(command: payload.command) } catch let error as AgentSpawnCommandGate.GateError {
            throw SpacesRuntimeError.invalidArgument(message: error.errorDescription ?? "Agent spawn command is not supported.")
        }
        let workspaceID = try orchestrator.resolveWorkspaceID(explicitWorkspaceID: payload.workspaceID, cwd: payload.cwd)
        let session = try orchestrator.createWorkspaceAgentSession(
            workspaceID: workspaceID, command: payload.command, title: payload.title, automationRunID: payload.automationRunID)
        return TerminalServiceProfileCommandResponse(message: "Started agent session.", terminalSession: session)
    }

    /// Terminates a coding-agent session addressed by its terminal session id. The orchestrator owns
    /// the flow (`killAgentSession`): a hook-signaled child stops through the coding-agent stop path
    /// with its subscribers told it exited first, and a not-yet-signaled session is terminated only
    /// when it was launched as a coding agent. A session that is neither is a loud error.
    private nonisolated func killProfileAgentSession(_ sessionID: String, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        guard try orchestrator.killAgentSession(terminalSessionID: sessionID) else {
            throw SpacesRuntimeError.invalidArgument(message: "No agent session for terminal \(sessionID).")
        }
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
            remoteAgentWatchService?.seedBaseline(deviceID: deviceID, childTerminalSessionID: payload.agentSessionID, row: validatedRow)
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
        if let rejection = livenessState.teardownRejection() { return rejection }
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
            if let rejection = self.livenessState.teardownRejection() { return rejection }
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
                        updatedAt: now, exitedAt: now, workingDirectory: launchConfiguration.workingDirectory)
                if runtimeState.servicePID != getpid(), Self.isLive(runtimeState), Self.isProcessAlive(pid: Int(runtimeState.servicePID)) {
                    return TerminalServiceResponse(
                        ok: false, message: "Terminal session \(sessionID) is owned by another process and was not stopped by spacesd.")
                }
                // `bellAt` carries forward: a session ending does not answer the bell it rang, and the
                // client's alert (whose identity is that timestamp) must survive the exit write.
                let exitedState = TerminalSessionRuntimeState(
                    sessionID: runtimeState.sessionID, backend: runtimeState.backend, servicePID: runtimeState.servicePID,
                    childPID: runtimeState.childPID, state: .exited, updatedAt: now, exitedAt: now, title: runtimeState.title,
                    workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                    rows: runtimeState.rows, bellAt: runtimeState.bellAt)
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
    /// caller — `terminateSession` on the engine actor is the caller today.
    private nonisolated func sessionSummary(for sessionID: String) throws -> TerminalServiceSessionSummary {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let launchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        return try summary(for: launchConfiguration, paths: paths)
    }

    /// `nonisolated`: reads only `TerminalSessionPersistence` (disk) and a process-alive check, so it runs
    /// correctly regardless of caller — `listSessionsOffMain` calls it off the main actor.
    private nonisolated func summaryIfLive(for knownSession: KnownTerminalSession) throws -> TerminalServiceSessionSummary? {
        let launchConfiguration = knownSession.launchConfiguration
        let paths = knownSession.paths
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
            hasFinalRender: (try? TerminalSessionPersistence.hasFinalRender(paths: paths)) ?? false)
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

    /// The live core's answer to a Device API `.state` read: the same payload a fresh subscriber's initial
    /// frame carries, so bypassing the subscription socket changes nothing the reader observes. Nil when no
    /// live core hosts the session, which sends the reader down the persisted/socket read.
    @TerminalEngineActor private func liveCoreOneShotStatePayload(sessionID: String) -> GhosttyRemoteSessionStatePayload? {
        sessionCores[sessionID]?.currentOneShotStatePayload()
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
        // Defer the first garbage-collection sweep by a full interval so clients re-attaching and handoff
        // resume completing after a daemon (re)start are never mistaken for a removed session. The deferral
        // marker is engine-isolated (it belongs to the GC path), so seed it on the engine actor; this hop
        // completes well before the first 1s timer tick reaches the same actor.
        Task { @TerminalEngineActor [weak self] in self?.lastSessionGarbageCollectionAt = Date() }
        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // `reapInactiveSessions` and `garbageCollectRemovedSessionsIfDue` are both engine-isolated
            // (they read `sessionCores`), so this hops onto the engine actor directly rather than the main
            // actor the timer callback fires on.
            Task { @TerminalEngineActor [weak self] in
                self?.reapInactiveSessions()
                self?.garbageCollectRemovedSessionsIfDue()
            }
        }
        if let lifecycleTimer { RunLoop.main.add(lifecycleTimer, forMode: .common) }
    }

    /// Reaps `.whileAttached` sessions once nothing still holds them, read from each core's in-memory
    /// attachment authority (`hasLiveAttachments`) rather than the durable mirror. A core is the sole writer
    /// of its own attachment rows, but the mirror write it enqueues for a just-applied attach can still be
    /// queued behind a contended write lock (see `TerminalCorePersistenceQueue`); a DB read here would race
    /// that queued write and could reap a session with a live owner. `.whileAttached` has no in-product
    /// creator today (nothing in the repo passes it; it is reachable only through a hand-crafted create
    /// request), so this loop is latent until that policy is used.
    @TerminalEngineActor private func reapInactiveSessions() {
        for (sessionID, sessionCore) in sessionCores {
            guard sessionCore.launchConfiguration.lifetimePolicy == .whileAttached else { continue }
            guard !sessionCore.hasLiveAttachments() else { continue }
            _ = terminateSession(id: sessionID)
        }
    }

    /// Reclaims the directory, transcript, and rows of sessions the product no longer shows, on a coarse
    /// cadence. The daemon is the sole owner of each session's on-disk footprint and the only party that
    /// can see authoritative attachment state across every client, so this GC lives here rather than in a
    /// client. `TerminalSessionGarbageCollector` enforces the safety gates (ended, unattached, unreferenced
    /// / age-expired / over-budget); the in-memory `sessionCores` are handed in so a live session the daemon
    /// owns is never collected. Age-expiry releases a long-ended session's product rows through the
    /// orchestrator's `releaseEndedTerminalSessionReferences` (agent rows via the finalization chokepoint),
    /// so the orchestrator is built lazily: the common sweep — nothing expired — never constructs it.
    /// The orphan sweep runs after collection so its "known" set reflects the rows that survived it.
    /// Engine-isolated because it reads `sessionCores`, which now lives on `TerminalEngineActor`.
    @TerminalEngineActor private func garbageCollectRemovedSessionsIfDue(now: Date = Date()) {
        if let lastSessionGarbageCollectionAt, now.timeIntervalSince(lastSessionGarbageCollectionAt) < Self.sessionGarbageCollectionInterval {
            return
        }
        lastSessionGarbageCollectionAt = now
        do {
            let store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
            var expiryOrchestrator: WorkspaceOrchestrator?
            try TerminalSessionGarbageCollector.collectRemovedSessions(
                activeSessionIDs: Set(sessionCores.keys), isReferencedByProduct: { try store.terminalSessionIsReferencedByProduct($0) },
                releaseExpiredReferences: { [self] sessionID in
                    let orchestrator = try expiryOrchestrator ?? makeProfileOrchestrator()
                    expiryOrchestrator = orchestrator
                    try orchestrator.releaseEndedTerminalSessionReferences(sessionID: sessionID)
                }, now: now,
                onPurgeFailure: { sessionID, error in
                    writeStandardError("spaces: terminal session garbage collection failed to purge \(sessionID), will retry next sweep: \(error)\n")
                },
                onBudgetExceeded: { totalBytes in
                    writeStandardError(
                        "spaces: ended terminal sessions hold \(totalBytes) bytes, over the \(TerminalSessionRetentionPolicy.standard.endedTranscriptByteBudget)-byte budget with no evictable session; will retry next sweep\n"
                    )
                })
            let knownSessionIDs = Set(try TerminalSessionPersistence.listKnownSessions().map(\.sessionID))
            try TerminalSessionOrphanSweep.sweep(
                knownSessionIDs: knownSessionIDs, activeSessionIDs: Set(sessionCores.keys),
                gracePeriod: TerminalSessionRetentionPolicy.standard.orphanGracePeriod, now: now,
                onFailure: { path, error in
                    writeStandardError("spaces: terminal session orphan sweep failed to remove \(path), will retry next sweep: \(error)\n")
                })
        } catch { writeStandardError("spaces: terminal session garbage collection failed: \(error)\n") }
    }

    /// Single startup repair chokepoint for durable runtime rows a predecessor daemon image (or a
    /// crashed prior process) left in a live state. Runs once, AFTER handoff adoption, so the sessions
    /// this image adopted (`adoptedSessionIDs`) are exempt. The full repair matrix — dead pid → repair
    /// `.failed`; own pid not adopted → repair `.exited`; own pid adopted → live; other live pid → leave
    /// — lives in `TerminalSessionStaleRecovery.reconcile`, keyed on the injected `getpid()` and the
    /// daemon's own `isProcessAlive` probe. The own-pid-not-adopted case is what closes the
    /// lost-write-across-`execv` class (`execv` preserves the pid, so the plain dead-pid check can never
    /// fire for a stranded row); a plain shutdown needs nothing more, since its successor runs under a
    /// different pid and its rows fall to the dead-pid case.
    private func recoverStaleSessions(adoptedSessionIDs: Set<String> = []) throws {
        let result = try TerminalSessionStaleRecovery.reconcile(
            ownPID: getpid(), adoptedSessionIDs: adoptedSessionIDs, isProcessAlive: { Self.isProcessAlive(pid: Int($0)) })
        // A repair write that could not commit within the sweep's bounded retry leaves the row in its
        // prior live state; it heals at the next daemon restart via the dead-pid branch. Log it so the
        // strand is observable rather than silent.
        for sessionID in result.unrepaired { writeStandardError("spacesd stale_session_repair_failed session=\(sessionID)\n") }
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

    /// Machine-readable failure category for a thrown error at the terminal-service flatten points.
    /// Delegates to `SpacesDaemonErrorClassification`, which owns the mapping so it stays testable and
    /// aligned with the Device API server's classification.
    private nonisolated static func errorCode(_ error: any Error) -> SpacesDeviceErrorCode { SpacesDaemonErrorClassification.errorCode(error) }

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
        agentSessionKiller: (@Sendable (String) throws -> Bool)? = nil, automationOperations: AutomationOperations? = nil,
        onRestartRequested: (@Sendable () -> Void)? = nil,
        liveTerminalSessionStateProvider: (@Sendable (String) -> GhosttyRemoteSessionStatePayload?)? = nil,
        liveInMemoryTerminalSessionsProvider: (@Sendable () -> [TerminalSessionCatalogEntry])? = nil
    ) {
        #if canImport(spacesdeviceapi)
            supervisor = SpacesDeviceAPISupervisor(
                builtInTerminalSessionTerminator: builtInTerminalSessionTerminator, builtInTerminalSessionLauncher: builtInTerminalSessionLauncher,
                agentSessionKiller: agentSessionKiller, automationOperations: automationOperations, onRestartRequested: onRestartRequested,
                liveTerminalSessionStateProvider: liveTerminalSessionStateProvider,
                liveInMemoryTerminalSessionsProvider: liveInMemoryTerminalSessionsProvider)
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
                await controller.shutdownOnce()
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
                // AppKit's `applicationWillTerminate` only reaches NSApp-driven termination (logout,
                // `NSApp.terminate`); a plain SIGTERM/SIGINT (what launchd and `kill` send) never runs it,
                // so without this the whole graceful teardown — transcript flush, attachment finalization,
                // reconcile-store WAL checkpoint, router stop — is skipped and the process dies mid-write.
                // Install the same signal sources the non-AppKit branch uses, before `app.run()` so nothing
                // can signal the process in the gap.
                let signalSources = installTerminationSignalHandlers(controller: controller)
                // Kick startup as a main-actor Task and then run the app run loop: `start()` awaits the
                // exec-in-place resume, which needs the run loop pumping ticks, and the request-accepting
                // server starts only after the resume completes.
                Task { @MainActor in
                    do { try await controller.start() } catch {
                        writeStandardError("spacesd: \(error)\n")
                        exit(1)
                    }
                }
                // Hold the signal sources for the run loop's lifetime — see
                // `installTerminationSignalHandlers` for why letting them deallocate silently disables
                // graceful shutdown.
                withExtendedLifetime(signalSources) { app.run() }
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
                    await controller.shutdownOnce()
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

    /// Installs a `DispatchSourceSignal` for SIGTERM and SIGINT so a signalled daemon runs its graceful
    /// teardown (transcript flush, attachment finalization, reconcile-store WAL checkpoint, router stop)
    /// instead of dying at the kernel's default disposition, which is an immediate, teardown-free exit.
    /// `signal(n, SIG_IGN)` must run before the dispatch source is created: a `DispatchSourceSignal` only
    /// OBSERVES a signal's delivery, it does not change what the signal does to the process, so without
    /// first ignoring it the default disposition (terminate) still fires the instant the signal arrives.
    /// The caller must hold the returned sources for the process's lifetime with `withExtendedLifetime` —
    /// a released `DispatchSourceSignal` cancels, which reverts to the ignore-only disposition installed
    /// above and silently disables graceful shutdown for the rest of the process's life, with no error to
    /// signal the regression.
    private static func installTerminationSignalHandlers(controller: SpacesDaemonController) -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { signalNumber in
            _ = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                writeStandardError("spacesd: received \(signalName(signalNumber)); shutting down\n")
                Task { @MainActor in
                    await controller.shutdownOnce()
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
}

private func writeStandardError(_ message: String) { FileHandle.standardError.write(Data(message.utf8)) }

private func environmentValue(_ name: String) -> String? {
    guard let rawValue = getenv(name) else { return nil }
    return String(cString: rawValue)
}
