#if os(Linux)
    import Dispatch
    import Foundation
    import Glibc
    import ghosttyvtshim
    import spacesterminalcore

    enum GhosttyLinuxHeadlessSessionError: LocalizedError {
        case vtSessionUnavailable
        case vtReplayFailed
        case eventRegistrationFailed
        case snapshotUnavailable

        var errorDescription: String? {
            switch self {
            case .vtSessionUnavailable: "libghostty-vt is not available for the headless terminal session."
            case .vtReplayFailed: "libghostty-vt could not replay the terminal transcript."
            case .eventRegistrationFailed: "libghostty-vt could not register the headless terminal session's event callbacks."
            case .snapshotUnavailable: "Unable to export a headless terminal render frame."
            }
        }
    }

    /// Bridges the PTY driver's synchronous output callback to the engine-actor task that
    /// persists and renders that output. Once the PTY driver has switched to handoff
    /// buffering, no delivery can register here, so draining this fence is a stable
    /// boundary before output.log is closed.
    final class GhosttyLinuxHandoffOutputDeliveryFence: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveryCount = 0
        private var drainWaiters: [CheckedContinuation<Void, Never>] = []

        func beginDelivery() {
            lock.lock()
            deliveryCount += 1
            lock.unlock()
        }

        func finishDelivery() {
            lock.lock()
            precondition(deliveryCount > 0, "finishing an output delivery that was never registered")
            deliveryCount -= 1
            let waiters = deliveryCount == 0 ? drainWaiters : []
            if deliveryCount == 0 { drainWaiters.removeAll() }
            lock.unlock()
            for waiter in waiters { waiter.resume() }
        }

        func waitUntilDrained() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard deliveryCount > 0 else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                drainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    @TerminalEngineActor public final class GhosttyEmbeddedSessionCore {
        private static let maxScrollbackBytes = TerminalScrollbackBudget.defaultMaxBytes
        nonisolated static let outputReplayChunkByteCount = 1024 * 1024

        private enum RenderStateExportMode {
            case selfContained
            case streamDeltaAllowed
        }

        public let launchConfiguration: TerminalSessionLaunchConfiguration
        public let paths: TerminalSessionPaths

        private let controlQueue: DispatchQueue
        private let stateStreamQueue: DispatchQueue
        /// Serial background executor for this core's durable SQLite writes, offloaded off the engine so a
        /// competing writer's 5s SQLite busy timeout can never freeze terminal I/O or control on the single
        /// engine executor. Runtime-state writes coalesce latest-wins; the terminated writes are FIFO-fenced.
        /// See `TerminalCorePersistenceQueue`.
        private let persistence: TerminalCorePersistenceQueue
        /// Orders every control-request input write (send text/bytes/paste, key) for this session and
        /// spaces submit carriage returns so they read as lone Enter keystrokes; see
        /// `TerminalControlInputSequencer`.
        private let controlInputSequencer = TerminalControlInputSequencer()
        private let ptyDriver: HostManagedPTYTerminalSessionDriver
        private let outputDeliveryFence = GhosttyLinuxHandoffOutputDeliveryFence()
        private var controlServer: TerminalControlServer?
        private var stateStreamServer: GhosttyRemoteSessionStateStreamServer?
        private var outputHandle: FileHandle?
        private var outputByteCount = 0
        /// Bounds `output.log` for this session, running the expensive preamble replay off the engine so a
        /// trim cannot stall other sessions' terminal I/O. See `TerminalTranscriptTrimCoordinator`.
        private lazy var transcriptTrim = TerminalTranscriptTrimCoordinator(
            outputPath: paths.outputPath,
            liveTranscriptEndOffset: { [weak self] in
                guard let self, outputHandle != nil else { return nil }
                return UInt64(outputByteCount)
            },
            adoptTrimmedTranscript: { [weak self] handle, endOffset in
                guard let self else { return }
                // The trim replaced output.log with a fresh inode; adopt its handle before closing the old
                // one so the stored property always holds a valid handle even if the close fails.
                let previousHandle = outputHandle
                outputHandle = handle
                outputByteCount = Int(endOffset)
                try? previousHandle?.close()
            })
        private nonisolated(unsafe) var vtSession: OpaquePointer?
        private var started = false
        private var terminating = false
        /// Live in-memory runtime state — the AUTHORITATIVE source broadcasts serve, advanced the moment a new
        /// state is computed regardless of whether it has reached disk. Kept distinct from
        /// `lastPersistedRuntimeState` so broadcasts always show live truth while the durable mirror converges.
        private var lastRuntimeState: TerminalSessionRuntimeState?
        /// Durable persist marker — mirrors what was last SUCCESSFULLY written to disk. Advanced only on a
        /// successful off-engine write, and the runtime-state change notification fires from here so
        /// DB-reading consumers (the overview) observe a change only once it is durable.
        private var lastPersistedRuntimeState: TerminalSessionRuntimeState?
        private var lastKnownChildPID: Int32?
        /// The title the running program last set with OSC 0/2, and the working directory it last
        /// reported with OSC 7, refreshed from the vt session as output arrives. Nil until the program
        /// sets one (or after it clears one), which is when the runtime state falls back to the
        /// launch configuration's values. Cached on the core rather than read from the vt session at
        /// every echo site because the cache must outlive the vt session itself: a handoff rebuilds
        /// the session and replays the transcript, and a trimmed transcript's state preamble
        /// deliberately does not restore titles.
        private var currentTitle: String?
        private var currentWorkingDirectory: String?
        private var terminalSize: (columns: Int, rows: Int) = (80, 24)
        // The Spaces theme appearance the vt session is currently themed for. The headless daemon
        // cannot read the client's OS appearance, so it defaults to dark and adopts the attaching
        // client's appearance on attach.
        private var currentAppearance: ThemeAppearance = .dark
        private var ownerEpoch: UInt64 = 0
        /// The newest resize serial accepted from each client. Resize requests travel off the client's
        /// serialized input path, so two sizes measured in order can arrive out of order; a size older
        /// than the one already applied would otherwise pin the session to a grid the client has left.
        /// Cleared when the owner epoch advances, since serials are per-ownership.
        private var lastResizeSerialByClientID: [String: UInt64] = [:]
        /// Rate-limits the durable client lease writes this core performs inline on the engine (see
        /// `touchClientLeaseIfDue`). Reset for a client on attach and detach — the only ways this core
        /// changes that client's durable row — and wholesale on termination's detach-all.
        private var leaseTouchCoalescer = TerminalClientLeaseTouchCoalescer()
        private var screenStateRevision: UInt64 = 0
        /// Set for the brief exec-in-place quiesce window so no late resync turn
        /// broadcasts a frame while the session is being handed to the staged daemon.
        /// Cleared on resume (`resumeFromHandoff`) or the failed-exec fallback
        /// (`resumeInPlaceAfterFailedExec`).
        private var suppressBroadcastsForHandoff = false
        /// Byte offset where renderer-disconnected output begins. Failed handoff streams
        /// this persisted suffix back through the existing VT without duplicating it.
        private var handoffTranscriptReplayOffset: UInt64?
        private var renderUpdateBaseline: GhosttyRenderUpdateBaseline?
        private var forceNextBroadcastFullRenderUpdate = false
        private var localOwnerCommandInputOutputResyncPending = false
        private var scrollDeltaNormalizer = TerminalScrollDeltaNormalizer()
        /// Pending precise horizontal delta for wheel reports. Only consulted while an application
        /// tracks the mouse — the viewport itself never scrolls horizontally.
        private var pendingPreciseHorizontalDelta: Double = 0
        private var inputOutputResyncTask: Task<Void, Never>?
        private let onSessionClosed: (@TerminalEngineActor (GhosttyEmbeddedSessionCore) -> Void)?

        public init(
            launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
            requestSurfaceRefreshAction _: (@TerminalEngineActor () -> Void)? = nil,
            onSessionClosed: (@TerminalEngineActor (GhosttyEmbeddedSessionCore) -> Void)? = nil
        ) {
            self.launchConfiguration = launchConfiguration
            self.paths = paths
            self.onSessionClosed = onSessionClosed
            controlQueue = DispatchQueue(label: "spaces.terminal.session-host.control.\(launchConfiguration.sessionID)")
            stateStreamQueue = DispatchQueue(label: "spaces.terminal.session-host.state-stream.\(launchConfiguration.sessionID)")
            persistence = TerminalCorePersistenceQueue(label: "spaces.terminal.session-host.persistence.\(launchConfiguration.sessionID)")
            ptyDriver = HostManagedPTYTerminalSessionDriver(launchConfiguration: launchConfiguration)
        }

        deinit { if let vtSession { spaces_ghostty_vt_session_free(vtSession) } }

        public func startIfNeeded() throws {
            guard !started else { return }
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            try ensureOutputHandle()
            guard let vtSession = makeVTSession(columns: terminalSize.columns, rows: terminalSize.rows) else {
                throw GhosttyLinuxHeadlessSessionError.vtSessionUnavailable
            }
            // A fresh session replays nothing, so every event it raises from here on belongs to live
            // output the user is watching.
            guard spaces_ghostty_vt_session_enable_events(vtSession) else {
                spaces_ghostty_vt_session_free(vtSession)
                throw GhosttyLinuxHeadlessSessionError.eventRegistrationFailed
            }
            self.vtSession = vtSession
            started = true
            terminating = false
            writeRuntimeState(state: .starting)
            installOutputHandler()
            ptyDriver.setSessionClosedHandler { [weak self] in self?.handleSessionClosed() }
            do {
                try ptyDriver.startIfNeeded()
                try startControlServer()
                try startStateStreamServer()
                writeRuntimeState(state: .running)
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
            } catch {
                terminate()
                throw error
            }
        }

        public func terminate() {
            guard started || vtSession != nil || controlServer != nil || stateStreamServer != nil else { return }
            terminating = true
            // Stamp the exit ONCE and reuse that snapshot for both the persisted runtime state and the
            // final payload's embedded runtime state. The client arms ended-scrollback replay with the
            // identity from the final state payload, while the server's transcript endpoint reports the
            // identity from the persisted runtime state; if the two disagree the client rejects the
            // ended run's transcript and scrollback replay is unavailable. `runIdentity` embeds a
            // sub-second exit timestamp, so two separate stamps virtually always differ — build one.
            let exitedState = makeRuntimeStateSnapshot(state: .exited)
            let finalPayload = makeStatePayload(reason: TerminalRemoteSessionStateReason.terminated, runtimeStateOverride: exitedState)
            // The exited runtime state, detach-all, and terminated payload are all ENQUEUED (not written
            // inline) so teardown never blocks the engine on the DB lock; FIFO ordering on the serial
            // persistence queue lands them after every pending mirror write and in this order: exited runtime
            // state (retry-fenced), detach-all, terminated payload. They complete asynchronously and survive
            // this core's release (the closures capture only `paths` and value types), so the durable mirror
            // converges even if the core is dropped right after. `enqueueRuntimeStateWrite` retries a failed
            // EXITED write in place, holding its FIFO position so the two writes below cannot pass it.
            lastRuntimeState = exitedState
            enqueueRuntimeStateWrite(exitedState)
            let detachPaths = paths
            let detachedAt = nowISO8601()
            persistence.enqueueWrite { databasePath in
                try? TerminalSessionPersistence.detachActiveClients(paths: detachPaths, detachedAt: detachedAt, databasePath: databasePath)
            }
            // Every client's durable row is being detached, so no coalescing record survives this run.
            leaseTouchCoalescer.forgetAll()
            if let finalPayload {
                let payloadPaths = paths
                persistence.enqueueWrite { databasePath in
                    try? TerminalSessionPersistence.writeRemoteSessionState(finalPayload, paths: payloadPaths, databasePath: databasePath)
                }
                stateStreamServer?.broadcast(finalPayload)
            }
            // Termination fence: the exited-state, detach-all, and terminated-payload writes are enqueued
            // above; FIFO on the serial persistence queue lands them in order and after every pending mirror
            // write. The durable-end notifications must fire only once those have committed (so a DB-reading
            // consumer like the overview observes the end state), but blocking the engine on that commit could
            // stall the single engine executor — and thus every live session — for seconds under DB write
            // contention (SQLite's 5s busy timeout). So instead of a blocking drain we enqueue one trailing
            // closure that, by FIFO, runs after the three writes commit and hops back to the engine to post the
            // notifications (persistence closures return to the engine only via async Task). This is the ONLY
            // path to the durable-end notifications on a natural child exit: `handleSessionClosed()` →
            // `terminate()` → `onSessionClosed` drops the core's last strong reference on the engine executor
            // before the `enqueueRuntimeStateWrite` weak-self hop can run, so that hop finds `self` nil and
            // fires nothing. This closure captures only the session id (a value type), so it survives the
            // core's release. A benign duplicate notification when the core stays alive is acceptable.
            let terminatedSessionID = launchConfiguration.sessionID
            persistence.enqueueOrderedWork {
                Task { @TerminalEngineActor in
                    TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: terminatedSessionID)
                    TerminalSessionNotification.post(.spacesTerminalAttachmentStateDidChange, sessionID: terminatedSessionID)
                    TerminalOverviewSignal.post()
                }
            }
            controlServer?.stop()
            controlServer = nil
            TerminalControlServer.removeSocketFileIfPresent(at: paths.controlSocketPath)
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)
            inputOutputResyncTask?.cancel()
            inputOutputResyncTask = nil
            localOwnerCommandInputOutputResyncPending = false
            ptyDriver.setOutputHandler(nil)
            ptyDriver.setSessionClosedHandler(nil)
            ptyDriver.terminate()
            if let vtSession {
                spaces_ghostty_vt_session_free(vtSession)
                self.vtSession = nil
            }
            try? outputHandle?.synchronize()
            try? outputHandle?.close()
            outputHandle = nil
            started = false
            terminating = false
        }

        public func currentRemoteStatePayload(reason: String = TerminalRemoteSessionStateReason.stateChange) -> GhosttyRemoteSessionStatePayload? {
            makeStatePayload(reason: reason, exportMode: .selfContained)
        }

        /// The payload a one-shot state read is answered with, matching what this session's own subscription
        /// socket exports for a fresh subscriber. Serving a Device API `.state` from here lets the daemon skip
        /// dialing its own session's unix socket to ask itself a question it can answer directly. Platform
        /// parity with the macOS `GhosttyEmbeddedSessionCore.currentOneShotStatePayload()`.
        public func currentOneShotStatePayload() -> GhosttyRemoteSessionStatePayload? {
            makeStatePayload(reason: TerminalRemoteSessionStateReason.initial, exportMode: .selfContained, markNextBroadcastFull: false)
        }

        /// The session summary built entirely from this core's in-memory launch configuration and
        /// `lastRuntimeState` — with no DB read. Serves the create path's post-start summary so a create
        /// reports the running session the moment `startIfNeeded()` returns (which advances `lastRuntimeState`
        /// synchronously via `writeRuntimeState(state: .running)`), independent of when the first
        /// runtime-state write commits to SQLite through the per-core persistence queue. Platform parity with
        /// the macOS `GhosttyEmbeddedSessionCore.inMemorySessionSummary()`; `SpacesdMain.createSessionOffMain`
        /// compiles for Linux too and calls this. Returns nil only before any runtime state has been computed
        /// (never started). At session birth no client has attached and no final render exists, so the
        /// attachment snapshot is empty and `hasFinalRender` is false.
        public func inMemorySessionSummary() -> TerminalServiceSessionSummary? {
            guard let runtimeState = lastRuntimeState else { return nil }
            return TerminalServiceSessionSummary(
                id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath,
                launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                hasFinalRender: false)
        }

        private func handleSessionClosed() {
            guard !terminating else { return }
            terminate()
            onSessionClosed?(self)
        }

        /// Awaitable drain used by daemon shutdown and the nil-quiesce handoff branch after `terminate()`.
        /// `terminate()` only ENQUEUES the exited runtime-state write, detach-all, and terminated payload onto
        /// the serial persistence queue; shutdown's `exit(0)` and the handoff's `execv` both destroy anything
        /// still queued. SpacesdMain awaits this after terminating a core so those writes commit first —
        /// otherwise a session's durable runtime row stays stuck at `.running` (and, across `execv`,
        /// `recoverStaleSessions` keeps skipping it because the pid is unchanged).
        public func drainPersistenceForShutdown() async { await persistence.drainAsync() }

        // MARK: - Exec-in-place handoff

        /// Quiesce this session for the exec-in-place daemon handoff: suppress
        /// broadcasts, stop the per-session resync task, and stop the control +
        /// state-stream servers (removing their socket files exactly as `terminate()`
        /// does) WITHOUT detaching clients, killing the child, or freeing the vt
        /// session. The PTY read loop keeps draining — first into an in-memory buffer,
        /// then straight to `output.log` — so not a byte is lost across the exec.
        /// Returns the handoff record the staged daemon needs to adopt this session, or
        /// nil when there is nothing live to hand off (the child already exited/closed),
        /// in which case the caller terminates the session normally.
        public func quiesceForHandoff() async throws -> DaemonHandoffSessionRecord? {
            handoffTranscriptReplayOffset = nil
            suppressBroadcastsForHandoff = true
            inputOutputResyncTask?.cancel()
            inputOutputResyncTask = nil
            localOwnerCommandInputOutputResyncPending = false

            controlServer?.stop()
            controlServer = nil
            TerminalControlServer.removeSocketFileIfPresent(at: paths.controlSocketPath)
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)

            // Drain accepted-but-unwritten control input before handing off. A `terminal send --submit`
            // splits into the text write and a carriage return the sequencer holds back by its separation
            // delay; the PTY write queue is likewise asynchronous. The control server is stopped above, so no
            // new sends can enqueue — await the sequencer chain and then the PTY write queue so the `execv`
            // that inherits this same master fd cannot destroy either with the CR (or the whole line) unwritten.
            await controlInputSequencer.drain()
            await ptyDriver.drainPendingWrites()

            // Nothing live to hand off (child dead/closed): caller terminates normally.
            guard let descriptor = ptyDriver.handoffDescriptorSnapshot() else { return nil }

            // Route further PTY bytes into an in-memory buffer so the read loop never
            // blocks while we drain the engine actor and close the durable output handle.
            await ptyDriver.beginHandoffOutputBuffering()

            // The PTY callback registers this second fence before returning and only
            // completes it after its engine-actor handleOutput task has appended output.log.
            // The driver's fence above makes the registration set stable; this drain proves
            // every registered persistence task completed without relying on timing.
            await outputDeliveryFence.waitUntilDrained()

            // Second write-queue drain, after the output fence: a handleOutput turn that finished
            // between the first drain and the fence may have enqueued query replies. Its query bytes
            // land before the boundary recorded below — the resume replay treats them as already
            // answered — so the replies must reach the PTY before execv destroys the queue, or they
            // are lost on both sides. No enqueue can race this drain: the control server is stopped,
            // the sequencer is drained, and the fence proved every output handler completed.
            await ptyDriver.drainPendingWrites()

            if let outputHandle {
                do {
                    try outputHandle.synchronize()
                    try outputHandle.close()
                    self.outputHandle = nil
                } catch {
                    try? outputHandle.close()
                    self.outputHandle = nil
                    throw error
                }
            }
            handoffTranscriptReplayOffset = try transcriptByteCount()

            // Flush the buffered bytes to output.log and install the direct-to-file writer
            // that keeps appending until execv.
            try ptyDriver.finishHandoffOutputBuffering(appendingTo: paths.outputPath)

            // Drain every pending durable mirror write (runtime state) before returning the record: the
            // caller `execv`s into the staged daemon, which reseeds from the DB, so the mirror must be
            // complete first. Async so the engine is not blocked while the queue flushes.
            await persistence.drainAsync()

            return DaemonHandoffSessionRecord(
                sessionID: launchConfiguration.sessionID, masterFD: descriptor.masterFD, childPID: descriptor.childPID, columns: terminalSize.columns,
                rows: terminalSize.rows, ownerEpoch: ownerEpoch, screenStateRevision: screenStateRevision, appearance: currentAppearance.rawValue,
                transcriptOffsetAtQuiesce: handoffTranscriptReplayOffset)
        }

        /// Holds the PTY sink boundary while the daemon performs its final persistence
        /// validation and `execv`, preventing a direct write from racing after the check.
        public func withValidatedHandoffOutputForExec<T>(_ operation: () throws -> T) throws -> T {
            try ptyDriver.withValidatedHandoffOutputForExec(operation)
        }

        /// Failed-`execv` fallback: `execv` returned, so this same image keeps running and
        /// nothing was freed. Stop the direct-to-file writer, reopen the output handle for
        /// append, restart the per-session servers, and resume broadcasts. This rebinds the
        /// still-live session; it never rebuilds it. This core has no periodic timers to
        /// resume — its resync task is armed on demand — so refreshing runtime state is the
        /// whole catch-up.
        public func resumeInPlaceAfterFailedExec() async {
            ptyDriver.pauseHandoffOutputForFallback()
            if let handoffTranscriptReplayOffset {
                do {
                    _ = try Self.replayOutputLog(at: paths.outputPath, startingAt: handoffTranscriptReplayOffset) { self.writeVTRenderer($0) }
                } catch { FileHandle.standardError.write(Data("spaces: ghostty handoff transcript replay failed: \(error)\n".utf8)) }
                // The replayed suffix is output this still-live (and still events-enabled) vt session
                // never saw, so it may carry a title or pwd newer than the cache, and queries the
                // program is still blocked on. Those are applied and answered. The bells and clipboard
                // writes the same suffix raised are dropped: they are as old as the handoff window, so
                // alerting on them would be alerting on output the user already scrolled past.
                let events = drainSessionEvents()
                applyMetadataEvents(titleChanged: events.titleChanged, pwdChanged: events.pwdChanged)
                sendQueryResponses(events.ptyResponse)
            }
            do { try openOutputHandlePreservingTranscript() } catch {
                FileHandle.standardError.write(Data("spaces: ghostty handoff transcript reopen failed: \(error)\n".utf8))
            }
            ptyDriver.endHandoffOutputBuffering()
            await outputDeliveryFence.waitUntilDrained()
            self.handoffTranscriptReplayOffset = nil
            suppressBroadcastsForHandoff = false
            do {
                try startControlServer()
                try startStateStreamServer()
            } catch { FileHandle.standardError.write(Data("spaces: ghostty handoff resume-in-place failed: \(error)\n".utf8)) }
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
        }

        /// Resume side of the exec-in-place handoff, run on a freshly built core in the
        /// staged daemon image for a session that survived the exec. Rebuilds the vt
        /// session at the persisted grid size and replays output.log (via
        /// `recreateVTRenderer`), adopts the inherited PTY, then restarts the servers and
        /// republishes a full frame so reconnecting clients get a self-contained baseline.
        ///
        /// This core's replay is synchronous libghostty-vt (`recreateVTRenderer` writes the
        /// transcript straight into the vt session), unlike the macOS core whose replay
        /// blocks on tick-pumped GhosttyKit IO. So there is no off-engine-actor dance: the
        /// replay runs inline. The method stays `async` only for API symmetry with the
        /// macOS core so stage 5's daemon call site compiles unchanged on both platforms.
        public func resumeFromHandoff(_ record: DaemonHandoffSessionRecord) async throws {
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            // Preserve output.log: recreateVTRenderer replays it to rebuild the screen.
            try openOutputHandlePreservingTranscript()

            // Apply the persisted grid and appearance BEFORE building the vt session so the
            // replayed frames wrap at the persisted width and carry the right colors
            // (makeVTSession reads both).
            terminalSize = (columns: record.columns, rows: record.rows)
            if let appearanceRaw = record.appearance, let appearance = ThemeAppearance(rawValue: appearanceRaw) { currentAppearance = appearance }

            started = true
            terminating = false
            suppressBroadcastsForHandoff = false
            installOutputHandler()
            ptyDriver.setSessionClosedHandler { [weak self] in self?.handleSessionClosed() }

            // Seed the title/cwd cache from the row the pre-exec image wrote: this core is a fresh
            // object, and the replay below cannot always recover them (a trimmed transcript's state
            // preamble deliberately restores no title). The replay's own refresh overwrites these when
            // it sees newer escape sequences.
            if let persisted = try? TerminalSessionPersistence.readRuntimeState(paths: paths) {
                currentTitle = persisted.title
                currentWorkingDirectory = persisted.workingDirectory
            }

            // Rebuild + replay at the persisted grid. recreateVTRenderer writes output.log
            // synchronously into a replacement VT session, then swaps it in and arms the
            // full-frame flag.
            try recreateVTRenderer(columns: record.columns, rows: record.rows, eventsLiveFromTranscriptOffset: record.transcriptOffsetAtQuiesce)

            // Adopt the inherited PTY only AFTER replay so no live byte races ahead of the
            // replayed transcript. The read loop starts here.
            ptyDriver.adopt(masterFD: record.masterFD, childPID: record.childPID)

            // The handoff-window suffix replayed above with events live, so this drain carries exactly
            // what those bytes raised. Nothing ever parsed them — the old image buffered them straight
            // to output.log — so the program may still be blocked on a query, and its title or pwd may
            // be newer than the row this core seeded from; both are settled here. The replies need the
            // adopted PTY, which is why the drain sits after `adopt` rather than inside the rebuild;
            // everything between the two is synchronous on the engine actor, so no live output can
            // interleave. The same suffix's bells and clipboard writes are dropped: they are as old as
            // the handoff window, so alerting on them would be alerting on output the user already
            // scrolled past. The macOS core needs none of this — its replay runs through the GhosttyKit
            // surface, which answers queries itself through its runtime write callback — so the record's
            // offset is written there for truthfulness and consumed only here.
            let events = drainSessionEvents()
            applyMetadataEvents(titleChanged: events.titleChanged, pwdChanged: events.pwdChanged)
            sendQueryResponses(events.ptyResponse)

            ownerEpoch = record.ownerEpoch
            // Advance past the recorded revision and force the first broadcast to a full
            // render update so reconnecting clients rebuild from a self-contained baseline.
            screenStateRevision = record.screenStateRevision &+ 1
            renderUpdateBaseline = nil
            forceNextBroadcastFullRenderUpdate = true

            try startControlServer()
            try startStateStreamServer()
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
        }

        var debugOwnerEpoch: UInt64 { ownerEpoch }
        var isStarted: Bool { started }

        private func installOutputHandler() {
            let outputDeliveryFence = outputDeliveryFence
            ptyDriver.setOutputHandler { [weak self, outputDeliveryFence] data in
                outputDeliveryFence.beginDelivery()
                Task { @TerminalEngineActor [weak self, outputDeliveryFence] in
                    defer { outputDeliveryFence.finishDelivery() }
                    self?.handleOutput(data)
                }
            }
        }

        private func handleOutput(_ data: Data) {
            guard started, !data.isEmpty else { return }
            logMobileTakeoverPerformance(
                name: "terminal_output_observed", count: data.count,
                attributes: ["output_bytes": String(data.count), "output_byte_count_before": String(outputByteCount)])
            _ = appendTranscript(data)
            writeVTRenderer(data)
            let events = drainSessionEvents()
            let metadataChanged = applyMetadataEvents(titleChanged: events.titleChanged, pwdChanged: events.pwdChanged)
            sendQueryResponses(events.ptyResponse)
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.output)
            // After the output broadcast: that payload carries the screen frame, this one carries no
            // screen state at all, so the frame keeps the delta chain and the metadata reason only
            // drives the client's title refresh.
            if metadataChanged { postSessionMetadataDidChange() }
            scheduleInputOutputResyncIfNeeded()
        }

        @discardableResult private func appendTranscript(_ data: Data) -> Bool {
            guard let outputHandle else { return false }
            // The write is the only step that can fail the append: if the durable bytes never landed, the
            // caller must know (it keys live-renderer application off this return value).
            do { try outputHandle.write(contentsOf: data) } catch { return false }
            outputByteCount += data.count
            // Head-truncate the durable transcript once it grows past the live-transcript bound so a
            // long-running session stops accumulating disk without bound. This only snapshots offsets on
            // the engine; the trim's expensive work runs off it and commits on a later engine turn, which
            // is also when `outputByteCount` picks up the reduced end offset. The append's success is
            // independent of it — the bytes are already durable in output.log, and a trim never touches
            // that file until its atomic swap.
            transcriptTrim.trimIfNeeded(currentEndOffset: UInt64(outputByteCount), columns: terminalSize.columns, rows: terminalSize.rows)
            return true
        }

        private func ensureOutputHandle() throws {
            _ = FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            outputByteCount = Int(try handle.seekToEnd())
            outputHandle = handle
        }

        /// Opens the durable output handle for append WITHOUT truncating any existing
        /// transcript, for the handoff resume paths. `resumeFromHandoff` replays output.log
        /// (via `recreateVTRenderer`) to rebuild the screen and `resumeInPlaceAfterFailedExec`
        /// continues the same transcript, so both must keep the existing bytes — unlike
        /// `ensureOutputHandle`, whose `createFile(contents: nil)` recreates (and thus
        /// empties) the log for a fresh start. Creating the file only when absent leaves any
        /// existing history in place; `seekToEnd` positions the handle to append and
        /// re-derive the byte count.
        private func openOutputHandlePreservingTranscript() throws {
            guard outputHandle == nil else { return }
            if !FileManager.default.fileExists(atPath: paths.outputPath) {
                _ = FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            outputByteCount = Int(try handle.seekToEnd())
            outputHandle = handle
        }

        private func transcriptByteCount() throws -> UInt64 {
            guard FileManager.default.fileExists(atPath: paths.outputPath) else { return 0 }
            let attributes = try FileManager.default.attributesOfItem(atPath: paths.outputPath)
            guard let size = attributes[.size] as? NSNumber else { throw POSIXError(.EIO) }
            return size.uint64Value
        }

        private func startControlServer() throws {
            let server = TerminalControlServer(socketPath: paths.controlSocketPath, queue: controlQueue) { [weak self] request in
                // The control server runs this on its own transport queue; bridge synchronously onto the
                // terminal engine actor (never the main actor) so a blocked main actor can't stall control.
                TerminalEngineActor.runSynchronously {
                    guard let self else {
                        return TerminalControlResponse(ok: false, message: "Terminal session is shutting down.", errorCode: .shuttingDown)
                    }
                    return self.handleControlRequest(request)
                }
            }
            try server.start()
            controlServer = server
        }

        private func startStateStreamServer() throws {
            let server = GhosttyRemoteSessionStateStreamServer(
                socketPath: paths.subscriptionSocketPath, queue: stateStreamQueue,
                initialStateProvider: { [weak self] in
                    TerminalEngineActor.runSynchronously {
                        self?.makeStatePayload(
                            reason: TerminalRemoteSessionStateReason.initial, exportMode: .selfContained, markNextBroadcastFull: false)
                    }
                })
            try server.start()
            stateStreamServer = server
        }

        public func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            let response: TerminalControlResponse
            switch request.command {
            case "attach": response = attach(request)
            case "detach": response = detach(request)
            case "heartbeat": response = heartbeat(request)
            case "takeover": response = takeover(request)
            case "send": response = send(request)
            case "key": response = key(request)
            case "clearScreen": response = clearScreen(request)
            case "resize": response = resize(request)
            case "scroll": response = scroll(request)
            case "mouseButton": response = mouseButton(request)
            case "setAppearance": response = setAppearance(request)
            default: response = TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(request.command)'.")
            }
            logMobileTakeoverPerformance(
                name: "terminal_control_host_handle", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                attributes: [
                    "action": request.command, "ok": response.ok ? "1" : "0", "client_id": request.clientID ?? "nil",
                    "owner_epoch": request.ownerEpoch.map(String.init) ?? "nil",
                ])
            return response
        }

        private func attach(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let client = request.client else {
                return TerminalControlResponse(ok: false, message: "Missing client payload.", errorCode: .invalidArgument)
            }
            let mode = request.attachmentMode ?? .viewer
            do {
                // Adopt the attaching client's light/dark appearance before broadcasting, so the
                // state the client receives on attach already carries the matching theme variant.
                if let appearance = request.appearance { applyThemeAppearance(appearance) }
                let previousOwner = activeOwnerClientID()
                try TerminalSessionPersistence.attachClient(
                    sessionID: launchConfiguration.sessionID, client: client, mode: mode, paths: paths, attachedAt: nowISO8601())
                // The attach wrote this client's lease and revived its durable row, so any coalescing record
                // from an earlier attachment of the same client id is void.
                leaseTouchCoalescer.forget(clientID: client.id)
                // Resize serials are scoped to an attachment, not to a client id. A client that reconnects
                // to a session it already owns keeps its id — an app relaunch reattaches as the same owner,
                // which leaves the owner unchanged and so does not advance the epoch — while its host
                // counts serials from zero again. Carrying the previous attachment's high-water mark across
                // that would reject every serial the reconnected client sends and pin the session to the
                // grid it had before.
                lastResizeSerialByClientID.removeValue(forKey: client.id)
                if mode == .owner, previousOwner != client.id { advanceOwnerEpoch() }
                writeRuntimeState(state: .running)
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.attachmentState)
                return TerminalControlResponse(ok: true, message: "Attached \(mode.rawValue) client.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        private func detach(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let clientID = request.clientID else {
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                let detachedOwner = activeOwnerClientID() == clientID
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: nowISO8601())
                leaseTouchCoalescer.forget(clientID: clientID)
                if detachedOwner { advanceOwnerEpoch() }
                writeRuntimeState(state: .running)
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.attachmentState)
                return TerminalControlResponse(ok: true, message: "Detached terminal client.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        private func heartbeat(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let clientID = request.clientID else {
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                guard try touchClientLeaseIfDue(clientID: clientID) else {
                    return TerminalControlResponse(ok: false, message: "Terminal client is no longer attached.", errorCode: .notFound)
                }
                return TerminalControlResponse(ok: true, message: "Refreshed terminal client lease.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        /// Refreshes `clientID`'s durable lease unless it was refreshed within the coalescing window, and
        /// reports whether the client is still attached.
        ///
        /// A skipped write answers from the coalescing record rather than from the database. That is sound
        /// because this core is the only writer of its session's client rows and it drops a client's record
        /// whenever it attaches or detaches that client: a surviving record therefore means the client was
        /// attached at the recorded write and nothing has detached it since. A write that reports the client
        /// gone — or fails outright — drops the record so the next heartbeat asks the database again.
        private func touchClientLeaseIfDue(clientID: String) throws -> Bool {
            let now = Date()
            guard leaseTouchCoalescer.isDurableTouchDue(clientID: clientID, now: now) else { return true }
            let attached: Bool
            do {
                attached = try TerminalSessionPersistence.touchClient(
                    id: clientID, paths: paths, touchedAt: GhosttyRemoteSessionStateTimestamp.string(from: now))
            } catch {
                leaseTouchCoalescer.forget(clientID: clientID)
                throw error
            }
            if !attached { leaseTouchCoalescer.forget(clientID: clientID) }
            return attached
        }

        private func takeover(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let clientID = request.clientID else {
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                _ = try? touchClientLeaseIfDue(clientID: clientID)
                let previousOwner = activeOwnerClientID()
                try TerminalSessionPersistence.transferOwnership(
                    sessionID: launchConfiguration.sessionID, newOwnerClientID: clientID, paths: paths, transferredAt: nowISO8601())
                if previousOwner != clientID { advanceOwnerEpoch() }
                writeRuntimeState(state: .running)
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.attachmentState)
                return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        private func send(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can send input.", errorCode: .ownershipRejected)
            }
            if request.asPaste {
                guard var text = request.text, request.bytes == nil else {
                    return TerminalControlResponse(ok: false, message: "Paste input requires text payload.", errorCode: .invalidArgument)
                }
                if request.appendNewline { text.append("\n") }
                guard let payload = encodePastePayload(text) else {
                    return TerminalControlResponse(ok: false, message: "Unable to encode paste input.", errorCode: .internalError)
                }
                markLocalOwnerCommandInputOutputResyncPending()
                enqueueControlInputWrite(payload)
                return TerminalControlResponse(ok: true, message: "Sent input.")
            }
            guard let payload = request.inputPayload else {
                return TerminalControlResponse(ok: false, message: "Missing input payload.", errorCode: .invalidArgument)
            }
            markLocalOwnerCommandInputOutputResyncPending()
            // Submit-safe two-write split for text payloads; see GhosttyEmbeddedSessionHost for the
            // paste-heuristic rationale and TerminalControlInputSequencer for the ordering guarantee. A
            // bare Enter (empty text) and opaque byte payloads keep the single (still sequenced) write.
            let isTextPayload = request.bytes == nil
            if request.appendNewline, isTextPayload, !payload.isEmpty {
                enqueueControlInputWrite(payload)
                enqueueControlSubmitCarriageReturn()
            } else {
                var bytes = payload
                if request.appendNewline { bytes.append(0x0D) }
                enqueueControlInputWrite(bytes)
            }
            return TerminalControlResponse(ok: true, message: "Sent input.")
        }

        private func enqueueControlInputWrite(_ bytes: Data) {
            controlInputSequencer.enqueueWrite { [weak self] in await TerminalEngineActor.run { self?.ptyDriver.sendRawBytes(bytes) } }
        }

        private func enqueueControlSubmitCarriageReturn() {
            controlInputSequencer.enqueueSubmitCarriageReturn { [weak self] in
                await TerminalEngineActor.run { self?.ptyDriver.sendRawBytes(Data([0x0D])) }
            }
        }

        private func encodePastePayload(_ text: String) -> Data? {
            guard let vtSession else { return nil }
            let data = Data(text.utf8)
            var encodedPointer: UnsafeMutablePointer<CChar>?
            var encodedLength: size_t = 0
            let encoded = data.withUnsafeBytes { rawBuffer -> Bool in
                if data.isEmpty { return spaces_ghostty_vt_session_encode_paste(vtSession, nil, 0, &encodedPointer, &encodedLength) }
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
                return spaces_ghostty_vt_session_encode_paste(vtSession, baseAddress, data.count, &encodedPointer, &encodedLength)
            }
            guard encoded else { return nil }
            defer { if let encodedPointer { spaces_ghostty_vt_free_buffer(encodedPointer) } }
            guard let encodedPointer, encodedLength > 0 else { return Data() }
            return Data(bytes: encodedPointer, count: encodedLength)
        }

        private func key(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can send input.", errorCode: .ownershipRejected)
            }
            guard let key = request.key, let resolution = TerminalKeyInput.resolve(key) else {
                return TerminalControlResponse(ok: false, message: "Unsupported terminal key.", errorCode: .invalidArgument)
            }
            switch resolution {
            case .hostAction(.clearScreenAndScrollback): return clearScreen(request)
            case .lineEditingBytes(let bytes): enqueueControlInputWrite(Data(bytes))
            case .keyPress(let spec):
                // The vt session is the live terminal state the encoding depends on, so a key press has
                // nowhere to be encoded without it.
                guard let vtSession, let bytes = GhosttyLinuxKeyEncoder.encode(spec, session: vtSession) else {
                    return TerminalControlResponse(ok: false, message: "Unable to encode terminal key.", errorCode: .sessionNotAvailable)
                }
                if spec.key == .enter { markLocalOwnerCommandInputOutputResyncPending() }
                // Some presses legitimately encode to nothing; that is a successful no-op, not a failure.
                if !bytes.isEmpty { enqueueControlInputWrite(bytes) }
            }
            return TerminalControlResponse(ok: true, message: "Sent key.")
        }

        private func clearScreen(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can clear the terminal.", errorCode: .ownershipRejected)
            }
            let mutation = GhosttyTerminalTranscriptMutation.clearScreenAndScrollback
            guard appendTranscript(mutation) else {
                return TerminalControlResponse(ok: false, message: "Unable to persist the terminal clear operation.")
            }
            writeVTRenderer(mutation)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.clearScreen)
            return TerminalControlResponse(ok: true, message: "Cleared terminal screen and scrollback.")
        }

        private func resize(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can resize the terminal.", errorCode: .ownershipRejected)
            }
            if let rejection = staleResizeSerialRejection(for: request) { return rejection }
            guard let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 else {
                return TerminalControlResponse(ok: false, message: "Missing terminal size.", errorCode: .invalidArgument)
            }
            guard let vtSession else { return TerminalControlResponse(ok: false, message: "Terminal renderer is unavailable.") }
            // Resizing to the grid the session already has is a no-op, not a reflow: reflowing would
            // rewrite every row, bump the screen revision and push a full frame to every subscriber for
            // a screen that did not change.
            guard terminalSize.columns != columns || terminalSize.rows != rows else {
                recordAcceptedResizeSerial(from: request)
                return TerminalControlResponse(ok: true, message: "Terminal already matches the requested size.")
            }
            // Resize transforms the LIVE renderer in place (libghostty reflow), never by
            // replaying output.log at the new size: the session already holds the accumulated
            // state, and the transcript's bytes (including any trim-time state preamble) are
            // laid out for the grid they were produced on, so a replay at another width
            // garbles the screen. Replay is reserved for the handoff paths, where renderer
            // memory genuinely did not survive the exec.
            guard spaces_ghostty_vt_session_resize(vtSession, UInt16(clamping: columns), UInt16(clamping: rows)) else {
                return TerminalControlResponse(ok: false, message: "Unable to resize the terminal renderer.")
            }
            // The reflow rewrote every row: drop the diff baseline and force the next
            // broadcast to a self-contained full frame, the same way a renderer swap does.
            renderUpdateBaseline = nil
            forceNextBroadcastFullRenderUpdate = true
            screenStateRevision &+= 1
            terminalSize = (columns, rows)
            recordAcceptedResizeSerial(from: request)
            _ = ptyDriver.resizeCellGrid(columns: columns, rows: rows)
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.resize)
            return TerminalControlResponse(ok: true, message: "Resized terminal.")
        }

        private func scroll(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can scroll the terminal.", errorCode: .ownershipRejected)
            }
            guard let vtSession else { return TerminalControlResponse(ok: false, message: "Terminal renderer is unavailable.") }
            let vertical = request.scrollVertical ?? 0
            let scrollMods = request.scrollMods ?? 0
            let deltaRows = scrollDeltaNormalizer.terminalViewportDeltaRows(vertical: vertical, scrollMods: scrollMods)
            // A wheel event belongs to the application once it tracks the mouse: ghostty's surface reports
            // one button-four/five press per row of delta (six/seven per column of horizontal delta) and
            // leaves the viewport alone, and this is the same behavior on the vt-only host.
            if GhosttyLinuxMouseEncoder.trackingIsActive(session: vtSession) {
                let deltaColumns = horizontalWheelReportDelta(horizontal: request.scrollHorizontal ?? 0, scrollMods: scrollMods)
                guard deltaRows != 0 || deltaColumns != 0 else { return TerminalControlResponse(ok: true, message: "Ignored zero scroll delta.") }
                return reportWheel(request, deltaRows: deltaRows, deltaColumns: deltaColumns, session: vtSession)
            }
            guard deltaRows != 0 else { return TerminalControlResponse(ok: true, message: "Ignored zero scroll delta.") }
            var attributes = [
                "action": request.command, "client_id": request.clientID ?? "nil", "delta_rows": String(deltaRows),
                "owner_epoch": request.ownerEpoch.map(String.init) ?? "nil", "scroll_mods": String(scrollMods), "scroll_vertical": String(vertical),
            ]
            let nativeStartedAt = Date()
            var beforeScrollbar = SpacesGhosttyVtScrollbar()
            var afterScrollbar = SpacesGhosttyVtScrollbar()
            guard spaces_ghostty_vt_session_scroll_viewport_with_info(vtSession, deltaRows, &beforeScrollbar, &afterScrollbar) else {
                return TerminalControlResponse(ok: false, message: "Unable to scroll terminal.")
            }
            attributes["scrollbar_before"] = "\(beforeScrollbar.offset)/\(beforeScrollbar.total)"
            attributes["scrollbar_after"] = "\(afterScrollbar.offset)/\(afterScrollbar.total)"
            guard beforeScrollbar.offset != afterScrollbar.offset else {
                logMobileTakeoverPerformance(
                    name: "scroll_native_end", elapsedMS: TerminalPerformance.elapsedMS(since: nativeStartedAt), attributes: attributes)
                return TerminalControlResponse(ok: true, message: "Already at scroll boundary.")
            }
            logMobileTakeoverPerformance(
                name: "scroll_native_end", elapsedMS: TerminalPerformance.elapsedMS(since: nativeStartedAt), attributes: attributes)
            screenStateRevision &+= 1
            let broadcastStartedAt = Date()
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.scroll)
            logMobileTakeoverPerformance(
                name: "scroll_broadcast_end", elapsedMS: TerminalPerformance.elapsedMS(since: broadcastStartedAt), attributes: attributes)
            return TerminalControlResponse(ok: true, message: "Scrolled terminal.")
        }

        /// Converts a horizontal scroll delta into wheel-report columns with ghostty's own x-axis
        /// semantics, which differ from the vertical axis on purpose: a non-precise notch maps to
        /// exactly one report (ghostty rounds the offset directly, with no discrete multiplier),
        /// and precise deltas accumulate against the cell width. Returns ghostty's sign: positive
        /// is rightward.
        private func horizontalWheelReportDelta(horizontal: Double, scrollMods: Int32) -> Int {
            guard horizontal != 0 else { return 0 }
            guard TerminalScrollModifiers.hasPreciseDeltas(scrollMods) else { return Int(horizontal.rounded()) }
            let pending = pendingPreciseHorizontalDelta + horizontal
            guard abs(pending) >= Self.approximateCellWidth else {
                pendingPreciseHorizontalDelta = pending
                return 0
            }
            let delta = Int((pending / Self.approximateCellWidth).rounded(.towardZero))
            pendingPreciseHorizontalDelta = pending - Double(delta) * Self.approximateCellWidth
            return delta
        }

        /// A headless session has no font metrics to take a real cell width from; the vertical
        /// axis' default cell height with a typical monospace aspect ratio stands in for one.
        private static let approximateCellWidth: Double = TerminalScrollDeltaNormalizer.defaultCellHeight / 2

        private func reportWheel(_ request: TerminalControlRequest, deltaRows: Int, deltaColumns: Int, session: OpaquePointer)
            -> TerminalControlResponse
        {
            let cell = pointerCell(x: request.scrollPointerX, y: request.scrollPointerY)
            // The vertical normalizer negates raw deltas (negative rows = scrolled up = button four);
            // horizontal deltas keep ghostty's sign (positive = right = button six).
            let verticalButton = deltaRows < 0 ? Self.wheelUpButton : Self.wheelDownButton
            let horizontalButton = deltaColumns > 0 ? Self.wheelRightButton : Self.wheelLeftButton
            for (button, magnitude) in [(verticalButton, abs(deltaRows)), (horizontalButton, abs(deltaColumns))] {
                for _ in 0..<magnitude {
                    guard
                        let bytes = GhosttyLinuxMouseEncoder.encode(
                            button: button, pressed: true, cellColumn: cell.column, cellRow: cell.row, mods: request.scrollPointerMods ?? 0,
                            session: session)
                    else {
                        return TerminalControlResponse(ok: false, message: "Unable to encode terminal mouse report.", errorCode: .sessionNotAvailable)
                    }
                    if !bytes.isEmpty { enqueueControlInputWrite(bytes) }
                }
            }
            return TerminalControlResponse(ok: true, message: "Reported terminal scroll.")
        }

        private func mouseButton(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can send input.", errorCode: .ownershipRejected)
            }
            guard let vtSession else { return TerminalControlResponse(ok: false, message: "Terminal renderer is unavailable.") }
            guard let button = request.mouseButton, let pressed = request.mousePressed else {
                return TerminalControlResponse(ok: false, message: "Missing mouse button.", errorCode: .invalidArgument)
            }
            guard button >= TerminalControlMouseButtonPayload.minimumButton, button <= TerminalControlMouseButtonPayload.maximumButton else {
                return TerminalControlResponse(ok: false, message: "Unsupported mouse button.", errorCode: .invalidArgument)
            }
            guard let pointerX = request.mousePointerX, let pointerY = request.mousePointerY else {
                return TerminalControlResponse(ok: false, message: "Missing mouse pointer position.", errorCode: .invalidArgument)
            }
            let position = TerminalScrollPointerPosition(x: pointerX, y: pointerY, mods: request.mousePointerMods ?? 0)
            guard position.isValid else {
                return TerminalControlResponse(ok: false, message: "Invalid terminal mouse button pointer position.", errorCode: .invalidArgument)
            }
            let cell = pointerCell(x: pointerX, y: pointerY)
            guard
                let bytes = GhosttyLinuxMouseEncoder.encode(
                    button: button, pressed: pressed, cellColumn: cell.column, cellRow: cell.row, mods: position.mods, session: vtSession)
            else { return TerminalControlResponse(ok: false, message: "Unable to encode terminal mouse report.", errorCode: .sessionNotAvailable) }
            // A button the terminal's current tracking mode does not report encodes to nothing; that is a
            // successful no-op, not a failure.
            if !bytes.isEmpty { enqueueControlInputWrite(bytes) }
            return TerminalControlResponse(ok: true, message: "Delivered mouse button.")
        }

        /// Resolves a client's normalized pointer against this session's own grid. Raw client pixels are
        /// never transported because client and daemon cell geometry differ; absent coordinates resolve to
        /// the origin, which is the only position a host with no rendered pointer can name.
        private func pointerCell(x: Double?, y: Double?) -> (column: Int, row: Int) {
            let columns = max(terminalSize.columns, 1)
            let rows = max(terminalSize.rows, 1)
            let column = Int((min(max(x ?? 0, 0), 1) * Double(columns)).rounded(.down))
            let row = Int((min(max(y ?? 0, 0), 1) * Double(rows)).rounded(.down))
            return (column: min(column, columns - 1), row: min(row, rows - 1))
        }

        private static let wheelUpButton = UInt8(SPACES_GHOSTTY_VT_MOUSE_BUTTON_FOUR.rawValue)
        private static let wheelDownButton = UInt8(SPACES_GHOSTTY_VT_MOUSE_BUTTON_FIVE.rawValue)
        private static let wheelRightButton = UInt8(SPACES_GHOSTTY_VT_MOUSE_BUTTON_SIX.rawValue)
        private static let wheelLeftButton = UInt8(SPACES_GHOSTTY_VT_MOUSE_BUTTON_SEVEN.rawValue)

        private func setAppearance(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let appearance = request.appearance else {
                return TerminalControlResponse(ok: false, message: "Missing appearance.", errorCode: .invalidArgument)
            }
            // Don't re-theme an exited session (parity with the macOS host's isRuntimeInteractiveForControl
            // guard). The renderer is freed on exit, and the control socket is torn down with it, so this
            // is the same not-running check the scroll handler makes before touching the vt session.
            guard started, vtSession != nil else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            // Appearance is a per-client view preference on a shared session with last-writer-wins
            // semantics, so it is deliberately NOT owner-gated: any attached client may re-theme the
            // terminal it is watching.
            guard appearance != currentAppearance else {
                return TerminalControlResponse(ok: true, message: "Terminal already matches the requested appearance.")
            }
            // The vt re-theme is synchronous (unlike the macOS io thread), and applyThemeAppearance
            // arms the full-frame flag and bumps the screen revision, so broadcast right after to push
            // the recolored full frame to subscribers promptly.
            applyThemeAppearance(appearance)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.stateChange)
            return TerminalControlResponse(ok: true, message: "Applied \(appearance.rawValue) appearance.")
        }

        private func ownerRequestIsCurrent(_ request: TerminalControlRequest) -> Bool {
            // Requests without a client ID are daemon-local trusted callers — the profile terminal
            // commands and the agent-facing Device API send path — which are deliberately not
            // attachment-gated. This matches the macOS host's ownerRequestRejection semantics; the
            // owner gate exists to arbitrate between attached rendering clients, not to block agents.
            guard let clientID = request.clientID else { return true }
            guard activeOwnerClientID() == clientID else { return false }
            guard let requestedOwnerEpoch = request.ownerEpoch else { return true }
            return requestedOwnerEpoch == ownerEpoch
        }

        private func activeOwnerClientID() -> String? {
            ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first { $0.mode == .owner }?.clientID
        }

        private func activeOwnerClient() -> TerminalClient? {
            guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
                let ownerID = TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: snapshot)
            else { return nil }
            return snapshot.clients.first { $0.id == ownerID }
        }

        private func advanceOwnerEpoch() {
            ownerEpoch &+= 1
            lastResizeSerialByClientID.removeAll(keepingCapacity: true)
        }

        private func staleResizeSerialRejection(for request: TerminalControlRequest) -> TerminalControlResponse? {
            guard let clientID = request.clientID, let resizeSerial = request.resizeSerial else { return nil }
            guard let lastResizeSerial = lastResizeSerialByClientID[clientID], resizeSerial <= lastResizeSerial else { return nil }
            return TerminalControlResponse(
                ok: false, message: "Ignoring stale resize serial \(resizeSerial); latest accepted serial is \(lastResizeSerial).",
                errorCode: .ownershipRejected)
        }

        private func recordAcceptedResizeSerial(from request: TerminalControlRequest) {
            guard let clientID = request.clientID, let resizeSerial = request.resizeSerial else { return }
            lastResizeSerialByClientID[clientID] = resizeSerial
        }

        private func markLocalOwnerCommandInputOutputResyncPending() {
            guard activeOwnerClient()?.kind == .localWindow else { return }
            localOwnerCommandInputOutputResyncPending = true
        }

        private func scheduleInputOutputResyncIfNeeded() {
            guard localOwnerCommandInputOutputResyncPending else { return }
            localOwnerCommandInputOutputResyncPending = false
            inputOutputResyncTask?.cancel()
            inputOutputResyncTask = Task { @TerminalEngineActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self else { return }
                self.inputOutputResyncTask = nil
                self.broadcastCurrentState(reason: TerminalRemoteSessionStateReason.inputOutput)
            }
        }

        private func writeVTRenderer(_ data: Data) {
            guard let vtSession, !data.isEmpty else { return }
            data.withUnsafeBytes { rawBuffer in
                _ = spaces_ghostty_vt_session_write(vtSession, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
            }
            screenStateRevision &+= 1
        }

        /// One output turn's terminal events, drained from the vt session's event sink. The sink also
        /// records bells and clipboard writes; this core does not consume those, so the drain releases
        /// them along with the rest of the record.
        private struct SessionEvents {
            var titleChanged = false
            var pwdChanged = false
            var ptyResponse = Data()
        }

        /// Takes the events the vt session accumulated during the writes since the last drain. The C
        /// sink hands over ownership of its buffers, which are released once copied into Swift values.
        private func drainSessionEvents() -> SessionEvents {
            guard let vtSession else { return SessionEvents() }
            var raw = SpacesGhosttyVtSessionEvents()
            spaces_ghostty_vt_session_drain_events(vtSession, &raw)
            defer { spaces_ghostty_vt_session_events_free(&raw) }
            var events = SessionEvents(titleChanged: raw.title_changed, pwdChanged: raw.pwd_changed)
            if let response = raw.pty_response, raw.pty_response_len > 0 { events.ptyResponse = Data(bytes: response, count: raw.pty_response_len) }
            return events
        }

        /// Writes the terminal's own replies to the program's queries (cursor position, mode reports,
        /// color reports, XTVERSION) back to the PTY. These go straight to the driver rather than
        /// through `controlInputSequencer`: that sequencer exists to order USER input against submits,
        /// and a reply the program is synchronously blocked reading must not queue behind typing.
        private func sendQueryResponses(_ bytes: Data) {
            guard !bytes.isEmpty else { return }
            ptyDriver.sendRawBytes(bytes)
        }

        /// Folds the title (OSC 0/2) and working directory (OSC 7) the just-written bytes reported into
        /// the cached metadata every runtime state and state payload echoes, and reports whether either
        /// changed. Called right after the bytes reach the vt session so the runtime state the caller
        /// then writes and broadcasts already carries the new values.
        ///
        /// Each getter is read only when its event fired, which is what makes an absent value
        /// unambiguous: the program emitted an empty payload, so the cache clears and the session falls
        /// back to its launch-configuration value. Without the event, absent would equally mean "never
        /// set", which is what a session rebuilt from a trimmed transcript reports.
        ///
        /// A reported OSC 7 payload that fails the decode (foreign host, unknown scheme, not a URI) is
        /// ignored outright and the previously accepted directory stands, matching the surface path,
        /// where a rejected OSC 7 never reaches the app.
        ///
        /// The event says a value was reported, not what it was — the value is read back from the vt
        /// session — so several reports of the same kind inside one write collapse to the last one.
        @discardableResult private func applyMetadataEvents(titleChanged: Bool, pwdChanged: Bool) -> Bool {
            guard let vtSession else { return false }
            var changed = false

            if titleChanged {
                // A whitespace-only payload normalizes to nil and clears, same as an empty one — the
                // macOS host also treats a whitespace-only title as cleared.
                let title = Self.normalizedSessionMetadataValue(Self.copyShimString { spaces_ghostty_vt_session_title(vtSession, $0, $1) })
                if currentTitle != title {
                    currentTitle = title
                    changed = true
                }
            }

            if pwdChanged {
                if let rawWorkingDirectory = Self.copyShimString({ spaces_ghostty_vt_session_pwd(vtSession, $0, $1) }) {
                    if let workingDirectory = Self.normalizedSessionMetadataValue(
                        TerminalWorkingDirectoryURI.decodedPath(fromOSC7: rawWorkingDirectory)), currentWorkingDirectory != workingDirectory
                    {
                        currentWorkingDirectory = workingDirectory
                        changed = true
                    }
                } else if currentWorkingDirectory != nil {
                    currentWorkingDirectory = nil
                    changed = true
                }
            }
            return changed
        }

        /// Rebuild path: adopts whatever title and working directory the replacement session's replay
        /// re-established. Never clears — a replay that does not re-emit an escape sequence says nothing
        /// about the value, and the cache it would erase is exactly the one the rebuild preserves.
        private func seedMetadataFromVTSession() {
            guard let vtSession else { return }
            if let title = Self.normalizedSessionMetadataValue(Self.copyShimString { spaces_ghostty_vt_session_title(vtSession, $0, $1) }) {
                currentTitle = title
            }
            if let rawWorkingDirectory = Self.copyShimString({ spaces_ghostty_vt_session_pwd(vtSession, $0, $1) }),
                let workingDirectory = Self.normalizedSessionMetadataValue(TerminalWorkingDirectoryURI.decodedPath(fromOSC7: rawWorkingDirectory))
            {
                currentWorkingDirectory = workingDirectory
            }
        }

        /// Announces a title/working-directory change under its own reason. `TerminalRemoteSessionStateNotificationRouting`
        /// routes the screen-content reasons (`output` and friends) to an output-shaped refresh that never
        /// re-derives pane and tab titles, so a metadata change carried only by the output broadcast would
        /// reach a mirroring client's cache without ever being displayed. Platform parity with the macOS
        /// host's `postSessionMetadataDidChange`.
        private func postSessionMetadataDidChange() {
            TerminalSessionNotification.post(.spacesTerminalSessionMetadataDidChange, sessionID: launchConfiguration.sessionID)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.sessionMetadata)
        }

        /// Reads one of the shim's malloc'd string getters into a Swift `String`. The shim reports an
        /// unset value as `false`, which surfaces here as nil.
        private static func copyShimString(_ read: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<Int>) -> Bool) -> String?
        {
            var pointer: UnsafeMutablePointer<CChar>?
            var length = 0
            guard read(&pointer, &length), let pointer, length > 0 else { return nil }
            defer { spaces_ghostty_vt_free_buffer(pointer) }
            return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
                String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
            }
        }

        private static func normalizedSessionMetadataValue(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// Rebuilds the VT renderer from the append-only transcript without ever
        /// materializing the whole file in memory. Replay happens into a replacement
        /// session first, so a read or VT-write failure leaves the current renderer
        /// intact and handoff resume can fail before adopting the inherited PTY.
        /// Only the handoff resume paths use this — renderer memory did not survive the
        /// exec there, so the transcript is the sole source of truth. A live resize never
        /// comes here: it resizes the existing vt session in place (reflow) instead.
        ///
        /// `eventsLiveFromTranscriptOffset` splits the replay: bytes before it are replayed with events
        /// off (they were already parsed once, by the pre-exec image), bytes from it onward with events
        /// live, so the caller's drain sees exactly what the unparsed handoff-window suffix raised. Nil
        /// (or an offset at/past the end of the file) replays the whole transcript with events off and
        /// enables them at the tail.
        private func recreateVTRenderer(columns: Int, rows: Int, eventsLiveFromTranscriptOffset: UInt64?) throws {
            guard let replacementSession = makeVTSession(columns: columns, rows: rows) else {
                throw GhosttyLinuxHeadlessSessionError.vtSessionUnavailable
            }
            func writeReplay(_ bytes: Data) throws {
                guard !bytes.isEmpty else { return }
                let succeeded = bytes.withUnsafeBytes { rawBuffer in
                    spaces_ghostty_vt_session_write(replacementSession, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
                }
                guard succeeded else { throw GhosttyLinuxHeadlessSessionError.vtReplayFailed }
            }
            func enableEvents() throws {
                guard spaces_ghostty_vt_session_enable_events(replacementSession) else {
                    throw GhosttyLinuxHeadlessSessionError.eventRegistrationFailed
                }
            }
            do {
                var replayedByteCount: UInt64 = 0
                var eventsEnabled = false
                let replayedOutput = try Self.replayOutputLog(at: paths.outputPath) { chunk in
                    let chunkStart = replayedByteCount
                    replayedByteCount &+= UInt64(chunk.count)
                    guard !eventsEnabled, let boundary = eventsLiveFromTranscriptOffset, boundary < replayedByteCount else {
                        try writeReplay(chunk)
                        return
                    }
                    // The boundary falls at or inside this chunk: write the already-parsed head, turn
                    // events on, then let the rest of the chunk replay under them.
                    let headCount = boundary > chunkStart ? Int(boundary - chunkStart) : 0
                    try writeReplay(chunk.prefix(headCount))
                    try enableEvents()
                    eventsEnabled = true
                    try writeReplay(chunk.dropFirst(headCount))
                }
                // Events are enabled only AFTER the replay above, so the historical bells and clipboard
                // writes the transcript carries do not fire a second time. Still before the swap, so a
                // failure here unwinds into the catch below with the current session untouched.
                if !eventsEnabled { try enableEvents() }
                if let vtSession { spaces_ghostty_vt_session_free(vtSession) }
                vtSession = replacementSession
                // The replayed transcript may carry a newer title/pwd than the cache; adopt those, but
                // keep the cached values when the replay never re-emits the escape sequences.
                seedMetadataFromVTSession()
                renderUpdateBaseline = nil
                forceNextBroadcastFullRenderUpdate = true
                if replayedOutput { screenStateRevision &+= 1 }
            } catch {
                spaces_ghostty_vt_session_free(replacementSession)
                throw error
            }
        }

        /// Streams a transcript through `consume` in fixed-size chunks. Internal so
        /// tests can enforce the memory-bound contract independently of file size.
        @discardableResult nonisolated static func replayOutputLog(at path: String, startingAt offset: UInt64 = 0, consume: (Data) throws -> Void)
            throws -> Bool
        {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            var replayedOutput = false
            while let chunk = try handle.read(upToCount: outputReplayChunkByteCount), !chunk.isEmpty {
                try consume(chunk)
                replayedOutput = true
            }
            return replayedOutput
        }

        /// Creates a headless vt session themed with the Spaces terminal colors, so the render
        /// frames this daemon streams to the client match the app instead of libghostty-vt's default
        /// palette. The daemon resolves the palette itself from the shared theme registry (it links
        /// `spacesterminalcore`); the attaching client conveys only its light/dark appearance
        /// (`applyThemeAppearance(_:)`), since the headless daemon cannot read the client's OS
        /// appearance. Until a client attaches, the session uses the default (dark) appearance.
        private func makeVTSession(columns: Int, rows: Int) -> OpaquePointer? {
            var theme = GhosttyVtSessionBridge.packTheme(ActiveTheme.descriptor.terminal(for: currentAppearance))
            return withUnsafePointer(to: &theme) { themePointer in
                spaces_ghostty_vt_session_new(UInt16(clamping: columns), UInt16(clamping: rows), Self.maxScrollbackBytes, themePointer)
            }
        }

        /// Re-themes the live session to the attaching client's appearance and forces the next
        /// broadcast to send a full frame so the recolored screen reaches the client immediately.
        /// A no-op when the appearance is unchanged, so repeated attaches do not churn full frames.
        private func applyThemeAppearance(_ appearance: ThemeAppearance) {
            guard appearance != currentAppearance else { return }
            currentAppearance = appearance
            guard let vtSession else { return }
            var theme = GhosttyVtSessionBridge.packTheme(ActiveTheme.descriptor.terminal(for: appearance))
            let applied = withUnsafePointer(to: &theme) { spaces_ghostty_vt_session_set_theme(vtSession, $0) }
            guard applied else { return }
            screenStateRevision &+= 1
            forceNextBroadcastFullRenderUpdate = true
        }

        private func writeRuntimeState(state: TerminalSessionState) { persistRuntimeState(makeRuntimeStateSnapshot(state: state)) }

        /// Builds a runtime-state snapshot for `state`, stamping `updatedAt`/`exitedAt` once per call.
        /// Extracted so an exit can be captured a single time and reused for both the persisted runtime
        /// state and the final payload (see `terminate()`), guaranteeing they share one `runIdentity`.
        private func makeRuntimeStateSnapshot(state: TerminalSessionState) -> TerminalSessionRuntimeState {
            let liveChildPID = ptyDriver.childPID()
            if let liveChildPID { lastKnownChildPID = liveChildPID }
            let foregroundPID = ptyDriver.foregroundPID()
            let foregroundProcess = foregroundPID.flatMap { TerminalForegroundProcessInspector.inspect(pid: $0) }
            let foregroundAgent = foregroundProcess.flatMap { TerminalForegroundProcessInspector.classify($0) }
            return TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(),
                childPID: liveChildPID ?? lastKnownChildPID, state: state, updatedAt: nowISO8601(),
                exitedAt: state.isInteractive ? nil : nowISO8601(), title: currentTitle ?? launchConfiguration.title,
                workingDirectory: currentWorkingDirectory ?? launchConfiguration.workingDirectory, columns: terminalSize.columns,
                rows: terminalSize.rows, foregroundPID: foregroundPID, foregroundExecutablePath: foregroundProcess?.executablePath,
                foregroundExecutableName: foregroundProcess?.executableName, foregroundArgv: foregroundProcess?.argv,
                foregroundDetectedAgentKind: foregroundAgent?.detectedAgentKind, foregroundDisplayLabel: foregroundAgent?.displayLabel,
                foregroundDisplayCommand: foregroundAgent?.displayCommand)
        }

        /// Advances the in-memory authoritative state immediately (so broadcasts show live truth regardless of
        /// when the durable write lands) and enqueues the durable runtime-state write off the engine. Coalesced
        /// latest-wins on the persistence queue, so a burst of persists — or an exited state superseding a
        /// still-queued running state — collapses to the newest. The durable marker advances and the
        /// change notification fires only on a successful write (see `markRuntimeStatePersisted`), so a failed
        /// write retries on the next persist and the overview never observes a change the DB has not committed.
        private func persistRuntimeState(_ runtimeState: TerminalSessionRuntimeState) {
            lastRuntimeState = runtimeState
            enqueueRuntimeStateWrite(runtimeState)
        }

        private func enqueueRuntimeStateWrite(_ state: TerminalSessionRuntimeState) {
            // `onPersisted` hops back to the engine to advance the durable marker (one-way rule); it is the
            // ONLY reference to `self` in the write chain, so the write — and any exited-state retry inside the
            // queue — survives this core's release (e.g. a session-close that drops the core after termination).
            persistence.enqueueRuntimeStateWrite(
                state, at: Date(), paths: paths,
                onPersisted: { [weak self] persistedState, _ in Task { @TerminalEngineActor in self?.markRuntimeStatePersisted(persistedState) } })
        }

        /// Advances the durable persist marker after a successful off-engine write and, when the persisted
        /// signature changed, fires the runtime-state notification so DB-reading consumers (the overview)
        /// observe the change only once it is durable while live subscribers still see live truth.
        private func markRuntimeStatePersisted(_ state: TerminalSessionRuntimeState) {
            let previousSignature = lastPersistedRuntimeState.map(runtimeStateSignature(for:))
            lastPersistedRuntimeState = state
            if previousSignature != runtimeStateSignature(for: state) { postRuntimeStateDidChange() }
        }

        private func postRuntimeStateDidChange() {
            TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: launchConfiguration.sessionID)
            TerminalOverviewSignal.post()
        }

        private func broadcastCurrentState(reason: String) {
            guard !suppressBroadcastsForHandoff else { return }
            let performanceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
            let startedAt = performanceLoggingEnabled ? Date() : nil
            guard let payload = makeStatePayload(reason: reason, exportMode: .streamDeltaAllowed) else { return }
            stateStreamServer?.broadcast(payload)
            guard performanceLoggingEnabled, let startedAt else { return }
            let decodedUpdate = payload.decodedRenderUpdate
            let attributes = GhosttyRenderFrameMetrics.attributes(
                reason: payload.reason, frame: decodedUpdate?.fullFrame, outputByteCount: outputByteCount,
                screenStateRevision: payload.screenStateRevision, frameKind: decodedUpdate?.frameKindMetricValue,
                baseRevision: decodedUpdate?.baseRevision, targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
                operationCount: decodedUpdate?.operationCount, changedCellCount: decodedUpdate?.changedCellCount,
                scrollOperationCount: decodedUpdate?.scrollOperationCount, fullFrameFallbackReason: decodedUpdate?.fallbackReason)
            logMobileTakeoverPerformance(
                name: "remote_state_publish", count: payload.renderUpdate?.count,
                attributes: [
                    "reason": payload.reason, "owner_kind": activeOwnerClient()?.kind.rawValue ?? "nil",
                    "render_update": payload.renderUpdate == nil ? "0" : "1", "render_update_bytes": String(payload.renderUpdate?.count ?? 0),
                ])
            logMobileTakeoverPerformance(
                name: "render_frame_payload_publish", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), count: payload.renderUpdate?.count,
                attributes: attributes)
        }

        private func makeStatePayload(
            reason: String, runtimeStateOverride: TerminalSessionRuntimeState? = nil, exportMode: RenderStateExportMode = .selfContained,
            markNextBroadcastFull: Bool = false
        ) -> GhosttyRemoteSessionStatePayload? {
            let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot()
            let ownerKind = TerminalRemoteSessionStatePolicy.activeOwnerClientKind(in: attachmentSnapshot)
            let includeScreenState = TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: reason, ownerKind: ownerKind)
            let runtimeState: TerminalSessionRuntimeState
            if let runtimeStateOverride {
                // Embed the caller-supplied snapshot verbatim so the payload's runtime state and the durable
                // row share one `runIdentity`. terminate() — the only caller that passes an override — enqueues
                // that durable exited write itself (retry-fenced, FIFO-ordered); this method only builds the
                // payload, so it must not persist here or the exited write would run inline on the engine.
                runtimeState = runtimeStateOverride
            } else {
                runtimeState = lastRuntimeState ?? fallbackRuntimeState(state: started ? .running : .exited)
            }
            let frame: GhosttyRenderFrame?
            let renderUpdateValue: GhosttyRenderUpdate?
            let renderUpdate: Data?
            if includeScreenState {
                let performanceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
                let snapshotExportStartedAt = performanceLoggingEnabled ? Date() : nil
                frame = try? renderFrame()
                let renderUpdateEncodeStartedAt = performanceLoggingEnabled ? Date() : nil
                renderUpdateValue = frame.map { makeRenderUpdate(for: $0, reason: reason, exportMode: exportMode) }
                renderUpdate = renderUpdateValue.flatMap { try? GhosttyRenderUpdateBinaryCodec.encode($0) }
                if performanceLoggingEnabled, let snapshotExportStartedAt, let renderUpdateEncodeStartedAt {
                    let renderUpdateEncodeMS = TerminalPerformance.elapsedMS(since: renderUpdateEncodeStartedAt)
                    var attributes = GhosttyRenderFrameMetrics.attributes(
                        reason: reason, frame: frame, outputByteCount: outputByteCount, screenStateRevision: screenStateRevision,
                        frameKind: renderUpdateValue?.frameKindMetricValue, baseRevision: renderUpdateValue?.baseRevision,
                        targetRevision: renderUpdateValue?.targetRevision ?? screenStateRevision, operationCount: renderUpdateValue?.operationCount,
                        changedCellCount: renderUpdateValue?.changedCellCount, scrollOperationCount: renderUpdateValue?.scrollOperationCount,
                        fullFrameFallbackReason: renderUpdateValue?.fallbackReason)
                    attributes["owner_kind"] = ownerKind?.rawValue ?? "nil"
                    attributes["render_update_bytes"] = String(renderUpdate?.count ?? 0)
                    attributes["render_update_encode_ms"] = String(renderUpdateEncodeMS)
                    logMobileTakeoverPerformance(
                        name: "render_frame_export_end", elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt),
                        count: renderUpdate?.count, attributes: attributes)
                }
            } else {
                frame = nil
                renderUpdateValue = nil
                renderUpdate = nil
            }
            if renderUpdate != nil, markNextBroadcastFull { forceNextBroadcastFullRenderUpdate = true }
            return GhosttyRemoteSessionStatePayload(
                sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: nowISO8601(), sessionStateRevision: nil, sessionStateFlags: nil,
                screenStateRevision: screenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
                title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, outputByteCount: outputByteCount,
                outputEndByteOffset: outputByteCount, renderUpdate: renderUpdate)
        }

        private func makeRenderUpdate(for frame: GhosttyRenderFrame, reason: String, exportMode: RenderStateExportMode) -> GhosttyRenderUpdate {
            let forceFullForSelfContainedExport = exportMode == .selfContained
            let hasPendingSubscriberBaselineReset = exportMode == .streamDeltaAllowed && forceNextBroadcastFullRenderUpdate
            let forceFullForSubscriberBaseline = hasPendingSubscriberBaselineReset && reason != TerminalRemoteSessionStateReason.scroll
            let forceFullForExplicitResync =
                reason == TerminalRemoteSessionStateReason.initial || reason == TerminalRemoteSessionStateReason.resize
                || reason == TerminalRemoteSessionStateReason.terminated
            let forceFull =
                forceFullForSelfContainedExport || forceFullForSubscriberBaseline || forceFullForExplicitResync
                || renderUpdateBaseline?.sessionRevision == frame.sessionRevision
            let forceFullReason =
                if reason == TerminalRemoteSessionStateReason.initial { "initial_baseline" } else if reason == TerminalRemoteSessionStateReason.resize
                { "resize_self_contained" } else if reason == TerminalRemoteSessionStateReason.terminated {
                    "explicit_resync"
                } else if forceFullForSubscriberBaseline { "subscriber_baseline_reset" } else if forceFullForSelfContainedExport {
                    "self_contained_state_export"
                } else { "baseline_already_current" }
            let update = GhosttyRenderUpdateFactory.makeUpdate(
                target: frame, baseline: renderUpdateBaseline, forceFull: forceFull, forceFullReason: forceFullReason)
            let shouldUpdateStreamBaseline = exportMode == .streamDeltaAllowed
            switch update.kind {
            case .full: if shouldUpdateStreamBaseline { renderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: frame) }
            case .delta:
                if let baseline = try? GhosttyRenderUpdateApplier.apply(update, to: renderUpdateBaseline) {
                    renderUpdateBaseline = baseline
                } else {
                    if shouldUpdateStreamBaseline { renderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: frame) }
                    return GhosttyRenderUpdate.full(frame, fallbackReason: "linux_delta_apply_failed")
                }
            case .resyncRequired: if shouldUpdateStreamBaseline { renderUpdateBaseline = nil }
            }
            if hasPendingSubscriberBaselineReset { forceNextBroadcastFullRenderUpdate = false }
            return update
        }

        private func renderFrame() throws -> GhosttyRenderFrame {
            guard let vtSession else { throw GhosttyLinuxHeadlessSessionError.vtSessionUnavailable }
            var rawSnapshot = SpacesGhosttyVtSnapshot()
            guard spaces_ghostty_vt_session_copy_snapshot(vtSession, &rawSnapshot) else { throw GhosttyLinuxHeadlessSessionError.snapshotUnavailable }
            defer { spaces_ghostty_vt_snapshot_free(&rawSnapshot) }
            let snapshot = GhosttyVtSessionBridge.snapshot(
                from: rawSnapshot, mouseReportingActive: GhosttyLinuxMouseEncoder.trackingIsActive(session: vtSession))
            return GhosttyRenderFrame(sessionRevision: screenStateRevision, ownerEpoch: ownerEpoch, snapshot: snapshot)
        }

        private func fallbackRuntimeState(state: TerminalSessionState) -> TerminalSessionRuntimeState {
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: lastKnownChildPID,
                state: state, updatedAt: nowISO8601(), exitedAt: state.isInteractive ? nil : nowISO8601(),
                title: currentTitle ?? launchConfiguration.title, workingDirectory: currentWorkingDirectory ?? launchConfiguration.workingDirectory,
                columns: terminalSize.columns, rows: terminalSize.rows)
        }

        private func runtimeStateSignature(for state: TerminalSessionRuntimeState) -> String {
            "\(state.sessionID)|\(state.backend.rawValue)|\(state.servicePID)|\(state.childPID.map(String.init) ?? "nil")|\(state.foregroundPID.map(String.init) ?? "nil")|\(state.foregroundExecutablePath ?? "nil")|\(state.foregroundExecutableName ?? "nil")|\(state.foregroundArgv?.joined(separator: "\u{1F}") ?? "nil")|\(state.foregroundDetectedAgentKind?.rawValue ?? "nil")|\(state.foregroundDisplayLabel ?? "nil")|\(state.foregroundDisplayCommand ?? "nil")|\(state.title ?? "nil")|\(state.workingDirectory ?? "nil")|\(state.columns.map(String.init) ?? "nil")|\(state.rows.map(String.init) ?? "nil")|\(state.state.rawValue)|\(state.exitedAt ?? "nil")"
        }

        private func nowISO8601() -> String { GhosttyRemoteSessionStateTimestamp.string(from: Date()) }

        /// `elapsedMS`/`count`/`attributes` are `@autoclosure` so a disabled logger never evaluates the
        /// dictionary literals callers build inline (e.g. per output tick in the session-state-change path)
        /// — the `isEnabled()` guard below runs first, and only then are the closures forced.
        private func logMobileTakeoverPerformance(
            name: String, elapsedMS: @autoclosure () -> Int? = nil, count: @autoclosure () -> Int? = nil,
            attributes: @autoclosure () -> [String: String] = [:]
        ) {
            guard SpacesDeviceTerminalPerformanceLogger.isEnabled() else { return }
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(
                    sessionID: launchConfiguration.sessionID, source: "linux-host", name: name, elapsedMS: elapsedMS(), count: count(),
                    attributes: attributes()))
        }
    }
#endif
