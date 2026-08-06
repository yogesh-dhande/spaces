import Foundation

#if os(macOS)
    public enum TerminalService {
        public static func ping(timeout: TimeInterval = 2) throws {
            let response = try pingResponse(timeout: timeout)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
        }

        public static func createSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
            if shouldUseXCTestCompatibilityBackend() { return try createXCTestCompatibilitySession(launchConfiguration) }
            let startedAt = Date()
            let ensureStartedAt = Date()
            let launchedService = try ensureRunning()
            let ensureElapsedMS = TerminalPerformance.elapsedMS(since: ensureStartedAt)
            let socketPath = try TerminalServicePaths.socketPath()
            let requestStartedAt = Date()
            let requestTimeout = createSessionRequestTimeout()
            let rpcTimeout = min(requestTimeout, createSessionRPCResponseTimeout())
            let response: TerminalServiceResponse
            do {
                response = try TerminalServiceClient.send(
                    request: TerminalServiceRequest(command: .create(.init(launchConfiguration: launchConfiguration))), socketPath: socketPath,
                    timeout: rpcTimeout)
            } catch {
                if let recovered = waitForCreatedSessionSummary(launchConfiguration, timeout: requestTimeout) {
                    TerminalPerformance.logMetric(
                        "terminal_service_create_session", target: "session=\(launchConfiguration.sessionID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                        detail:
                            "service_launch=\(launchedService ? 1 : 0) ensure_running_ms=\(ensureElapsedMS) rpc_ms=\(TerminalPerformance.elapsedMS(since: requestStartedAt)) recovered=1 error=\(String(describing: error)) state=\(recovered.state.rawValue)"
                    )
                    return recovered
                }
                throw error
            }
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
            guard let session = response.session else { throw TerminalServiceError.requestFailed("spacesd did not return a session summary.") }
            TerminalPerformance.logMetric(
                "terminal_service_create_session", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail:
                    "service_launch=\(launchedService ? 1 : 0) ensure_running_ms=\(ensureElapsedMS) rpc_ms=\(TerminalPerformance.elapsedMS(since: requestStartedAt)) state=\(session.state.rawValue)"
            )
            return session
        }

        public static func terminateSession(id sessionID: String) throws {
            if shouldUseXCTestCompatibilityBackend() {
                try terminateXCTestCompatibilitySession(id: sessionID)
                return
            }
            try ensureRunning()
            let socketPath = try TerminalServicePaths.socketPath()
            let response = try TerminalServiceClient.send(
                request: TerminalServiceRequest(command: .terminate(.init(sessionID: sessionID))), socketPath: socketPath, timeout: 10)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
        }

        public static func listSessions() throws -> [TerminalServiceSessionSummary] {
            if shouldUseXCTestCompatibilityBackend() { return try listXCTestCompatibilitySessions() }
            let socketPath = try TerminalServicePaths.socketPath()
            guard FileManager.default.fileExists(atPath: socketPath) else { return [] }
            let response = try TerminalServiceClient.send(request: TerminalServiceRequest(command: .list), socketPath: socketPath, timeout: 5)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
            return response.sessions ?? []
        }

        public static func sendProfileCommand(_ profileCommand: TerminalServiceProfileCommand, timeout: TimeInterval = 15) throws
            -> TerminalServiceProfileCommandResponse
        {
            try ensureRunning(timeout: min(timeout, 5))
            let socketPath = try TerminalServicePaths.socketPath()
            let response = try TerminalServiceClient.send(
                request: TerminalServiceRequest(command: .profileCommand(profileCommand)), socketPath: socketPath, timeout: timeout)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
            guard let profile = response.profile else { throw TerminalServiceError.requestFailed("spacesd did not return a profile response.") }
            return profile
        }

        /// - Parameter requireWireCompatibility: When `true` (the default, used by command dispatch),
        ///   an adopted already-running daemon must speak this build's wire protocol or this throws.
        ///   `relaunch` passes `false`: it is replacing the daemon, so it must tolerate the outgoing
        ///   stale daemon still answering ping during its shutdown grace instead of aborting the wait.
        ///
        /// A ping answered with `ok == false` and `errorCode == .handingOff` means the daemon is alive
        /// and mid exec-in-place handoff to an updated image, not dead — see `waitForLivePongThroughTransition`.
        /// This waits for the replacement image instead of spawning a competing daemon. A ping answered
        /// with `.shuttingDown` means the opposite: the daemon is on its way out with no successor coming,
        /// so instead of waiting for a replacement the flock winner waits for that daemon's instance-lock
        /// ownership to actually end (see `waitForInstanceLockOwnerToExit`) before spawning a fresh one of
        /// its own. That same gate also covers a daemon whose accept source is already cancelled and
        /// answers no ping at all while it drains persistence — it reads the lock, the contended resource,
        /// rather than depending on the daemon still being reachable enough to say `.shuttingDown`.
        @discardableResult public static func ensureRunning(timeout: TimeInterval = 5, requireWireCompatibility: Bool = true) throws -> Bool {
            let startedAt = Date()
            let socketPath = try TerminalServicePaths.socketPath()
            if FileManager.default.fileExists(atPath: socketPath), let response = try? pingResponse(timeout: 1) {
                if response.ok {
                    if requireWireCompatibility { try assertDaemonWireCompatible(response) }
                    TerminalPerformance.logMetric(
                        "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: true, detail: "launched=0")
                    return false
                }
                // The daemon answered but is mid exec-handoff, not dead: wait for the replacement image to
                // rebind the socket instead of spawning a second daemon (which would only lose the instance
                // lock and exit). A non-transitional failure (an ordinary error, or no daemon at all) falls
                // straight through to the normal lock-and-spawn path below.
                if isTransitionalHandoffPing(response), let liveResponse = Self.waitForLivePongThroughTransition(socketPath: socketPath) {
                    if requireWireCompatibility { try assertDaemonWireCompatible(liveResponse) }
                    TerminalPerformance.logMetric(
                        "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: true, detail: "launched=0 transitioned=1")
                    return false
                }
            }

            // Serialize the spawn across processes and threads. Concurrent callers (app startup
            // threads, the CLI, harnesses) previously each launched a spacesd; the instance-lock
            // loser exited, but both raced TerminalServiceTLSIdentityStore generation, which can
            // leave the surviving listener serving a certificate that no longer matches the
            // fingerprint pairing advertised — after which every pinned Device API connect hangs
            // to its timeout. One launcher holds the flock; everyone else waits on it, then
            // adopts the daemon the winner started. Lock wait is intentionally outside the
            // startup timeout because a profile migration may hold this same lock while it
            // creates a database backup.
            let launchLockPath = try TerminalServicePaths.launchLockPath()
            let lockDescriptor = open(launchLockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lockDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(lockDescriptor) }

            while flock(lockDescriptor, LOCK_EX) != 0 { guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) } }
            defer { flock(lockDescriptor, LOCK_UN) }

            // The lock winner may be adopting a daemon another launcher finished starting first.
            if FileManager.default.fileExists(atPath: socketPath), let response = try? pingResponse(timeout: 1) {
                if response.ok {
                    if requireWireCompatibility { try assertDaemonWireCompatible(response) }
                    TerminalPerformance.logMetric(
                        "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: true, detail: "launched=0 adopted=1")
                    return false
                }
                // Same transitional wait as the pre-lock check above: the winner may be looking at a
                // daemon that started handing off to an update after we took the lock.
                if isTransitionalHandoffPing(response), let liveResponse = Self.waitForLivePongThroughTransition(socketPath: socketPath) {
                    if requireWireCompatibility { try assertDaemonWireCompatible(liveResponse) }
                    TerminalPerformance.logMetric(
                        "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: true, detail: "launched=0 adopted=1 transitioned=1")
                    return false
                }
            }

            // A live instance-lock owner means a spawn right now is doomed: the child's
            // `SpacesDaemonController.init` collides with the still-held lock, throws `alreadyRunning`,
            // and exits immediately, and the spawn-poll loop below never retries the spawn itself (it
            // only pings), so the caller's operation would fail even though a working daemon was moments
            // away. Wait for the owner to actually leave — not merely to have announced it is leaving —
            // before falling through to spawn.
            //
            // The gate reads `TerminalServiceInstanceLock` itself, the actual contended resource, instead
            // of a ping response. That is what lets one check cover both ways an outgoing daemon can look
            // right now: one still answering pings with a `.shuttingDown` rejection, and one whose accept
            // source is already cancelled — so a ping gets no response at all — while it drains queued
            // session persistence. Either way the lock file is the fact that actually distinguishes
            // "going" from "gone"; a ping response alone cannot in the second case, because there isn't
            // one.
            //
            // This runs only here, after the flock is held, so exactly one caller (the launch winner)
            // pays the wait; every other concurrent caller is already parked on the flock and simply
            // adopts whatever the winner ends up starting.
            //
            // A handoff never trips this into a harmful wait: the exec'd successor keeps the same pid, so
            // the lock record it inherits still names that same live pid as owner, and the handoff cases
            // above already returned earlier via `waitForLivePongThroughTransition`'s `.handingOff` wait
            // before this point is ever reached.
            waitForInstanceLockOwnerToExit(socketPath: socketPath, lockPath: try TerminalServicePaths.instanceLockPath())

            // The gate above can end two ways: the owner actually left, or a live daemon answered `ok`
            // while still wearing the owner's pid (an exec-in-place successor never changes pid). Re-check
            // for the latter here, before spawning: spawning into an already-live daemon would only create
            // a doomed competitor that loses the instance lock and exits.
            if FileManager.default.fileExists(atPath: socketPath), let response = try? pingResponse(timeout: 1), response.ok {
                if requireWireCompatibility { try assertDaemonWireCompatible(response) }
                TerminalPerformance.logMetric(
                    "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                    success: true, detail: "launched=0 adopted=1 lockgate=1")
                return false
            }

            // Computed after the instance-lock-owner wait above, not before it, so a slow-to-exit outgoing
            // daemon never eats into the budget the spawn-poll loop below needs to observe a freshly
            // spawned replacement.
            let deadline = Date().addingTimeInterval(timeout)

            let profile = try SpacesProfile.current()
            // What actually started the daemon, for the metric detail and for the timeout error: launchd
            // resolves the installed job's binary itself, so naming the label rather than a path is the
            // honest report of what was asked to start.
            let startedBy: String
            let startDetail: String
            if case .launchAgentKickstart(let label) = resolveStartPlan(profile: profile), kickstartLaunchAgent(label: label, deadline: deadline) {
                startedBy = label
                startDetail = "launchagent=\(label)"
            } else {
                // Reached either because this profile is started directly (a development profile, a pinned
                // SPACESD_EXECUTABLE, or an installed profile whose agent plist the installer never wrote), or
                // because the kickstart failed. The second case is a deliberate fallback: an installed profile
                // whose LaunchAgent is unloaded or broken would otherwise leave the user with no daemon at all
                // and no client-side way back, so a client-owned daemon in that already-degraded install beats
                // none. It reintroduces the launchd-versus-client ownership fight only there, and only until
                // the next install repair rewrites the agent.
                let executableURL = try resolveExecutableURL(profile: profile)
                let process = Process()
                process.executableURL = executableURL
                process.environment = ProcessInfo.processInfo.environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                startedBy = executableURL.path
                startDetail = "pid=\(process.processIdentifier)"
            }

            while Date() < deadline {
                if FileManager.default.fileExists(atPath: socketPath), let response = try? pingResponse(timeout: 1), response.ok {
                    if requireWireCompatibility { try assertDaemonWireCompatible(response) }
                    TerminalPerformance.logMetric(
                        "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: true, detail: "launched=1 \(startDetail)")
                    return true
                }
                Thread.sleep(forTimeInterval: 0.05)
            }

            TerminalPerformance.logMetric(
                "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                success: false, detail: "launched=1 \(startDetail)")
            throw TerminalServiceError.serviceStartupTimedOut(startedBy)
        }

        /// Pins which `spacesd` binary starts. Shared by daemon resolution and the start-plan decision so the
        /// two cannot disagree about whether a pin is in force.
        static let pinnedExecutableEnvironmentVariable = "SPACESD_EXECUTABLE"

        /// Environment bindings that forbid starting a daemon through launchd, whatever the profile.
        ///
        /// One criterion covers the whole list: launchd starts the job with its own environment, so any Spaces
        /// binding that changes WHICH daemon runs or HOW it serves this client is dropped on the way to a
        /// kickstarted daemon. What comes up is then the wrong build, or a daemon serving a socket or an
        /// endpoint this caller is not talking to, and the caller's poll times out against a daemon that is
        /// running perfectly well. Spawning directly is what carries the binding to the daemon that has to
        /// honor it.
        ///
        /// The Device API variables are mirrored as literals rather than referenced: `SpacesDeviceAPIConfiguration`
        /// owns them and its module depends on this one, so they cannot be imported here. Those declarations
        /// carry a note pointing back at this list so a rename cannot silently drift.
        static let kickstartForbiddingEnvironmentVariables = [
            pinnedExecutableEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable, CaddyService.executableEnvironmentVariable,
            "SPACES_DEVICE_API_DISABLED", "SPACES_DEVICE_API_HOST", "SPACES_DEVICE_API_PORT",
        ]

        /// How `ensureRunning` starts a daemon once it has decided one has to be started.
        enum DaemonStartPlan: Equatable {
            /// Spawn the `spacesd` this client resolves, as a child of this process.
            case directSpawn
            /// Ask launchd to start the installed profile's LaunchAgent job with this label.
            case launchAgentKickstart(label: String)
        }

        /// Decides how this profile's daemon should be started, so that the installed profile has exactly one
        /// spawner on the machine.
        ///
        /// The installer writes a per-user LaunchAgent (`SpacesBinaryLayout.launchAgentURL`) with `KeepAlive`,
        /// making launchd the supervisor that keeps an installed daemon available with no app running. A client
        /// that spawned that daemon itself would take the profile's instance lock, launchd's own spawn would
        /// lose the lock and exit non-zero, and `KeepAlive` would retry it every few seconds for as long as the
        /// client-owned daemon lives. Routing the start through launchd keeps ownership where the supervision
        /// is.
        ///
        /// Any binding in `kickstartForbiddingEnvironmentVariables` forces a direct spawn, for every profile
        /// including the installed one, because launchd would drop it.
        ///
        /// A kickstart is also only correct when this process's home IS the account home. `launchctl kickstart`
        /// addresses a job REGISTERED in the user's GUI domain by label; it does not load or even read the plist
        /// path checked here. A process running with an isolated `HOME` therefore still reaches the real
        /// account's registered job, whatever its own home contains, so it would start the production daemon
        /// against a profile resolved somewhere else entirely and then poll a socket that job will never bind.
        /// The plist check cannot see that, because a same-named plist under an isolated home (exactly what a
        /// test fixture writes) looks identical to the installed one. Comparing the home the profile resolved
        /// from against the account home from the password database is what establishes that the registered job
        /// and this caller's profile belong to the same user. An unknown account home means that identity cannot
        /// be established at all, so it spawns directly.
        ///
        /// A development profile has no agent, and an installed profile can be missing its plist when the
        /// install is partial. Both are started directly.
        ///
        /// - Parameter accountHomeDirectoryPath: The account's real home, from the password database rather
        ///   than `HOME`, which is what makes it evidence of identity rather than of what the environment
        ///   claims. `nil` means it could not be read.
        /// - Parameter launchAgentURL: Where to look for the agent plist. `nil` resolves it under the same home
        ///   `environment` resolves a profile from (`SpacesProfile.currentHomeDirectoryURL`), rather than
        ///   `SpacesBinaryLayout.launchAgentURL()`'s `NSHomeDirectory()`, which ignores an overridden `HOME`.
        ///   Past the home-identity gate above the two homes are the same path, so this is the same lookup
        ///   stated in terms of the home actually in play.
        static func resolveStartPlan(
            environment: [String: String] = ProcessInfo.processInfo.environment, profile: SpacesProfile, fileManager: FileManager = .default,
            accountHomeDirectoryPath: String? = SpacesProfile.accountHomeDirectoryPath(), launchAgentURL: URL? = nil
        ) -> DaemonStartPlan {
            for variable in kickstartForbiddingEnvironmentVariables {
                let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard value.isEmpty else { return .directSpawn }
            }
            guard profile.isInstalledProfile, let accountHomeDirectoryPath else { return .directSpawn }
            let environmentHomeURL = SpacesProfile.currentHomeDirectoryURL(environment: environment)
            guard SpacesProfile.canonicalPath(environmentHomeURL.path) == SpacesProfile.canonicalPath(accountHomeDirectoryPath) else {
                return .directSpawn
            }
            let plistURL = launchAgentURL ?? SpacesBinaryLayout.launchAgentURL(homeDirectoryURL: environmentHomeURL)
            guard fileManager.fileExists(atPath: plistURL.path) else { return .directSpawn }
            return .launchAgentKickstart(label: SpacesBinaryLayout.launchAgentLabel)
        }

        /// Asks launchd to start the installed profile's daemon job now, and reports whether launchctl said it
        /// worked. The caller's socket poll, not this, decides whether a daemon is actually reachable.
        ///
        /// `kickstart` rather than `load` or `start`: the job is already bootstrapped by the installer, and
        /// `kickstart` both starts it immediately when launchd is holding it in respawn-throttle backoff and is
        /// a no-op when the job's process is already running.
        ///
        /// `deadline` is `ensureRunning`'s deadline, so waiting on launchctl never outlives the caller's window;
        /// `launchAgentKickstartTimeout` caps it further so an unresponsive launchd cannot consume a generous
        /// budget and leave nothing for the socket poll that decides the outcome.
        private static func kickstartLaunchAgent(label: String, deadline: Date) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let waitDeadline = min(deadline, Date().addingTimeInterval(launchAgentKickstartTimeout))
            while process.isRunning, Date() < waitDeadline { Thread.sleep(forTimeInterval: 0.05) }
            guard !process.isRunning else {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        }

        private static let launchAgentKickstartTimeout: TimeInterval = 5

        @discardableResult public static func relaunch(timeout: TimeInterval = 5) throws -> Bool {
            let socketPath = try TerminalServicePaths.socketPath()
            if FileManager.default.fileExists(atPath: socketPath) {
                stopExistingService(socketPath: socketPath, timeout: min(max(timeout / 2, 0.5), 2))
            }
            try? FileManager.default.removeItem(atPath: socketPath)
            return try ensureRunning(timeout: timeout, requireWireCompatibility: false)
        }

        /// Session-preserving replacement for `relaunch`, used by opportunistic ensure-current recovery.
        ///
        /// `relaunch` force-kills the daemon and every terminal session it hosts. This instead delegates the
        /// busy check to the daemon via `.shutdownIfIdle`, which the daemon evaluates atomically: a daemon with
        /// live sessions refuses (returns `ok == false`) and is left running untouched, so this returns `false`
        /// without killing or spawning anything and the caller must treat recovery as not done. An idle daemon
        /// complies, and it is then replaced exactly like `relaunch`.
        ///
        /// - Returns: `true` when a fresh daemon is (re)started or was already running; `false` when the daemon
        ///   refused because it still has live sessions.
        @discardableResult public static func relaunchIfIdle(timeout: TimeInterval = 5) throws -> Bool {
            let socketPath = try TerminalServicePaths.socketPath()
            guard FileManager.default.fileExists(atPath: socketPath) else {
                return try ensureRunning(timeout: timeout, requireWireCompatibility: false)
            }
            let response: TerminalServiceResponse
            do {
                response = try TerminalServiceClient.send(
                    request: TerminalServiceRequest(command: .shutdownIfIdle), socketPath: socketPath, timeout: min(timeout, 1))
            } catch {
                // An unresponsive daemon (dead socket file / hung process) can't vouch for its sessions, so fall
                // back to the forced relaunch today's recovery relies on for genuinely hung daemons.
                return try relaunch(timeout: timeout)
            }
            guard response.ok else { return false }
            var candidatePIDs = Set<pid_t>()
            if let servicePID = response.servicePID { candidatePIDs.insert(pid_t(servicePID)) }
            _ = waitForServiceExit(socketPath: socketPath, candidatePIDs: candidatePIDs, timeout: timeout)
            try? FileManager.default.removeItem(atPath: socketPath)
            return try ensureRunning(timeout: timeout, requireWireCompatibility: false)
        }

        private static func pingResponse(timeout: TimeInterval = 2) throws -> TerminalServiceResponse {
            let socketPath = try TerminalServicePaths.socketPath()
            return try TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath, timeout: timeout)
        }

        /// Bounds how long `ensureRunning` waits for a transitional `.handingOff` ping to resolve into a
        /// live pong before giving up and falling back to spawning a new daemon. The handoff preflight the
        /// old image runs before exec-ing (`DaemonHandoffPreflight.run`) can alone take up to 10s, and the
        /// replacement image then needs a further moment to exec and rebind the socket, so 15s leaves margin
        /// without masking a daemon that genuinely vanished mid-handoff. This wait is specific to a handoff:
        /// a `.shuttingDown` ping never reaches it, because no successor is coming for `ensureRunning` to
        /// wait for (issue #325's follow-up split — see `DaemonLivenessState.teardownRejection`'s doc).
        private static let handoffTransitionTimeout: TimeInterval = 15

        /// True when a ping response means "the daemon is alive but mid exec-handoff", i.e. answered its
        /// own liveness probe with `.handingOff` rather than timing out, refusing to connect, or reporting
        /// `.shuttingDown`. A `.shuttingDown` ping is also a live answer, but it promises no successor is
        /// coming, so `ensureRunning` must not pause here waiting for one — it needs to fall straight
        /// through to the unified `waitForInstanceLockOwnerToExit` gate's own bounded wait for that
        /// daemon's exit instead. Any other failure (a different error code, or no response at all) is an
        /// ordinary "daemon looks dead" signal and gets the same immediate-spawn treatment — that gate
        /// runs regardless, so it also catches the no-response case.
        ///
        /// Peers are lockstep on `SpacesWireProtocol` (exact-version match, no backward compatibility), so
        /// this predicate only ever interprets a response from a same-version daemon. A foreign-version
        /// daemon's teardown responses carry no contract here: the worst a misread one costs is one bounded
        /// wait — `handoffTransitionTimeout` for a code misread as a handoff, `shutdownExitTimeout`'s
        /// lock-owner gate otherwise — before `ensureRunning` falls through to its normal spawn-and-poll
        /// path and recovers.
        static func isTransitionalHandoffPing(_ response: TerminalServiceResponse) -> Bool { !response.ok && response.errorCode == .handingOff }

        /// Polls liveness until the daemon that reported a transitional `.handingOff` ping answers a live
        /// pong again, or `handoffTransitionTimeout` elapses. Returns the live response, or `nil` on timeout
        /// so the caller falls back to the normal lock-and-spawn path (safe even if the daemon never comes
        /// back, since spawning is guarded by the launch flock and the daemon instance lock).
        ///
        /// An unreachable socket during the wait is expected, not a failure: the old image stops its socket
        /// server before `execv`, and the new image needs a moment to rebind the same path, so it is treated
        /// exactly like another `.handingOff` reply — keep polling.
        static func waitForLivePongThroughTransition(socketPath: String) -> TerminalServiceResponse? {
            let deadline = Date().addingTimeInterval(handoffTransitionTimeout)
            while Date() < deadline {
                if let response = try? TerminalServiceClient.send(
                    request: TerminalServiceRequest(command: .ping), socketPath: socketPath, timeout: 1), response.ok
                {
                    return response
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return nil
        }

        /// Bounds how long `ensureRunning`'s flock winner waits for an outgoing daemon that still holds
        /// `TerminalServiceInstanceLock` to actually release it before spawning a replacement. Unlike
        /// `handoffTransitionTimeout`, this waits for nothing to *arrive* — there is no successor — only
        /// for the outgoing process to leave. `shutdown()`'s dominant cost is draining each live session's
        /// queued persistence writes through a SQLite connection whose busy timeout is 5s
        /// (`SpacesSQLiteDatabase.busyTimeoutMS`), so a single contended session can legitimately take that
        /// long; this matches that budget rather than borrowing the handoff constant's extra margin for an
        /// exec preflight a shutdown never runs.
        private static let shutdownExitTimeout: TimeInterval = 5

        /// Waits for the process recorded as the profile's live `TerminalServiceInstanceLock` owner (if
        /// any) to actually leave — either by exiting, or by a live daemon answering the socket — bounded
        /// by `shutdownExitTimeout`. This is the gate `ensureRunning`'s flock winner runs before spawning:
        /// a live owner means a spawn right now is doomed (the child's `SpacesDaemonController.init`
        /// collides with the still-held lock and exits), so the winner waits for the owner to leave rather
        /// than spawning straight into that collision. See the call site's comment in `ensureRunning` for
        /// why reading the lock — rather than depending on a ping response — is what lets this cover an
        /// outgoing daemon whose accept source is already cancelled and answers no ping at all.
        ///
        /// An exec-in-place handoff successor keeps the outgoing process's pid, so "pid alive" alone can't
        /// tell an outgoing daemon from a live successor wearing the same pid. This runs its own poll loop
        /// (rather than delegating to `waitForServiceExit`, whose other callers genuinely want "gone" and
        /// for whom a live-pong exit would be wrong) so it can also return the moment a ping answers
        /// `ok: true`: that is a healthy daemon, not one on its way out, so there is nothing left to wait
        /// for and the caller's post-gate adoption check picks it up instead. Without this early exit, that
        /// case would burn the full `shutdownExitTimeout` waiting for a pid that will never die, and
        /// `ensureRunning` would then spawn a doomed competitor before its own poll loop finally adopted
        /// the live successor.
        ///
        /// Returns immediately, without waiting, when the lock file is absent or names a pid that is
        /// already dead: only a live owner can block a spawn, so there is nothing to wait for otherwise.
        static func waitForInstanceLockOwnerToExit(socketPath: String, lockPath: String) {
            guard let ownerPID = try? TerminalServiceInstanceLock.activeOwnerProcessID(path: lockPath) else { return }
            let deadline = Date().addingTimeInterval(shutdownExitTimeout)
            while Date() < deadline {
                // Mirrors `waitForServiceExit`'s own per-iteration checks (its pid-liveness helper and its
                // short-timeout ping probe on `socketPath`), plus the ok-pong early exit described above.
                let response =
                    FileManager.default.fileExists(atPath: socketPath)
                    ? try? TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath, timeout: 0.2) : nil
                if let response, response.ok { return }
                if !isProcessAlive(pid: Int(ownerPID)) && response == nil { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        private static func stopExistingService(socketPath: String, timeout: TimeInterval) {
            var candidatePIDs = Set<pid_t>()
            if let response = try? pingResponse(timeout: min(timeout, 1)), let servicePID = response.servicePID {
                candidatePIDs.insert(pid_t(servicePID))
            }

            if let response = try? TerminalServiceClient.send(
                request: TerminalServiceRequest(command: .shutdown), socketPath: socketPath, timeout: min(timeout, 1))
            {
                if let servicePID = response.servicePID { candidatePIDs.insert(pid_t(servicePID)) }
                if response.ok, waitForServiceExit(socketPath: socketPath, candidatePIDs: candidatePIDs, timeout: timeout) { return }
            }

            if candidatePIDs.isEmpty { candidatePIDs.formUnion(serviceProcessIDsOwningSocket(socketPath, timeout: timeout) ?? []) }
            terminateServiceProcesses(candidatePIDs, timeout: timeout)
        }

        private static func terminateServiceProcesses(_ pids: Set<pid_t>, timeout: TimeInterval) {
            let targetPIDs = pids.filter { $0 > 0 && $0 != getpid() }
            guard !targetPIDs.isEmpty else { return }

            for pid in targetPIDs { kill(pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if targetPIDs.allSatisfy({ !isProcessAlive(pid: Int($0)) }) { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            for pid in targetPIDs where isProcessAlive(pid: Int(pid)) { kill(pid, SIGKILL) }
        }

        private static func waitForServiceExit(socketPath: String, candidatePIDs: Set<pid_t>, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let livePIDs = candidatePIDs.filter { isProcessAlive(pid: Int($0)) }
                // Pings the given `socketPath` directly, the same way `waitForLivePongThroughTransition`
                // does, rather than going through `pingResponse()` (which re-resolves the canonical
                // profile socket path). Every caller passes its own already-resolved canonical path today,
                // so this is behavior-preserving, but it keeps this check honoring its own parameter like
                // the `fileExists` check beside it, instead of silently depending on the two paths always
                // agreeing.
                let canPing =
                    FileManager.default.fileExists(atPath: socketPath)
                    && ((try? TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath, timeout: 0.2))
                        != nil)
                if livePIDs.isEmpty && !canPing { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }

        /// Returns nil when the sweep never produced a trustworthy answer (lsof hit the deadline,
        /// failed to launch, or exited nonzero): an indeterminate probe, not proof the socket is
        /// unowned. Callers that destroy state on "no owner" must treat nil as "owner unknown". Only
        /// a clean, completed sweep returns a real (possibly empty) confirmed-unowned set.
        static func serviceProcessIDsOwningSocket(_ socketPath: String, timeout: TimeInterval) -> Set<pid_t>? {
            let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
            guard let executablePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
            guard
                let result = capturedStandardOutput(executableURL: URL(fileURLWithPath: executablePath), arguments: ["-nP", "-U"], timeout: timeout),
                result.terminationStatus == 0
            else { return nil }
            return parseSocketOwnerProcessIDs(String(decoding: result.output, as: UTF8.self), socketPath: socketPath)
        }

        /// Runs a short-lived process and captures its stdout. The pipe must be drained BEFORE
        /// waiting for exit: a child that writes more than the kernel's pipe buffer (64KB) blocks
        /// until someone reads, so waiting first deadlocks both processes. `lsof -nP -U` output
        /// routinely exceeds that buffer on a busy desktop. A watchdog SIGKILLs the child if it
        /// outlives `timeout`, so callers with a bounded shutdown budget never block indefinitely.
        static func capturedStandardOutput(executableURL: URL, arguments: [String], timeout: TimeInterval) -> (
            terminationStatus: Int32, output: Data
        )? {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }

            let timedOutLock = NSLock()
            var timedOut = false
            let watchdog = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOutLock.lock()
                timedOut = true
                timedOutLock.unlock()
                kill(process.processIdentifier, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            timedOutLock.lock()
            let didTimeOut = timedOut
            timedOutLock.unlock()
            if didTimeOut { return nil }
            return (process.terminationStatus, data)
        }

        static func parseProcessIDs(_ output: String) -> Set<pid_t> {
            let processIDs: [pid_t] = output.split(whereSeparator: \.isWhitespace).compactMap { token in
                guard let processID = Int32(token, radix: 10) else { return nil }
                return processID
            }
            return Set(processIDs)
        }

        static func parseSocketOwnerProcessIDs(_ output: String, socketPath: String) -> Set<pid_t> {
            let processIDs: [pid_t] = output.split(separator: "\n").compactMap { line in
                guard line.contains(socketPath) else { return nil }
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count > 1, let processID = Int32(columns[1], radix: 10) else { return nil }
                return processID
            }
            return Set(processIDs)
        }

        private static func shouldUseXCTestCompatibilityBackend() -> Bool {
            SpacesTestHost.isRunningUnderXCTest() && ProcessInfo.processInfo.environment["SPACESD_EXECUTABLE"] == nil
        }

        public static func createSessionRequestTimeout(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
            positiveTimeout(environment["SPACESD_CREATE_TIMEOUT"], defaultValue: 30)
        }

        static func createSessionRPCResponseTimeout(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
            positiveTimeout(environment["SPACESD_CREATE_RPC_TIMEOUT"], defaultValue: 2)
        }

        private static func positiveTimeout(_ rawValue: String?, defaultValue: TimeInterval) -> TimeInterval {
            guard let rawValue, let value = TimeInterval(rawValue), value > 0 else { return defaultValue }
            return value
        }

        private static func waitForCreatedSessionSummary(_ launchConfiguration: TerminalSessionLaunchConfiguration, timeout: TimeInterval)
            -> TerminalServiceSessionSummary?
        {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let summary = try? sessionSummaryIfLive(for: launchConfiguration) { return summary }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            return nil
        }

        private static func sessionSummaryIfLive(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary?
        {
            let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else { return nil }
            guard runtimeState.state == .starting || runtimeState.state == .running else { return nil }
            guard isProcessAlive(pid: Int(runtimeState.servicePID)) else { return nil }
            return TerminalServiceSessionSummary(
                id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
        }

        private static func createXCTestCompatibilitySession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws
            -> TerminalServiceSessionSummary
        {
            let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: nil)

            let runtimeState =
                (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
                ?? TerminalSessionRuntimeState(
                    sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: nil,
                    state: .running, updatedAt: TerminalSessionTimestamp.string(from: Date()), workingDirectory: launchConfiguration.workingDirectory)
            try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
            return TerminalServiceSessionSummary(
                id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
        }

        private static func terminateXCTestCompatibilitySession(id sessionID: String) throws {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            guard let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths) else { return }
            let now = TerminalSessionTimestamp.string(from: Date())
            let runtimeState =
                (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
                ?? TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: nil, state: .exited, updatedAt: now,
                    exitedAt: now, workingDirectory: launchConfiguration.workingDirectory)
            let exitedState = TerminalSessionRuntimeState(
                sessionID: sessionID, backend: runtimeState.backend, servicePID: runtimeState.servicePID, childPID: runtimeState.childPID,
                state: .exited, updatedAt: now, exitedAt: now, title: runtimeState.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                rows: runtimeState.rows, bellAt: runtimeState.bellAt)
            try TerminalSessionPersistence.writeRuntimeState(exitedState, paths: paths)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
        }

        private static func listXCTestCompatibilitySessions() throws -> [TerminalServiceSessionSummary] {
            try TerminalSessionPersistence.listKnownSessions().compactMap { knownSession in
                let launchConfiguration = knownSession.launchConfiguration
                let paths = knownSession.paths
                guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return nil }
                guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else { return nil }
                guard runtimeState.state == .starting || runtimeState.state == .running else { return nil }
                guard isProcessAlive(pid: Int(runtimeState.servicePID)) else { return nil }
                return TerminalServiceSessionSummary(
                    id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                    workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                    lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                    childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
            }
        }

        /// Resolves the `spacesd` binary a client of `profile` should launch.
        ///
        /// A profile is only ever served by a daemon that belongs to the build asking for it, so the
        /// candidate list is split by where a candidate comes from:
        ///
        /// - `SPACESD_EXECUTABLE` wins for every profile. It names one binary outright, which makes it a
        ///   deliberate choice rather than a silent substitution, and the terminal E2E scripts pin their
        ///   daemon with it.
        /// - Candidates derived from the running executable — its sibling, its symlink-resolved sibling,
        ///   and its bundle's resources — apply to every profile, because they necessarily belong to the
        ///   build that is asking.
        /// - The installed links (`~/.spaces/bin/spacesd`, `/usr/local/bin/spacesd`) apply only to the
        ///   installed profile. They are location-fixed and always point at whatever
        ///   `/Applications/Spaces.app` last installed, which is an unrelated release from a repo-local
        ///   build's point of view.
        /// - The checkout-relative build products under the current working directory apply only to a
        ///   development profile. They describe whichever checkout the process happens to have been
        ///   started in, which says nothing about the installed profile.
        ///
        /// Both halves of that split prevent the same failure in opposite directions: a foreign daemon
        /// brought up on this profile's runtime directory and socket answers, but on a different wire
        /// protocol, so the client reports `daemonWireIncompatible` and the real cause — an entirely
        /// different build serving the profile — stays invisible. A profile with no daemon of its own
        /// therefore fails with `daemonNotFound` rather than borrowing one.
        ///
        /// - Parameter installedLinkURLs: The installed layout's fixed daemon links. Injectable so a
        ///   test can supply a temporary installed layout instead of the real machine's.
        static func resolveExecutableURL(
            environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default, profile: SpacesProfile,
            installedLinkURLs: [URL] = [SpacesBinaryLayout.userHelperLinkURL(for: .spacesd), SpacesBinaryLayout.systemLinkURL(for: .spacesd)]
                .compactMap { $0 }
        ) throws -> URL {
            let currentExecutablePath = environment["_"] ?? Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
            let currentExecutableURL = URL(fileURLWithPath: currentExecutablePath)
            let currentExecutableDirectory = currentExecutableURL.deletingLastPathComponent()
            let resolvedCurrentExecutableDirectory = currentExecutableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            let bundledResourceDirectory = currentExecutableDirectory.deletingLastPathComponent().appendingPathComponent(
                "Resources", isDirectory: true)

            // Candidates repeat routinely — an unresolved symlink, or an executable whose directory is
            // also the bundle's resource directory — and the list is reported verbatim when nothing
            // matches, so keep it deduplicated.
            var candidates: [String] = []
            func appendCandidate(_ path: String?) {
                guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return }
                guard !candidates.contains(trimmed) else { return }
                candidates.append(trimmed)
            }

            appendCandidate(environment[pinnedExecutableEnvironmentVariable])
            appendCandidate(currentExecutableDirectory.appendingPathComponent("spacesd", isDirectory: false).path(percentEncoded: false))
            appendCandidate(resolvedCurrentExecutableDirectory.appendingPathComponent("spacesd", isDirectory: false).path(percentEncoded: false))
            appendCandidate(Bundle.main.resourceURL?.appendingPathComponent("spacesd", isDirectory: false).path(percentEncoded: false))
            appendCandidate(bundledResourceDirectory.appendingPathComponent("spacesd", isDirectory: false).path(percentEncoded: false))
            // Split by what the profile IS — the installed profile, or any development one — rather than by
            // which resolution branch produced it, since the installed profile is reachable through more
            // than one branch.
            if profile.isInstalledProfile {
                for linkURL in installedLinkURLs { appendCandidate(linkURL.path) }
            } else {
                for relativePath in [
                    "apps/macos/.build/debug/spacesd", "apps/macos/.build/release/spacesd", ".build/debug/spacesd", ".build/release/spacesd",
                ] { appendCandidate(currentDirectory.appendingPathComponent(relativePath, isDirectory: false).path(percentEncoded: false)) }
            }

            for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate, isDirectory: false)
            }

            throw TerminalServiceError.daemonNotFound(profile: profile, searchedPaths: candidates)
        }

        private static func isProcessAlive(pid: Int) -> Bool {
            guard pid > 0 else { return false }
            if kill(pid_t(pid), 0) == 0 { return true }
            return errno == EPERM
        }
    }

    public enum TerminalServiceError: LocalizedError {
        /// No `spacesd` belonging to the asking build was found for this profile. One case covers both
        /// profile kinds because it is one event — a profile with no daemon of its own — and the profile
        /// only decides which half of the excluded candidates has to be explained: an installed profile
        /// never starts a development build from the current directory, and a development profile never
        /// starts the installed daemon.
        case daemonNotFound(profile: SpacesProfile, searchedPaths: [String])
        case daemonWireIncompatible(TerminalServiceDaemonWireIncompatibility)
        case requestFailed(String)
        case serviceStartupTimedOut(String)

        public var errorDescription: String? {
            switch self {
            case .daemonNotFound(let profile, let searchedPaths):
                let described: (kind: String, explanation: String) =
                    profile.isInstalledProfile
                    ? (
                        "installed",
                        "An installed profile starts only the daemon shipped with the running build or installed beside it, never a development "
                            + "build from the current directory. Reinstall Spaces or set SPACESD_EXECUTABLE."
                    )
                    : (
                        "development",
                        "A development profile never starts the installed daemon (~/.spaces/bin/spacesd, /usr/local/bin/spacesd), which is a "
                            + "different build and would answer this client on a foreign wire protocol. Build the daemon in this checkout "
                            + "(swift build --product spacesd) or set SPACESD_EXECUTABLE."
                    )
                // The discovery route is carried as provenance only: it explains how a surprising profile was
                // arrived at without being what decided anything above.
                return "No spacesd was found for the \(described.kind) profile at \(profile.rootDirectory) "
                    + "(resolved via \(profile.source.rawValue)). \(described.explanation) Searched: " + searchedPaths.joined(separator: ", ")
            case .daemonWireIncompatible(let incompatibility): return incompatibility.message
            case .requestFailed(let message): return message
            case .serviceStartupTimedOut(let path): return "Timed out waiting for spacesd to start from \(path)."
            }
        }
    }
#else
    public enum TerminalService {
        public static func ping(timeout: TimeInterval = 2) throws {
            let response = try pingResponse(timeout: timeout)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
        }

        public static func createSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
            try ensureRunning()
            let response = try TerminalServiceClient.send(
                request: TerminalServiceRequest(command: .create(.init(launchConfiguration: launchConfiguration))),
                socketPath: try TerminalServicePaths.socketPath(), timeout: createSessionRequestTimeout())
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
            guard let session = response.session else { throw TerminalServiceError.requestFailed("spacesd did not return a session summary.") }
            return session
        }

        public static func terminateSession(id sessionID: String) throws {
            try ensureRunning()
            let response = try TerminalServiceClient.send(
                request: TerminalServiceRequest(command: .terminate(.init(sessionID: sessionID))), socketPath: try TerminalServicePaths.socketPath(),
                timeout: 10)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
        }

        public static func listSessions() throws -> [TerminalServiceSessionSummary] {
            let socketPath = try TerminalServicePaths.socketPath()
            guard FileManager.default.fileExists(atPath: socketPath) else { return [] }
            let response = try TerminalServiceClient.send(request: TerminalServiceRequest(command: .list), socketPath: socketPath, timeout: 5)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
            return response.sessions ?? []
        }

        public static func sendProfileCommand(_ profileCommand: TerminalServiceProfileCommand, timeout: TimeInterval = 15) throws
            -> TerminalServiceProfileCommandResponse
        {
            try ensureRunning(timeout: min(timeout, 5))
            let response = try TerminalServiceClient.send(
                request: TerminalServiceRequest(command: .profileCommand(profileCommand)), socketPath: try TerminalServicePaths.socketPath(),
                timeout: timeout)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
            guard let profile = response.profile else { throw TerminalServiceError.requestFailed("spacesd did not return a profile response.") }
            return profile
        }

        /// - Parameter requireWireCompatibility: When `true` (the default, used by command dispatch),
        ///   an adopted already-running daemon must speak this build's wire protocol or this throws.
        ///   `relaunch` passes `false`: it sends a best-effort `.shutdown` and then waits here, so the
        ///   outgoing stale daemon still answering ping during its shutdown grace must not abort the wait.
        ///
        /// A Linux daemon is owned by user systemd, not by this process: every profile on the device has its
        /// own user unit, so starting one is asking systemd to start that profile's unit rather than spawning
        /// a daemon here the way macOS does. This still adopts a live daemon without going near systemd, so
        /// the common case costs one ping.
        @discardableResult public static func ensureRunning(timeout: TimeInterval = 5, requireWireCompatibility: Bool = true) throws -> Bool {
            // `timeout` is the caller's whole budget for this call, so one deadline computed here bounds
            // every step: asking systemd to start the unit is work inside the window, not a preamble to
            // it. Callers that deliberately bound this call (`sendProfileCommand` passes `min(timeout, 5)`)
            // must not be held past their own deadline by an unresponsive user systemd instance.
            let deadline = Date().addingTimeInterval(timeout)
            let socketPath = try TerminalServicePaths.socketPath()
            if FileManager.default.fileExists(atPath: socketPath), let response = try? pingResponse(timeout: min(timeout, 1)), response.ok {
                if requireWireCompatibility { try assertDaemonWireCompatible(response) }
                return false
            }

            // Linux is the only platform that hosts a daemon under user systemd. This half of the file is
            // everything that is not macOS, which includes iOS — a platform with no daemon of its own, no
            // systemd, and no `Process` to reach one with — so the start attempt is Linux-only and iOS waits
            // for a socket exactly as it did before, then reports the same unavailability.
            #if os(Linux)
                let startedUnit = startSystemdUnit(for: try SpacesProfile.current(), deadline: deadline)
            #else
                let startedUnit: String? = nil
            #endif
            // Polling is entered only while budget remains, and each ping is bounded by what is left of it.
            // Starting the unit can consume the whole window on its own, and a `repeat` would then spend one
            // more ping and sleep past the deadline the caller asked to be held to. The ping keeps a small
            // floor because a timeout of a few microseconds is not a request anything can answer — it would
            // report an unreachable daemon rather than a slow one.
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                let pingTimeout = max(0.05, min(remaining, 1))
                if FileManager.default.fileExists(atPath: socketPath), let response = try? pingResponse(timeout: pingTimeout), response.ok {
                    if requireWireCompatibility { try assertDaemonWireCompatible(response) }
                    return startedUnit != nil
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw TerminalServiceError.serviceUnavailable(socketPath: socketPath, startedUnit: startedUnit)
        }

        #if os(Linux)
            /// The user systemd unit that owns this profile's daemon on a Linux device.
            ///
            /// The installed profile is recognised by its root rather than by the branch that resolved it, so a
            /// daemon that reached `~/.spaces` by any route asks systemd for the one unit that serves it.
            ///
            /// `nil` means no unit exists for the profile, so there is nothing to start and a missing daemon stays
            /// the caller's error. That is the honest answer for a repo-built worktree profile or an ephemeral
            /// explicit database path: both belong to a developer-driven process on a machine with a Spaces
            /// checkout, where the daemon is started by whatever launched the build, and inventing a unit name for
            /// them would only ask systemd to start something that was never installed. A profile that fell
            /// through to `<home>/.spaces` without that being the installed root — a redirected `HOME` — has no
            /// unit either, for the same reason.
            static func systemdUnitName(for profile: SpacesProfile) -> String? {
                if profile.isInstalledProfile { return "spacesd.service" }
                switch profile.source {
                case .deployedDevelopmentProfile:
                    return "spacesd@\(URL(fileURLWithPath: profile.rootDirectory, isDirectory: true).lastPathComponent).service"
                case .installedFallback, .developmentWorktree, .explicitDatabasePath: return nil
                }
            }

            /// Asks user systemd to start this profile's daemon unit, and returns the unit it asked about — `nil`
            /// when the profile has no unit or the command could not be run at all.
            ///
            /// A failing start is not fatal here: the caller's poll below decides the outcome, because whether a
            /// daemon ends up answering is the only thing that matters and systemd reports plenty of non-failures
            /// (an already-active unit, a unit still starting) that say nothing about that.
            ///
            /// `deadline` is `ensureRunning`'s single deadline, so waiting on `systemctl` never outlives the
            /// caller's own window.
            private static func startSystemdUnit(for profile: SpacesProfile, deadline: Date) -> String? {
                guard let unitName = systemdUnitName(for: profile) else { return nil }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["systemctl", "--user", "start", unitName]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return nil }
                let startDeadline = systemdStartWaitDeadline(overallDeadline: deadline)
                while process.isRunning, Date() < startDeadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { process.terminate() }
                return unitName
            }

            /// How long waiting on `systemctl --user start` may last: never past `overallDeadline`, and never
            /// longer than `systemdStartTimeout` even when the caller allows more, so a systemd instance that
            /// never answers cannot consume a generous window and leave nothing for the socket wait that
            /// decides the outcome.
            static func systemdStartWaitDeadline(overallDeadline: Date, now: Date = Date()) -> Date {
                min(overallDeadline, now.addingTimeInterval(systemdStartTimeout))
            }

            private static let systemdStartTimeout: TimeInterval = 5
        #endif

        @discardableResult public static func relaunch(timeout: TimeInterval = 5) throws -> Bool {
            let socketPath = try TerminalServicePaths.socketPath()
            if FileManager.default.fileExists(atPath: socketPath) {
                _ = try? TerminalServiceClient.send(
                    request: TerminalServiceRequest(command: .shutdown), socketPath: socketPath, timeout: min(timeout, 1))
            }
            return try ensureRunning(timeout: timeout, requireWireCompatibility: false)
        }

        /// Session-preserving replacement for `relaunch`, used by opportunistic ensure-current recovery.
        ///
        /// `relaunch` sends a forced `.shutdown` that terminates every terminal session the daemon hosts. This
        /// instead delegates the busy check to the daemon via `.shutdownIfIdle`: a daemon with live sessions
        /// refuses (returns `ok == false`) and is left running untouched, so this returns `false` without
        /// stopping anything and the caller must treat recovery as not done. An idle daemon complies and this
        /// waits for it to come back exactly like `relaunch`.
        ///
        /// - Returns: `true` when the daemon is (re)available; `false` when it refused because of live sessions.
        @discardableResult public static func relaunchIfIdle(timeout: TimeInterval = 5) throws -> Bool {
            let socketPath = try TerminalServicePaths.socketPath()
            guard FileManager.default.fileExists(atPath: socketPath) else {
                return try ensureRunning(timeout: timeout, requireWireCompatibility: false)
            }
            let response: TerminalServiceResponse
            do {
                response = try TerminalServiceClient.send(
                    request: TerminalServiceRequest(command: .shutdownIfIdle), socketPath: socketPath, timeout: min(timeout, 1))
            } catch {
                // An unresponsive daemon can't vouch for its sessions, so fall back to the forced relaunch that
                // today's recovery relies on for genuinely hung daemons.
                return try relaunch(timeout: timeout)
            }
            guard response.ok else { return false }
            return try ensureRunning(timeout: timeout, requireWireCompatibility: false)
        }

        public static func createSessionRequestTimeout(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
            guard let rawValue = environment["SPACESD_CREATE_TIMEOUT"], let value = TimeInterval(rawValue), value > 0 else { return 30 }
            return value
        }

        private static func pingResponse(timeout: TimeInterval = 2) throws -> TerminalServiceResponse {
            try TerminalServiceClient.send(
                request: TerminalServiceRequest(command: .ping), socketPath: try TerminalServicePaths.socketPath(), timeout: timeout)
        }
    }

    public enum TerminalServiceError: LocalizedError {
        case daemonWireIncompatible(TerminalServiceDaemonWireIncompatibility)
        case requestFailed(String)
        /// No daemon answered for this profile. `startedUnit` names the user systemd unit that was started
        /// and still produced no socket, so the report distinguishes "systemd was asked and did not deliver"
        /// from a profile that has no unit to ask about at all.
        case serviceUnavailable(socketPath: String, startedUnit: String?)

        public var errorDescription: String? {
            switch self {
            case .daemonWireIncompatible(let incompatibility): return incompatibility.message
            case .requestFailed(let message): return message
            case .serviceUnavailable(let socketPath, let startedUnit):
                var message = "spacesd is not running for this user. Expected daemon socket at \(socketPath)."
                if let startedUnit { message += " Started \(startedUnit), which produced no daemon socket." }
                return message
            }
        }
    }
#endif

public struct TerminalServiceDaemonWireIncompatibility: Sendable {
    public let verdict: SpacesWireCompatibility
    public let status: TerminalServiceDaemonStatus?
    public let message: String

    public var canRestartDaemon: Bool { verdict == .daemonTooOld }
}

extension TerminalService {
    /// Guards local dispatch against a daemon whose wire contract differs from this build's.
    ///
    /// `ensureRunning` adopts an already-running daemon after a liveness ping, so a stale `spacesd`
    /// left over from a previous app version would otherwise receive a payload it cannot decode and
    /// fail with an opaque decoding error. The daemon advertises its `protocolVersion` on the ping
    /// response, so we compare it here and refuse to dispatch on a mismatch. We do not auto-relaunch:
    /// restarting the daemon kills the user's running terminals, so that stays the user's decision and
    /// this returns an actionable message instead. Returns `nil` when the daemon is compatible.
    ///
    /// A ping response with no `daemonStatus` comes from a daemon predating wire-version negotiation,
    /// which counts as too old (never a match) — the same rule `TerminalServiceDaemonStatus` applies to
    /// a missing `protocolVersion`.
    static func daemonWireIncompatibilityDetails(_ response: TerminalServiceResponse) -> TerminalServiceDaemonWireIncompatibility? {
        let verdict = response.daemonStatus.map(SpacesWireCompatibility.evaluate(daemonStatus:)) ?? .daemonTooOld
        guard !verdict.isCompatible else { return nil }
        var message: String
        switch verdict {
        case .clientTooOld:
            message = "The running spacesd daemon speaks a newer connection protocol than this Spaces build. Update Spaces to match it, then retry."
        case .daemonTooOld, .compatible:
            // Quitting/relaunching the Spaces app does not help: the daemon is managed by the OS service
            // manager (launchd `KeepAlive` / systemd `Restart=always`) and outlives the app, and app
            // launch only adopts it. Restarting the daemon makes it exit and respawn from the updated
            // binary — the daemon restart control in the Spaces app (shown for this device) does exactly that.
            message =
                "The running spacesd daemon speaks an older connection protocol than this Spaces build. "
                + "Restart the daemon to load the update, then retry."
            if let status = response.daemonStatus,
                status.activeSessionCount > 0 || status.runningProcesses > 0 || status.activeAgents + status.waitingAgents > 0
            {
                message += " Restarting stops the daemon's running terminals, processes, and agents."
            }
        }
        return TerminalServiceDaemonWireIncompatibility(verdict: verdict, status: response.daemonStatus, message: message)
    }

    static func assertDaemonWireCompatible(_ response: TerminalServiceResponse) throws {
        if let incompatibility = daemonWireIncompatibilityDetails(response) { throw TerminalServiceError.daemonWireIncompatible(incompatibility) }
    }
}
