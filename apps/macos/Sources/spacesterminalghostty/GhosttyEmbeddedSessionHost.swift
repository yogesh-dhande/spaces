#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Darwin
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    private let ghosttyEmbeddedSessionTraceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_TERMINAL_TRACE"] == "1"

    private func ghosttyEmbeddedSessionTrace(_ sessionID: String, _ message: @autoclosure () -> String) {
        guard ghosttyEmbeddedSessionTraceEnabled else { return }
        fputs("spaces-mobile-terminal-trace t=\(ghosttyEmbeddedSessionTraceSeconds()) mac-host session=\(sessionID) \(message())\n", stderr)
        fflush(stderr)
    }

    private func ghosttyEmbeddedSessionTraceSeconds() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    @MainActor public protocol TerminalGhosttySessionInfoProviding: AnyObject {
        func activeOwnerClientID() -> String?
        var effectiveTitle: String { get }
        var effectiveWorkingDirectory: String { get }
    }

    @MainActor public protocol TerminalGhosttyRendererHosting: AnyObject {
        func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws
        func releaseRendererSurface()
        func setFocused(_ focused: Bool, for clientID: String)
        func focusWindow(_ window: NSWindow?)
        @discardableResult func handleKeyEvent(_ event: NSEvent, for clientID: String) -> Bool
        @discardableResult func synchronizeSurfaceGeometry() -> Bool
        func hasRenderableSurface() -> Bool
        func requestSurfaceRefresh()
        func prepareRenderStateExport()
        func snapshot() -> GhosttyTerminalSnapshot?
        func snapshotText() -> String?
        func sessionSnapshot() -> GhosttyTerminalSnapshot?
        func sessionSnapshotText() -> String?
        func copySelectionToPasteboard() -> Bool
        /// Reads the terminal's current shared selection via the daemon's `readSelectionText` and
        /// writes it to the pasteboard on success. See `RemoteGhosttySessionHost`'s implementation for
        /// why this is distinct from `copySelectionToPasteboard`.
        func copySharedSelectionToPasteboard(completion: @escaping @MainActor (Bool) -> Void)
        func pasteClipboardContents() -> Bool
        /// Renders this session at the app-wide terminal text size. A client-side display setting, so
        /// it applies whatever this host's attachment mode is and whether or not the session is live.
        func applyTerminalTextSize(_ size: TerminalTextSize)
        @discardableResult func sendTextAsPaste(_ text: String) -> Bool
        @discardableResult func performBindingAction(_ action: String) -> Bool
        @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)
            -> Bool
        @discardableResult func clearScreenAndScrollback() -> Bool
        var debugSearchState: GhosttyTerminalSearchDebugState { get }
        var debugSurfaceRefreshRequestCount: Int { get }
        func debugVisibleSurfaceText() -> String?
        /// The live surface's shared-selection text, so a test can observe the daemon-projected
        /// selection painted from streamed frames (see `GhosttyMirrorTerminalView.debugSurfaceSelectionText`).
        /// Nil with no surface or no selection.
        func debugSurfaceSelectionText() -> String?
    }

    @MainActor public protocol TerminalGhosttySessionHosting: TerminalGhosttySessionInfoProviding, TerminalGhosttyRendererHosting {}

    extension TerminalGhosttyRendererHosting {
        @discardableResult public func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
            sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: 0, pointerPosition: nil)
        }

        @discardableResult public func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32) -> Bool {
            sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: nil)
        }

        /// Default: no shared selection to read, so callers fall back to `copySelectionToPasteboard()`
        /// immediately. Only `RemoteGhosttySessionHost` overrides this with the real `readSelectionText`
        /// round trip; every other conformer (test fakes included) reports nothing shared to find.
        public func copySharedSelectionToPasteboard(completion: @escaping @MainActor (Bool) -> Void) { completion(false) }
    }

    /// The daemon-side embedded renderer host, run on the terminal engine actor. It deliberately does
    /// NOT conform to the app-facing `TerminalGhosttyRendererHosting` protocol (which stays `@MainActor`
    /// for `RemoteGhosttySessionHost` and the app UI): the daemon drives it through concrete methods, so
    /// the window-focus / `NSEvent` key-handling members that existed only to satisfy that protocol are
    /// gone (those are the app's responsibility and cannot run on the engine actor).
    @TerminalEngineActor public final class GhosttyHeadlessRendererHost {
        private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
        private let clearScreenAndScrollbackAction: @TerminalEngineActor () -> Bool
        private var isOwnerClient: (@TerminalEngineActor (String) -> Bool)?
        private var inputActivityHandler: (@TerminalEngineActor (Int) -> Void)?

        init(sessionDriver: GhosttyEmbeddedTerminalSessionDriver, clearScreenAndScrollbackAction: @escaping @TerminalEngineActor () -> Bool) {
            self.sessionDriver = sessionDriver
            self.clearScreenAndScrollbackAction = clearScreenAndScrollbackAction
        }

        func setOwnerClientResolver(_ resolver: @escaping @TerminalEngineActor (String) -> Bool) { isOwnerClient = resolver }

        func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { sessionDriver.setOutputHandler(handler) }

        func setInputActivityHandler(_ handler: (@TerminalEngineActor (Int) -> Void)?) { inputActivityHandler = handler }

        func startSessionIfNeeded() throws { try sessionDriver.startIfNeeded() }

        public func requestSurfaceRefresh() { sessionDriver.requestSurfaceRefresh() }

        public func prepareRenderStateExport() {
            sessionDriver.requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
        }

        /// Owner input activity is recorded before the delivery it describes, matching how the scroll and
        /// mouse-button paths record theirs. The event marks the host taking delivery of the input, and the
        /// mac latency gate anchors its total there, so recording it after the write would leave ghostty's
        /// key encoding and the PTY write inside neither end of the gate and hide a regression in them.
        /// Everything the record schedules is deferred (a coalesced broadcast, an output-gate window), so
        /// nothing it triggers can observe the terminal before this write lands.
        ///
        /// Accepted risk: when the E2E performance log is enabled, recording the event appends a line to
        /// that log synchronously, so its cost lands between the timestamp and this write and counts
        /// inside the gated latency total. The same is already true at the far end, where the export
        /// event is written before the frame is handed to the client, so a log-based harness cannot
        /// place instrumentation outside its own gate. The cost is bounded: an append of one record
        /// measures 30us at p50 and 207us at the worst of 5000, against a gate measuring 4.9ms p95
        /// with a 15ms budget. Deferring the write would mean carrying a timestamp through product
        /// code for measurement alone, which buys less than the noise it removes.
        /// The host-PTY writes these bytes produced, or nil when the session has been torn down and there
        /// was nowhere to write them. The submit path awaits the batch so its send answers for the bytes;
        /// interactive input uses the `Bool` form below and keeps the enqueue contract.
        func sendRawBytesAwaitingEmission(_ data: Data) -> TerminalInputWriteBatch? {
            inputActivityHandler?(data.count)
            return sessionDriver.sendRawBytesAwaitingEmission(data)
        }

        /// Reports whether the bytes reached the session (see the driver): a send whose session has been
        /// torn down fails rather than silently writing nowhere.
        @discardableResult func sendRawBytes(_ data: Data) -> Bool {
            inputActivityHandler?(data.count)
            return sessionDriver.sendRawBytes(data)
        }

        /// Sends a named key press, letting ghostty encode it against the live terminal state. The
        /// encoded length is not observable from here, so owner input activity counts the press itself.
        @discardableResult func sendKey(_ spec: TerminalKeySpec) -> Bool {
            inputActivityHandler?(1)
            return GhosttyEmbeddedKeyEvent.withKeyEvent(for: spec) { sessionDriver.sendKey($0) }
        }

        @discardableResult public func sendTextAsPaste(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            inputActivityHandler?(text.utf8.count)
            return sessionDriver.sendTextAsPaste(text)
        }

        /// Writes `text` through ghostty's paste encoder and reports, from inside that same engine-isolated
        /// step, whether it went out framed by bracketed-paste markers. Ghostty derives the framing from
        /// live terminal state at write time, so the mode is read here — immediately before the write, with
        /// no tick in between — rather than by the caller before the write is even enqueued. That is as
        /// close to "decision and encoding at one instant" as the embedded API allows, and it is what the
        /// submit path paces its carriage return against.
        func sendSubmitTextAsPaste(_ text: String) -> GhosttySubmitTextWrite {
            guard !text.isEmpty else { return .notDelivered }
            let framed = sessionDriver.bracketedPasteActive()
            inputActivityHandler?(text.utf8.count)
            guard let writes = sessionDriver.sendTextAsPasteAwaitingEmission(text) else { return .notDelivered }
            return .written(framed: framed, writes: writes)
        }

        func bracketedPasteActive() -> Bool { sessionDriver.bracketedPasteActive() }

        func foregroundPID() -> Int32? { sessionDriver.foregroundPID() }

        func childPID() -> Int32? { sessionDriver.childPID() }

        func surfaceCellSize() -> (columns: Int, rows: Int)? { sessionDriver.surfaceCellSize() }

        @discardableResult func resizeCellGrid(columns: Int, rows: Int) -> Bool { sessionDriver.resizeCellGrid(columns: columns, rows: rows) }

        func terminateSession() { sessionDriver.terminate() }

        /// Flush accepted-but-unwritten input toward the PTY master before an exec handoff; see
        /// `GhosttyEmbeddedTerminalSessionDriver.drainPendingInputWrites`.
        func drainPendingInputWrites() async { await sessionDriver.drainPendingInputWrites() }

        func setSurfaceFocused(_ focused: Bool) { sessionDriver.setFocused(focused) }

        public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
            _ = client
            _ = mode
            _ = container
            try startSessionIfNeeded()
        }

        public func releaseRendererSurface() {}

        public func setFocused(_ focused: Bool, for clientID: String) { sessionDriver.setFocused(isOwnerClient?(clientID) == true && focused) }

        public func hasRenderableSurface() -> Bool { sessionDriver.snapshot() != nil }

        public func snapshot() -> GhosttyTerminalSnapshot? { sessionDriver.snapshot() }

        public func snapshotText() -> String? { sessionDriver.snapshotText() }

        public func sessionSnapshot() -> GhosttyTerminalSnapshot? { sessionDriver.snapshot() }

        func sessionRenderStateSnapshot() -> GhosttyTerminalSnapshotCapture.CapturedSnapshot? { sessionDriver.renderStateSnapshot() }

        public func sessionSnapshotText() -> String? { sessionDriver.snapshotText() }

        public func copySelectionToPasteboard() -> Bool { false }

        public func pasteClipboardContents() -> Bool {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
            return sendTextAsPaste(text)
        }

        @discardableResult public func performBindingAction(_ action: String) -> Bool {
            if action == "clear_screen" { return clearScreenAndScrollback() }
            return sessionDriver.performBindingAction(action)
        }

        @discardableResult public func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?
        ) -> Bool { sessionDriver.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition) }

        @discardableResult public func sendMouseButton(button: UInt8, pressed: Bool, pointerPosition: TerminalScrollPointerPosition?) -> Bool {
            sessionDriver.sendMouseButton(button: button, pressed: pressed, pointerPosition: pointerPosition)
        }

        @discardableResult public func clearScreenAndScrollback() -> Bool { clearScreenAndScrollbackAction() }

        @discardableResult public func setSelectionAbsolute(startColumn: UInt16, startRow: UInt32, endColumn: UInt16, endRow: UInt32, rectangle: Bool)
            -> Bool
        {
            sessionDriver.setSelectionAbsolute(
                startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow, rectangle: rectangle)
        }

        public func clearSelection() { sessionDriver.clearSelection() }

        public func readSelectionText() -> String? { sessionDriver.readSelectionText() }

        public var debugSearchState: GhosttyTerminalSearchDebugState { .init(isVisible: false, query: "", total: nil, selected: nil) }

        public var debugSurfaceRefreshRequestCount: Int { sessionDriver.debugRefreshRequestCount }

        public func debugVisibleSurfaceText() -> String? { sessionDriver.snapshotText() }

        public func debugSurfaceSelectionText() -> String? { sessionDriver.readSelectionText() }
    }

    @TerminalEngineActor public final class GhosttyEmbeddedSessionCore {
        private static let incomingOutputCoalescingInterval: Duration = .milliseconds(4)
        private static let interactiveInputFlushWindowNanoseconds: UInt64 = 750_000_000
        private static let interactiveInputMaximumByteCount = 128

        private final class IncomingOutputBuffer: @unchecked Sendable {
            enum FlushSchedule: Sendable, Equatable {
                case none
                case delayed
                case immediate
            }

            struct DrainedOutput: Sendable {
                let data: Data
                let isInteractive: Bool
            }

            private let lock = NSLock()
            private var pendingData = Data()
            private var flushScheduled = false
            private var immediateFlushScheduled = false
            private var pendingInteractiveOutput = false

            func append(_ data: Data, interactive: Bool) -> FlushSchedule {
                guard !data.isEmpty else { return .none }
                lock.lock()
                defer { lock.unlock() }
                pendingData.append(data)
                pendingInteractiveOutput = pendingInteractiveOutput || interactive
                if flushScheduled {
                    guard interactive, !immediateFlushScheduled else { return .none }
                    immediateFlushScheduled = true
                    return .immediate
                }
                flushScheduled = true
                immediateFlushScheduled = interactive
                return interactive ? .immediate : .delayed
            }

            func drain() -> DrainedOutput {
                lock.lock()
                defer { lock.unlock() }
                let drained = pendingData
                let isInteractive = pendingInteractiveOutput
                pendingData = Data()
                flushScheduled = false
                immediateFlushScheduled = false
                pendingInteractiveOutput = false
                return DrainedOutput(data: drained, isInteractive: isInteractive)
            }
        }

        private final class InteractiveOutputGate: @unchecked Sendable {
            private let lock = NSLock()
            private var deadlineUptimeNanoseconds: UInt64?

            func markActivity(now: UInt64 = DispatchTime.now().uptimeNanoseconds, windowNanoseconds: UInt64) {
                lock.lock()
                deadlineUptimeNanoseconds = now &+ windowNanoseconds
                lock.unlock()
            }

            func consumeIfActive(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard let deadline = deadlineUptimeNanoseconds, now <= deadline else {
                    deadlineUptimeNanoseconds = nil
                    return false
                }
                deadlineUptimeNanoseconds = nil
                return true
            }
        }

        private enum RenderStateExportMode {
            case selfContained
            case streamDeltaAllowed
        }

        public let launchConfiguration: TerminalSessionLaunchConfiguration
        public let paths: TerminalSessionPaths

        private let controlQueue: DispatchQueue
        private let stateStreamQueue: DispatchQueue
        /// Serial background executor for this core's durable SQLite writes. Every mutation the engine used to
        /// perform synchronously on its critical path — per-request client lease touches, the runtime-state
        /// timer's persist, stale-client expiry detaches, the final terminated payload — is enqueued here
        /// instead. SQLite runs in WAL mode with a 5s busy timeout: a competing writer (e.g. an agent hook's
        /// `spaces agent signal` burst) makes any WRITE block on the write lock up to that timeout, which on
        /// the engine executor froze all terminal I/O; WAL READS never block on a writer, so reads stay inline
        /// on the engine. Writes commit in enqueue order (serial queue); the DB is a durable mirror that
        /// converges while the engine's in-memory state (`latestRuntimeState`, `cachedAttachmentSnapshot`)
        /// stays authoritative for reads and broadcasts. Handoff drains this queue before `execv` so the staged
        /// daemon reads a complete mirror; termination enqueues its final writes last so FIFO ordering lands
        /// the terminated payload after every pending mirror write.
        private let persistence: TerminalCorePersistenceQueue
        /// Orders every control-request input write (send text/bytes/paste, key) for this session so a
        /// submit's pasted text and its carriage return stay an adjacent pair; see
        /// `TerminalControlInputSequencer`.
        private let controlInputSequencer = TerminalControlInputSequencer()
        private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
        private lazy var rendererHostStorage = GhosttyHeadlessRendererHost(
            sessionDriver: sessionDriver, clearScreenAndScrollbackAction: { [weak self] in self?.clearScreenAndScrollback() ?? false })
        private let requestSurfaceRefreshAction: @TerminalEngineActor () -> Void
        /// Per-session 1s runtime-state timer. A `DispatchSourceTimer` on the engine queue replaces the
        /// old `Timer`/`RunLoop.main` pairing — the engine actor's queue has no run loop.
        private var runtimeStateTimer: DispatchSourceTimer?
        private var controlServer: TerminalControlServer?
        private var stateStreamServer: GhosttyRemoteSessionStateStreamServer?
        private var outputHandle: FileHandle?
        /// Bounds `output.log` for this session, running the expensive preamble replay off the engine so a
        /// trim cannot stall other sessions' terminal I/O. See `TerminalTranscriptTrimCoordinator`.
        private lazy var transcriptTrim = TerminalTranscriptTrimCoordinator(
            outputPath: paths.outputPath,
            liveTranscriptEndOffset: { [weak self] in
                guard let self, let outputHandle else { return nil }
                return try? outputHandle.seekToEnd()
            },
            // The committed end offset is discarded: this core re-derives the transcript's end from the
            // handle on every append (`seekToEnd`) rather than tracking a byte count, so the adopted
            // handle's position is the only state that has to change.
            adoptTrimmedTranscript: { [weak self] handle, _ in
                guard let self else { return }
                // The trim replaced output.log with a fresh inode; adopt its handle before closing the old
                // one so the stored property always holds a valid handle even if the close fails.
                let previousHandle = outputHandle
                outputHandle = handle
                try? previousHandle?.close()
            })
        private var started = false
        private var didTerminateCurrentRun = false
        private var currentTitle: String?
        private var currentWorkingDirectory: String?
        /// When the running program last rang the bell, coalesced by `bellCoalescer`.
        private var currentBellAt: String?
        var bellCoalescer = TerminalBellCoalescer()
        private var lastObservedProcessWorkingDirectory: String?
        private var lastKnownChildPID: Int32?
        private var lastKnownSurfaceSize: (columns: Int, rows: Int)?
        /// The grid of the latest accepted resize request whose forced-full frame has not gone out yet; see
        /// `handleTerminalGridReflow`.
        private var pendingResizeBroadcastGrid: (columns: Int, rows: Int)?
        private var lastSessionStateRevision: UInt64?
        private var lastSessionStateFlags: GhosttyEmbeddedSessionStateChange.Flags?
        private var lastScreenStateRevision: UInt64?
        private var lastExportedScreenStateRevision: UInt64?
        private var lastRenderUpdateBaseline: GhosttyRenderUpdateBaseline?
        private var renderUpdateRevision: UInt64 = 0
        private var forceNextBroadcastFullRenderUpdate = false
        /// Scroll rects a `.selfContained` export drained from Ghostty but could not ship (a self-contained
        /// export always forces a full frame, and a full frame never carries rects). See
        /// `TerminalStreamScrollRectCarry` for why this exists; folded/drained in `makeRenderUpdate`.
        private var streamScrollRectCarry = TerminalStreamScrollRectCarry()
        /// Live in-memory runtime state — the AUTHORITATIVE source broadcasts serve, advanced the moment a
        /// new state is computed regardless of whether it reaches disk. Kept distinct from
        /// `lastPersistedRuntimeState` so the invariant holds under a failed persist: broadcasts always show
        /// live truth here, while the durable mirror converges via retry (see `refreshRuntimeState`).
        private var latestRuntimeState: TerminalSessionRuntimeState?
        /// Durable persist marker — mirrors what was last SUCCESSFULLY written to disk. Advanced only on a
        /// successful write so `shouldPersistRuntimeState` retries after a failure rather than being
        /// suppressed by a stale success marker. Not the broadcast source (that is
        /// `latestRuntimeState`); this exists to drive persistence/retry decisions.
        private var lastPersistedRuntimeState: TerminalSessionRuntimeState?
        private var sessionStartedAt: Date?
        private var foregroundPIDOverrideForTesting: Int32?
        private var foregroundProcessResolver: (Int32) -> TerminalForegroundProcessSnapshot? = { TerminalForegroundProcessInspector.inspect(pid: $0) }
        private var didLogFirstOutput = false
        private let incomingOutputBuffer = IncomingOutputBuffer()
        private let inputStateBroadcastCoalescer = TerminalEngineNextTurnCoalescer()
        private let screenStateChangeBroadcastCoalescer = TerminalEngineNextTurnCoalescer()
        private var pendingScreenStateChangeBroadcastRevision: UInt64?
        private lazy var inputOutputResyncScheduler = GhosttyInputOutputResyncScheduler { [weak self] in
            guard let self else { return }
            self.requestSurfaceRefreshAction()
            GhosttyEmbeddedAppService.shared.tick()
            self.broadcastCurrentState(reason: TerminalRemoteSessionStateReason.inputOutput)
        }
        private let interactiveOutputGate = InteractiveOutputGate()
        /// This session's attachment snapshot (`terminal_clients` + `terminal_attachments`) held in memory:
        /// the AUTHORITY for every enforcement and broadcast read, not a cache of the database in front of it.
        /// Seeded from the durable rows on first read, then advanced in place by each mutation this core makes
        /// (`applyAttach`, `applyDetach`, `applyOwnershipTransfer`, `applyClientUpsert`,
        /// `markClientsExpiredInCache`, `markAllAttachmentsDetachedInCache`, `recordClientLeaseTouchInCache`),
        /// each of which enqueues its durable mirror write onto the per-core persistence queue rather than
        /// writing on the engine executor.
        ///
        /// The DB is the mirror, so it necessarily lags: a write blocked on SQLite's write lock commits up to
        /// the 5s busy timeout later, and performing it on the engine would freeze PTY output and control for
        /// every live session in the daemon for that long. Enforcement therefore reads this snapshot —
        /// `isOwner`, `activeOwnerClientID`, `hasActiveAttachments`, `activeLocalWindowClientID`, and the
        /// attach/detach mode-change pre-checks all resolve through
        /// `currentActiveAttachments()`/`currentAttachmentSnapshot()`. Reading the not-yet-committed DB instead
        /// would `.ownershipRejected` the very client the broadcast just told owns the terminal, silently
        /// dropping its keystrokes.
        ///
        /// It is dropped (`invalidateAttachmentSnapshotCache`) only to RECONCILE: a lifecycle mirror write that
        /// exhausted its retries, an expiry transaction that rolled back, or one reported `.superseded`. In each
        /// case memory asserts something durable state does not, so the next read reseeds from committed truth.
        ///
        /// A reseed can still read stale rows even when nothing invalidated the cache: a mutation applied while
        /// the cache was empty (see `pendingAttachmentMutations`) has its durable write enqueued but not yet
        /// committed, and a concurrent reseed can read the database before that write lands. `mutateAttachmentSnapshot`
        /// and `currentAttachmentSnapshot()` hold and replay such mutations rather than losing them; see
        /// `pendingAttachmentMutations`.
        ///
        /// SINGLE-WRITER INVARIANT: the live in-process session core is the sole writer of a live session's
        /// attachment/client rows, which is what lets memory lead the mirror. Every attach, detach,
        /// heartbeat-lease touch, ownership transfer, and stale-client expiry routes through this core's
        /// control handlers. The only writers OUTSIDE a core — `SpacesdMain.recoverStaleSessions` and
        /// `Orchestrator.markReservedWorkspaceTerminalLaunchFailed` — act exclusively on sessions with NO live
        /// core (crashed-prior-daemon sessions, never-started reservations), so they can never race one. A
        /// fresh core (daemon restart, exec-in-place handoff) reseeds from the mirror.
        private var cachedAttachmentSnapshot: TerminalSessionAttachmentSnapshot? { didSet { cachedLiveWireAttachmentSnapshot = nil } }
        /// `cachedAttachmentSnapshot` reduced to what a subscriber is sent, memoized so a session's attach
        /// history is scanned once per attachment change instead of once per broadcast. The broadcast path
        /// runs on the shared `TerminalEngineActor`, where the scan would otherwise grow with the session's
        /// lifetime attach count on every output tick — the very growth this projection exists to keep off
        /// the wire. Invalidated by `cachedAttachmentSnapshot`'s `didSet` rather than by each of its writers,
        /// so no mutation path can forget to.
        private var cachedLiveWireAttachmentSnapshot: TerminalSessionAttachmentSnapshot?

        /// Attachment-mutation transforms acknowledged to a caller while no base snapshot was available to
        /// apply them to (cache empty AND the reseeding disk read also failed). The caller's durable mirror
        /// write is enqueued regardless of whether the transform could be applied here, so the mutation is
        /// held rather than dropped: `currentAttachmentSnapshot()` replays these, in order, on top of the next
        /// successful reseed, which reconstructs the acknowledged state even if that reseed's read predates the
        /// still-queued write. INVARIANT: a non-nil `cachedAttachmentSnapshot` implies this is empty — entries
        /// accumulate only while every reseed fails, and are drained together the moment one succeeds.
        private var pendingAttachmentMutations: [(TerminalSessionAttachmentSnapshot) -> TerminalSessionAttachmentSnapshot] = []
        /// Test-only: when set, `currentAttachmentSnapshot()` treats its reseeding disk read as failed without
        /// touching the database, so a test can exercise the `pendingAttachmentMutations` path deterministically.
        /// See `debugSetForceAttachmentSnapshotReseedFailureForTesting`.
        private var forceAttachmentSnapshotReseedFailureForTesting = false
        /// Last heartbeat instant per remote client, recorded synchronously on the engine the moment a
        /// heartbeat lands — independent of when its coalesced durable lease write commits and of the
        /// attachment-snapshot cache's invalidation lifecycle. `expireStaleRemoteClientsIfNeeded` consults
        /// this so a client that just heartbeated is never expired off a stale DB lease read whose durable
        /// touch has not yet committed under write contention (see that method).
        private var latestRemoteClientHeartbeat: [String: Date] = [:]
        /// Per-client heartbeat generation, bumped synchronously on the engine each time a heartbeat/lease touch
        /// is accepted (independent of when its coalesced durable touch commits). A queued stale-client expiry
        /// captures each candidate's generation at decision time and, inside its write transaction, skips
        /// detaching any candidate whose generation advanced — vetoing the detach of a client that heartbeated
        /// while the expiry's durable write was stuck FIFO-behind that heartbeat's own touch. Lock-guarded so the
        /// persistence-queue thread can read it from inside `expireClients` (see `TerminalClientHeartbeatGenerationGate`).
        private let heartbeatGenerationGate = TerminalClientHeartbeatGenerationGate()
        /// Rate-limits the durable half of the lease touches above (see `TerminalClientLeaseTouchCoalescer`),
        /// so a stream of keystrokes costs one lease write per coalescing interval instead of one per
        /// keystroke. Reset for a client wherever this core rewrites that client's durable row — attach,
        /// detach, stale expiry — and wholesale on termination, so no attachment inherits the previous
        /// attachment's write record.
        private var leaseTouchCoalescer = TerminalClientLeaseTouchCoalescer()
        /// Remote clients whose expiry (detach, and possibly ownership transfer) has already been enqueued
        /// but whose durable detach has not yet committed. Skipped on subsequent timer ticks so a burst of
        /// ticks cannot enqueue duplicate detach/transfer writes — or bump `ownerEpoch` repeatedly — for the
        /// same not-yet-committed expiry decision. Pruned to the current DB stale-candidate set each tick, so
        /// a client that reconnects (fresh lease) or whose detach has committed becomes expirable again.
        private var expiredRemoteClientIDs: Set<String> = []
        private var ownerEpoch: UInt64 = 0
        /// Set for the brief exec-in-place quiesce window so no late timer/coalescer
        /// turn broadcasts a frame while the session is being handed to the staged
        /// daemon. Cleared on resume (`resumeFromHandoff`) or on the failed-exec
        /// fallback (`resumeInPlaceAfterFailedExec`).
        private var suppressBroadcastsForHandoff = false
        /// Byte offset where renderer-disconnected output begins. On failed handoff the
        /// persisted suffix is streamed back into the existing renderer without being
        /// appended to the transcript again.
        private var handoffTranscriptReplayOffset: UInt64?
        private var lastResizeSerialByClientID: [String: UInt64] = [:]
        private let onSessionClosed: (@TerminalEngineActor (GhosttyEmbeddedSessionCore) -> Void)?

        public init(
            launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
            requestSurfaceRefreshAction: (@TerminalEngineActor () -> Void)? = nil,
            onSessionClosed: (@TerminalEngineActor (GhosttyEmbeddedSessionCore) -> Void)? = nil
        ) {
            self.launchConfiguration = launchConfiguration
            self.paths = paths
            self.onSessionClosed = onSessionClosed
            controlQueue = DispatchQueue(label: "spaces.terminal.session-host.control.\(launchConfiguration.sessionID)")
            stateStreamQueue = DispatchQueue(label: "spaces.terminal.session-host.state-stream.\(launchConfiguration.sessionID)")
            persistence = TerminalCorePersistenceQueue(label: "spaces.terminal.session-host.persistence.\(launchConfiguration.sessionID)")
            sessionDriver = GhosttyEmbeddedTerminalSessionDriver(launchConfiguration: launchConfiguration)
            self.requestSurfaceRefreshAction = requestSurfaceRefreshAction ?? { [sessionDriver] in sessionDriver.requestSurfaceRefresh() }
            sessionDriver.onActionEvent = { [weak self] event in self?.applyActionEvent(event) }
            sessionDriver.onClipboardWrite = { [weak self] text in self?.forwardClipboardWriteToOwner(text) }
            sessionDriver.onSessionStateChanged = { [weak self] change in self?.applySessionStateChange(change) }
            sessionDriver.onSurfaceCellSizeChanged = { [weak self] columns, rows in
                guard let self else { return }
                self.lastKnownSurfaceSize = (columns, rows)
                self.refreshRuntimeState(force: true)
            }
            sessionDriver.onTerminalGridReflowed = { [weak self] columns, rows in self?.handleTerminalGridReflow(columns: columns, rows: rows) }
            rendererHostStorage.setOwnerClientResolver { [weak self] clientID in self?.isOwner(clientID: clientID) ?? false }
            rendererHostStorage.setInputActivityHandler { [weak self] byteCount in self?.handleOwnerInputActivity(byteCount: byteCount) }
            sessionDriver.onSurfaceClosed = { [weak self] in self?.handleSessionClosed() }
        }

        public func startIfNeeded() throws {
            guard !started else { return }
            let startedAt = Date()
            do {
                try paths.ensureDirectories()
                enqueueLaunchConfigurationWrite(clearingPreviousRunRuntimeState: true)
                try ensureOutputHandle()
                rendererHostStorage.setOutputHandler { [weak self] data in self?.enqueueIncomingOutput(data) }
                rendererHostStorage.setInputActivityHandler { [weak self] byteCount in self?.handleOwnerInputActivity(byteCount: byteCount) }
                didTerminateCurrentRun = false
                started = true
                try rendererHostStorage.startSessionIfNeeded()
                guard started, !didTerminateCurrentRun else { return }
                try startControlServer()
                try startStateStreamServer()
                startRuntimeStateTimer()
                refreshRuntimeState(force: true)
                sessionStartedAt = startedAt
                didLogFirstOutput = false
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
                TerminalPerformance.logMetric(
                    "terminal_session_start", target: "session=\(launchConfiguration.sessionID) backend=\(launchConfiguration.backend.rawValue)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_session_start", target: "session=\(launchConfiguration.sessionID) backend=\(launchConfiguration.backend.rawValue)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                started = false
                throw error
            }
        }

        public func attachClient(_ client: TerminalClient, mode: TerminalAttachmentMode) throws {
            try startIfNeeded()
            let activeAttachments = currentActiveAttachments()
            let currentAttachment = activeAttachments.first { $0.clientID == client.id }
            let previousOwnerClientID = activeAttachments.first { $0.mode == .owner }?.clientID
            if currentAttachment?.mode != mode {
                applyAttach(client: client, mode: mode, attachedAt: TerminalSessionTimestamp.string(from: Date()))
                leaseTouchCoalescer.forget(clientID: client.id)
                if mode == .owner, previousOwnerClientID != client.id { advanceOwnerEpoch(reason: "attach") }
                postAttachmentStateDidChange()
            }
            refreshRuntimeState(force: true)
        }

        public func detach(clientID: String) throws {
            let detachedClientWasOwner = isOwner(clientID: clientID)
            applyDetach(clientID: clientID, detachedAt: TerminalSessionTimestamp.string(from: Date()))
            // The detach rewrote this client's durable row, so its coalesced-write record no longer describes
            // anything: were the same client to re-attach, the first touch of the new attachment must write.
            leaseTouchCoalescer.forget(clientID: clientID)
            // Derive the ownership successor from the in-memory snapshot the detach was just applied to
            // (enforcement's source) — NOT by reseeding from the durable mirror, whose matching detach is
            // enqueued and not yet committed. `activeLocalWindowClientID(excluding:)` reads the same snapshot.
            var remainingOwnerClientID = currentActiveAttachments().first(where: { $0.mode == .owner })?.clientID
            if detachedClientWasOwner, remainingOwnerClientID == nil, let localOwnerClientID = activeLocalWindowClientID(excluding: clientID) {
                applyOwnershipTransfer(to: localOwnerClientID, transferredAt: TerminalSessionTimestamp.string(from: Date()))
                remainingOwnerClientID = localOwnerClientID
                advanceOwnerEpoch(reason: "detach_transfer")
            }
            if Self.shouldClearFocusAfterDetachingClient(
                detachedClientWasOwner: detachedClientWasOwner, remainingOwnerClientID: remainingOwnerClientID)
            {
                rendererHostStorage.setSurfaceFocused(false)
            }
            if remainingOwnerClientID == nil, rendererHostStorage.hasRenderableSurface() { rendererHostStorage.releaseRendererSurface() }
            postAttachmentStateDidChange()
            refreshRuntimeState(force: true)
        }

        public func isOwner(clientID: String) -> Bool {
            guard isRuntimeInteractiveForControl() else { return false }
            return currentActiveAttachments().contains { $0.clientID == clientID && $0.mode == .owner }
        }

        public func activeOwnerClientID() -> String? {
            guard isRuntimeInteractiveForControl() else { return nil }
            return currentActiveAttachments().first(where: { $0.mode == .owner })?.clientID
        }

        private func hasActiveAttachments() -> Bool { !currentActiveAttachments().isEmpty }

        /// Whether the in-memory attachment authority (`currentAttachmentSnapshot()`) currently has any live
        /// attachment, per `TerminalSessionAttachmentSnapshot.liveAttachments` (active AND lease-fresh for the
        /// client kinds a lease governs). The daemon's `.whileAttached` reaper calls this instead of reading
        /// the durable mirror: this core is the single writer of its own attachment rows, so memory is always
        /// at least as current as the database, and a DB read can observe an attach whose durable mirror is
        /// still queued behind a contended write lock as "no attachment" and reap a session with a live owner.
        ///
        /// A nil snapshot means the cache was empty AND the reseeding disk read failed (see
        /// `currentAttachmentSnapshot`), i.e. attachment state is genuinely unknown. Answering `true` in that
        /// case preserves the old DB-reading reaper's `try?` guard, which skipped the session on a failed read
        /// rather than treating a read failure as grounds to reap it.
        public func hasLiveAttachments(now: Date = Date()) -> Bool {
            guard let snapshot = currentAttachmentSnapshot() else { return true }
            return !snapshot.liveAttachments(now: now).isEmpty
        }

        /// Whether the in-memory attachment authority (`currentAttachmentSnapshot()`) currently has a live
        /// owner-mode attachment, per `TerminalSessionAttachmentSnapshot.liveAttachments`. The close-time ad-hoc
        /// stop decision calls this through the daemon's prober instead of reading the durable mirror, because
        /// the closing client's detach is applied to this snapshot before its durable mirror commits: a
        /// durable read taken right after that detach can still see the just-detached owner and wrongly keep a
        /// session the user closed.
        ///
        /// A nil snapshot means the cache was empty AND the reseeding disk read failed (see
        /// `currentAttachmentSnapshot`), i.e. attachment state is genuinely unknown. Answering `true` in that
        /// case fails closed, the same way `hasLiveAttachments` does: this answer gates a termination, and a
        /// wrongful stop destroys a terminal the user cannot get back.
        public func hasLiveOwnerAttachment(now: Date = Date()) -> Bool {
            guard let snapshot = currentAttachmentSnapshot() else { return true }
            return snapshot.liveAttachments(now: now).contains { $0.mode == .owner }
        }

        private func activeLocalWindowClientID(excluding excludedClientID: String) -> String? {
            guard let snapshot = currentAttachmentSnapshot() else { return nil }
            let clientsByID = Dictionary(uniqueKeysWithValues: snapshot.clients.map { ($0.id, $0) })
            return snapshot.attachments.filter { $0.detachedAt == nil && $0.clientID != excludedClientID }.compactMap {
                attachment -> TerminalClient? in
                guard let client = clientsByID[attachment.clientID], client.kind == .localWindow, client.disconnectedAt == nil else { return nil }
                return client
            }.first?.id
        }

        public var rendererHost: GhosttyHeadlessRendererHost { rendererHostStorage }
        var isStarted: Bool { started }

        public func terminate() {
            let now = TerminalSessionTimestamp.string(from: Date())
            let childPID = observedChildPID()
            runtimeStateTimer?.cancel()
            runtimeStateTimer = nil
            inputOutputResyncScheduler.cancelForTermination()
            controlServer?.stop()
            controlServer = nil
            TerminalControlServer.removeSocketFileIfPresent(at: paths.controlSocketPath)
            // Flush any output still buffered for the coalesced write before blocking further appends
            // below. A command that produces output and exits immediately (e.g. `seq 1 300`) leaves its
            // final bytes in `incomingOutputBuffer` pending the delayed flush; that flush's `appendOutput`
            // would then be dropped by the `didTerminateCurrentRun` guard, leaving `output.log` empty even
            // though the surface rendered the output. The ended-session scrollback replay reads `output.log`,
            // so without this flush a self-exiting command has no transcript to scroll back through.
            flushPendingIncomingOutputForStateExport()
            didTerminateCurrentRun = true
            started = false
            let exitedState = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: childPID,
                state: .exited, updatedAt: now, exitedAt: now, title: currentTitle, workingDirectory: effectiveWorkingDirectory,
                columns: lastKnownSurfaceSize?.columns, rows: lastKnownSurfaceSize?.rows, bellAt: currentBellAt)
            // All three terminal writes are enqueued (not written inline) so teardown never blocks the engine
            // on the DB lock; FIFO ordering on the serial persistence queue lands them after every pending
            // mirror write and in this order: exited runtime state, detach-all, terminated payload. They
            // complete asynchronously and survive this core's release (the closures capture only `paths` and
            // value types), so the durable mirror converges even if the core is dropped right after.
            persistExitedRuntimeState(exitedState)
            let detachPaths = paths
            enqueuePersistenceWrite { databasePath in
                try? TerminalSessionPersistence.detachActiveClients(paths: detachPaths, detachedAt: now, databasePath: databasePath)
            }
            // Every client's durable row is being detached, so no coalesced-write record survives this run:
            // a relaunch of this core re-attaches from scratch and its first touch per client must write.
            leaseTouchCoalescer.forgetAll()
            // Reflect the detach in memory (NOT by re-reading the not-yet-committed durable mirror) so the
            // terminated payload, built from `currentAttachmentSnapshot`, advertises no active owner —
            // matching the enqueued durable detach above.
            markAllAttachmentsDetachedInCache(detachedAt: now)
            let finalPayload = currentRemoteSessionState(reason: TerminalRemoteSessionStateReason.terminated, outputByteCount: nil)
            if let finalPayload {
                let payloadPaths = paths
                enqueuePersistenceWrite { databasePath in
                    try? TerminalSessionPersistence.writeRemoteSessionState(finalPayload, paths: payloadPaths, databasePath: databasePath)
                }
                broadcastRemoteStatePayload(finalPayload, startedAt: Date(), ownerClient: nil, outputByteCount: nil)
            }
            // Termination fence: the exited-state, detach-all, and terminated-payload writes are enqueued
            // above; FIFO on the serial persistence queue lands them in order and after every pending mirror
            // write. The durable-end notifications must fire only once those have committed (so a DB-reading
            // consumer like the overview observes the end state), but blocking the engine on that commit
            // could stall the single engine executor — and thus every live session — for seconds under DB
            // write contention (SQLite's 5s busy timeout). So instead of a blocking drain we enqueue one
            // trailing closure that, by FIFO, runs after the three writes commit and hops back to the engine
            // to post the notifications (persistence closures return to the engine only via async Task). It
            // captures only the session id (a value type), so it survives this core's release.
            let terminatedSessionID = launchConfiguration.sessionID
            persistence.enqueueOrderedWork {
                Task { @TerminalEngineActor in
                    TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: terminatedSessionID)
                    TerminalSessionNotification.post(.spacesTerminalAttachmentStateDidChange, sessionID: terminatedSessionID)
                    TerminalOverviewSignal.post()
                }
            }
            rendererHostStorage.terminateSession()
            try? outputHandle?.synchronize()
            try? outputHandle?.close()
            outputHandle = nil
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)
        }

        private func persistExitedRuntimeState(_ state: TerminalSessionRuntimeState) {
            latestRuntimeState = state
            enqueueRuntimeStateWrite(state, at: Date())
        }

        // MARK: - Off-engine durable persistence

        /// Enqueue a durable write with no coalescing (unique mutations: expiry detaches, ownership transfer,
        /// the terminated payload). Runs on the serial persistence queue in enqueue (FIFO) order.
        private func enqueuePersistenceWrite(_ write: @escaping @Sendable (String) -> Void) { persistence.enqueueWrite(write) }

        /// Enqueue a latest-wins coalesced durable write for `key`: only the newest enqueue runs; a burst
        /// collapses to one write of the newest value. FIFO order across keys.
        private func enqueueCoalescedPersistenceWrite(key: String, _ write: @escaping @Sendable (String) -> Void) {
            persistence.enqueueCoalescedWrite(key: key, write)
        }

        /// Blocks the caller until every write enqueued so far has committed. Deadlock-free from the engine:
        /// persistence closures only ever hop BACK to the engine asynchronously (`Task { @TerminalEngineActor }`),
        /// never with a synchronous wait, so a blocked engine cannot cycle with the queue. Used only for the
        /// handoff/termination fences and test determinism — never on the per-keystroke path.
        private func drainPersistenceQueue() { persistence.drain() }

        /// Async drain for the handoff quiesce path: suspends (rather than blocking the engine) until the
        /// persistence queue is empty, so every mirror write is durable before the caller `execv`s.
        private func drainPersistenceQueueAsync() async { await persistence.drainAsync() }

        /// Awaitable drain used by daemon shutdown and the nil-quiesce handoff branch after `terminate()`.
        /// `terminate()` only ENQUEUES the exited runtime-state write, detach-all, terminated payload, and the
        /// trailing durable-end notification onto this serial queue; shutdown's `exit(0)` and the handoff's
        /// `execv` both destroy anything still queued. SpacesdMain awaits this after terminating a core so
        /// those writes commit first — otherwise a session's durable runtime row stays stuck at `.running`
        /// (and, across `execv`, `recoverStaleSessions` keeps skipping it because the pid is unchanged).
        public func drainPersistenceForShutdown() async { await drainPersistenceQueueAsync() }

        /// Enqueues the durable runtime-state write off the engine. Coalesced latest-wins, so a burst of
        /// persists (or an exited state superseding a still-queued running state) collapses to the newest.
        /// On a successful write the durable marker is advanced back on the engine (finding-13 semantics:
        /// `lastPersistedRuntimeState`/timestamp advance only on success so a failed write retries next cycle;
        /// `latestRuntimeState` stays the authoritative broadcast source regardless). The exited-state
        /// in-place retry that fences termination lives in `TerminalCorePersistenceQueue`.
        private func enqueueRuntimeStateWrite(_ state: TerminalSessionRuntimeState, at writeAt: Date) {
            // `onPersisted` hops back to the engine to advance the durable marker (one-way rule); it is the
            // ONLY reference to `self` in the write chain, so the write — and any exited-state retry — survives
            // this core's release (e.g. a session-close that drops the core right after termination).
            persistence.enqueueRuntimeStateWrite(
                state, at: writeAt, paths: paths,
                onPersisted: { [weak self] persistedState, _ in Task { @TerminalEngineActor in self?.markRuntimeStatePersisted(persistedState) } })
        }

        /// Advances the durable persist marker after a successful off-engine write and, when the persisted
        /// signature changed, fires the runtime-state notification/broadcast — so DB-reading consumers (the
        /// overview) observe the change only once it is durable while live subscribers still see live truth
        /// from `latestRuntimeState`.
        private func markRuntimeStatePersisted(_ state: TerminalSessionRuntimeState) {
            let previousSignature = lastPersistedRuntimeState.map(runtimeStateSignature(for:))
            lastPersistedRuntimeState = state
            if previousSignature != runtimeStateSignature(for: state) { postRuntimeStateDidChange() }
        }

        // MARK: - Lifecycle writes (in-memory authority, durable mirror off the engine)

        /// The label `enqueueLaunchConfigurationWrite` enqueues under. Every other durable write this core
        /// makes validates against the `terminal_sessions` row that write creates, so a failure of THIS
        /// specific write is treated differently in `reconcileAfterFailedLifecycleWrite`: there is no row left
        /// to reconcile against, only one to terminate the core over.
        private static let launchConfigurationWriteLabel = "launch_configuration"

        /// Enqueues one once-per-lifecycle durable write with bounded in-place retry (see
        /// `TerminalCorePersistenceQueue.enqueueLifecycleWrite`). The engine has already applied the mutation
        /// to the authoritative in-memory snapshot, so this only mirrors it; on final failure the core hands
        /// the label to `reconcileAfterFailedLifecycleWrite`, which reconciles for an attachment write (drops
        /// the in-memory snapshot so the next read reseeds from committed truth) or terminates the core for
        /// the launch-configuration write (there is no session row left for later mirror writes to validate
        /// against, so reconciling would just make every later write fail as `unknownSession`).
        private func enqueueLifecycleWrite(_ label: String, _ write: @escaping @Sendable (String) throws -> Void) {
            persistence.enqueueLifecycleWrite(
                label, write: write, onFailure: { [weak self] in Task { @TerminalEngineActor in self?.reconcileAfterFailedLifecycleWrite(label) } })
        }

        /// Handles a lifecycle mirror write that exhausted its retries. The launch-configuration write is the
        /// FIRST entry on this core's persistence queue and every later write validates against the row it
        /// creates, so its failure leaves nothing to reconcile: the core terminates rather than reseeding a
        /// snapshot that would just make every later mirror write fail as `unknownSession`. Any other
        /// lifecycle write (attach, detach, ownership transfer, client upsert) drops the in-memory snapshot so
        /// the next read reseeds from committed truth, and re-broadcasts so subscribers and owner gating agree
        /// with it again. Called only from the persistence queue's engine hop.
        ///
        /// The reconcile hop above is itself asynchronous, so the queue can advance to a later write before
        /// this runs; a reseed can then read the database before that later write commits, leaving memory
        /// briefly behind the mirror it just reseeded from. Reaching that window needs one write to exhaust
        /// all retries (roughly 26 seconds of continuous write-lock contention) followed by the database
        /// recovering immediately with another write already queued behind it. The next lifecycle mutation
        /// (or an owner re-attach) reseeds again and self-heals it, so ordering the reconcile behind the
        /// queue, or guarding it with a generation counter, is complexity this corner does not justify.
        private func reconcileAfterFailedLifecycleWrite(_ label: String) {
            trace("lifecycle_write_failed write=\(label)")
            guard label != Self.launchConfigurationWriteLabel else {
                // The pending-launch registry entry was already cleared by the launch write's own onFailure
                // closure, core-independently, before this hop ran (see `enqueueLaunchConfigurationWrite`).
                terminate()
                // `terminate()` alone never calls `onSessionClosed`, only the natural child-exit path
                // (`handleSessionClosed()`) does, so without this call the daemon's session registry keeps
                // this dead core registered for its lifetime, and a later create for the same session id
                // would hand back the terminated object instead of building a fresh one.
                onSessionClosed?(self)
                return
            }
            invalidateAttachmentSnapshotCache()
            postAttachmentStateDidChange()
        }

        /// The session's `terminal_sessions` row, written as the FIRST entry on this core's persistence queue
        /// (nothing is enqueued before `startIfNeeded`/`resumeFromHandoff` runs). Every other durable write
        /// this core makes validates against that row, so serial FIFO ordering — not a blocking wait here — is
        /// what guarantees they commit after it exists.
        private func enqueueLaunchConfigurationWrite(clearingPreviousRunRuntimeState: Bool) {
            let configuration = launchConfiguration
            let paths = paths
            // Recorded before the enqueue and cleared only after the row commits: launch-pending probes
            // (automation polling, tracked-window liveness) read the registry first, so the gap between
            // this in-memory create and the write-behind row landing is never visible to them. The write's
            // final failure clears the entry in this write's own onFailure closure below, through the
            // value-captured session id rather than through the core: the persistence queue holds no
            // reference to the core, so a fast-exiting core can be deallocated before the failure callback
            // runs, and clearing inside the weak-self reconcile alone would leak a permanent pending entry
            // that keeps launch-pending probes and agent-signal requests treating a dead session as launching.
            // The clear below is generation-scoped: an older still-queued launch write for this same
            // session id can never erase this launch's entry, only the entry it itself recorded.
            // The SQL upsert itself is deliberately NOT generation-guarded. A stale queued launch write
            // could only clobber a successor's `terminal_sessions` row if the same session id were
            // recreated while the old core's write was still retrying, and no product path reuses a
            // session id: every create mints a fresh UUID (ad-hoc/agent launches and workspace terminal
            // reservations alike), a reservation is finished exactly once, and handoff resume drains the
            // old daemon's queues before execv. Even under a hypothetical reuse, the gated runtime-state
            // DELETE removes only exited/failed rows, so a live successor's runtime row survives and the
            // 1Hz signature-gated runtime refresh restores it; only the config columns would go stale.
            let generation = TerminalSessionPendingLaunchRegistry.shared.recordPending(configuration)
            persistence.enqueueLifecycleWrite(
                Self.launchConfigurationWriteLabel,
                write: { databasePath in
                    try TerminalSessionPersistence.writeLaunchConfiguration(
                        configuration, paths: paths, clearingPreviousRunRuntimeState: clearingPreviousRunRuntimeState, databasePath: databasePath)
                    TerminalSessionPendingLaunchRegistry.shared.clear(sessionID: configuration.sessionID, generation: generation)
                },
                onFailure: { [weak self] in
                    // Cleared here, outside the weak-self hop, so the registry entry never depends on the
                    // core still being alive when the failure callback runs.
                    TerminalSessionPendingLaunchRegistry.shared.clear(sessionID: configuration.sessionID, generation: generation)
                    Task { @TerminalEngineActor in self?.reconcileAfterFailedLifecycleWrite(Self.launchConfigurationWriteLabel) }
                })
        }

        /// Applies an attachment mutation to the authoritative in-memory snapshot. A nil snapshot means the
        /// cache is empty AND the reseeding disk read failed; the caller's durable mirror write still goes
        /// out regardless, so the transform is held in `pendingAttachmentMutations` instead of being dropped —
        /// `currentAttachmentSnapshot()` replays it once a reseed succeeds.
        private func mutateAttachmentSnapshot(_ transform: @escaping (TerminalSessionAttachmentSnapshot) -> TerminalSessionAttachmentSnapshot) {
            guard let snapshot = currentAttachmentSnapshot() else {
                pendingAttachmentMutations.append(transform)
                return
            }
            cachedAttachmentSnapshot = transform(snapshot)
        }

        /// Applies a client upsert to the in-memory snapshot and enqueues its durable mirror.
        private func applyClientUpsert(_ client: TerminalClient) {
            mutateAttachmentSnapshot { $0.applyingClientUpsert(client, leaseRefreshedAt: client.connectedAt) }
            let paths = paths
            enqueueLifecycleWrite("client_upsert") { databasePath in
                try TerminalSessionPersistence.upsertClient(client, paths: paths, databasePath: databasePath)
            }
        }

        /// Applies an attach to the in-memory snapshot and enqueues its durable mirror. The session id the
        /// mirror validates against is this core's own — `writeLaunchConfiguration` deletes every other
        /// session row for this root before inserting it — so no canonical-id lookup is needed on the engine.
        private func applyAttach(client: TerminalClient, mode: TerminalAttachmentMode, attachedAt: String) {
            let sessionID = launchConfiguration.sessionID
            mutateAttachmentSnapshot { $0.applyingAttach(client: client, mode: mode, sessionID: sessionID, attachedAt: attachedAt) }
            let paths = paths
            enqueueLifecycleWrite("attach") { databasePath in
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: attachedAt, databasePath: databasePath)
            }
        }

        /// Applies a detach to the in-memory snapshot and enqueues its durable mirror.
        private func applyDetach(clientID: String, detachedAt: String) {
            mutateAttachmentSnapshot { $0.applyingDetach(clientID: clientID, detachedAt: detachedAt) }
            let paths = paths
            enqueueLifecycleWrite("detach") { databasePath in
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: detachedAt, databasePath: databasePath)
            }
        }

        /// Applies an ownership transfer to the in-memory snapshot and enqueues its durable mirror.
        private func applyOwnershipTransfer(to newOwnerClientID: String, transferredAt: String) {
            let sessionID = launchConfiguration.sessionID
            mutateAttachmentSnapshot { $0.applyingOwnershipTransfer(to: newOwnerClientID, sessionID: sessionID, transferredAt: transferredAt) }
            let paths = paths
            enqueueLifecycleWrite("ownership_transfer") { databasePath in
                try TerminalSessionPersistence.transferOwnership(
                    sessionID: sessionID, newOwnerClientID: newOwnerClientID, paths: paths, transferredAt: transferredAt, databasePath: databasePath)
            }
        }

        /// Enqueues a durable agent-signal-event append on this core's own serial persistence queue, rather than
        /// through `enqueueLifecycleWrite`'s shared wrapper: that wrapper's failure path reconciles attachment
        /// state (drops the cached snapshot, or terminates the core for the launch-configuration label), which
        /// is unrelated to a signal row. A signal recorded while this core's launch-configuration write is
        /// still queued must commit after the `terminal_sessions` row exists; FIFO ordering on the serial
        /// persistence queue is what guarantees that, exactly as it does for the attach and detach mirrors.
        ///
        /// On final failure there is nothing to reconcile (no in-memory state mirrors signal rows), so the loss
        /// is logged and accepted: signal delivery was already best-effort at the sender (agent hooks append
        /// `|| true`).
        public func enqueueAgentSignalAppend(_ event: TerminalServiceAgentSignalEvent) {
            let paths = paths
            persistence.enqueueLifecycleWrite(
                "agent_signal",
                write: { databasePath in try TerminalSessionPersistence.appendPendingAgentSignal(event, paths: paths, databasePath: databasePath) },
                onFailure: { [weak self] in Task { @TerminalEngineActor in self?.trace("lifecycle_write_failed write=agent_signal") } })
        }

        /// Records a client's heartbeat-lease touch: refreshes the in-memory cache lease so on-engine reads
        /// reflect it without a disk hit, then enqueues a coalesced durable write. Lease expiry runs on a
        /// multi-second scale, so durable staleness of a coalesced touch between writes is harmless.
        ///
        /// The in-memory half runs on EVERY touch, for every client kind — it is what keeps this session's own
        /// stale-client expiry and owner gating honest. The daemon's own inactive-session reaper reads that
        /// same in-memory snapshot (`hasLiveAttachments`) rather than the durable column, so it never lags
        /// behind an uncommitted touch either. The durable write is performed only for a client whose
        /// liveness the lease actually decides, and then only once per coalescing interval
        /// (`leaseTouchCoalescer`); only readers of `lease_refreshed_at` that have no live core to ask (the
        /// session garbage collector, a fresh core reseeding after handoff) see that lag.
        private func enqueueClientLeaseTouch(clientID: String) {
            let touchedAtDate = Date()
            let touchedAt = TerminalSessionTimestamp.string(from: touchedAtDate)
            // Record the heartbeat instant on the engine synchronously so stale-client expiry honors it even
            // before the coalesced durable touch commits (finding B1).
            latestRemoteClientHeartbeat[clientID] = touchedAtDate
            // Advance the client's heartbeat generation so an already-queued stale-client expiry — whose durable
            // detach sits FIFO-ahead of this touch — vetoes detaching this client when it commits (finding R7-2).
            heartbeatGenerationGate.recordHeartbeat(forClientID: clientID)
            recordClientLeaseTouchInCache(clientID: clientID, leaseRefreshedAt: touchedAt)
            guard clientLivenessDependsOnLease(clientID: clientID) else { return }
            guard leaseTouchCoalescer.isDurableTouchDue(clientID: clientID, now: touchedAtDate) else { return }
            let paths = paths
            enqueueCoalescedPersistenceWrite(key: "lease:\(clientID)") { databasePath in
                // `disconnected_at IS NULL` inside `touchClient` makes this a no-op for an already-detached
                // client, so a stray touch enqueued for one can never resurrect its lease; the result is unused.
                _ = try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: touchedAt, databasePath: databasePath)
            }
        }

        /// Whether `clientID`'s durable lease has any reader (`TerminalClientKind.livenessDependsOnLease`).
        ///
        /// A local window client is judged live by its attachment row alone: `liveAttachments` counts it live
        /// while attached whatever its lease says, `staleRemoteClients` never returns it, and this core answers
        /// its heartbeats from in-memory attachment state rather than from the write's result. Its
        /// `lease_refreshed_at` is therefore read by nobody, so writing it is contention on the profile
        /// database for no information. Unknown clients keep writing: a client with no row in the snapshot has
        /// no kind to exempt it, and the write is a no-op against a row that does not exist.
        private func clientLivenessDependsOnLease(clientID: String) -> Bool {
            guard let kind = currentAttachmentSnapshot()?.clients.first(where: { $0.id == clientID })?.kind else { return true }
            return kind.livenessDependsOnLease
        }

        /// Updates the in-memory snapshot's client lease in place (no disk read). Deliberately reads
        /// `cachedAttachmentSnapshot` rather than `currentAttachmentSnapshot()`: a lease touch is not worth a
        /// disk reseed, and the next reseed carries the durable lease once its coalesced write commits.
        private func recordClientLeaseTouchInCache(clientID: String, leaseRefreshedAt: String) {
            guard let snapshot = cachedAttachmentSnapshot else { return }
            cachedAttachmentSnapshot = snapshot.applyingClientLeaseTouch(clientID: clientID, leaseRefreshedAt: leaseRefreshedAt)
        }

        private func handleSessionClosed() {
            terminate()
            onSessionClosed?(self)
        }

        // MARK: - Exec-in-place handoff

        /// Quiesce this session for the exec-in-place daemon handoff: stop the
        /// per-session timers, suppress broadcasts, and stop the control + state-stream
        /// servers (removing their socket files exactly as `terminate()` does) WITHOUT
        /// detaching clients, killing the child, or freeing the GhosttyKit session. The
        /// PTY read loop keeps draining — first into an in-memory buffer, then straight
        /// to `output.log` — so not a byte is lost across the exec. Returns the handoff
        /// record the staged daemon needs to adopt this session, or nil when there is
        /// nothing live to hand off (the child already exited/closed), in which case the
        /// caller terminates the session normally.
        public func quiesceForHandoff() async throws -> DaemonHandoffSessionRecord? {
            handoffTranscriptReplayOffset = nil
            // Force the durable row current before the exec. `title` is out of the persist signature, so the
            // stored title can be arbitrarily stale by now; the adopting core seeds itself from this row, and
            // the persistence drain later in this function is what makes the write land before `execv`.
            refreshRuntimeState(force: true)
            suppressBroadcastsForHandoff = true
            runtimeStateTimer?.cancel()
            runtimeStateTimer = nil
            inputOutputResyncScheduler.cancelForTermination()

            controlServer?.stop()
            controlServer = nil
            TerminalControlServer.removeSocketFileIfPresent(at: paths.controlSocketPath)
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)

            // Drain accepted-but-unwritten control input before handing off. Input can still be queued here:
            // a plain send is answered as soon as its write is enqueued, a submit's two sequencer writes (the
            // pasted text, then the carriage return) can be mid-flight for a request the control server has
            // not answered yet, and the host PTY write queue behind both is asynchronous. The control server
            // is stopped above, so no new sends can enqueue — await the sequencer chain and then the PTY
            // write queue so the `execv` that inherits this same master fd cannot destroy either with the CR
            // (or the whole line) unwritten. The child's echo of the drained input flows through the normal
            // output path below.
            await controlInputSequencer.drain()
            await rendererHostStorage.drainPendingInputWrites()

            // Nothing live to hand off (child dead/closed): caller terminates normally.
            guard let descriptor = sessionDriver.handoffDescriptorSnapshot() else { return nil }

            // Route further PTY bytes into an in-memory buffer so the read loop never
            // blocks while we drain the main actor and close the durable output handle.
            await sessionDriver.beginHandoffOutputBuffering()

            // The driver has disabled Ghostty's data callback and awaited both the PTY
            // handler boundary and every callback already inside Spaces. All callback
            // bytes are therefore registered in this locked buffer; drain it directly.
            flushPendingIncomingOutputForStateExport()

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
            try sessionDriver.finishHandoffOutputBuffering(appendingTo: paths.outputPath)

            // Drain every pending durable mirror write (lease touches, runtime state) before returning the
            // record: the caller `execv`s into the staged daemon, which reseeds from the DB, so the mirror
            // must be complete first. Async so the engine is not blocked while the queue flushes.
            await drainPersistenceQueueAsync()

            let size = observedSurfaceSize() ?? lastKnownSurfaceSize ?? (columns: 80, rows: 24)
            return DaemonHandoffSessionRecord(
                sessionID: launchConfiguration.sessionID, masterFD: descriptor.masterFD, childPID: descriptor.childPID, columns: size.columns,
                rows: size.rows, ownerEpoch: ownerEpoch, screenStateRevision: lastScreenStateRevision ?? 0,
                appearance: GhosttyEmbeddedAppService.shared.currentAppearance.rawValue, transcriptOffsetAtQuiesce: handoffTranscriptReplayOffset)
        }

        /// Holds the PTY sink boundary while the daemon performs its final persistence
        /// validation and `execv`, preventing a direct write from racing after the check.
        public func withValidatedHandoffOutputForExec<T>(_ operation: () throws -> T) throws -> T {
            try sessionDriver.withValidatedHandoffOutputForExec(operation)
        }

        /// Failed-`execv` fallback: `execv` returned, so this same image keeps running and
        /// nothing was freed. Stop the direct-to-file writer, reopen the output handle for
        /// append, restart the per-session servers, and resume timers/broadcasts. This
        /// rebinds the still-live session; it never rebuilds it.
        public func resumeInPlaceAfterFailedExec() async {
            // Freeze the direct writer before reading its persisted range or seeking the
            // replacement FileHandle. PTY output arriving during replay stays buffered.
            sessionDriver.pauseHandoffOutputForFallback()
            if let handoffTranscriptReplayOffset {
                await sessionDriver.replayPersistedHandoffOutput(at: paths.outputPath, startingAt: handoffTranscriptReplayOffset)
            }
            do { try openOutputHandlePreservingTranscript() } catch { fputs("spaces: ghostty handoff transcript reopen failed: \(error)\n", stderr) }
            await sessionDriver.endHandoffOutputBuffering()
            flushPendingIncomingOutputForStateExport()
            self.handoffTranscriptReplayOffset = nil
            suppressBroadcastsForHandoff = false
            do {
                try startControlServer()
                try startStateStreamServer()
            } catch { fputs("spaces: ghostty handoff resume-in-place failed: \(error)\n", stderr) }
            startRuntimeStateTimer()
            refreshRuntimeState(force: true)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
        }

        /// Resume side of the exec-in-place handoff, run on a freshly built core in the
        /// staged daemon image for a session that survived the exec. Rebuilds the session
        /// by adopting the inherited PTY and replaying output.log at the persisted grid
        /// size, then restarts the servers and republishes a full frame so reconnecting
        /// clients get a self-contained baseline. The process-wide GhosttyKit app runtime
        /// must already be started (its per-process `ghostty_init` guard was wiped by
        /// exec); this ensures it before rebuilding a session.
        public func resumeFromHandoff(_ record: DaemonHandoffSessionRecord) async throws {
            try GhosttyEmbeddedAppService.shared.startIfNeeded()
            try paths.ensureDirectories()
            // The runtime row being resumed is this session's current-run state carried across the
            // handoff, not a previous run's leftover, so this write must not clear it.
            enqueueLaunchConfigurationWrite(clearingPreviousRunRuntimeState: false)
            // Preserve output.log: adoptFromHandoff replays it to rebuild the screen.
            try openOutputHandlePreservingTranscript()

            // Seed the bell from the row the pre-exec image wrote, before anything in this resume writes
            // runtime state from this core's (empty) state — the first such write would put NULL over the
            // bell and silently retract an alert the user has not dealt with. Title and cwd are
            // deliberately not seeded (the surface replay re-establishes them), but no replay can
            // re-establish a bell: it is an event, not screen state, and a trimmed transcript may not even
            // carry the BEL. The coalescing window is restored with it, so a bell moments after the
            // handoff — including one the replayed transcript re-rings through the live action handler —
            // is absorbed into the alert the user already has instead of minting a second one.
            let persistedRuntimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
            let persistedBellAt = persistedRuntimeState?.bellAt
            currentBellAt = persistedBellAt
            bellCoalescer.seedLastAdvanced(at: persistedBellAt.flatMap(TerminalSessionTimestamp.date(from:)))
            // Seed the reported title from the row the quiescing daemon forced before `execv`. The adopted
            // session's program is mid-run and may not report a title again for a long time (a spinner does
            // so within a frame, an editor showing a filename may never), and this core is the authority the
            // overview now reads that title from, so starting at nil would blank a live pane's title.
            currentTitle = persistedRuntimeState?.title

            // Apply the recorded appearance BEFORE replay so the rebuilt frames carry the
            // right colors. Appearance is an app-wide (one ghostty_app_t) last-writer-wins
            // setting, applied the same way an attaching client applies it.
            if let appearanceRaw = record.appearance, let appearance = ThemeAppearance(rawValue: appearanceRaw) {
                GhosttyEmbeddedAppService.shared.applyColorScheme(appearance)
            }

            rendererHostStorage.setOutputHandler { [weak self] data in self?.enqueueIncomingOutput(data) }
            rendererHostStorage.setInputActivityHandler { [weak self] byteCount in self?.handleOwnerInputActivity(byteCount: byteCount) }
            didTerminateCurrentRun = false
            started = true
            suppressBroadcastsForHandoff = false

            do {
                try await sessionDriver.adoptFromHandoff(
                    masterFD: record.masterFD, childPID: record.childPID, columns: record.columns, rows: record.rows, outputLogPath: paths.outputPath)
            } catch {
                started = false
                throw error
            }

            ownerEpoch = record.ownerEpoch
            // Advance past the recorded revision and force the first broadcast to a full
            // render update so reconnecting clients rebuild from a self-contained baseline.
            lastScreenStateRevision = record.screenStateRevision &+ 1
            lastRenderUpdateBaseline = nil
            forceNextBroadcastFullRenderUpdate = true
            lastKnownSurfaceSize = (columns: record.columns, rows: record.rows)

            try startControlServer()
            try startStateStreamServer()
            startRuntimeStateTimer()
            sessionStartedAt = Date()
            didLogFirstOutput = false
            refreshRuntimeState(force: true)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
        }

        var debugOwnerEpoch: UInt64 { ownerEpoch }

        public func childPID() -> Int32? { observedChildPID() }

        /// The session's foreground process read from the PTY right now, not the periodic sample carried
        /// on runtime state. The conditional stop of a user-closed ad hoc terminal decides against this so
        /// a command started an instant before the close is seen.
        public func currentForegroundProcess() -> TerminalForegroundProcessSnapshot? { observedForegroundPID().flatMap(foregroundProcessResolver) }

        public var effectiveTitle: String { currentTitle ?? launchConfiguration.title }
        // Prefer the live cwd observed from the foreground/child process (cached by refreshRuntimeState)
        // so the working directory clients see converges on reality even when the shell never reports a
        // new PWD through Ghostty shell integration (OSC 7). currentWorkingDirectory (the PWD-action
        // value) remains the next fallback, then the launch directory. This property is read on the
        // per-render broadcast path, so it only reads the cached value — the proc lookup that fills the
        // cache runs on the slower runtime-state refresh path.
        public var effectiveWorkingDirectory: String {
            lastObservedProcessWorkingDirectory ?? currentWorkingDirectory ?? launchConfiguration.workingDirectory
        }

        /// The session summary built entirely from this core's in-memory launch configuration and
        /// `latestRuntimeState` — with no DB read. Serves the create path's post-start summary so a create
        /// reports the running session the moment `startIfNeeded()` returns (which advances
        /// `latestRuntimeState` synchronously via `refreshRuntimeState(force:)`), independent of when the
        /// first runtime-state write commits to SQLite. That first write is enqueued on the per-core
        /// persistence queue, so under writer contention it can lag the busy timeout; polling the durable
        /// mirror for it could time out and report `ok:false` for a live session. Returns nil only before any
        /// runtime state has been computed (never started), which the create path treats as a failed start
        /// and rolls back.
        ///
        /// Mirrors the fields of `SpacesdMain.summary(for:paths:)`. The two fields that helper reads from
        /// disk are trivially known at session birth: no client has attached yet, so the attachment snapshot
        /// is empty (`cachedAttachmentSnapshot` is nil at birth), and no final render exists, so
        /// `hasFinalRender` is false.
        public func inMemorySessionSummary() -> TerminalServiceSessionSummary? {
            guard let runtimeState = latestRuntimeState else { return nil }
            return TerminalServiceSessionSummary(
                id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath,
                launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: inMemoryLiveWireAttachmentSnapshot(),
                hasFinalRender: false)
        }

        /// The catalog entry built entirely from this core's in-memory state, with no DB read. Serves the
        /// Device API overview's live-session merge the same way `inMemorySessionSummary()` serves the CLI
        /// list merge: session lifecycle SQLite writes are write-behind on the per-core persistence queue,
        /// so a session started moments ago can have no committed rows for
        /// `TerminalSessionCatalog.listLiveSessions()` to find. Socket availability is probed from the
        /// filesystem exactly as the catalog probes it for DB-derived entries, so a merged entry answers
        /// the same question the same way.
        public func inMemoryCatalogEntry(fileManager: FileManager = .default) -> TerminalSessionCatalogEntry? {
            guard let runtimeState = latestRuntimeState else { return nil }
            return TerminalSessionCatalogEntry(
                launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: inMemoryLiveWireAttachmentSnapshot(),
                paths: paths, isControlAvailable: fileManager.fileExists(atPath: paths.controlSocketPath),
                isSubscriptionAvailable: fileManager.fileExists(atPath: paths.subscriptionSocketPath))
        }

        private func startControlServer() throws {
            let controlServer = TerminalControlServer(socketPath: paths.controlSocketPath, queue: controlQueue) { [weak self] request in
                // The control server runs this on its own transport queue, which is where the request is
                // handled from: `handleControlRequest` bridges synchronously onto the terminal engine actor
                // (never the main actor, so a blocked main actor can't stall control) and then waits HERE,
                // off the engine, for a send's writes to reach the PTY.
                guard let self else {
                    return TerminalControlResponse(ok: false, message: "Terminal session is shutting down.", errorCode: .shuttingDown)
                }
                return self.handleControlRequest(request)
            }
            try controlServer.start()
            self.controlServer = controlServer
        }

        private func startStateStreamServer() throws {
            let stateStreamServer = GhosttyRemoteSessionStateStreamServer(
                socketPath: paths.subscriptionSocketPath, queue: stateStreamQueue,
                initialStateProvider: { [weak self] in
                    TerminalEngineActor.runSynchronously {
                        // Arm the forced full frame for EVERY subscriber whose unicast initial
                        // carries no render update, not just the first connection: one-shot
                        // `.state` reads share this socket, so "no existing clients" is routinely
                        // false when the real subscriber connects, and without a full-frame
                        // baseline its deltas can never apply (the pane never becomes renderable).
                        self?.currentRemoteSessionState(
                            reason: TerminalRemoteSessionStateReason.initial, outputByteCount: nil, exportMode: .selfContained,
                            markNextBroadcastFullWhenMissingRenderUpdate: true)
                    }
                })
            try stateStreamServer.start()
            self.stateStreamServer = stateStreamServer
        }

        /// Handles a control request from OFF the terminal engine actor: hops onto the engine to handle it
        /// and then, for a send, waits here for the writes that send enqueued to reach the PTY, so the
        /// response reports a real write rather than an accepted request. Callers are transport threads —
        /// this session's control-socket queue and the daemon's off-main send path — never the engine
        /// itself, which is where those writes run.
        public nonisolated func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            TerminalEngineActor.runSynchronously { self.handleControlRequestOnEngine(request) }.resolvedResponse()
        }

        func handleControlRequestOnEngine(_ request: TerminalControlRequest) -> TerminalControlHandling {
            let command = request.commandValue
            trace(
                "control_request command=\(command.name) client=\(request.clientID ?? request.client?.id ?? "nil") target_session=\(launchConfiguration.sessionID)"
            )
            if case .send = command { return controlResponseForSendRequest(request) }
            let response: TerminalControlResponse =
                switch command {
                case .attach: controlResponseForAttachRequest(request)
                case .detach: controlResponseForDetachRequest(request)
                case .heartbeat: controlResponseForHeartbeatRequest(request)
                case .send: preconditionFailure("send is handled above so its write acknowledgement is carried out to the caller")
                case .key: controlResponseForKeyRequest(request)
                case .clearScreen: controlResponseForClearScreenRequest(request)
                case .takeover: controlResponseForTakeoverRequest(request)
                case .resize: controlResponseForResizeRequest(request)
                case .scroll: controlResponseForScrollRequest(request)
                case .mouseButton: controlResponseForMouseButtonRequest(request)
                case .setAppearance: controlResponseForSetAppearanceRequest(request)
                case .setSelection: controlResponseForSetSelectionRequest(request)
                case .clearSelection: controlResponseForClearSelectionRequest(request)
                case .readSelectionText: controlResponseForReadSelectionTextRequest(request)
                case .unsupported(let name): TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(name)'.")
                }
            return TerminalControlHandling(response: response)
        }

        private func ownerRequestRejection(for request: TerminalControlRequest, commandName: String, startedAt: Date) -> TerminalControlResponse? {
            guard let clientID = request.clientID else { return nil }
            guard isOwner(clientID: clientID) else {
                TerminalPerformance.logMetric(
                    "terminal_control_\(commandName)", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "owner=stale")
                return TerminalControlResponse(
                    ok: false, message: "Only the active owner can \(commandName) the terminal.", errorCode: .ownershipRejected)
            }
            guard let requestedOwnerEpoch = request.ownerEpoch else { return nil }
            guard requestedOwnerEpoch == ownerEpoch else {
                TerminalPerformance.logMetric(
                    "terminal_control_\(commandName)", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false,
                    detail: "owner_epoch=\(requestedOwnerEpoch) current_owner_epoch=\(ownerEpoch)")
                return TerminalControlResponse(
                    ok: false, message: "Ignoring stale owner epoch \(requestedOwnerEpoch); current owner epoch is \(ownerEpoch).",
                    errorCode: .ownershipRejected)
            }
            return nil
        }

        private func staleResizeSerialRejection(for request: TerminalControlRequest, startedAt: Date) -> TerminalControlResponse? {
            guard let clientID = request.clientID, let resizeSerial = request.resizeSerial else { return nil }
            guard let lastResizeSerial = lastResizeSerialByClientID[clientID], resizeSerial <= lastResizeSerial else { return nil }
            TerminalPerformance.logMetric(
                "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false,
                detail: "resize_serial=\(resizeSerial) last_resize_serial=\(lastResizeSerial)")
            return TerminalControlResponse(
                ok: false, message: "Ignoring stale resize serial \(resizeSerial); latest accepted serial is \(lastResizeSerial).",
                errorCode: .ownershipRejected)
        }

        private func recordAcceptedResizeSerial(from request: TerminalControlRequest) {
            guard let clientID = request.clientID, let resizeSerial = request.resizeSerial else { return }
            lastResizeSerialByClientID[clientID] = resizeSerial
        }

        private func advanceOwnerEpoch(reason: String) {
            ownerEpoch &+= 1
            lastResizeSerialByClientID.removeAll(keepingCapacity: true)
            lastRenderUpdateBaseline = nil
            trace("owner_epoch_advanced reason=\(reason) owner_epoch=\(ownerEpoch) owner=\(activeOwnerClientID() ?? "nil")")
        }

        private func controlResponseForAttachRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            guard let client = request.client else {
                TerminalPerformance.logMetric(
                    "terminal_control_attach", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing client payload.", errorCode: .invalidArgument)
            }
            let mode = request.attachmentMode ?? .viewer
            let attachedAt = nowISO8601()
            let authoritativeClient = Self.clientForAttachLease(client, attachedAt: attachedAt)
            // Adopt the attaching client's light/dark appearance. The Ghostty color scheme is
            // app-scoped (one ghostty_app_t per daemon), so this re-themes every live surface in
            // the daemon on a last-writer-wins basis. The io thread applies the colors
            // asynchronously, so we deliberately do NOT broadcast inline here: an immediate frame
            // would still carry the pre-retheme colors. Instead we arm forceNextBroadcastFull
            // below and let the recolored screen reach subscribers through the existing screen
            // state-change broadcast that Ghostty triggers once the retheme lands (and the
            // always-fresh initial-frame export for subscribers that connect afterwards).
            let appearanceChanged = request.appearance.map { GhosttyEmbeddedAppService.shared.applyColorScheme($0) } ?? false
            let previousOwnerClientID = activeOwnerClientID()
            applyClientUpsert(authoritativeClient)
            // An attach is liveness evidence in its own right, not just a lease write: record it in the same
            // heartbeat map and generation gate a lease touch would (see `enqueueClientLeaseTouch`). Without
            // this, a client that just reattached has a fresh in-memory lease but an unrecorded heartbeat; if
            // the durable mirror write from `applyClientUpsert` is still sitting in the persistence queue when
            // the next 1s stale-client sweep ticks, the sweep derives its candidates from committed DB rows,
            // sees the old (still-committed) stale lease, and expires this freshly reattached client out from
            // under it, and with no heartbeat-generation bump either, the queued expiry's own compare-and-set
            // would have nothing to veto it at commit time.
            let attachedAtDate = Date()
            latestRemoteClientHeartbeat[authoritativeClient.id] = attachedAtDate
            heartbeatGenerationGate.recordHeartbeat(forClientID: authoritativeClient.id)
            // The upsert rewrote this client's durable lease, so any coalesced-write record from an
            // earlier attachment of the same client id is void; the first touch of this attachment writes.
            leaseTouchCoalescer.forget(clientID: authoritativeClient.id)
            // Resize serials are scoped to an attachment, not to a client id. A client that reconnects
            // to a session it already owns keeps its id — an app relaunch reattaches as the same owner
            // in the same mode, which advances no epoch and changes no attachment — while its host
            // counts serials from zero again. Carrying the previous attachment's high-water mark across
            // that would reject every serial the reconnected client sends and pin the session to the
            // grid it had before. Accepted residual: nothing distinguishes incarnations on the wire,
            // so a resize still in flight from the PREVIOUS host of this same id could land after the
            // reset and outrank the new host's early serials. That needs a same-process host swap with
            // a send mid-flight, misorders at most a few sends (serials keep incrementing past the
            // stale mark and every state payload re-announces the viewport), and the alternative —
            // carrying an attachment incarnation in every resize request — is a wire change this
            // corner does not justify.
            lastResizeSerialByClientID.removeValue(forKey: authoritativeClient.id)
            let currentAttachment = currentActiveAttachments().first { $0.clientID == authoritativeClient.id }
            let attachmentChanged = currentAttachment?.mode != mode
            if attachmentChanged {
                applyAttach(client: authoritativeClient, mode: mode, attachedAt: attachedAt)
                if mode == .owner, previousOwnerClientID != authoritativeClient.id { advanceOwnerEpoch(reason: "control_attach") }
                postAttachmentStateDidChange()
            }
            // Only an attach that actually moved this session's attachments can have changed anything
            // the runtime state carries. Re-attaching the same client in the same mode — what every
            // refocus of an already-open pane does — leaves the unforced refresh, which persists only
            // when the state's own signature moved.
            refreshRuntimeState(force: attachmentChanged)
            // Set after the attachment broadcast above so the recolored screen (delivered by the
            // next broadcast, once Ghostty finishes the async retheme) is a self-contained full
            // frame rather than a color-only delta from a stale baseline. There is no host-side
            // screen revision to bump here: lastScreenStateRevision tracks Ghostty's own
            // revisions, which the retheme advances on its own.
            if appearanceChanged { forceNextBroadcastFullRenderUpdate = true }
            TerminalPerformance.logMetric(
                "terminal_control_attach", target: "session=\(launchConfiguration.sessionID) client=\(authoritativeClient.id)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "mode=\(mode.rawValue)")
            return TerminalControlResponse(ok: true, message: "Attached \(mode.rawValue) client.")
        }

        private func controlResponseForSetAppearanceRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            // Appearance is a per-client view preference on a shared session with last-writer-wins
            // semantics, so it is deliberately NOT owner-gated: viewers flip their own app appearance
            // and every client should be able to re-theme the terminal it is watching.
            guard let appearance = request.appearance else {
                TerminalPerformance.logMetric(
                    "terminal_control_set_appearance", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing appearance.", errorCode: .invalidArgument)
            }
            // Re-theme every live surface app-wide (one ghostty_app_t per daemon). The io thread
            // applies the colors asynchronously, so we do NOT broadcast inline here: an immediate
            // frame would still carry the pre-retheme colors. Instead arm forceNextBroadcastFull so
            // the recolored screen reaches subscribers as a self-contained full frame through the
            // screen state-change broadcast Ghostty triggers once the retheme lands.
            let appearanceChanged = GhosttyEmbeddedAppService.shared.applyColorScheme(appearance)
            if appearanceChanged { forceNextBroadcastFullRenderUpdate = true }
            TerminalPerformance.logMetric(
                "terminal_control_set_appearance", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail: "appearance=\(appearance.rawValue) changed=\(appearanceChanged ? 1 : 0)")
            return TerminalControlResponse(
                ok: true,
                message: appearanceChanged ? "Applied \(appearance.rawValue) appearance." : "Terminal already matches the requested appearance.")
        }

        private func controlResponseForSetSelectionRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            // Selection is deliberately shared state, not owner-gated (see
            // `TerminalControlCommand.requiresOwnerClientID`): any attached viewer may set it, and the
            // result is broadcast to every other viewer.
            guard let startColumn = request.selectionStartColumn, let startRow = request.selectionStartRow,
                let endColumn = request.selectionEndColumn, let endRow = request.selectionEndRow
            else {
                TerminalPerformance.logMetric(
                    "terminal_control_set_selection", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing selection endpoints.", errorCode: .invalidArgument)
            }
            let didSet = rendererHostStorage.setSelectionAbsolute(
                startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow, rectangle: request.selectionRectangle ?? false)
            let selectionText = didSet ? rendererHostStorage.readSelectionText() : nil
            if didSet { broadcastCurrentState(reason: TerminalRemoteSessionStateReason.selection) }
            TerminalPerformance.logMetric(
                "terminal_control_set_selection", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: didSet)
            return TerminalControlResponse(
                ok: didSet, message: didSet ? "Set terminal selection." : "Unable to set terminal selection.", selectionText: selectionText)
        }

        private func controlResponseForClearSelectionRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            // Not owner-gated for the same reason as `controlResponseForSetSelectionRequest` above.
            rendererHostStorage.clearSelection()
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.selection)
            TerminalPerformance.logMetric(
                "terminal_control_clear_selection", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
            return TerminalControlResponse(ok: true, message: "Cleared terminal selection.")
        }

        private func controlResponseForReadSelectionTextRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            // A pure read: never broadcasts, and not owner-gated so any viewer can read what the shared
            // selection currently says (e.g. before deciding whether to extend or replace it).
            let selectionText = rendererHostStorage.readSelectionText()
            TerminalPerformance.logMetric(
                "terminal_control_read_selection_text", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
            return TerminalControlResponse(ok: true, message: "Read terminal selection.", selectionText: selectionText)
        }

        private func controlResponseForDetachRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard let clientID = request.clientID else {
                TerminalPerformance.logMetric(
                    "terminal_control_detach", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                let hasActiveAttachment = currentActiveAttachments().contains { $0.clientID == clientID }
                if hasActiveAttachment { try detach(clientID: clientID) }
                TerminalPerformance.logMetric(
                    "terminal_control_detach", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
                return TerminalControlResponse(ok: true, message: "Detached terminal client.")
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_control_detach", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: String(describing: error))
            }
        }

        private func controlResponseForHeartbeatRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard let clientID = request.clientID else {
                TerminalPerformance.logMetric(
                    "terminal_control_heartbeat", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            // Honest signal for a durably disconnected client: if the client has no active attachment and no
            // pending (veto-able) stale-client expiry that its own heartbeat could rescue, it was expired/detached
            // and is heartbeating a corpse. Tell it so it can re-attach instead of refreshing forever (finding
            // R7-2). A client whose expiry is still pending in `expiredRemoteClientIDs` is NOT durably gone — this
            // heartbeat's generation bump below will veto that expiry — so it heartbeats ok.
            if isClientDurablyDisconnected(clientID) {
                TerminalPerformance.logMetric(
                    "terminal_control_heartbeat", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "durably_disconnected")
                return TerminalControlResponse(ok: false, message: "Terminal client is no longer attached.", errorCode: .notFound)
            }
            // The durable lease write is coalesced off the engine; the client's lease is recorded in memory
            // immediately, so the heartbeat acknowledges success without waiting on the DB write lock.
            enqueueClientLeaseTouch(clientID: clientID)
            TerminalPerformance.logMetric(
                "terminal_control_heartbeat", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
            return TerminalControlResponse(ok: true, message: "Refreshed terminal client lease.")
        }

        /// A submit's response carries the write acknowledgement out to its off-engine caller, which waits
        /// on it: the bytes are written on the engine after this returns, so "accepted" is not something
        /// this function can honestly report as "sent" — and an automation stamping a seed prompt as
        /// delivered needs "sent".
        ///
        /// The other sends keep the enqueue contract deliberately. They carry no downstream record of
        /// delivery, they are a stream of interactive input whose guarantee is the sequencer's ordering,
        /// and holding a client's per-keystroke round trip open until each write lands would pay for a
        /// distinction nothing reads.
        private func controlResponseForSendRequest(_ request: TerminalControlRequest) -> TerminalControlHandling {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlHandling(
                    response: TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning))
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "send", startedAt: startedAt) {
                return TerminalControlHandling(response: rejection)
            }
            if request.asPaste {
                guard var text = request.text, request.bytes == nil else {
                    return TerminalControlHandling(
                        response: TerminalControlResponse(ok: false, message: "Paste input requires text payload.", errorCode: .invalidArgument))
                }
                if request.appendNewline { text.append("\n") }
                guard !text.isEmpty else {
                    return TerminalControlHandling(
                        response: TerminalControlResponse(ok: false, message: "Missing input payload.", errorCode: .invalidArgument))
                }
                markLocalOwnerCommandInputOutputResyncPending()
                enqueueControlInputPaste(text)
                TerminalPerformance.logMetric(
                    "terminal_control_send", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "bytes=\(text.utf8.count)")
                return TerminalControlHandling(response: TerminalControlResponse(ok: true, message: "Sent input."))
            } else {
                guard let payload = request.inputPayload else {
                    return TerminalControlHandling(
                        response: TerminalControlResponse(ok: false, message: "Missing input payload.", errorCode: .invalidArgument))
                }
                markLocalOwnerCommandInputOutputResyncPending()
                // Submit-safe send: a text payload with appendNewline is a "submit" (type this, press Enter).
                // Agent TUIs (Claude Code, Codex, OpenCode) group bytes that arrive in one PTY read burst
                // into a paste, so text merged with its own carriage return lands in the composer
                // unsubmitted. The text (which may itself contain newlines, e.g. a multi-line notification)
                // goes in as a paste and the CR (0x0D) follows as its own write, both inside one sequencer
                // slot (`enqueueControlInputSubmit`). Ghostty derives the paste encoding from the live
                // terminal state AT WRITE TIME: an application that enabled bracketed paste (DECSET 2004)
                // receives the text framed by paste markers — the frame closes before the CR arrives, making
                // the CR a distinct Enter keystroke no matter how the bytes are batched into read bursts, so
                // the CR follows immediately. An application with bracketed paste OFF receives the text
                // unframed, so only time can keep the CR out of the text's read burst and the CR is spaced
                // from it (issue #187). Which of the two happened is reported by the text write itself
                // rather than sampled here, so the pacing can never be decided against a framing the bytes
                // did not go out with. Enter is a CR because shells and Claude Code accept LF or CR while
                // Codex and OpenCode submit only on CR. An empty text with appendNewline is a bare Enter
                // (e.g. answering a TUI dialog, or the automation prompt ladder's submit): there is nothing
                // to frame, so the CR goes in alone. Byte payloads are opaque input rather than composer
                // text, so they keep the single inline write.
                var submitAcknowledgement: TerminalInputWriteAcknowledgement?
                if request.appendNewline, request.bytes == nil, let text = request.text, !text.isEmpty {
                    submitAcknowledgement = enqueueControlInputSubmit(text)
                } else {
                    var bytes = payload
                    if request.appendNewline { bytes.append(0x0D) }
                    // A submit answers for its Enter however that Enter was written. A bare Enter and a byte
                    // payload go out as one write rather than the two-write split, but they are still
                    // submits: their write answers for the host-PTY writes ghostty produced for it and the
                    // response resolves against that acknowledgement — otherwise a child that exits with
                    // the CR still queued would report a submitted prompt that never landed. Input without
                    // a newline is not a submit and keeps the unwaited enqueue, so ordinary interactive
                    // writes never pay a round trip for an answer no caller asked for.
                    if request.appendNewline {
                        submitAcknowledgement = enqueueControlInputSubmitWrite(bytes)
                    } else {
                        enqueueControlInputWrite(bytes)
                    }
                }
                TerminalPerformance.logMetric(
                    "terminal_control_send", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "bytes=\(payload.count)")
                return TerminalControlHandling(
                    response: TerminalControlResponse(ok: true, message: "Sent input."), writeAcknowledgement: submitAcknowledgement)
            }
        }

        @discardableResult private func enqueueControlInputWrite(_ bytes: Data) -> TerminalInputWriteAcknowledgement {
            controlInputSequencer.enqueueWrite { [weak self] in
                await TerminalEngineActor.run { self?.rendererHostStorage.sendRawBytes(bytes) == true ? .delivered : .notDelivered }
            }
        }

        /// A submit that goes out as one write: a bare Enter, or a byte payload with its appended carriage
        /// return. Like each half of the two-write submit, it answers for the host-PTY writes ghostty
        /// produced for it rather than for ghostty having accepted the bytes, so a send whose Enter was
        /// still queued when the child exited fails instead of reporting a prompt as submitted.
        private func enqueueControlInputSubmitWrite(_ bytes: Data) -> TerminalInputWriteAcknowledgement {
            controlInputSequencer.enqueueWrite { [weak self] in
                let writes = await TerminalEngineActor.run { () -> TerminalInputWriteBatch? in
                    guard let self else { return nil }
                    return self.rendererHostStorage.sendRawBytesAwaitingEmission(bytes)
                }
                guard let writes else { return .notDelivered }
                return await writes.outcome()
            }
        }

        /// A submit — the text and the carriage return that runs it — as one sequencer slot. The text goes
        /// through ghostty's paste encoder, which frames it with bracketed-paste markers when the running
        /// application enabled DECSET 2004 and passes it through verbatim otherwise; the write reports which
        /// it did, and the sequencer paces the CR against that. Reading the mode inside the write is what
        /// keeps the decision and the encoding at one instant: ghostty derives the encoding from live
        /// terminal state when the write runs, so a mode sampled at request time can disagree with the
        /// bytes that actually went out and leave the CR paced for a framing the text never had.
        /// Each half also answers for the host-PTY writes ghostty produced for it, not for ghostty having
        /// accepted the input: the batch is collected inside the engine-isolated call and awaited here, off
        /// the engine, so a write still sitting on the host PTY queue when the child exits fails the send
        /// instead of stamping a prompt as delivered.
        private func enqueueControlInputSubmit(_ text: String) -> TerminalInputWriteAcknowledgement {
            controlInputSequencer.enqueueSubmit(
                writeText: { [weak self] in
                    let write = await TerminalEngineActor.run { self?.rendererHostStorage.sendSubmitTextAsPaste(text) ?? .notDelivered }
                    guard case .written(let framed, let writes) = write else { return .notDelivered }
                    return await writes.outcome() == .delivered ? .written(framed: framed) : .notDelivered
                },
                writeCarriageReturn: { [weak self] in
                    let writes = await TerminalEngineActor.run { () -> TerminalInputWriteBatch? in
                        guard let self else { return nil }
                        return self.rendererHostStorage.sendRawBytesAwaitingEmission(Data([0x0D]))
                    }
                    guard let writes else { return .notDelivered }
                    return await writes.outcome()
                })
        }

        /// Writes text through ghostty's paste encoder for an explicit paste request. A submit's text takes
        /// `enqueueControlInputSubmit` instead, which also reports the framing its CR must be paced against.
        @discardableResult private func enqueueControlInputPaste(_ text: String) -> TerminalInputWriteAcknowledgement {
            controlInputSequencer.enqueueWrite { [weak self] in
                await TerminalEngineActor.run { self?.rendererHostStorage.sendTextAsPaste(text) == true ? .delivered : .notDelivered }
            }
        }

        /// Queued through the same sequencer as text writes so a key press never overtakes the text it was
        /// meant to follow.
        @discardableResult private func enqueueControlKeyPress(_ spec: TerminalKeySpec) -> TerminalInputWriteAcknowledgement {
            controlInputSequencer.enqueueWrite { [weak self] in
                await TerminalEngineActor.run { self?.rendererHostStorage.sendKey(spec) == true ? .delivered : .notDelivered }
            }
        }

        private func controlResponseForKeyRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "key", startedAt: startedAt) { return rejection }
            guard let key = request.key, let resolution = TerminalKeyInput.resolve(key) else {
                TerminalPerformance.logMetric(
                    "terminal_control_key", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Unsupported terminal key.", errorCode: .invalidArgument)
            }
            switch resolution {
            case .hostAction(.clearScreenAndScrollback):
                return controlResponseForClearScreenRequest(request, startedAt: startedAt, touchClient: false)
            case .lineEditingBytes(let bytes): enqueueControlInputWrite(Data(bytes))
            case .keyPress(let spec):
                if spec.key == .enter { markLocalOwnerCommandInputOutputResyncPending() }
                enqueueControlKeyPress(spec)
            }
            TerminalPerformance.logMetric(
                "terminal_control_key", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "key=\(key)")
            return TerminalControlResponse(ok: true, message: "Sent key.")
        }

        private func controlResponseForClearScreenRequest(_ request: TerminalControlRequest, startedAt: Date = Date(), touchClient: Bool = true)
            -> TerminalControlResponse
        {
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            if touchClient, let clientID = request.clientID { touchClientLease(clientID) }
            if let rejection = ownerRequestRejection(for: request, commandName: "clear", startedAt: startedAt) { return rejection }
            let cleared = rendererHostStorage.clearScreenAndScrollback()
            if cleared { broadcastCurrentState(reason: TerminalRemoteSessionStateReason.clearScreen) }
            TerminalPerformance.logMetric(
                "terminal_control_clear_screen", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: cleared)
            return TerminalControlResponse(
                ok: cleared, message: cleared ? "Cleared terminal screen and scrollback." : "Unable to clear terminal screen.")
        }

        private func controlResponseForScrollRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "scroll", startedAt: startedAt) { return rejection }
            let horizontal = CGFloat(request.scrollHorizontal ?? 0)
            let vertical = CGFloat(request.scrollVertical ?? 0)
            let scrollMods = request.scrollMods ?? 0
            let pointerPosition: TerminalScrollPointerPosition?
            switch resolvedPointerPosition(x: request.scrollPointerX, y: request.scrollPointerY, mods: request.scrollPointerMods, command: "scroll") {
            case .resolved(let position): pointerPosition = position
            case .rejected(let response): return response
            }
            guard horizontal != 0 || vertical != 0 || scrollMods != 0 else {
                return TerminalControlResponse(ok: true, message: "Ignored zero scroll delta.")
            }
            guard horizontal != 0 || vertical != 0 else { return TerminalControlResponse(ok: true, message: "Ignored zero scroll delta.") }
            if let ownerClient = activeOwnerClient() {
                logMobileTakeoverPerformance(
                    name: "owner_input_activity", attributes: ["owner_kind": ownerClient.kind.rawValue, "interactive": "1", "input_kind": "scroll"])
            }
            let scrolled = rendererHostStorage.sendScroll(
                horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
            if scrolled { broadcastCurrentState(reason: TerminalRemoteSessionStateReason.scroll) }
            TerminalPerformance.logMetric(
                "terminal_control_scroll", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: scrolled)
            return TerminalControlResponse(ok: scrolled, message: scrolled ? "Scrolled terminal." : "Unable to scroll terminal.")
        }

        /// Resolves a control request's normalized pointer fields. Absent coordinates leave the daemon's
        /// pointer where it is; a partial or out-of-range pair is a malformed request, not a no-op.
        private enum PointerPositionResolution {
            case resolved(TerminalScrollPointerPosition?)
            case rejected(TerminalControlResponse)
        }

        private func resolvedPointerPosition(x: Double?, y: Double?, mods: UInt32?, command: String) -> PointerPositionResolution {
            switch (x, y, mods) {
            case (nil, nil, nil): return .resolved(nil)
            case (let x?, let y?, let mods):
                let position = TerminalScrollPointerPosition(x: x, y: y, mods: mods ?? 0)
                guard position.isValid else {
                    return .rejected(
                        TerminalControlResponse(ok: false, message: "Invalid terminal \(command) pointer position.", errorCode: .invalidArgument))
                }
                return .resolved(position)
            default:
                return .rejected(
                    TerminalControlResponse(
                        ok: false, message: "Terminal \(command) pointer coordinates must be provided together.", errorCode: .invalidArgument))
            }
        }

        private func controlResponseForMouseButtonRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "mouseButton", startedAt: startedAt) { return rejection }
            guard let button = request.mouseButton, let pressed = request.mousePressed else {
                return TerminalControlResponse(ok: false, message: "Missing mouse button.", errorCode: .invalidArgument)
            }
            guard button >= TerminalControlMouseButtonPayload.minimumButton, button <= TerminalControlMouseButtonPayload.maximumButton else {
                return TerminalControlResponse(ok: false, message: "Unsupported mouse button.", errorCode: .invalidArgument)
            }
            let pointerPosition: TerminalScrollPointerPosition?
            switch resolvedPointerPosition(
                x: request.mousePointerX, y: request.mousePointerY, mods: request.mousePointerMods, command: "mouse button")
            {
            case .resolved(let position): pointerPosition = position
            case .rejected(let response): return response
            }
            // A click carries its own position: unlike a scroll, which can legitimately ride whatever the
            // pointer was last moved to, a button with no position names no cell.
            guard let pointerPosition else {
                return TerminalControlResponse(ok: false, message: "Missing mouse pointer position.", errorCode: .invalidArgument)
            }
            if let ownerClient = activeOwnerClient() {
                logMobileTakeoverPerformance(
                    name: "owner_input_activity",
                    attributes: ["owner_kind": ownerClient.kind.rawValue, "interactive": "1", "input_kind": "mouse_button"])
            }
            // No state broadcast, unlike scroll: a button press changes nothing on its own. Whatever the
            // application draws in response arrives as terminal output and is broadcast with that output.
            let delivered = rendererHostStorage.sendMouseButton(button: button, pressed: pressed, pointerPosition: pointerPosition)
            TerminalPerformance.logMetric(
                "terminal_control_mouse_button", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: delivered)
            return TerminalControlResponse(ok: delivered, message: delivered ? "Delivered mouse button." : "Unable to deliver mouse button.")
        }

        private func controlResponseForTakeoverRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            guard let clientID = request.clientID else {
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            touchClientLease(clientID)
            flushPendingIncomingOutputForStateExport()
            // Mirrors the durable transfer's own precondition (`transferOwnership` throws `unknownClient` for
            // a client with no row) against the authoritative in-memory snapshot, so a takeover naming a
            // client this session never saw is still rejected on the spot rather than acked and then failed
            // by a queued write nobody is waiting on.
            guard currentAttachmentSnapshot()?.clients.contains(where: { $0.id == clientID }) == true else {
                TerminalPerformance.logMetric(
                    "terminal_control_takeover", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: String(describing: TerminalSessionPersistenceError.unknownClient(clientID)))
            }
            let previousOwnerClientID = activeOwnerClientID()
            // Apply the transfer to the in-memory snapshot synchronously so owner-gating enforcement (which
            // reads it) sees the new owner immediately rather than the pre-takeover owner until the deferred
            // broadcast Task below runs. The notification and re-broadcast stay deferred so the takeover ack
            // returns without waiting on the full-frame broadcast.
            applyOwnershipTransfer(to: clientID, transferredAt: TerminalSessionTimestamp.string(from: Date()))
            if previousOwnerClientID != clientID { advanceOwnerEpoch(reason: "takeover") }
            Task { @TerminalEngineActor [weak self] in
                guard let self else { return }
                self.postAttachmentStateDidChange()
                self.refreshRuntimeState(force: true)
            }
            TerminalPerformance.logMetric(
                "terminal_control_takeover", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
            return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
        }

        private func controlResponseForResizeRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "resize", startedAt: startedAt) { return rejection }
            if let rejection = staleResizeSerialRejection(for: request, startedAt: startedAt) { return rejection }
            guard let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 else {
                return TerminalControlResponse(ok: false, message: "Missing terminal size.", errorCode: .invalidArgument)
            }
            let currentSize = observedSurfaceSize()
            if currentSize?.columns == columns, currentSize?.rows == rows {
                trace(
                    "resize_request_noop client=\(request.clientID ?? "nil") columns=\(columns) rows=\(rows) runtime=\(traceSize(currentSize)) owner=\(activeOwnerClientID() ?? "nil")"
                )
                TerminalPerformance.logMetric(
                    "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "columns=\(columns) rows=\(rows) noop=1")
                recordAcceptedResizeSerial(from: request)
                return TerminalControlResponse(ok: true, message: "Terminal already matches the requested size.")
            }
            trace(
                "resize_request client=\(request.clientID ?? "nil") columns=\(columns) rows=\(rows) runtime_before=\(traceSize(currentSize)) owner=\(activeOwnerClientID() ?? "nil")"
            )
            // Armed BEFORE the surface resize, because ghostty can finish the reflow (and report it) while
            // `resizeCellGrid` is still measuring the surface; arming afterwards would let that report land
            // with nothing to match and lose the broadcast.
            pendingResizeBroadcastGrid = (columns: columns, rows: rows)
            let resized = rendererHostStorage.resizeCellGrid(columns: columns, rows: rows)
            refreshRuntimeState(force: true)
            trace("resize_request_result resized=\(resized ? 1 : 0) runtime_after=\(traceSize(observedSurfaceSize()))")
            TerminalPerformance.logMetric(
                "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: resized, detail: "columns=\(columns) rows=\(rows)")
            if resized {
                recordAcceptedResizeSerial(from: request)
            } else {
                // The surface never reached the requested grid, so no reflow will ever be reported for it.
                // Leaving the arm in place would let an unrelated later reflow that happens to land on this
                // grid fire a resize broadcast for a request that failed.
                pendingResizeBroadcastGrid = nil
            }
            return TerminalControlResponse(ok: resized, message: resized ? "Resized terminal." : "Unable to match the requested terminal size.")
        }

        /// Broadcasts the forced-full `resize` frame once ghostty reports the terminal reflowed to the grid
        /// the owner asked for.
        ///
        /// The broadcast cannot ride the resize control request itself: setting the surface size only queues
        /// the reflow onto ghostty's io thread, so a frame captured in that turn still carries the old grid
        /// while the payload's runtime state already reports the new one, and the pane vetoes it as
        /// `stale_resize_grid` and paints nothing until its throttled resync. Ghostty's host-managed resize
        /// callback runs after the terminal has been reflowed, so a frame captured from here carries the
        /// requested grid with the session's screen reflowed onto it.
        ///
        /// Only the grid of the LATEST accepted resize broadcasts. Two resizes in quick succession leave the
        /// second one armed, and the first one's report is dropped here rather than shipping a frame at a
        /// grid the pane has already moved off.
        ///
        /// The report's dimensions alone cannot decide that, because a rapid sequence can revisit a grid
        /// (80x24 → 79x24 → 80x24): the FIRST 80x24 report matches the arm the LAST 80x24 request left, and
        /// by the time this turn captures a frame the intervening 79x24 reflow may have applied. That ships
        /// a 79x24 frame under an 80x24 runtime state, which the pane vetoes as `stale_resize_grid`, and the
        /// genuine final report then finds nothing armed, leaving the blank pane this broadcast prevents.
        /// Nothing in the report distinguishes the two: ghostty's callback carries dimensions only, and one
        /// resize request can produce any number of reports (`resizeCellGrid` measures and rescales in a
        /// loop), so counting them cannot identify the last one either.
        ///
        /// So the frame is captured here, and the one capture both decides and ships: it takes the renderer
        /// mutex the reflow ran under and is therefore the only authority on the reflowed terminal's grid
        /// (the surface size leads the reflow, which is what makes it useless here), and the same capture is
        /// handed to the broadcast as the screen state to export. Verifying one capture and then letting the
        /// broadcast take its own would reopen the race it closes, since a queued reflow can apply in the gap
        /// between them and ship a grid-B frame under an arm cleared on grid A. A capture that does not carry
        /// the armed grid leaves the arm in place for the report that will, and costs a later delta nothing
        /// but its scroll-rect shortcut.
        private func handleTerminalGridReflow(columns: Int, rows: Int) {
            guard let pending = pendingResizeBroadcastGrid, pending.columns == columns, pending.rows == rows else { return }
            let capturedScreenState = captureLiveSessionScreenState()
            let capturedGrid = capturedScreenState.snapshot.map { (columns: $0.columns, rows: $0.rows) }
            guard let capturedGrid, capturedGrid.columns == columns, capturedGrid.rows == rows else {
                trace("resize_reflow_capture_skip columns=\(columns) rows=\(rows) captured=\(traceSize(capturedGrid))")
                return
            }
            pendingResizeBroadcastGrid = nil
            trace("resize_reflow_broadcast columns=\(columns) rows=\(rows)")
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.resize, preCapturedScreenState: capturedScreenState)
        }

        private func startRuntimeStateTimer() {
            runtimeStateTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: TerminalEngineActor.shared.queue)
            timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
            timer.setEventHandler { [weak self] in
                // Fires on the engine queue (the timer's queue), so assume the engine isolation.
                TerminalEngineActor.assumeIsolated {
                    guard let self, self.started else { return }
                    self.expireStaleRemoteClientsIfNeeded()
                    self.refreshRuntimeState(force: false)
                    self.flushPendingOverviewSignalForMetadata()
                }
            }
            timer.resume()
            runtimeStateTimer = timer
        }

        private func refreshRuntimeState(force: Bool) {
            guard !didTerminateCurrentRun else { return }
            guard started || !currentRuntimeStateIsExited() else { return }
            let now = Date()
            let liveChildPID = rendererHostStorage.childPID()
            if let liveChildPID { lastKnownChildPID = liveChildPID }
            let childPID = liveChildPID ?? lastKnownChildPID
            let foregroundPID = observedForegroundPID()
            if started, liveChildPID == nil, let lastKnownChildPID, !hasActiveAttachments(), !Self.isProcessAlive(pid: lastKnownChildPID) {
                handleSessionClosed()
                return
            }
            let foregroundProcess = foregroundPID.flatMap(foregroundProcessResolver)
            let foregroundAgent = foregroundProcess.flatMap(TerminalForegroundProcessInspector.classify)
            // Refresh the cached live cwd here (off the per-render broadcast path) so effectiveWorkingDirectory
            // publishes the process's real directory even when the shell never emits an OSC 7 PWD report.
            if let liveWorkingDirectory = Self.liveProcessWorkingDirectory(foregroundPID: foregroundPID, childPID: childPID) {
                lastObservedProcessWorkingDirectory = liveWorkingDirectory
            }
            let state = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(),
                childPID: childPID ?? lastKnownChildPID, state: .running, updatedAt: TerminalSessionTimestamp.string(from: now),
                // The raw reported title, not `effectiveTitle`: the runtime state records what the program
                // said, and folding the launch title in would leave every reader unable to tell an untitled
                // session from one that titled itself after its own name.
                title: currentTitle, workingDirectory: effectiveWorkingDirectory, columns: observedSurfaceSize()?.columns,
                rows: observedSurfaceSize()?.rows, foregroundPID: foregroundProcess?.pid, foregroundExecutablePath: foregroundProcess?.executablePath,
                foregroundExecutableName: foregroundProcess?.executableName, foregroundArgv: foregroundProcess?.argv,
                foregroundDetectedAgentKind: foregroundAgent?.detectedAgentKind, foregroundDisplayLabel: foregroundAgent?.displayLabel,
                foregroundDisplayCommand: foregroundAgent?.displayCommand, bellAt: currentBellAt,
                // Published alongside the foreground classification because the two answer different halves
                // of "is this agent ready for its prompt?": the classification says the agent process is
                // there, this says its TUI has taken the terminal over. Agent-prompt delivery waits for both.
                bracketedPasteActive: rendererHostStorage.bracketedPasteActive())
            // Advance the in-memory authoritative state first so broadcasts show live truth immediately,
            // independent of when (or whether) the enqueued durable write lands.
            latestRuntimeState = state
            let shouldPersist = force || shouldPersistRuntimeState(state)
            guard shouldPersist else { return }
            // Persist off the engine. The durable marker advances and the change notification fires only when
            // the write succeeds (see `enqueueRuntimeStateWrite`/`markRuntimeStatePersisted`), so a failed
            // write retries next cycle and the overview never observes a change the DB has not committed.
            enqueueRuntimeStateWrite(state, at: now)
        }

        private func currentRuntimeStateIsExited() -> Bool {
            if latestRuntimeState?.state == .exited { return true }
            return (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.state == .exited
        }

        /// Expires lease-lapsed remote clients. The liveness READS stay inline on the engine (WAL reads never
        /// block on a competing writer); only the WRITES move off it. The DB read reflects committed leases
        /// only, so the candidate set it returns is filtered against the in-memory heartbeat map (a client
        /// that heartbeated since its DB row was read is spared, even if its coalesced durable touch has not
        /// yet committed under write contention) and against the already-enqueued expiry set (so repeated
        /// ticks never enqueue duplicate detach/transfer writes for the same not-yet-committed decision). The
        /// post-expiry owner state is derived in memory from the pre-expiry attachments — never by re-reading
        /// the DB, which would still show the not-yet-committed detach — and the durable detach +
        /// ownership-transfer writes are enqueued (in order) onto the persistence queue so a burst of
        /// expiries can never block the engine on the DB lock.
        ///
        /// This runs once a second for every live session, so it first asks the in-memory attachment
        /// snapshot whether the session has any client a lease could expire at all, and does nothing when it
        /// does not. That is the overwhelming majority of sessions and of ticks: a local window client is
        /// lease-exempt and a session nobody has attached to has no clients. The cache is authoritative for
        /// this question by the same single-writer invariant that lets owner gating read it (see
        /// `cachedAttachmentSnapshot`) — a lease-governed client can only appear through an attach on this
        /// core, which invalidates the cache — so the gate can only skip a tick that had nothing to expire.
        ///
        /// The gate also requires `expiredRemoteClientIDs` to be empty. A client already marked expired here
        /// is, by construction, no longer in `hasLeaseGovernedAttachedClient()`'s view — `markClientsExpiredInCache`
        /// optimistically detaches it in the same cache this gate reads, before its durable detach write has
        /// committed. Without this second condition, the very first tick after an expiry decision would see
        /// no lease-governed attached client and take the fast path below, which clears `expiredRemoteClientIDs`.
        /// That erases the pending marker `isClientDurablyDisconnected` depends on to veto a rescuing heartbeat
        /// (see its doc comment) while the expiry write can still be sitting in the queue — e.g. behind a
        /// contended SQLite write lock — so a heartbeat arriving in that window would be rejected instead of
        /// vetoing the pending detach, disconnecting a client that was actually still alive. Keeping the ids
        /// around costs nothing while nothing is pending; it only routes ticks with an in-flight decision
        /// through the full (still cheap) logic below, which already ignores ids it re-derives as no longer
        /// stale.
        @discardableResult func expireStaleRemoteClientsIfNeeded(now: Date = Date()) -> [String] {
            let cutoff = now.addingTimeInterval(-TerminalSessionPersistence.remoteClientLeaseInterval)
            // Keep only fresh heartbeats: an entry older than the cutoff can no longer protect a client and
            // would otherwise accumulate for the daemon's lifetime.
            latestRemoteClientHeartbeat = latestRemoteClientHeartbeat.filter { $0.value >= cutoff }
            guard hasLeaseGovernedAttachedClient() || !expiredRemoteClientIDs.isEmpty else {
                expiredRemoteClientIDs.removeAll(keepingCapacity: true)
                return []
            }
            guard let databaseStaleClients = try? TerminalSessionPersistence.staleRemoteClients(paths: paths, now: now), !databaseStaleClients.isEmpty
            else {
                expiredRemoteClientIDs.removeAll(keepingCapacity: true)
                return []
            }
            let databaseStaleClientIDs = databaseStaleClients.map(\.clientID)
            // The `lease_refreshed_at` each stale row currently carries, keyed by client id. Carried into the
            // queued `expireClients` transaction so its per-client detach is a compare-and-set: a client whose
            // lease moved between this decision and the commit is skipped rather than re-disconnected.
            let observedLeaseByClientID = Dictionary(
                databaseStaleClients.map { ($0.clientID, $0.leaseRefreshedAt) }, uniquingKeysWith: { first, _ in first })
            // A client that reconnected (fresh DB lease) or whose durable detach has committed drops out of
            // the DB candidate set; forget it so a later genuine lapse can be expired again.
            expiredRemoteClientIDs.formIntersection(databaseStaleClientIDs)
            // The DB read reflects committed leases only. Honor the in-memory heartbeat map (updated
            // synchronously on the engine) so a client whose durable lease touch has not yet committed under
            // write contention is not expired off its stale DB row, and skip clients whose expiry was already
            // enqueued on a prior tick so repeated ticks never enqueue duplicate detach/transfer writes.
            let staleClientIDs = databaseStaleClientIDs.filter { clientID in
                if expiredRemoteClientIDs.contains(clientID) { return false }
                if let heartbeat = latestRemoteClientHeartbeat[clientID], heartbeat >= cutoff { return false }
                return true
            }
            guard !staleClientIDs.isEmpty else { return [] }
            expiredRemoteClientIDs.formUnion(staleClientIDs)
            for clientID in staleClientIDs {
                latestRemoteClientHeartbeat[clientID] = nil
                // The queued expiry rewrites these clients' durable rows; drop their coalesced-write records
                // so a client that comes back (or vetoes its own expiry by heartbeating) writes its lease
                // rather than resting on a record the expiry invalidated.
                leaseTouchCoalescer.forget(clientID: clientID)
            }
            // In-memory, not a DB read: under write-behind the DB lags the authority by whatever sits in the
            // persistence queue. If a viewer has taken over ownership in memory while its transfer write is
            // still queued, a DB read here would still see the stale prior owner and no remaining owner, and
            // the derivation below would transfer ownership to a local window client and advance the owner
            // epoch, stomping the acknowledged takeover the live authority already committed to memory.
            let activeAttachmentsBeforeExpiry = currentActiveAttachments()
            let staleClientIDSet = Set(staleClientIDs)
            let detachedClientWasOwner = activeAttachmentsBeforeExpiry.contains {
                $0.mode == .owner && $0.detachedAt == nil && staleClientIDSet.contains($0.clientID)
            }
            let detachedAt = TerminalSessionTimestamp.string(from: now)
            let sessionID = launchConfiguration.sessionID
            let paths = paths
            // Post-expiry owner derived from the pre-expiry in-memory snapshot (the enqueued detach has not
            // committed yet, and the DB itself may still be behind the in-memory authority by whatever the
            // persistence queue has not yet applied: see the comment on `activeAttachmentsBeforeExpiry` above).
            var remainingOwnerClientID = activeAttachmentsBeforeExpiry.first {
                $0.mode == .owner && $0.detachedAt == nil && !staleClientIDSet.contains($0.clientID)
            }?.clientID
            let ownershipTransferTarget: String?
            if detachedClientWasOwner, remainingOwnerClientID == nil, let localOwnerClientID = activeLocalWindowClientID(excluding: "") {
                ownershipTransferTarget = localOwnerClientID
                remainingOwnerClientID = localOwnerClientID
                advanceOwnerEpoch(reason: "stale_client_transfer")
            } else {
                ownershipTransferTarget = nil
            }
            // Carry each stale client's observed lease into the queued transaction so its detach is a
            // compare-and-set. `observedLeaseByClientID` always contains every id in `staleClientIDs` (both
            // derive from the same DB read), so the compactMap never drops a client.
            let expiringClients: [TerminalSessionPersistence.StaleRemoteClient] = staleClientIDs.compactMap { clientID in
                guard let leaseRefreshedAt = observedLeaseByClientID[clientID] else { return nil }
                return .init(clientID: clientID, leaseRefreshedAt: leaseRefreshedAt)
            }
            // Snapshot each candidate's heartbeat generation at decision time. The queued `expireClients` re-reads
            // the generation inside its write transaction and skips (never detaches) any candidate that
            // heartbeated after this decision — its durable lease touch is queued behind the expiry, so the
            // committed lease row still looks stale (finding R7-2).
            let heartbeatGate = heartbeatGenerationGate
            let observedHeartbeatGenerations = heartbeatGate.snapshot(forClientIDs: staleClientIDs)
            // Enqueue the detaches and the (optional) ownership transfer as ONE atomic transaction
            // (`expireClients`) so a partial commit can never leave durable state ownerless. Two distinct
            // post-write signals hop back to the engine:
            //   - THROWN error: a genuine write failure that rolled the transaction back untouched. Un-mark the
            //     clients so the next 1s tick re-derives the IDENTICAL decision from the still-stale rows and
            //     retries the whole expiry (`rearmStaleClientExpiryAfterWriteFailure`).
            //   - `.superseded`: the transaction COMMITTED whatever was still valid, but a synchronous
            //     engine-side write (takeover, detach, re-attach) moved durable state out from under the
            //     decision, so some/all of it was skipped. Retrying the SAME decision would be wrong — instead
            //     reconcile: un-mark and reseed the optimistic cache from committed truth
            //     (`reconcileStaleClientExpiryAfterSupersededDecision`), letting the next tick derive a FRESH
            //     decision. Keeping these paths separate is load-bearing: routing supersession through the
            //     failure retry would re-apply a stale decision and could stomp a legitimate new owner.
            enqueuePersistenceWrite { [weak self] databasePath in
                do {
                    let outcome = try TerminalSessionPersistence.expireClients(
                        expiringClients, transferOwnershipTo: ownershipTransferTarget, sessionID: sessionID, paths: paths, detachedAt: detachedAt,
                        heartbeatGate: heartbeatGate, observedHeartbeatGenerations: observedHeartbeatGenerations, databasePath: databasePath)
                    if outcome == .superseded {
                        Task { @TerminalEngineActor in self?.reconcileStaleClientExpiryAfterSupersededDecision(clientIDs: staleClientIDs) }
                    }
                } catch {
                    let failureDescription = String(describing: error)
                    Task { @TerminalEngineActor in self?.rearmStaleClientExpiryAfterWriteFailure(clientIDs: staleClientIDs, error: failureDescription)
                    }
                }
            }
            // Mirror the atomic write into the in-memory cache BEFORE broadcasting, so the payload advertises
            // the post-expiry attachment state (expired clients gone, transfer target the owner) without
            // reading the not-yet-committed durable mirror. On write failure
            // `rearmStaleClientExpiryAfterWriteFailure` invalidates the cache so it reseeds from the
            // (rolled-back, still pre-expiry) durable state — keeping cache and DB coherent for the retry.
            markClientsExpiredInCache(clientIDs: staleClientIDs, newOwnerClientID: ownershipTransferTarget, detachedAt: detachedAt)
            if Self.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: remainingOwnerClientID) {
                rendererHostStorage.setSurfaceFocused(false)
            }
            if remainingOwnerClientID == nil, rendererHostStorage.hasRenderableSurface() { rendererHostStorage.releaseRendererSurface() }
            postAttachmentStateDidChange()
            refreshRuntimeState(force: true)
            return staleClientIDs
        }

        /// Re-arms stale-client expiry after its atomic detach/transfer transaction failed: un-marks the client
        /// IDs so the next timer tick re-derives them from the still-stale DB rows and re-enqueues the expiry.
        /// Also invalidates the attachment-snapshot cache, which `expireStaleRemoteClientsIfNeeded` optimistically
        /// mutated to reflect the expiry as if it had committed: the transaction rolled back untouched, so
        /// reseeding from the true (pre-expiry) durable state restores coherence between cache and DB for the
        /// retry. Called only from the persistence queue's engine hop on write failure. Rebroadcasts after the
        /// invalidate so subscribers that already received the optimistic post-expiry payload converge back to
        /// the (rolled-back) committed truth instead of keeping the wrong advertised state until an unrelated change.
        private func rearmStaleClientExpiryAfterWriteFailure(clientIDs: [String], error: String) {
            trace("stale_client_expiry_write_failed clients=\(clientIDs) error=\(error)")
            expiredRemoteClientIDs.subtract(clientIDs)
            invalidateAttachmentSnapshotCache()
            postAttachmentStateDidChange()
        }

        /// Reconciles the optimistic expiry cache after `expireClients` reported `.superseded`: the durable world
        /// moved out from under the decision (a client refreshed its lease, a different client took ownership via
        /// takeover, or the transfer target detached in the race window). Distinct from the write-FAILURE path
        /// (`rearmStaleClientExpiryAfterWriteFailure`): the transaction did NOT fail and did NOT roll back — it
        /// committed whatever remained valid. Retrying the SAME decision would re-apply stale intent (and could
        /// stomp a legitimate new owner), so instead un-mark these clients — letting the next tick derive a FRESH
        /// decision from current durable rows — and reseed the optimistically-mutated cache from committed truth.
        /// Called only from the persistence queue's engine hop on the `.superseded` signal. Rebroadcasts after the
        /// invalidate so subscribers that already received the optimistic post-expiry payload converge back to
        /// the (partially different) committed truth instead of keeping the wrong advertised state until an
        /// unrelated change.
        private func reconcileStaleClientExpiryAfterSupersededDecision(clientIDs: [String]) {
            trace("stale_client_expiry_superseded clients=\(clientIDs)")
            expiredRemoteClientIDs.subtract(clientIDs)
            invalidateAttachmentSnapshotCache()
            postAttachmentStateDidChange()
        }

        @discardableResult private func appendOutput(_ data: Data, interactiveResync: Bool = false, shouldBroadcastState: Bool = true) -> Bool {
            guard !didTerminateCurrentRun else { return false }
            let startedAt = Date()
            do {
                let outputHandle = try ensureOutputHandle()
                try outputHandle.write(contentsOf: data)
                let endOffset = try outputHandle.seekToEnd()
                // Head-truncate the durable transcript once it grows past the live-transcript bound so a
                // long-running session stops accumulating disk without bound. This only snapshots offsets
                // on the engine; the trim's expensive work runs off it and swaps in the bounded file on a
                // later engine turn. The preamble grid only affects cursor placement (mode capture is
                // size-independent), so an unobserved surface size falls back to the universal 80x24
                // default rather than skipping the trim and letting the transcript grow unbounded.
                let terminalSize = observedSurfaceSize() ?? (columns: 80, rows: 24)
                transcriptTrim.trimIfNeeded(currentEndOffset: endOffset, columns: terminalSize.columns, rows: terminalSize.rows)
                requestSurfaceRefreshAction()
                GhosttyEmbeddedAppService.shared.tick()
                postOutputDidChange(
                    data: data, outputEndByteOffset: Self.clampedInt(endOffset), interactiveResync: interactiveResync,
                    shouldBroadcastState: shouldBroadcastState)
                TerminalPerformance.logMetric(
                    "terminal_output_write", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "bytes=\(data.count)")
                if !didLogFirstOutput, !data.isEmpty {
                    didLogFirstOutput = true
                    if let sessionStartedAt {
                        TerminalPerformance.logMetric(
                            "terminal_first_output", target: "session=\(launchConfiguration.sessionID)",
                            elapsedMS: TerminalPerformance.elapsedMS(since: sessionStartedAt), success: true, detail: "bytes=\(data.count)")
                    }
                }
                return true
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_output_write", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "bytes=\(data.count)")
                fputs("spaces: ghostty output write failed: \(error)\n", stderr)
                return false
            }
        }

        /// Keeps the renderer mutation replayable. The marker enters the same locked
        /// coalescing buffer as PTY callbacks, preserving its byte order with concurrent
        /// output before the buffer is drained synchronously.
        private func clearScreenAndScrollback() -> Bool {
            guard sessionDriver.clearScreenAndScrollback() else { return false }
            _ = incomingOutputBuffer.append(GhosttyTerminalTranscriptMutation.clearScreenAndScrollback, interactive: false)
            let outputThroughClear = incomingOutputBuffer.drain()
            return appendOutput(outputThroughClear.data, interactiveResync: outputThroughClear.isInteractive, shouldBroadcastState: false)
        }

        @discardableResult private func ensureOutputHandle() throws -> FileHandle {
            if let outputHandle { return outputHandle }
            FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
            let createdHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            try createdHandle.seekToEnd()
            outputHandle = createdHandle
            return createdHandle
        }

        /// Opens the durable output handle for append WITHOUT truncating any existing
        /// transcript, for the handoff resume paths. `resumeFromHandoff` replays output.log
        /// to rebuild the screen and `resumeInPlaceAfterFailedExec` continues the same
        /// transcript, so both must keep the existing bytes — unlike `ensureOutputHandle`,
        /// whose `createFile(contents: nil)` recreates (and thus empties) the log for a
        /// fresh start. Creating the file only when absent leaves any existing history in
        /// place; `seekToEnd` positions the handle to append and re-derive the byte count.
        private func openOutputHandlePreservingTranscript() throws {
            guard outputHandle == nil else { return }
            if !FileManager.default.fileExists(atPath: paths.outputPath) { FileManager.default.createFile(atPath: paths.outputPath, contents: nil) }
            if !FileManager.default.fileExists(atPath: paths.serviceLogPath) {
                FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            try handle.seekToEnd()
            outputHandle = handle
        }

        private func transcriptByteCount() throws -> UInt64 {
            guard FileManager.default.fileExists(atPath: paths.outputPath) else { return 0 }
            let attributes = try FileManager.default.attributesOfItem(atPath: paths.outputPath)
            guard let size = attributes[.size] as? NSNumber else { throw POSIXError(.EIO) }
            return size.uint64Value
        }

        func applyActionEvent(_ event: GhosttyActionEvent) {
            switch event {
            case .setTitle(let title):
                // The reported title advances the in-memory state — the authority live subscribers and the
                // overview read — but does not force the durable mirror. An agent TUI animating a spinner in
                // its title sets one here several times a second, and forcing a write per set committed a
                // SQLite transaction per animation frame. `title` is out of `runtimeStateSignature`, so this
                // unforced refresh writes only if some other field moved too. See `shouldPersistRuntimeState`.
                currentTitle = Self.normalizedSessionMetadataValue(title)
                postSessionMetadataDidChange()
                refreshRuntimeState(force: false)
                return
            case .setWorkingDirectory(let path): currentWorkingDirectory = Self.normalizedSessionMetadataValue(path)
            case .ringBell:
                // A bell changes no metadata a title is derived from, so it skips the metadata
                // announcement below and only forces the runtime-state write the clients read the
                // timestamp from. `ring` returning nil is the coalescing window absorbing this bell.
                //
                // A daemon handoff replays the transcript through this same surface, so every bell the
                // scrollback ever carried is re-emitted here and stamps a fresh timestamp. The window
                // collapses that whole replay into a single alert, which is the bound accepted for it:
                // GhosttyKit delivers surface actions asynchronously, so nothing at this layer can tell
                // a replayed bell from a live one.
                //
                // One timestamp per session is the alert model: a later bell REPLACES the identity, so a
                // bell a client suppresses as watched can supersede an earlier unwatched one that never
                // alerted (two rings over 30s apart straddling a client's watch window with no refresh
                // between). Accepted: closing it means per-session bell history on the wire, and the
                // user is already looking at this terminal when the superseding bell rings.
                guard let bellAt = bellCoalescer.ring() else { return }
                currentBellAt = TerminalSessionTimestamp.string(from: bellAt)
                refreshRuntimeState(force: true)
                return
            case .openURL:
                // Dropped: the daemon never opens a URL. It runs as a launchd GUI-session agent, so an
                // open here would launch this host's browser for input that may have arrived from a
                // phone or another Mac, which is not where the user is looking. Every client mirrors
                // the session locally and runs its own link detection, so the link opens on the device
                // the user activated it from. `action_cb` still reports the action as handled, which
                // keeps Ghostty's own shell-out fallback from opening it here instead.
                return
            case .mouseOverLink, .startSearch, .endSearch, .searchTotal, .searchSelected: return
            }
            postSessionMetadataDidChange()
            refreshRuntimeState(force: true)
        }

        /// Sends a program's OSC 52 copy to the client that owns the session, so the text lands on the
        /// machine the user is typing on rather than on this daemon's host.
        ///
        /// Dropped when nothing owns the session: a copy is a one-shot with no destination then, and
        /// queueing it for a future owner would paste text the user copied in a session they had walked
        /// away from. Replayed writes never reach here — the driver's replay bracket refuses them at
        /// the runtime callback, where a replayed write is still distinguishable from a live one.
        ///
        /// The copy rides the state stream and touches no runtime state, so this deliberately does not
        /// force a runtime-state write the way the metadata and bell paths do.
        private func forwardClipboardWriteToOwner(_ text: String) {
            guard let ownerClientID = activeOwnerClientID() else { return }
            broadcastCurrentState(
                reason: TerminalRemoteSessionStateReason.clipboardWrite,
                clipboardWrite: TerminalClipboardWritePayload(targetClientID: ownerClientID, text: text))
        }

        func applySessionStateChange(_ change: GhosttyEmbeddedSessionStateChange) {
            lastSessionStateRevision = max(lastSessionStateRevision ?? change.revision, change.revision)
            lastSessionStateFlags = change.flags
            if change.flags.contains(.screen) { lastScreenStateRevision = max(lastScreenStateRevision ?? change.revision, change.revision) }
            if change.flags.contains(.screen) {
                requestSurfaceRefreshAction()
                logMobileTakeoverPerformance(
                    name: "state_change", attributes: ["revision": String(change.revision), "flags": String(change.flags.rawValue)])
                scheduleScreenStateChangeBroadcast(revision: change.revision)
            }
            var titleChanged = false
            var workingDirectoryChanged = false

            if change.flags.contains(.title) {
                let nextTitle = Self.normalizedSessionMetadataValue(change.title)
                if currentTitle != nextTitle {
                    currentTitle = nextTitle
                    titleChanged = true
                }
            }

            if change.flags.contains(.workingDirectory) {
                let nextWorkingDirectory = Self.normalizedSessionMetadataValue(change.workingDirectory)
                if currentWorkingDirectory != nextWorkingDirectory {
                    currentWorkingDirectory = nextWorkingDirectory
                    workingDirectoryChanged = true
                }
            }

            if titleChanged || workingDirectoryChanged { postSessionMetadataDidChange() }

            if change.flags.contains(.foregroundProcess) { _ = observedChildPID() }
            if change.flags.contains(.size), let size = rendererHostStorage.surfaceCellSize() { lastKnownSurfaceSize = size }

            // A title-only change refreshes the in-memory state (which is what live subscribers and the
            // overview read) but does not force the durable mirror: agent TUIs animate a spinner in their
            // title several times a second, and forcing a write per frame committed a SQLite transaction per
            // frame. `title` is out of `runtimeStateSignature`, so the unforced refresh persists only if some
            // other field also moved, and the row still picks the title up on the next write for any reason
            // and on the exited-state write at termination.
            if workingDirectoryChanged || !change.flags.intersection(.runtimeState).isEmpty {
                refreshRuntimeState(force: true)
            } else if titleChanged {
                refreshRuntimeState(force: false)
            }
        }

        private func observedChildPID() -> Int32? {
            if let childPID = rendererHostStorage.childPID() {
                lastKnownChildPID = childPID
                return childPID
            }
            return lastKnownChildPID
        }

        private func observedForegroundPID() -> Int32? { foregroundPIDOverrideForTesting ?? rendererHostStorage.foregroundPID() }

        private static func liveProcessWorkingDirectory(foregroundPID: Int32?, childPID: Int32?) -> String? {
            if let foregroundPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: foregroundPID) { return cwd }
            if let childPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: childPID) { return cwd }
            return nil
        }

        private func observedSurfaceSize() -> (columns: Int, rows: Int)? {
            if let size = rendererHostStorage.surfaceCellSize() {
                lastKnownSurfaceSize = size
                return size
            }
            return lastKnownSurfaceSize
        }

        /// Notifies and re-broadcasts after an attachment-row mutation. It deliberately does NOT touch the
        /// in-memory snapshot: every mutation has already been applied there (that snapshot is the authority),
        /// and its durable mirror is only enqueued — reseeding from disk here would re-advertise pre-mutation
        /// rows, e.g. a dead client as owner right after a stale-client expiry.
        private func postAttachmentStateDidChange() {
            TerminalSessionNotification.post(.spacesTerminalAttachmentStateDidChange, sessionID: launchConfiguration.sessionID)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.attachmentState)
        }

        /// Set when a metadata change (title, working directory) still owes overview subscribers a rebuild,
        /// cleared by the 1 Hz tick that posts it. Overview pushes used to ride the durable runtime-state
        /// write, so dropping `title` from the persist signature would otherwise leave the sidebar showing a
        /// stale title until some unrelated field changed. Posting per change instead would push an overview
        /// rebuild — and a cross-process distributed notification — per spinner frame, which is the cost this
        /// whole change exists to remove, so the signal is coalesced onto the tick every live session already
        /// runs. Subscribers converge within a second; live subscribers are unaffected either way, since
        /// `broadcastCurrentState` below still goes out on every change.
        private var owesOverviewSignalForMetadata = false

        private func postSessionMetadataDidChange() {
            TerminalSessionNotification.post(.spacesTerminalSessionMetadataDidChange, sessionID: launchConfiguration.sessionID)
            owesOverviewSignalForMetadata = true
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.sessionMetadata)
        }

        /// Posts the coalesced metadata overview signal, if one is owed. Driven by the 1 Hz tick. A session
        /// that ends with a change still owed needs nothing here: termination posts an unconditional
        /// `TerminalOverviewSignal` of its own once its exited-state write commits.
        private func flushPendingOverviewSignalForMetadata() {
            guard owesOverviewSignalForMetadata else { return }
            owesOverviewSignalForMetadata = false
            TerminalOverviewSignal.post()
        }

        private func postRuntimeStateDidChange() {
            TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: launchConfiguration.sessionID)
            // This post covers any metadata change still owed, so the tick does not send a second one.
            owesOverviewSignalForMetadata = false
            TerminalOverviewSignal.post()
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.runtimeState)
        }

        private func postOutputDidChange(data: Data, outputEndByteOffset: Int?, interactiveResync: Bool = false, shouldBroadcastState: Bool = true) {
            TerminalSessionNotification.post(.spacesTerminalOutputDidChange, sessionID: launchConfiguration.sessionID)
            inputOutputResyncScheduler.handleOutputDidChange(interactive: interactiveResync)
            guard shouldBroadcastState else { return }
            broadcastCurrentState(
                reason: TerminalRemoteSessionStateReason.output, outputByteCount: data.count, outputEndByteOffset: outputEndByteOffset)
        }

        private func handleOwnerInputActivity(byteCount: Int) {
            guard let ownerClient = activeOwnerClient() else { return }
            let interactiveInput = byteCount > 0 && byteCount <= Self.interactiveInputMaximumByteCount
            logMobileTakeoverPerformance(
                name: "owner_input_activity", count: byteCount,
                attributes: ["owner_kind": ownerClient.kind.rawValue, "interactive": interactiveInput ? "1" : "0"])
            if interactiveInput { interactiveOutputGate.markActivity(windowNanoseconds: Self.interactiveInputFlushWindowNanoseconds) }
            if ownerClient.kind == .localWindow {
                inputOutputResyncScheduler.noteLocalOwnerInput()
                return
            }
            scheduleInputStateBroadcast()
        }

        private func markLocalOwnerCommandInputOutputResyncPending() {
            guard activeOwnerClient()?.kind == .localWindow else { return }
            inputOutputResyncScheduler.noteLocalOwnerCommand()
        }

        private func scheduleInputStateBroadcast() {
            inputStateBroadcastCoalescer.schedule { [weak self] in
                guard let self else { return }
                self.requestSurfaceRefreshAction()
                GhosttyEmbeddedAppService.shared.tick()
                self.broadcastCurrentState(reason: TerminalRemoteSessionStateReason.input)
            }
        }

        private func scheduleScreenStateChangeBroadcast(revision: UInt64) {
            guard activeOwnerClient() != nil else { return }
            pendingScreenStateChangeBroadcastRevision = max(pendingScreenStateChangeBroadcastRevision ?? revision, revision)
            screenStateChangeBroadcastCoalescer.schedule { [weak self] in
                guard let self else { return }
                let revision = self.pendingScreenStateChangeBroadcastRevision
                self.pendingScreenStateChangeBroadcastRevision = nil
                guard self.screenStateRevisionNeedsExport(revision) else { return }
                self.requestSurfaceRefreshAction()
                GhosttyEmbeddedAppService.shared.tick()
                guard self.screenStateRevisionNeedsExport(revision) else { return }
                self.broadcastCurrentState(reason: TerminalRemoteSessionStateReason.stateChange)
            }
        }

        private func screenStateRevisionNeedsExport(_ revision: UInt64?) -> Bool {
            guard let revision else { return true }
            guard let lastExportedScreenStateRevision else { return true }
            return lastExportedScreenStateRevision < revision
        }

        private func nowISO8601() -> String { TerminalSessionTimestamp.string(from: Date()) }

        private static func clampedInt(_ value: UInt64) -> Int {
            guard value <= UInt64(Int.max) else { return Int.max }
            return Int(value)
        }

        private static func normalizedSessionMetadataValue(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func clientForAttachLease(_ client: TerminalClient, attachedAt: String) -> TerminalClient {
            guard client.kind != .localWindow else { return client }
            return TerminalClient(id: client.id, kind: client.kind, identity: client.identity, connectedAt: attachedAt, disconnectedAt: nil)
        }

        private func activeOwnerClient() -> TerminalClient? {
            guard isRuntimeInteractiveForControl() else { return nil }
            guard let snapshot = currentAttachmentSnapshot(),
                let attachment = snapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })
            else { return nil }
            return snapshot.clients.first(where: { $0.id == attachment.clientID })
        }

        /// The session's attachment snapshot, served from `cachedAttachmentSnapshot` and read from disk only
        /// on a cache miss. See `cachedAttachmentSnapshot` for the single-writer invariant that makes serving
        /// the cache on the hot path sound. A successful reseed replays `pendingAttachmentMutations` on top of
        /// the rows it read before caching the result: those transforms were already acknowledged to their
        /// callers and their durable writes are still queued, so the reseed's rows can predate them, and
        /// replaying is what makes the result equal the acknowledged state rather than a stale one.
        ///
        /// Accepted risk: the replay does not distinguish a pending transform whose own durable write later
        /// exhausted its retries, so a reseed triggered by that write's failure re-applies it anyway. Reaching
        /// that state needs a database that fails a read (the only way a transform lands in the pending list)
        /// and then keeps failing the same mutation's write for its full retry span before recovering — and
        /// even then memory keeps exactly what the caller was acknowledged, the very next reseed converges on
        /// committed truth (pending is emptied here), and a daemon restart rebuilds attachments from live
        /// clients. Threading per-write outcome tokens through both cores to exclude that one transform is
        /// complexity this corner does not justify.
        private func currentAttachmentSnapshot() -> TerminalSessionAttachmentSnapshot? {
            if let cachedAttachmentSnapshot { return cachedAttachmentSnapshot }
            guard !forceAttachmentSnapshotReseedFailureForTesting, var snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
            else { return nil }
            for transform in pendingAttachmentMutations { snapshot = transform(snapshot) }
            pendingAttachmentMutations.removeAll()
            cachedAttachmentSnapshot = snapshot
            return snapshot
        }

        /// Active (non-detached) attachments served from `currentAttachmentSnapshot()` — the in-memory cache,
        /// reseeded from disk on a miss. Every owner-gating enforcement read (`isOwner`, `activeOwnerClientID`,
        /// `hasActiveAttachments`, attach/detach mode-change checks) resolves through this so gating agrees with
        /// the cache the broadcasts advertise. See `cachedAttachmentSnapshot`.
        /// The attachment snapshot a broadcast carries: `currentAttachmentSnapshot()` reduced by
        /// `TerminalSessionAttachmentSnapshot.liveWireProjection`, served from `cachedLiveWireAttachmentSnapshot`.
        private func currentLiveWireAttachmentSnapshot() -> TerminalSessionAttachmentSnapshot? {
            if let cachedLiveWireAttachmentSnapshot { return cachedLiveWireAttachmentSnapshot }
            // Read the full snapshot first: a cache miss there assigns `cachedAttachmentSnapshot`, whose
            // `didSet` clears the derived cache, so the projection must be stored after that call returns.
            guard let snapshot = currentAttachmentSnapshot() else { return nil }
            let projection = snapshot.liveWireProjection()
            cachedLiveWireAttachmentSnapshot = projection
            return projection
        }

        /// The broadcast projection of whatever attachment state is already in memory, WITHOUT the disk
        /// reseed `currentLiveWireAttachmentSnapshot()` performs. The in-memory summary and catalog entry
        /// exist to describe a session whose lifecycle writes have not committed yet, so a DB read there
        /// would both defeat their purpose and put a SQLite open on the overview's per-session rebuild.
        private func inMemoryLiveWireAttachmentSnapshot() -> TerminalSessionAttachmentSnapshot {
            if let cachedLiveWireAttachmentSnapshot { return cachedLiveWireAttachmentSnapshot }
            // An empty snapshot for a nil cache is deliberately NOT memoized: storing it would make
            // `currentLiveWireAttachmentSnapshot()` serve "nobody is attached" from the derived cache and
            // skip the disk reseed that would have told it otherwise. Populating from a real snapshot is
            // safe and is what keeps a lease touch (every keystroke clears the derived cache) from making
            // each later overview rebuild re-filter the session's whole attach history.
            guard let cachedAttachmentSnapshot else { return TerminalSessionAttachmentSnapshot() }
            let projection = cachedAttachmentSnapshot.liveWireProjection()
            cachedLiveWireAttachmentSnapshot = projection
            return projection
        }

        private func currentActiveAttachments() -> [TerminalAttachment] {
            (currentAttachmentSnapshot()?.attachments ?? []).filter { $0.detachedAt == nil }
        }

        /// Whether any still-attached client is one whose liveness the lease decides, i.e. whether the
        /// stale-client sweep has anything it could possibly expire. Mirrors the predicate
        /// `TerminalSessionPersistence.staleRemoteClients` runs in SQL — attached, connected, and a kind
        /// `livenessDependsOnLease` covers — against `currentAttachmentSnapshot()` instead of the database.
        private func hasLeaseGovernedAttachedClient() -> Bool {
            guard let snapshot = currentAttachmentSnapshot() else { return false }
            let attachedClientIDs = Set(snapshot.attachments.filter { $0.detachedAt == nil }.map(\.clientID))
            return snapshot.clients.contains { $0.disconnectedAt == nil && $0.kind.livenessDependsOnLease && attachedClientIDs.contains($0.id) }
        }

        /// Drops the in-memory attachment snapshot so the next read reseeds from the durable mirror. Called
        /// only to reconcile after a durable write did not take what memory already asserts (see
        /// `cachedAttachmentSnapshot`). Deliberately leaves `pendingAttachmentMutations` untouched: those
        /// transforms were acknowledged separately from the write that failed here, and their own writes are
        /// still queued, so they must still replay onto the reseed this triggers.
        private func invalidateAttachmentSnapshotCache() { cachedAttachmentSnapshot = nil }

        /// Marks every still-active attachment detached in the in-memory cache so the terminated payload
        /// reflects the teardown WITHOUT reading the durable mirror (whose matching detach write is only
        /// enqueued, not yet committed). Populates the cache from disk first so a never-invalidated cache
        /// still captures the pre-teardown attachments.
        private func markAllAttachmentsDetachedInCache(detachedAt: String) {
            guard let snapshot = currentAttachmentSnapshot() else { return }
            let detachedAttachments = snapshot.attachments.map { attachment -> TerminalAttachment in
                guard attachment.detachedAt == nil else { return attachment }
                return TerminalAttachment(
                    id: attachment.id, sessionID: attachment.sessionID, clientID: attachment.clientID, mode: attachment.mode,
                    attachedAt: attachment.attachedAt, detachedAt: detachedAt)
            }
            cachedAttachmentSnapshot = TerminalSessionAttachmentSnapshot(clients: snapshot.clients, attachments: detachedAttachments)
        }

        /// Mirrors the atomic `expireClients` write in the in-memory cache so the broadcast that follows a
        /// stale-client expiry advertises the post-expiry attachment state WITHOUT reading the durable mirror
        /// (whose matching transaction is only enqueued, not yet committed). Marks each stale client
        /// disconnected and its still-active attachments detached, then — when a transfer target is given —
        /// applies the ownership transfer exactly as the SQL does: demote every other active owner to viewer and
        /// promote the target's active attachment to owner (inserting one if the target has none). Populates the
        /// cache from disk first so a never-invalidated cache still captures the pre-expiry attachments.
        private func markClientsExpiredInCache(clientIDs: [String], newOwnerClientID: String?, detachedAt: String) {
            guard let snapshot = currentAttachmentSnapshot() else { return }
            let staleClientIDs = Set(clientIDs)
            let clients = snapshot.clients.map { client -> TerminalClient in
                guard staleClientIDs.contains(client.id), client.disconnectedAt == nil else { return client }
                return TerminalClient(
                    id: client.id, kind: client.kind, identity: client.identity, connectedAt: client.connectedAt, disconnectedAt: detachedAt,
                    leaseRefreshedAt: client.leaseRefreshedAt)
            }
            let attachments = snapshot.attachments.map { attachment -> TerminalAttachment in
                guard attachment.detachedAt == nil, staleClientIDs.contains(attachment.clientID) else { return attachment }
                return TerminalAttachment(
                    id: attachment.id, sessionID: attachment.sessionID, clientID: attachment.clientID, mode: attachment.mode,
                    attachedAt: attachment.attachedAt, detachedAt: detachedAt)
            }
            let expired = TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments)
            guard let newOwnerClientID else {
                cachedAttachmentSnapshot = expired
                return
            }
            cachedAttachmentSnapshot = expired.applyingOwnershipTransfer(
                to: newOwnerClientID, sessionID: launchConfiguration.sessionID, transferredAt: detachedAt)
        }

        /// Refreshes a client's heartbeat lease off the engine (see `enqueueClientLeaseTouch`). No-op when the
        /// client id is absent. The lease write is coalesced onto the persistence queue so a burst of control
        /// requests never blocks the engine on the DB write lock.
        private func touchClientLease(_ clientID: String?) {
            guard let clientID else { return }
            enqueueClientLeaseTouch(clientID: clientID)
        }

        /// Whether `clientID` is durably gone from this session: it has no active attachment in the authoritative
        /// in-memory cache AND is not the subject of a still-pending stale-client expiry. The second clause is
        /// load-bearing: a pending expiry optimistically marks the client detached in the cache, but the client's
        /// own heartbeat vetoes that expiry (via the generation gate), so such a client is not durably gone.
        private func isClientDurablyDisconnected(_ clientID: String) -> Bool {
            if expiredRemoteClientIDs.contains(clientID) { return false }
            return !currentActiveAttachments().contains { $0.clientID == clientID }
        }

        private func isRuntimeInteractiveForControl() -> Bool {
            if started { return true }
            let runtimeState = (try? TerminalSessionPersistence.readRuntimeState(paths: paths)) ?? latestRuntimeState
            guard let runtimeState else { return true }
            return runtimeState.state.isInteractive
        }

        nonisolated static func shouldClearFocusAfterDetachingClient(detachedClientWasOwner: Bool, remainingOwnerClientID: String?) -> Bool {
            detachedClientWasOwner || remainingOwnerClientID == nil
        }

        /// A runtime state is persisted when it says something the stored row does not: the signature covers
        /// every field of the row except `updated_at`, which is derived from the write itself, and `title`.
        ///
        /// `title` is excluded because it is not a durable fact about the session, it is whatever the program
        /// is printing right now, and agent TUIs animate a spinner in it several times a second. Including it
        /// meant a SQLite transaction per animation frame. The authority for a live session's title is the
        /// core's in-memory `latestRuntimeState`, which advances on every report and is what live subscribers
        /// and the device overview read (`TerminalSessionCatalog.mergingLiveInMemorySessions` overlays it onto
        /// the DB-derived entry). The stored column still converges: any write triggered by another field
        /// carries the current title, the handoff quiesce forces one before `execv`, and the exited-state
        /// write records the final title an ended pane is shown under.
        ///
        /// There is deliberately no periodic rewrite of an unchanged row. The 1 Hz refresh runs per session
        /// for as long as the session lives, so rewriting on a timer meant every idle terminal committed a
        /// transaction every few seconds forever, purely to move `updated_at` forward. Nothing reads that
        /// column as a freshness signal: session liveness is decided by the service pid, stale recovery by
        /// pid liveness, garbage collection by `exited_at`, and client liveness by
        /// `terminal_clients.lease_refreshed_at`. Its readers — the overview payload, a terminated session's
        /// `emittedAt`, the pane debug overlay — display it or pass it through, and a session that exits or
        /// changes anything at all writes immediately because the signature changes.
        private func shouldPersistRuntimeState(_ state: TerminalSessionRuntimeState) -> Bool {
            guard let lastPersistedRuntimeState else { return true }
            return runtimeStateSignature(for: lastPersistedRuntimeState) != runtimeStateSignature(for: state)
        }

        private func runtimeStateSignature(for state: TerminalSessionRuntimeState) -> String {
            "\(state.sessionID)|\(state.backend.rawValue)|\(state.servicePID)|\(state.childPID.map(String.init) ?? "nil")|\(state.foregroundPID.map(String.init) ?? "nil")|\(state.foregroundExecutablePath ?? "nil")|\(state.foregroundExecutableName ?? "nil")|\(state.foregroundArgv?.joined(separator: "\u{1F}") ?? "nil")|\(state.foregroundDetectedAgentKind?.rawValue ?? "nil")|\(state.foregroundDisplayLabel ?? "nil")|\(state.foregroundDisplayCommand ?? "nil")|\(state.workingDirectory ?? "nil")|\(state.columns.map(String.init) ?? "nil")|\(state.rows.map(String.init) ?? "nil")|\(state.state.rawValue)|\(state.exitedAt ?? "nil")|\(state.bellAt ?? "nil")|\(state.bracketedPasteActive)"
        }

        private static func isProcessAlive(pid: Int32) -> Bool {
            guard pid > 0 else { return false }
            if kill(pid, 0) == 0 { return true }
            return errno == EPERM
        }

        private nonisolated func enqueueIncomingOutput(_ data: Data) {
            let flushSchedule = incomingOutputBuffer.append(data, interactive: interactiveOutputGate.consumeIfActive())
            guard flushSchedule != .none else { return }
            Task { [weak self] in
                if flushSchedule == .delayed { do { try await Task.sleep(for: Self.incomingOutputCoalescingInterval) } catch { return } }
                guard let self else { return }
                // Drain ON the terminal engine actor so drain and file append form one critical
                // section. Every other drain (clearScreenAndScrollback's transcript
                // mutation, the quiesce flush) runs on the engine actor too, so this keeps
                // output.log byte order identical to buffer order. Draining here off the
                // engine actor would let an engine-actor drain+append (e.g. a clear) write
                // first, landing these earlier bytes AFTER the clear in the transcript —
                // a handoff replay would then resurrect the cleared screen.
                await TerminalEngineActor.run {
                    let drainedOutput = self.incomingOutputBuffer.drain()
                    guard !drainedOutput.data.isEmpty else { return }
                    _ = self.appendOutput(drainedOutput.data, interactiveResync: drainedOutput.isInteractive)
                }
            }
        }

        private func flushPendingIncomingOutputForStateExport() {
            let coalescedData = incomingOutputBuffer.drain()
            guard !coalescedData.data.isEmpty else { return }
            appendOutput(coalescedData.data, interactiveResync: coalescedData.isInteractive, shouldBroadcastState: false)
        }

        func prepareRenderStateExport() { flushPendingIncomingOutputForStateExport() }

        public func currentRemoteStatePayload(reason: String = TerminalRemoteSessionStateReason.stateChange) -> GhosttyRemoteSessionStatePayload? {
            currentRemoteSessionState(reason: reason, outputByteCount: nil, exportMode: .selfContained)
        }

        /// The payload a one-shot state read is answered with, byte-for-byte what this session's own
        /// subscription socket would have exported for a fresh subscriber: a self-contained frame that also
        /// arms the next broadcast to carry a full render update when this export could not produce one, so
        /// a reader left without a baseline still converges. Serving a Device API `.state` from here lets the
        /// daemon skip dialing its own session's unix socket to ask itself a question it can answer directly.
        public func currentOneShotStatePayload() -> GhosttyRemoteSessionStatePayload? {
            currentRemoteSessionState(
                reason: TerminalRemoteSessionStateReason.initial, outputByteCount: nil, exportMode: .selfContained,
                markNextBroadcastFullWhenMissingRenderUpdate: true)
        }

        private func broadcastCurrentState(
            reason: String, outputByteCount: Int? = nil, outputEndByteOffset: Int? = nil, clipboardWrite: TerminalClipboardWritePayload? = nil,
            preCapturedScreenState: LiveSessionScreenState? = nil
        ) {
            guard !suppressBroadcastsForHandoff else { return }
            let startedAt = Date()
            let ownerClient = activeOwnerClient()
            let includeScreenState = Self.remoteStateShouldIncludeScreenState(reason: reason, ownerKind: ownerClient?.kind)
            trace(
                "broadcast_state_begin reason=\(reason) include_screen=\(includeScreenState ? 1 : 0) runtime=\(traceSize(observedSurfaceSize())) output_bytes=\(outputByteCount ?? 0)"
            )
            guard stateStreamServer != nil,
                let payload = currentRemoteSessionState(
                    reason: reason, outputByteCount: outputByteCount, outputEndByteOffset: outputEndByteOffset, exportMode: .streamDeltaAllowed,
                    clipboardWrite: clipboardWrite, preCapturedScreenState: preCapturedScreenState)
            else { return }
            broadcastRemoteStatePayload(payload, startedAt: startedAt, ownerClient: ownerClient, outputByteCount: outputByteCount)
        }

        private func broadcastRemoteStatePayload(
            _ payload: GhosttyRemoteSessionStatePayload, startedAt: Date, ownerClient: TerminalClient?, outputByteCount: Int?
        ) {
            stateStreamServer?.broadcast(payload)
            trace(
                "broadcast_state_end reason=\(payload.reason) render_update=\(payload.renderUpdate == nil ? 0 : 1) runtime=\(traceSize(columns: payload.runtimeState?.columns, rows: payload.runtimeState?.rows)) owner_epoch=\(ownerEpoch)"
            )
            // Metric emission only; the wire encode happens inside broadcast() on the stream
            // server's queue. Skip the assembly when no perf log is recording.
            guard SpacesDeviceTerminalPerformanceLogger.isEnabled() || TerminalPerformance.isEnabled else { return }
            let decodedUpdate = payload.decodedRenderUpdate
            let renderUpdateAttributes = GhosttyRenderFrameMetrics.attributes(
                reason: payload.reason, frame: decodedUpdate?.fullFrame, outputByteCount: outputByteCount,
                screenStateRevision: payload.screenStateRevision, frameKind: decodedUpdate?.frameKindMetricValue,
                baseRevision: decodedUpdate?.baseRevision, targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
                operationCount: decodedUpdate?.operationCount, changedCellCount: decodedUpdate?.changedCellCount,
                scrollOperationCount: decodedUpdate?.scrollOperationCount, fullFrameFallbackReason: decodedUpdate?.fallbackReason)
            logMobileTakeoverPerformance(
                name: "remote_state_publish", count: payload.renderUpdate?.count,
                attributes: [
                    "reason": payload.reason, "owner_kind": ownerClient?.kind.rawValue ?? "nil", "output_bytes": String(outputByteCount ?? 0),
                    "render_update": payload.renderUpdate == nil ? "0" : "1", "render_update_bytes": String(payload.renderUpdate?.count ?? 0),
                ])
            logMobileTakeoverPerformance(
                name: "render_frame_payload_publish", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), count: payload.renderUpdate?.count,
                attributes: renderUpdateAttributes)
            TerminalPerformance.logMetric(
                "terminal_remote_state_publish", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail:
                    "reason=\(payload.reason) render_update=\(payload.renderUpdate == nil ? 0 : 1) bytes=\(outputByteCount ?? 0) render_update_bytes=\(payload.renderUpdate?.count ?? 0)"
            )
            TerminalPerformance.logMetric(
                "terminal_render_frame_payload_publish", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail: GhosttyRenderFrameMetrics.detailString(renderUpdateAttributes))
        }

        private func currentRemoteSessionState(
            reason: String, outputByteCount: Int?, outputEndByteOffset: Int? = nil, exportMode: RenderStateExportMode = .selfContained,
            markNextBroadcastFull: Bool = false, markNextBroadcastFullWhenMissingRenderUpdate: Bool = false,
            clipboardWrite: TerminalClipboardWritePayload? = nil, preCapturedScreenState: LiveSessionScreenState? = nil
        ) -> GhosttyRemoteSessionStatePayload? {
            // Serve runtime state from memory: this core is the sole writer of a live session's runtime
            // state and advances `latestRuntimeState` the moment it computes a new one, so the in-memory copy
            // is authoritative (live truth) whether or not the durable write has landed yet. Falling back to
            // disk only covers the brief pre-first-compute window. This removes a per-output-chunk SQLite open
            // that otherwise saturated the serial terminal-engine executor and starved input.
            let runtimeState = latestRuntimeState ?? (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
            // Broadcasts carry live rows only; the core keeps the full history for its own gating.
            // See `TerminalSessionAttachmentSnapshot.liveWireProjection`.
            let attachmentSnapshot = currentLiveWireAttachmentSnapshot()
            let ownerClient = activeOwnerClient()
            let includeScreenState = Self.remoteStateShouldIncludeScreenState(reason: reason, ownerKind: ownerClient?.kind)
            let bootstrapOutputByteCount = outputByteCount
            let bootstrapOutputEndByteOffset = outputEndByteOffset
            if includeScreenState {
                let snapshotExportStartedAt = Date()
                trace(
                    "snapshot_export_begin reason=\(reason) runtime=\(traceSize(columns: runtimeState?.columns, rows: runtimeState?.rows)) owner=\(attachmentSnapshot?.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID ?? "nil")"
                )
                logMobileTakeoverPerformance(
                    name: "snapshot_export_begin",
                    attributes: [
                        "reason": reason, "owner_kind": ownerClient?.kind.rawValue ?? "nil", "runtime_columns": String(runtimeState?.columns ?? 0),
                        "runtime_rows": String(runtimeState?.rows ?? 0),
                    ])
                let resolvedScreenState = resolveRemoteScreenState(
                    runtimeState: runtimeState, reason: reason, ownerKind: ownerClient?.kind, preCapturedScreenState: preCapturedScreenState)
                let snapshot = resolvedScreenState.snapshot
                let frame = snapshot.map { GhosttyRenderFrame(sessionRevision: renderFrameRevision(for: $0), ownerEpoch: ownerEpoch, snapshot: $0) }
                let renderUpdateEncodeStartedAt = Date()
                let renderUpdateValue = frame.map {
                    makeRenderUpdate(
                        for: $0, reason: reason, nativeScrollRects: resolvedScreenState.scrollRects,
                        nativeScrollRectsOverflowed: resolvedScreenState.scrollRectsOverflowed, exportMode: exportMode)
                }
                let renderUpdate = renderUpdateValue.flatMap { try? GhosttyRenderUpdateBinaryCodec.encode($0) }
                if renderUpdate != nil, markNextBroadcastFull { forceNextBroadcastFullRenderUpdate = true }
                if renderUpdate == nil, markNextBroadcastFullWhenMissingRenderUpdate { forceNextBroadcastFullRenderUpdate = true }
                let renderUpdateEncodeMS = TerminalPerformance.elapsedMS(since: renderUpdateEncodeStartedAt)
                if renderUpdate != nil, let lastScreenStateRevision, exportMode == .streamDeltaAllowed {
                    lastExportedScreenStateRevision = lastScreenStateRevision
                }
                trace(
                    "render_frame_export_end reason=\(reason) render_update=\(renderUpdate == nil ? 0 : 1) frame_size=\(traceSize(columns: snapshot?.columns, rows: snapshot?.rows)) source=\(resolvedScreenState.source) owner_epoch=\(ownerEpoch)"
                )
                var renderUpdateAttributes = GhosttyRenderFrameMetrics.attributes(
                    reason: reason, frame: frame, outputByteCount: outputByteCount, screenStateRevision: lastScreenStateRevision,
                    frameKind: renderUpdateValue?.frameKindMetricValue, baseRevision: renderUpdateValue?.baseRevision,
                    targetRevision: renderUpdateValue?.targetRevision ?? lastScreenStateRevision, operationCount: renderUpdateValue?.operationCount,
                    changedCellCount: renderUpdateValue?.changedCellCount, scrollOperationCount: renderUpdateValue?.scrollOperationCount,
                    fullFrameFallbackReason: renderUpdateValue?.fallbackReason)
                renderUpdateAttributes["source"] = resolvedScreenState.source
                renderUpdateAttributes["owner_kind"] = ownerClient?.kind.rawValue ?? "nil"
                renderUpdateAttributes["render_update_bytes"] = String(renderUpdate?.count ?? 0)
                renderUpdateAttributes["render_update_encode_ms"] = String(renderUpdateEncodeMS)
                logMobileTakeoverPerformance(
                    name: "render_frame_export_end", elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt),
                    count: renderUpdate?.count, attributes: renderUpdateAttributes)
                TerminalPerformance.logMetric(
                    "terminal_render_frame_export", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt), success: renderUpdate != nil,
                    detail: GhosttyRenderFrameMetrics.detailString(renderUpdateAttributes))
                return GhosttyRemoteSessionStatePayload(
                    sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
                    sessionStateRevision: lastSessionStateRevision, sessionStateFlags: lastSessionStateFlags?.rawValue,
                    screenStateRevision: lastScreenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
                    title: effectiveTitle, workingDirectory: effectiveWorkingDirectory, outputByteCount: bootstrapOutputByteCount,
                    outputEndByteOffset: bootstrapOutputEndByteOffset, renderUpdate: renderUpdate, clipboardWrite: clipboardWrite)
            }
            if markNextBroadcastFullWhenMissingRenderUpdate { forceNextBroadcastFullRenderUpdate = true }
            return GhosttyRemoteSessionStatePayload(
                sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
                sessionStateRevision: lastSessionStateRevision, sessionStateFlags: lastSessionStateFlags?.rawValue,
                screenStateRevision: lastScreenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
                title: effectiveTitle, workingDirectory: effectiveWorkingDirectory, outputByteCount: bootstrapOutputByteCount,
                outputEndByteOffset: bootstrapOutputEndByteOffset, clipboardWrite: clipboardWrite)
        }

        private func makeRenderUpdate(
            for frame: GhosttyRenderFrame, reason: String, nativeScrollRects capturedScrollRects: [GhosttyRenderScrollRectOperation] = [],
            nativeScrollRectsOverflowed capturedScrollRectsOverflowed: Bool = false, exportMode: RenderStateExportMode = .selfContained
        ) -> GhosttyRenderUpdate {
            // A `.selfContained` export always forces a full frame below (`forceFullForSelfContainedExport`),
            // and a full frame never carries scroll rects, so the rects Ghostty just drained for this export
            // would otherwise vanish. Carry them for the next stream export instead. A `.streamDeltaAllowed`
            // export that itself ends up emitting a full frame (baseline reset, delta-apply failure, etc.) is
            // still correct to drain here: a client poisons its own carry on any full frame it receives, so
            // the rects this drain hands it are moot the moment the full frame lands.
            let nativeScrollRects: [GhosttyRenderScrollRectOperation]
            let nativeScrollRectsOverflowed: Bool
            switch exportMode {
            case .selfContained:
                streamScrollRectCarry.fold(rects: capturedScrollRects, overflowed: capturedScrollRectsOverflowed)
                nativeScrollRects = []
                nativeScrollRectsOverflowed = false
            case .streamDeltaAllowed:
                (nativeScrollRects, nativeScrollRectsOverflowed) = streamScrollRectCarry.drain(
                    mergingWith: capturedScrollRects, overflowed: capturedScrollRectsOverflowed)
            }
            let hasPendingSubscriberBaselineReset = exportMode == .streamDeltaAllowed && forceNextBroadcastFullRenderUpdate
            let forceFullForSubscriberBaseline = hasPendingSubscriberBaselineReset && reason != TerminalRemoteSessionStateReason.scroll
            let forceFullForSelfContainedExport = exportMode == .selfContained
            let forceFullForExplicitResync =
                reason == TerminalRemoteSessionStateReason.initial || reason == TerminalRemoteSessionStateReason.inputOutput
                || reason == TerminalRemoteSessionStateReason.resize || reason == TerminalRemoteSessionStateReason.terminated
            let forceFull =
                forceFullForExplicitResync || forceFullForSelfContainedExport || lastRenderUpdateBaseline?.sessionRevision == frame.sessionRevision
                || forceFullForSubscriberBaseline
            let forceFullReason =
                if reason == TerminalRemoteSessionStateReason.initial {
                    "initial_baseline"
                } else if reason == TerminalRemoteSessionStateReason.inputOutput || reason == TerminalRemoteSessionStateReason.terminated {
                    "explicit_resync"
                } else if reason == TerminalRemoteSessionStateReason.resize { "resize_self_contained" } else if forceFullForSubscriberBaseline {
                    "subscriber_baseline_reset"
                } else if forceFullForSelfContainedExport { "self_contained_state_export" } else { "baseline_already_current" }
            let update = GhosttyRenderUpdateFactory.makeUpdate(
                target: frame, baseline: lastRenderUpdateBaseline, forceFull: forceFull, forceFullReason: forceFullReason,
                nativeScrollRects: nativeScrollRects, nativeScrollRectsOverflowed: nativeScrollRectsOverflowed)
            let shouldUpdateStreamBaseline = exportMode == .streamDeltaAllowed
            // What actually goes out, which is `update` except where a delta that could not be applied
            // locally is replaced below. The pending-baseline promise is answered against this rather than
            // against `update`, so both readings agree with what the subscriber received.
            var emittedUpdate = update
            switch update.kind {
            case .full:
                if shouldUpdateStreamBaseline, let fullFrame = update.fullFrame {
                    lastRenderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: fullFrame)
                }
            case .delta:
                if let appliedBaseline = try? GhosttyRenderUpdateApplier.apply(update, to: lastRenderUpdateBaseline) {
                    lastRenderUpdateBaseline = appliedBaseline
                } else {
                    emittedUpdate = GhosttyRenderUpdate.full(frame, fallbackReason: "local_delta_apply_failed")
                    if shouldUpdateStreamBaseline { lastRenderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: frame) }
                }
            case .resyncRequired: if shouldUpdateStreamBaseline { lastRenderUpdateBaseline = nil }
            }
            // The arm is a promise to a subscriber whose initial carried no render update, and only a full
            // frame keeps it. A scroll is excluded from `forceFullForSubscriberBaseline` on purpose — its
            // delta rewrites the viewport through scroll rects and a full frame would waste that — but a
            // delta hands the subscriber nothing to apply, so spending the promise on one would leave it
            // with a frame it can only drop and a resync round trip before the pane shows anything.
            if hasPendingSubscriberBaselineReset, emittedUpdate.kind == .full { forceNextBroadcastFullRenderUpdate = false }
            return emittedUpdate
        }

        private func renderFrameRevision(for snapshot: GhosttyTerminalSnapshot) -> UInt64 {
            if let lastScreenStateRevision, lastScreenStateRevision > renderUpdateRevision {
                renderUpdateRevision = lastScreenStateRevision
            } else if renderUpdateRevision == 0, let lastSessionStateRevision {
                renderUpdateRevision = lastSessionStateRevision
            } else if renderUpdateRevision == 0 {
                renderUpdateRevision = 1
            }

            if let baselineRevision = lastRenderUpdateBaseline?.sessionRevision, baselineRevision > renderUpdateRevision {
                renderUpdateRevision = baselineRevision
            }
            if let lastRenderUpdateBaseline, lastRenderUpdateBaseline.sessionRevision == Optional(renderUpdateRevision),
                lastRenderUpdateBaseline.snapshot != snapshot
            {
                if renderUpdateRevision < UInt64.max { renderUpdateRevision += 1 }
            }
            return renderUpdateRevision
        }

        /// One read of the live terminal: the snapshot (or its text fallback) and the scroll rects ghostty
        /// had pending when it was taken. Passing one of these back into the export path is what lets a
        /// caller emit the exact frame it already inspected instead of racing a second capture against it.
        private typealias LiveSessionScreenState = (
            snapshot: GhosttyTerminalSnapshot?, snapshotText: String?, scrollRects: [GhosttyRenderScrollRectOperation], scrollRectsOverflowed: Bool
        )

        private func resolveRemoteScreenState(
            runtimeState: TerminalSessionRuntimeState?, reason: String, ownerKind: TerminalClientKind?,
            preCapturedScreenState: LiveSessionScreenState? = nil
        ) -> (
            snapshot: GhosttyTerminalSnapshot?, snapshotText: String?, scrollRects: [GhosttyRenderScrollRectOperation], scrollRectsOverflowed: Bool,
            source: String
        ) {
            let liveSessionScreenState = preCapturedScreenState ?? captureLiveSessionScreenState()
            let sessionSnapshot = liveSessionScreenState.snapshot
            let sessionSnapshotText = liveSessionScreenState.snapshotText
            // A selection broadcast exists precisely to move selection state in both directions, so the
            // clear on an otherwise blank screen must still carry the frame so viewers un-paint the
            // highlight: the visible-content gate below exists to avoid exporting meaningless blank
            // frames for output-driven reasons, and does not apply to a selection change.
            if reason == TerminalRemoteSessionStateReason.selection
                || Self.remoteScreenStateHasVisibleContent(snapshot: sessionSnapshot, snapshotText: sessionSnapshotText)
            {
                return (
                    snapshot: sessionSnapshot, snapshotText: sessionSnapshotText, scrollRects: liveSessionScreenState.scrollRects,
                    scrollRectsOverflowed: liveSessionScreenState.scrollRectsOverflowed, source: "session"
                )
            }

            let isLiveRuntime = runtimeState?.state == .running || runtimeState?.state == .starting
            // The rects `captureLiveSessionScreenState()` just drained are dropped here rather than folded
            // into `streamScrollRectCarry`: they describe movement on a screen this export just found empty,
            // and a mirror's drag carry only ever needs to track movement over visible content it can select
            // against. Movement on an empty screen cannot mislead a drag over visible content later, so
            // carrying it forward would only cost carry capacity for no product benefit.
            return (
                snapshot: nil, snapshotText: nil, scrollRects: [], scrollRectsOverflowed: false,
                source: isLiveRuntime ? "session_empty" : "session_unavailable"
            )
        }

        private func captureLiveSessionScreenState() -> LiveSessionScreenState {
            flushPendingIncomingOutputForStateExport()
            rendererHostStorage.prepareRenderStateExport()
            let capturedRenderState = rendererHostStorage.sessionRenderStateSnapshot()
            let sessionSnapshot = capturedRenderState?.snapshot
            let sessionSnapshotText = sessionSnapshot == nil ? rendererHostStorage.sessionSnapshotText() : nil
            return (
                snapshot: sessionSnapshot, snapshotText: sessionSnapshotText, scrollRects: capturedRenderState?.scrollRects ?? [],
                scrollRectsOverflowed: capturedRenderState?.scrollRectsOverflowed ?? false
            )
        }

        static func remoteStateShouldIncludeScreenState(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: reason, ownerKind: ownerKind)
        }

        static func remoteScreenStateHasVisibleContent(snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) -> Bool {
            TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: snapshot, snapshotText: snapshotText)
        }

        var debugCurrentTitle: String? { currentTitle }
        /// Drives the real OSC-title path so a test exercises the same decision a program's title set makes.
        func debugApplyTitleActionEvent(_ title: String) { applyActionEvent(.setTitle(title)) }
        /// Runs the coalesced overview-signal flush the 1 Hz tick performs.
        func debugFlushPendingOverviewSignalForMetadata() { flushPendingOverviewSignalForMetadata() }
        var debugOwesOverviewSignalForMetadata: Bool { owesOverviewSignalForMetadata }
        var debugCurrentWorkingDirectory: String? { currentWorkingDirectory }
        func debugHandleIncomingOutput(_ data: Data) { appendOutput(data, interactiveResync: interactiveOutputGate.consumeIfActive()) }
        func debugBufferIncomingOutputForStateExport(_ data: Data) { _ = incomingOutputBuffer.append(data, interactive: false) }
        func debugStartStateStreamServerForTesting() throws { try startStateStreamServer() }
        func debugStopStateStreamServerForTesting() {
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)
        }
        func debugBroadcastCurrentStateForTesting(reason: String) { broadcastCurrentState(reason: reason) }
        func debugHandleOwnerInputActivity(byteCount: Int = 1) { handleOwnerInputActivity(byteCount: byteCount) }
        func debugMarkLocalOwnerCommandInputOutputResyncPending() { markLocalOwnerCommandInputOutputResyncPending() }
        func debugCurrentRemoteSessionState(reason: String) -> GhosttyRemoteSessionStatePayload? {
            currentRemoteSessionState(reason: reason, outputByteCount: nil, exportMode: .selfContained)
        }
        func debugPersistRuntimeState(force: Bool = true) {
            refreshRuntimeState(force: force)
            // Persistence is now off-engine; block until it commits so tests can read the durable state.
            drainPersistenceQueue()
        }
        /// Blocks until all enqueued durable writes have committed. Test-only fence for the off-engine
        /// persistence queue (lease touches, expiry detaches) so assertions can read the durable mirror.
        func debugDrainPersistenceQueue() { drainPersistenceQueue() }
        /// Test-only: parks the serial persistence queue on a returned semaphore so a test can enqueue further
        /// work (e.g. an expiry detach) and then break the database in the deterministic window before that
        /// work runs. Signal the semaphore to release the queue.
        func debugHoldPersistenceQueue() -> DispatchSemaphore {
            let gate = DispatchSemaphore(value: 0)
            persistence.enqueueOrderedWork { gate.wait() }
            return gate
        }
        func debugSetLastKnownChildPID(_ pid: Int32?) { lastKnownChildPID = pid }
        func debugSetForegroundPIDForTesting(_ pid: Int32?) { foregroundPIDOverrideForTesting = pid }
        func debugSetForegroundProcessResolverForTesting(_ resolver: @escaping (Int32) -> TerminalForegroundProcessSnapshot?) {
            foregroundProcessResolver = resolver
        }
        func debugSetLastKnownSurfaceSize(columns: Int, rows: Int) { lastKnownSurfaceSize = (columns, rows) }
        /// Test-only: arms the pending resize broadcast exactly as an accepted resize control request does.
        /// The real arm sits behind `resizeCellGrid`, which needs a live ghostty surface, so this is what
        /// lets a test drive `handleTerminalGridReflow` against a stubbed capture.
        func debugArmPendingResizeBroadcastGridForTesting(columns: Int, rows: Int) { pendingResizeBroadcastGrid = (columns, rows) }
        /// Test-only: delivers a terminal-reflow report the way ghostty's host-managed resize callback does.
        func debugHandleTerminalGridReflowForTesting(columns: Int, rows: Int) { handleTerminalGridReflow(columns: columns, rows: rows) }
        func debugHandleSessionClosed() { handleSessionClosed() }
        func debugMarkStartedForTesting() { started = true }
        /// Test-only: forces the attachment cache empty, exactly as `invalidateAttachmentSnapshotCache()` does
        /// on the real reconcile path.
        func debugInvalidateAttachmentSnapshotCacheForTesting() { invalidateAttachmentSnapshotCache() }
        /// Test-only: see `forceAttachmentSnapshotReseedFailureForTesting`.
        func debugSetForceAttachmentSnapshotReseedFailureForTesting(_ forced: Bool) { forceAttachmentSnapshotReseedFailureForTesting = forced }

        private func trace(_ message: @autoclosure () -> String) { ghosttyEmbeddedSessionTrace(launchConfiguration.sessionID, message()) }

        private func traceSize(_ size: (columns: Int, rows: Int)?) -> String {
            guard let size else { return "nil" }
            return "\(size.columns)x\(size.rows)"
        }

        private func traceSize(columns: Int?, rows: Int?) -> String {
            guard let columns, let rows else { return "nil" }
            return "\(columns)x\(rows)"
        }

        /// `elapsedMS`/`count`/`attributes` are `@autoclosure` so a disabled logger never evaluates the
        /// dictionary literals callers build inline (e.g. `applySessionStateChange`'s "state_change" event,
        /// which fires on every `.screen` change — i.e. every terminal output tick) — the `isEnabled()`
        /// guard below runs first, and only then are the closures forced.
        private func logMobileTakeoverPerformance(
            name: String, elapsedMS: @autoclosure () -> Int? = nil, count: @autoclosure () -> Int? = nil,
            attributes: @autoclosure () -> [String: String] = [:]
        ) {
            guard SpacesDeviceTerminalPerformanceLogger.isEnabled() else { return }
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(
                    sessionID: launchConfiguration.sessionID, source: "mac-host", name: name, elapsedMS: elapsedMS(), count: count(),
                    attributes: attributes()))
        }

    }

    @TerminalEngineActor public final class GhosttyEmbeddedSessionHost {
        /// Nonisolated because the core is itself engine-isolated (and so Sendable), and control requests
        /// are handled from OFF the engine: a send waits there for its writes, which run on the engine.
        public nonisolated let core: GhosttyEmbeddedSessionCore

        public var launchConfiguration: TerminalSessionLaunchConfiguration { core.launchConfiguration }
        public var paths: TerminalSessionPaths { core.paths }
        public var rendererHost: GhosttyHeadlessRendererHost { core.rendererHost }

        init(
            launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
            requestSurfaceRefreshAction: (@TerminalEngineActor () -> Void)? = nil
        ) {
            core = GhosttyEmbeddedSessionCore(
                launchConfiguration: launchConfiguration, paths: paths, requestSurfaceRefreshAction: requestSurfaceRefreshAction)
        }

        init(core: GhosttyEmbeddedSessionCore) { self.core = core }

        public func startIfNeeded() throws { try core.startIfNeeded() }

        public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
            let startedAt = Date()
            do {
                try core.startIfNeeded()
                guard core.isStarted else { return }
                try core.rendererHost.attach(client: client, mode: mode, into: container)
                try core.attachClient(client, mode: mode)
                // Window focus is an app-side (main-actor) concern handled by RemoteGhosttySessionHost; the
                // headless daemon renderer has no window to key, so an owner attach only refreshes here.
                if mode == .owner, container != nil { core.rendererHost.requestSurfaceRefresh() }
                TerminalPerformance.logMetric(
                    "terminal_window_attach", target: "session=\(launchConfiguration.sessionID) client=\(client.id)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "mode=\(mode.rawValue)")
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_window_attach", target: "session=\(launchConfiguration.sessionID) client=\(client.id)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "mode=\(mode.rawValue)")
                throw error
            }
        }

        public func detach(clientID: String) throws { try core.detach(clientID: clientID) }

        public func releaseRendererSurface() { core.rendererHost.releaseRendererSurface() }

        public func setFocused(_ focused: Bool, for clientID: String) { core.rendererHost.setFocused(focused, for: clientID) }

        public func isOwner(clientID: String) -> Bool { core.isOwner(clientID: clientID) }

        public func activeOwnerClientID() -> String? { core.activeOwnerClientID() }

        public func hasRenderableSurface() -> Bool { core.rendererHost.hasRenderableSurface() }

        public func requestSurfaceRefresh() { core.rendererHost.requestSurfaceRefresh() }

        public func prepareRenderStateExport() { core.rendererHost.prepareRenderStateExport() }

        public func snapshot() -> GhosttyTerminalSnapshot? { return core.rendererHost.snapshot() }

        public func snapshotText() -> String? { return core.rendererHost.snapshotText() }

        public func sessionSnapshot() -> GhosttyTerminalSnapshot? { return core.rendererHost.sessionSnapshot() }

        public func sessionSnapshotText() -> String? { return core.rendererHost.sessionSnapshotText() }

        public func copySelectionToPasteboard() -> Bool { core.rendererHost.copySelectionToPasteboard() }

        public func pasteClipboardContents() -> Bool { core.rendererHost.pasteClipboardContents() }

        @discardableResult public func sendTextAsPaste(_ text: String) -> Bool { core.rendererHost.sendTextAsPaste(text) }

        @discardableResult public func performBindingAction(_ action: String) -> Bool { core.rendererHost.performBindingAction(action) }

        @discardableResult public func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?
        ) -> Bool {
            core.rendererHost.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
        }

        @discardableResult public func clearScreenAndScrollback() -> Bool { core.rendererHost.clearScreenAndScrollback() }

        public var debugSearchState: GhosttyTerminalSearchDebugState { core.rendererHost.debugSearchState }

        public var debugSurfaceRefreshRequestCount: Int { core.rendererHost.debugSurfaceRefreshRequestCount }
        public func debugVisibleSurfaceText() -> String? { return core.rendererHost.debugVisibleSurfaceText() }

        public func debugSurfaceSelectionText() -> String? { return core.rendererHost.debugSurfaceSelectionText() }

        public func terminate() { core.terminate() }

        public func childPID() -> Int32? { core.childPID() }

        public var effectiveTitle: String { core.effectiveTitle }

        public var effectiveWorkingDirectory: String { core.effectiveWorkingDirectory }

        public func inMemorySessionSummary() -> TerminalServiceSessionSummary? { core.inMemorySessionSummary() }

        public func inMemoryCatalogEntry() -> TerminalSessionCatalogEntry? { core.inMemoryCatalogEntry() }

        /// Nonisolated for the same reason the core's is: a send waits for its writes, which run on the
        /// engine, so the request must be handled from off it.
        nonisolated func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse { core.handleControlRequest(request) }
        func applyActionEvent(_ event: GhosttyActionEvent) { core.applyActionEvent(event) }
        func applySessionStateChange(_ change: GhosttyEmbeddedSessionStateChange) { core.applySessionStateChange(change) }
        @discardableResult func expireStaleRemoteClientsIfNeeded(now: Date = Date()) -> [String] { core.expireStaleRemoteClientsIfNeeded(now: now) }

        nonisolated static func shouldClearFocusAfterDetachingClient(detachedClientWasOwner: Bool, remainingOwnerClientID: String?) -> Bool {
            GhosttyEmbeddedSessionCore.shouldClearFocusAfterDetachingClient(
                detachedClientWasOwner: detachedClientWasOwner, remainingOwnerClientID: remainingOwnerClientID)
        }

        var debugCurrentTitle: String? { core.debugCurrentTitle }
        func debugApplyTitleActionEvent(_ title: String) { core.debugApplyTitleActionEvent(title) }
        func debugFlushPendingOverviewSignalForMetadata() { core.debugFlushPendingOverviewSignalForMetadata() }
        var debugOwesOverviewSignalForMetadata: Bool { core.debugOwesOverviewSignalForMetadata }
        var debugCurrentWorkingDirectory: String? { core.debugCurrentWorkingDirectory }
        func debugHandleIncomingOutput(_ data: Data) { core.debugHandleIncomingOutput(data) }
        func debugBufferIncomingOutputForStateExport(_ data: Data) { core.debugBufferIncomingOutputForStateExport(data) }
        func debugStartStateStreamServerForTesting() throws { try core.debugStartStateStreamServerForTesting() }
        func debugStopStateStreamServerForTesting() { core.debugStopStateStreamServerForTesting() }
        func debugBroadcastCurrentStateForTesting(reason: String) { core.debugBroadcastCurrentStateForTesting(reason: reason) }
        func debugHandleOwnerInputActivity(byteCount: Int = 1) { core.debugHandleOwnerInputActivity(byteCount: byteCount) }
        func debugMarkLocalOwnerCommandInputOutputResyncPending() { core.debugMarkLocalOwnerCommandInputOutputResyncPending() }
        func debugCurrentRemoteSessionState(reason: String) -> GhosttyRemoteSessionStatePayload? {
            core.debugCurrentRemoteSessionState(reason: reason)
        }
        func debugPersistRuntimeState(force: Bool = true) { core.debugPersistRuntimeState(force: force) }
        func debugDrainPersistenceQueue() { core.debugDrainPersistenceQueue() }
        func debugHoldPersistenceQueue() -> DispatchSemaphore { core.debugHoldPersistenceQueue() }
        func debugSetLastKnownChildPID(_ pid: Int32?) { core.debugSetLastKnownChildPID(pid) }
        func debugSetForegroundPIDForTesting(_ pid: Int32?) { core.debugSetForegroundPIDForTesting(pid) }
        func debugSetForegroundProcessResolverForTesting(_ resolver: @escaping (Int32) -> TerminalForegroundProcessSnapshot?) {
            core.debugSetForegroundProcessResolverForTesting(resolver)
        }
        func debugHandleSessionClosed() { core.debugHandleSessionClosed() }
        func debugMarkStartedForTesting() { core.debugMarkStartedForTesting() }
        func debugInvalidateAttachmentSnapshotCacheForTesting() { core.debugInvalidateAttachmentSnapshotCacheForTesting() }
        func debugSetForceAttachmentSnapshotReseedFailureForTesting(_ forced: Bool) {
            core.debugSetForceAttachmentSnapshotReseedFailureForTesting(forced)
        }
    }

#endif
