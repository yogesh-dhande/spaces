#if canImport(AppKit)
    import AppKit
    import Foundation
    import spacesterminalcore

    public typealias RemoteGhosttyTerminalServiceRequestSender = @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    public typealias RemoteGhosttyAgentSignalHandler = @MainActor @Sendable ([TerminalServiceAgentSignalEvent]) throws -> [String]
    /// Reports that an interactive control request — typed input, key, scroll, resize, or clear-screen
    /// — failed to reach the device. Raised from the serial input queue (off the main actor, awaited
    /// through its `async` `onError`) with the error the send threw, and deliberately not classified
    /// here: the host knows only that its request failed, while the owner of the session's link state
    /// (`DeviceTerminalSessionStateModel.reportFailedInputSend`) knows whether a given failure is
    /// evidence about the link, and whether that evidence is conclusive.
    ///
    /// Returns whether the failure is CONCLUSIVE proof the link is gone, not merely that this one send
    /// failed. When `true`, the host discards this pane's queued input (`TerminalInputSerialQueue.cancelAll()`)
    /// instead of letting a backlog typed during the outage drain and deliver late — including any Enter —
    /// once the link recovers. Only a connection-level failure (refused, closed, every candidate address
    /// unreachable) — or a repeat failure during an outage already confirmed — answers `true`.
    ///
    /// A bare request timeout answers `false`, and the model does not treat it as an outage either: it
    /// leaves the pane's state subscription installed and corroborates the timeout with a `.ping` before
    /// deciding anything. The interactive control deadline is tight enough
    /// (`DeviceTerminalSessionStateModel.interactiveControlRequestTimeoutSeconds`, 5s) that a live but
    /// congested link misses it on its own: the send path never touches the main actor
    /// (`TerminalInputSerialQueue.enqueue` hands off to a detached task that talks to the pinned-TLS
    /// connection directly). Interactive sends and the `.state` resync fetch share one per-session
    /// request client, which acquires its request lock before starting the per-operation deadline, so a
    /// keystroke queued behind a grid-sized resync fetch is not charged for that wait — it gets a fresh
    /// 5s window once its turn comes. What actually burns that window is the daemon's own answer running
    /// late: under heavy streaming the daemon's serial terminal-engine queue is saturated, so a
    /// keystroke's response can genuinely time out with nothing wrong with the link. Discarding a live
    /// pane's backlog — or putting a "connection lost" banner over a working pane — on that false alarm is
    /// the bug this distinction exists to avoid, and a silently dead link (nothing ever answers) produces
    /// the identical timeout, so the timeout by itself is not conclusive either way.
    public typealias RemoteGhosttyInputFailureHandler = @Sendable (any Error) async -> Bool
    public typealias RemoteGhosttyStateStreamSubscriber =
        @Sendable (
            _ sessionID: String, _ onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void,
            _ onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) throws -> any TerminalRemoteStateStreamClient

    /// A fetched transcript range, inflated, with where it sits in `output.log` and the run identity the
    /// server reported it was read from.
    ///
    /// `startByteOffset` and `endByteOffset` bracket the file bytes the payload covers: the replay built
    /// from it holds the transcript from `startByteOffset` (zero means the whole file) through
    /// `endByteOffset`. A capped suffix's payload is longer than that range, because the state preamble in
    /// front of it exists nowhere in the file.
    ///
    /// The host validates `runIdentity` against the run its replay was armed against, so a fetch that
    /// straddles a relaunch (which truncates `output.log`) cannot install the new run's bytes under the
    /// old run's final frame. `runIdentity` is nil when the server did not report one (the
    /// missing-output error path maps to an empty transcript with no identity).
    ///
    /// `isSuffixRebuild` answers a continuation the daemon could not serve as one (a head-trim moved the
    /// bytes the offset named, or the gap is wider than the page asked for): the payload is then a fresh
    /// replayable suffix, so the caller rebuilds its replay from it instead of appending it.
    public struct RemoteGhosttyTranscript: Sendable {
        public let data: Data
        public let startByteOffset: UInt64
        public let endByteOffset: UInt64
        /// The `output.log` these bytes were read from, which the next continuation sends back so the
        /// daemon can tell an appended transcript from one a head-trim rewrote. Nil when the server
        /// served no file at all (the missing-output error path, which carries no bytes either).
        public let fileIdentity: UInt64?
        public let runIdentity: String?
        public let isSuffixRebuild: Bool

        public init(
            data: Data, startByteOffset: UInt64, endByteOffset: UInt64, fileIdentity: UInt64?, runIdentity: String?, isSuffixRebuild: Bool = false
        ) {
            self.data = data
            self.startByteOffset = startByteOffset
            self.endByteOffset = endByteOffset
            self.fileIdentity = fileIdentity
            self.runIdentity = runIdentity
            self.isSuffixRebuild = isSuffixRebuild
        }
    }

    /// Reads a range of the session's persisted output transcript for the pane's client-local scrollback
    /// replay. Read-only.
    ///
    /// Without `fromByteOffset` the daemon serves the newest `maxBytes` as a replayable suffix, which is
    /// what builds a replay. With it (accompanied by `fileIdentity`, the transcript file the replay's
    /// bytes were read from, which proves the offset still names them), it serves exactly what the
    /// session has appended since, which is what keeps a replay current without rebuilding it.
    public typealias RemoteGhosttyTranscriptProvider =
        @Sendable (_ maxBytes: Int, _ fromByteOffset: UInt64?, _ fileIdentity: UInt64?) async throws -> RemoteGhosttyTranscript

    /// The pane-side terminal host for every Mac pane, the local device's included. "Remote" is relative
    /// to the daemon process that runs the Ghostty core: this host paints the frames that daemon streams
    /// over the Device API and hosts no Ghostty surface of its own, so a local-device pane and a
    /// paired-device pane share this path and differ only in the socket their state model dials.
    @MainActor public final class RemoteGhosttySessionHost: TerminalGhosttySessionHosting {
        private let launchConfiguration: TerminalSessionLaunchConfiguration
        private let paths: TerminalSessionPaths
        private let terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender?
        private let stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber?
        private let transcriptProvider: RemoteGhosttyTranscriptProvider?
        private let agentSignalHandler: RemoteGhosttyAgentSignalHandler?
        /// Notified when an interactive control request — typed input, paste, key, scroll, resize, or
        /// clear-screen — throws. Input rides a different connection than the state subscription, so a
        /// send that cannot reach the device is the earliest evidence the link may be gone — a silently
        /// dead network path leaves the subscription's socket looking healthy until TCP keepalive gives up
        /// a minute or more later. "May be" because a bare request timeout is not conclusive by itself (see
        /// the handler's own doc): the same 5s deadline that catches a dead link also catches an app-side
        /// stall that never touched the network. See `reportInputFailure`, the shared call point every one
        /// of those requests funnels its failure through.
        private let inputFailureHandler: RemoteGhosttyInputFailureHandler?
        private let terminalView: GhosttyMirrorTerminalView
        /// The main actor's mirror of the payload the pipeline stored, updated as each reduction result
        /// is applied. Every main-actor reader below (title, working directory, owner, owner epoch,
        /// runtime grid, ended-run identity, render-state key) reads it rather than the pipeline's copy,
        /// so none of them has to await anything. It therefore lags the pipeline by whatever is in
        /// flight: at most the one payload being reduced, because the consumer awaits each
        /// application before taking the next. Every reader tolerates that: they describe the session as
        /// last rendered, which is exactly what a lagging mirror holds.
        private var latestState: GhosttyRemoteSessionStatePayload?
        /// Reduces incoming payloads off the main actor, in arrival order across every entry point. It
        /// owns the reducer (and so the render-update baseline and the previous stored payload the next
        /// reduce chains from); this host only applies what it hands back.
        private lazy var statePipeline = TerminalRemoteStateReductionPipeline(
            shouldUseFrame: { frame, payload in
                Self.shouldUseRenderFrameSnapshot(frame.snapshot, runtimeState: payload.runtimeState, reason: payload.reasonKind)
            }, apply: { [weak self] output in self?.applyReducedState(output) })
        /// Whether a payload carrying a full frame is in the pipeline and has not been applied yet.
        ///
        /// The pipeline reduces off the main actor, so a host that is built and attached within one
        /// main-actor turn — the lazy pane open, whose registration with the session's state model replays
        /// that model's cached frame synchronously — holds no frame at attach time even though one is
        /// already on its way. Without this, every such open would ask the device for a frame it is about
        /// to receive and pay for a grid-sized export.
        ///
        /// Cleared by ANY apply the pipeline delivers rather than by matching the payload that set it: the
        /// apply mailbox collapses runs of outputs, so the apply that lands can describe a later payload
        /// than the one marked here. Since every submitted payload still produces an apply — its own, or
        /// the one it was collapsed into — clearing on any apply cannot leave this stuck set, and clearing
        /// it early (on an apply for an older payload) costs at most the one resync it exists to avoid.
        private let pendingFullFrameSubmission = PendingFullFrameSubmission()
        /// What `updateHeldScreenUpdates` last told the pipeline, so the reads that answer the question
        /// do not take the mailbox's lock on every apply.
        private var lastHeldScreenUpdates = false
        private var stateStreamClient: GhosttyRemoteSessionStateStreamClient?
        private var directStateStreamClient: (any TerminalRemoteStateStreamClient)?
        private var lastSubscriptionAttemptAt: Date?
        private var directStateFetchInFlight = false
        private var lastRenderUpdateResyncAt: Date?
        /// The one delayed `.state` request owed to a resync the throttle turned away; see
        /// `scheduleTrailingRenderUpdateResync`.
        private var pendingRenderUpdateResyncTask: Task<Void, Never>?
        /// What a landing frame must cover for that delayed request to count as answered. Non-nil exactly
        /// while `pendingRenderUpdateResyncTask` is armed; see `TerminalResyncOwedOrdering` for why a
        /// frame alone is not proof.
        private var owedRenderUpdateResyncOrdering: TerminalResyncOwedOrdering?
        /// How long one resync request paces the next. Only a test overrides it
        /// (`renderUpdateResyncIntervalForTesting`), so a suite can drive the trailing retry to its
        /// boundary instead of waiting out a real second.
        private static let defaultRenderUpdateResyncInterval: TimeInterval = 1
        var renderUpdateResyncIntervalForTesting: TimeInterval?
        private var renderUpdateResyncInterval: TimeInterval { renderUpdateResyncIntervalForTesting ?? Self.defaultRenderUpdateResyncInterval }
        private var attachedClient: TerminalClient?
        private var attachedMode: TerminalAttachmentMode = .viewer
        /// Unit tests inject a uniquely-named pasteboard here so an owner-targeted OSC 52 write never
        /// touches the developer's real clipboard. Nil in the app, where the write goes to
        /// `NSPasteboard.general`.
        var clipboardPasteboardOverrideForTesting: NSPasteboard?
        private var lastRequestedViewportSize: (columns: Int, rows: Int)?
        /// The mirror surface generation the last owner attach measured its viewport against. An attach
        /// that finds a different generation is looking at a rebuilt surface and re-sends the viewport.
        private var lastAttachedSurfaceGeneration: UInt64?
        private var pendingViewportResizeSize: (columns: Int, rows: Int)?
        private var pendingViewportResizeTask: Task<Void, Never>?
        /// The one-turn deferral every measured viewport size waits out before it is sent (see
        /// `handleViewportSizeChange`). A measurement of a *different* size replaces the pending one, so
        /// only the size the layout settled on is ever sent; a measurement of the same size leaves it
        /// alone, so a busy state stream cannot keep postponing it.
        private var pendingViewportSettleTask: Task<Void, Never>?
        /// The size `pendingViewportSettleTask` is waiting to send. Non-nil exactly while that task is
        /// pending — both are cleared together when it fires or is abandoned.
        private var pendingViewportSettleSize: (columns: Int, rows: Int)?
        /// Whether any measurement folded into the pending settle turn asked to be announced even when
        /// it matches the size the daemon last accepted. Sticky across replacement: a forced
        /// measurement superseded by a later one still forces the send of that later size.
        private var pendingViewportSettleForce = false
        private var resizeSerial: UInt64 = 0
        private let inputQueue = TerminalInputSerialQueue()
        /// State of this pane's client-local scrollback replay, for live and ended panes alike: `idle`
        /// until a page is read, `loading` while one is read and the replay is built or extended off the
        /// main actor (accumulating the rows scrolled meanwhile), `ready` once the replay is back on the
        /// main actor, `unavailable` when there is no transcript to replay.
        ///
        /// `loading`'s `model` is the replay that load holds, and a load holding one owns it outright: the
        /// main actor neither scrolls nor appends it until the install hands it back, which is what lets
        /// the work run off the main actor. A whole-budget read holds the replay it is deepening, so the
        /// rebuilt replay can restore its distance above the newest row; a continuation read holds the
        /// replay it is appending its bytes to. It is nil for the first read of a pane, which has no
        /// replay yet. Its `grid` is the grid the read was started at, which is the grid the replay it
        /// builds will wrap its rows at: a resize landing while it is in flight compares against it
        /// exactly as it compares against a built replay's own grid.
        private enum LocalScrollbackState {
            case idle
            case loading(pendingDeltaRows: Int, model: TerminalLocalScrollbackModel?, grid: (columns: Int, rows: Int))
            case ready(TerminalLocalScrollbackModel)
            case unavailable
        }
        private var localScrollbackState: LocalScrollbackState = .idle
        /// Invalidates in-flight transcript reads across a discard. A read started for one run can still
        /// be resolving when the session relaunches (or the user types, or the grid moves) and a fresh
        /// read starts in the same enum case, so an enum-only guard would install the first read's bytes
        /// under the second. `discardLocalScrollback` bumps this, and every post-suspension check
        /// requires an unchanged generation before applying its result.
        private var localScrollbackGeneration: UInt64 = 0
        /// The run the current replay (or `.unavailable` verdict) belongs to: the child process that
        /// wrote the bytes, see `TerminalSessionRuntimeState.runKey(for:)`. `nil` whenever no replay is armed.
        private var localScrollbackRunKey: String?
        /// The appearance the replay was built at, so a theme switch under a built replay rebuilds it
        /// rather than leaving the pane scrolling rows painted in the other appearance's colors.
        private var localScrollbackAppearance: ThemeAppearance?
        /// Monotonic local revision for replay frames, so the mirror's frame-dedupe never drops a
        /// scrolled viewport that happens to match a prior revision.
        private var localScrollbackRevision: UInt64 = 0
        private var localScrollDeltaNormalizer = TerminalScrollDeltaNormalizer()
        /// Whether the pane is currently painting a replay frame instead of the session's own. Distinct
        /// from holding a model: every pane prefetches one after its first paint, and a pane that has not
        /// been scrolled shows the live screen.
        private var isShowingLocalScrollbackFrame = false
        /// Whether this pane has already asked for its prefetch page. One read per armed run: a read that
        /// fails leaves the state `.idle` so the next gesture retries, without every later frame paying
        /// for another attempt.
        private var hasRequestedLocalScrollbackPrefetch = false
        /// The continuation read in flight, if any. A continuation appends below the replay's viewport,
        /// which Ghostty keeps pinned, so the gesture that triggered it keeps scrolling while it flies;
        /// this is what keeps a later gesture from stacking a second read on the first and appending the
        /// same range twice.
        ///
        /// It records which read is in flight rather than merely that one is: discarding and reopening a
        /// replay (a keystroke, a resize, a relaunch) leaves the previous read running, and a bare flag
        /// let that stale read's completion clear the mark the current replay's read had set. The
        /// identity is the pair the completion is already checked against: the load generation it
        /// started under, and the replay it extends.
        private struct LocalScrollbackContinuationRead {
            let generation: UInt64
            let model: TerminalLocalScrollbackModel
        }
        private var localScrollbackContinuationRead: LocalScrollbackContinuationRead?
        /// A rewind owed to a replay a load is holding. Leaving the replay rewinds it to its newest row so
        /// the next gesture starts where the user is looking, but a load that holds the replay owns it
        /// until it installs, so the rewind is recorded here and applied there. Without it the install
        /// would hand back a replay parked at the offset the user just left, and their next gesture would
        /// jump straight back into the history they walked away from.
        private var pendingLocalScrollbackRewind = false
        /// The newest complete frame the session's own stream produced, kept whether or not it was
        /// painted. A pane showing a replay frame keeps reducing live frames underneath it (the session's
        /// viewport never moved), and leaving the replay repaints this, which is what lets the jump
        /// control return to the live screen without asking the daemon for anything.
        private var latestLiveRenderFrame: GhosttyRenderFrame?
        /// Where `output.log` ended as of the newest state payload that reported it. Compared against the
        /// replay's own end offset at a gesture's start, so a gesture pays for a continuation read only
        /// when the session has actually written something since the replay was last brought up to date.
        private var latestTranscriptEndByteOffset: UInt64?
        /// Where one wheel gesture's events go, decided at its first event and held for the rest of it.
        /// Latching is what keeps a frame landing mid-gesture (a program entering the alternate screen,
        /// say) from splitting one flick between the local replay and the daemon.
        private enum ScrollRoute {
            case daemon
            case localReplay
        }
        private var latchedScrollRoute: ScrollRoute?
        /// Whether the gesture in flight was cancelled by the user leaving history on purpose: typing, or
        /// the jump-to-bottom control. Its remaining deltas are dropped rather than routed. Sending them
        /// to the replay would paint the history the user just left back over the live screen the moment
        /// the flick's next momentum event arrives, and sending them to the daemon would move the shared
        /// viewport a local gesture never touches. Cleared wherever the route latch is, so the gesture's
        /// own end (its momentum report, or the idle boundary a phase-less gesture gets instead) is what
        /// lets the next gesture scroll again.
        private var isScrollGestureCancelled = false
        /// When the latched gesture last saw an event. A trackpad flick ends with a momentum phase, but a
        /// mouse wheel's discrete clicks carry no phase at all, so a pause is what separates two turns of
        /// the wheel into two gestures.
        private var lastScrollEventAt: Date?
        private static let scrollGestureIdleInterval: TimeInterval = 0.25
        /// The clock gesture timing is measured against. It is a seam so a test can hold a flick's deltas
        /// inside the idle interval, or cross that boundary on purpose, instead of depending on how long
        /// the run loop happened to take.
        var scrollGestureClock: @MainActor () -> Date = { Date() }
        private lazy var scrollCoalescer = TerminalScrollCoalescer { [weak self] batch, finish in
            guard let self else {
                finish()
                return
            }
            self.enqueueRemoteScrollBatch(batch, onFinished: finish)
        }

        public init(
            launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
            terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender? = nil,
            stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber? = nil, transcriptProvider: RemoteGhosttyTranscriptProvider? = nil,
            agentSignalHandler: RemoteGhosttyAgentSignalHandler? = nil, linkOpenHandler: (@MainActor (String) -> Void)? = nil,
            inputFailureHandler: RemoteGhosttyInputFailureHandler? = nil
        ) {
            self.launchConfiguration = launchConfiguration
            self.paths = paths
            self.terminalServiceRequestSender = terminalServiceRequestSender
            self.stateStreamSubscriber = stateStreamSubscriber
            self.transcriptProvider = transcriptProvider
            self.agentSignalHandler = agentSignalHandler
            self.inputFailureHandler = inputFailureHandler
            terminalView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
            terminalView.onOpenLink = linkOpenHandler
            terminalView.onDisplayStateChanged = { [weak self] _ in self?.updateHeldScreenUpdates() }
            ensureStateStreamStartedIfNeeded()
        }

        /// Makes no isolation assumption: a `deinit` runs on whichever thread dropped the last reference —
        /// a background one whenever an async caller holds the final reference to the pane that owns this
        /// host — so it can neither assume the main actor nor skip its cleanup off it. Skipping is the
        /// worse of the two: it leaves the device's state subscription installed and this host's callbacks
        /// in the model's fan-out for the life of the session (issue #537).
        ///
        /// Task cancellation and the input queue's `cancelAll()` are thread-safe on their own (the queue is
        /// lock-guarded), so they run here. The two stream clients are driven from the main actor
        /// everywhere else, so they are captured as values and stopped there.
        ///
        /// The scroll coalescer needs nothing: this host holds its only strong reference, so it dies with
        /// the host, and the flush task it owns holds it weakly — that task wakes to a deallocated
        /// coalescer and returns without enqueuing anything.
        deinit {
            pendingViewportSettleTask?.cancel()
            pendingViewportResizeTask?.cancel()
            pendingRenderUpdateResyncTask?.cancel()
            inputQueue.cancelAll()
            let stateStreamClient = stateStreamClient
            let directStateStreamClient = directStateStreamClient
            MainThreadDeinitCleanup.run {
                stateStreamClient?.stop()
                directStateStreamClient?.stop()
            }
        }

        public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
            attachedClient = client
            let isInteractive = isInteractiveRuntimeStateForControl()
            attachedMode = isInteractive ? mode : .viewer
            // Any viewport size measured before this attach belongs to the previous attachment's
            // ownership and epoch; the attach below re-announces the current one.
            pendingViewportSettleTask?.cancel()
            pendingViewportSettleTask = nil
            pendingViewportSettleSize = nil
            pendingViewportSettleForce = false
            pendingViewportResizeTask?.cancel()
            pendingViewportResizeTask = nil
            pendingViewportResizeSize = nil
            terminalView.acceptsTerminalInput = isInteractive && mode == .owner
            // Viewers keep the session's real capture flags (their clicks are never forwarded, but the
            // mirror should arbitrate like the session it shows); only an ended session strips them.
            terminalView.sessionPermitsMouseCapture = isInteractive
            terminalView.onSendText = { [weak self] text, asPaste in self?.sendRemoteInput(text, asPaste: asPaste) }
            terminalView.onSendKey = { [weak self] key in self?.sendRemoteKey(key) }
            terminalView.onSendScroll = { [weak self] horizontal, vertical, scrollMods, pointerPosition in
                self?.sendRemoteScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
            }
            terminalView.onJumpToBottom = { [weak self] in self?.handleJumpToBottom() }
            terminalView.onSendMouseButton = { [weak self] button, pressed, pointerPosition in
                self?.sendRemoteMouseButton(button: button, pressed: pressed, pointerPosition: pointerPosition)
            }
            terminalView.onClearSelection = { [weak self] in self?.sendRemoteClearSelection() }
            terminalView.onSetSelection = { [weak self] startColumn, startRow, endColumn, endRow, isRectangle in
                self?.sendRemoteSetSelection(
                    startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow, isRectangle: isRectangle)
            }
            terminalView.onViewportSizeChanged = { [weak self] columns, rows in self?.handleViewportSizeChange(columns: columns, rows: rows) }
            terminalView.onAppearanceChanged = { [weak self] in self?.discardLocalScrollbackIfAppearanceChanged() }

            if let container, terminalView.superview !== container {
                terminalView.removeFromSuperview()
                terminalView.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(terminalView)
                NSLayoutConstraint.activate([
                    terminalView.topAnchor.constraint(equalTo: container.topAnchor),
                    terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
            if let container {
                container.needsLayout = true
                container.layoutSubtreeIfNeeded()
            }
            // Same rule as applyReducedState: while the pane's own replay is showing a scrolled
            // viewport, a re-attach must not clobber it with the session's frame. But if the surface was
            // released and recreated between detach and this attach, repaint the replay viewport so the
            // recreated surface is not left blank.
            if !isLocalScrollbackReplayActive {
                let frame = currentRenderFrameForRenderUpdate()
                terminalView.update(frame: frame, renderStateKey: currentRenderStateKey())
                // Attaching with no frame, and none on the way, leaves nothing to paint and no baseline for
                // the deltas the stream carries — they describe only the cells that changed. That happens
                // when the subscriber's own full frame has not landed yet (this host is built lazily, after
                // its pane's state model has been streaming) and when an owner change scrubbed the render
                // update out of the stored payload. Nothing else on this path would ask: the owner attach's
                // viewport resize below announces nothing when the grid has not moved, and a delta failing
                // to apply is the only other trigger. So ask here instead of waiting for that failure —
                // unless a full frame is already queued for this host, which is the ordinary lazy pane open
                // (see `pendingFullFrameSubmission`). Throttled with every other resync request and
                // satisfied by the `.state` response, so a re-attach while one is in flight adds nothing.
                // Owed by no particular update: this attach found no frame at all, so any frame closes it.
                if frame == nil, !pendingFullFrameSubmission.isPending { requestRenderUpdateStateResync(owedBy: .anyFrame) }
            } else {
                repaintLocalReplayViewportIfSurfaceEmpty()
            }
            if isInteractive && mode == .owner { sendViewportResizeForOwnerAttach() }
        }

        public func releaseRendererSurface() { terminalView.releaseSurface() }

        // `setFocused` is a passive focus-state sync driven by metadata refreshes and app
        // activation (a coding agent rewriting the terminal title fires it many times per
        // second). It must not steal first responder from other controls such as the sidebar or
        // tab rename editor, so the focused branch uses the guarded reclaim, which only grabs
        // focus back when it has fallen to the window floor during mirror re-parenting.
        // Deliberate, user-intent focus (pane clicked, ownership promoted) goes through
        // `focusWindow`, which does steal.
        public func setFocused(_ focused: Bool, for clientID: String) {
            guard clientID == attachedClient?.id else {
                if !focused, terminalView.window?.firstResponder === terminalView { terminalView.window?.makeFirstResponder(nil) }
                return
            }
            if focused { terminalView.restoreFirstResponderIfWindowReady() }
        }

        public func focusWindow(_ window: NSWindow?) { terminalView.focusWindow(window) }

        @discardableResult public func handleKeyEvent(_ event: NSEvent, for clientID: String) -> Bool {
            guard isInteractiveRuntimeStateForControl(), clientID == attachedClient?.id, attachedMode == .owner else { return false }
            return terminalView.handleTerminalKeyEvent(event, requireFirstResponder: false)
        }

        @discardableResult public func synchronizeSurfaceGeometry() -> Bool {
            guard isInteractiveRuntimeStateForControl(), attachedMode == .owner else { return false }
            sendCurrentViewportResizeIfNeeded(force: true)
            return true
        }

        public func activeOwnerClientID() -> String? {
            ensureStateStreamStartedIfNeeded()
            return currentOwnerClientID()
        }

        /// Who owns the session according to the state this host currently holds — the one notion of live
        /// ownership, shared with `activeOwnerClientID()`, which only adds the subscription kick callers
        /// coming from outside need. Split out so a caller already inside the payload-apply path can ask
        /// the same question without re-entering the subscription machinery on every event.
        private func currentOwnerClientID() -> String? {
            guard isInteractiveRuntimeStateForControl() else { return nil }
            return latestState?.attachmentSnapshot?.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        }

        public func hasRenderableSurface() -> Bool { terminalView.hasRenderedContent }

        public func requestSurfaceRefresh() {
            requestDirectStateRefresh(reason: TerminalRemoteSessionStateReason.stateChange.rawValue)
            // Same rule as applyReducedState: a refresh must not clobber a scrolled replay viewport, but
            // it must repaint the replay when the surface was released and recreated underneath it.
            if !isLocalScrollbackReplayActive {
                terminalView.update(frame: currentRenderFrameForRenderUpdate(), renderStateKey: currentRenderStateKey())
            } else {
                repaintLocalReplayViewportIfSurfaceEmpty()
            }
        }

        public func prepareRenderStateExport() {}

        public func snapshot() -> GhosttyTerminalSnapshot? {
            ensureStateStreamStartedIfNeeded()
            return currentSnapshot()
        }

        public func snapshotText() -> String? {
            ensureStateStreamStartedIfNeeded()
            if let renderedSnapshotText = terminalView.renderedSnapshotText(), !renderedSnapshotText.isEmpty { return renderedSnapshotText }
            if let snapshotText = latestSnapshotTextIfCompatible() { return snapshotText }
            if let snapshot = latestSnapshotIfCompatible() { return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot) }
            return nil
        }

        public func sessionSnapshot() -> GhosttyTerminalSnapshot? { snapshot() }

        public func sessionSnapshotText() -> String? { snapshotText() }

        /// The mirror carries the size itself, including across the surface rebuilds
        /// `GhosttyMirrorSurfaceMRU` forces, and re-measures its grid; the measurement reaches the daemon
        /// through `onViewportSizeChanged` like any other resize, so there is nothing to send from here.
        public func applyTerminalTextSize(_ size: TerminalTextSize) { terminalView.applyTerminalTextSize(size) }

        public func copySelectionToPasteboard() -> Bool { terminalView.copySelectionToPasteboard() }

        /// Reads the terminal's current shared selection via `readSelectionText` and writes it to the
        /// pasteboard on success. Not owner-gated, matching the daemon's command. Distinct from
        /// `copySelectionToPasteboard` (this pane's own painted mirror surface), which shows nothing
        /// once the shared selection scrolls out of this viewport: the daemon always has the full text
        /// regardless of what any one viewer can currently see.
        public func copySharedSelectionToPasteboard(completion: @escaping @MainActor (Bool) -> Void) {
            guard isInteractiveRuntimeStateForControl(), let client = attachedClient else {
                completion(false)
                return
            }
            // The daemon-owned selection is anchored in the session's own screen, which the pane is not
            // showing while its replay is on screen; copying it would hand back text the user cannot see.
            guard !isShowingLocalScrollbackFrame else {
                completion(false)
                return
            }
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let pasteboardChangeCountAtCopy = terminalView.selectionPasteboardChangeCount
            // `self` is only captured where this closure is already main-actor isolated (the outer
            // `Task`'s own capture list), never carried through the nested detached closure: passing a
            // main-actor class reference through a nonisolated closure into a later main-actor closure is
            // what the compiler flags as a potential data race, even though nothing here is actually
            // concurrent.
            Task { @MainActor [weak self] in
                let selectionText = await Task.detached(priority: .userInitiated) {
                    let response = try? Self.sendControlRequest(
                        TerminalControlRequest(command: .readSelectionText(.init(clientID: clientID))), sessionID: sessionID, socketPath: socketPath,
                        requestSender: requestSender)
                    return response?.selectionText
                }.value
                guard let self, let selectionText, !selectionText.isEmpty else {
                    completion(false)
                    return
                }
                // A copy the user made while the read was in flight wins: the guarded write yields to
                // it, and the flow still completes as handled because the caller's fallback is another
                // clipboard write that would clobber that newer copy all the same.
                self.terminalView.writeSelectionTextToPasteboard(selectionText, ifPasteboardUnchangedSince: pasteboardChangeCountAtCopy)
                completion(true)
            }
        }

        public func pasteClipboardContents() -> Bool { terminalView.pasteClipboardContents() }

        @discardableResult public func sendTextAsPaste(_ text: String) -> Bool {
            guard !text.isEmpty, isInteractiveRuntimeStateForControl(), attachedClient != nil else { return false }
            sendRemoteInput(text, asPaste: true)
            return true
        }

        @discardableResult public func performBindingAction(_ action: String) -> Bool {
            let permitsFinalRenderReadOnlyAction = !isInteractiveRuntimeStateForControl() && Self.isReadOnlyBindingAction(action)
            guard attachedMode == .owner || permitsFinalRenderReadOnlyAction else { return false }
            return terminalView.performBindingAction(action)
        }

        /// One wheel event, delivered exactly as the mirror view delivers a real one: the host routes it
        /// per gesture to the daemon or to this pane's own replay (see `routeScroll`).
        @discardableResult public func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?
        ) -> Bool { terminalView.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition) }

        @discardableResult public func clearScreenAndScrollback() -> Bool {
            guard isInteractiveRuntimeStateForControl(), attachedClient != nil, attachedMode == .owner else { return false }
            sendRemoteClearScreenAndScrollback()
            return true
        }

        public var debugSurfaceRefreshRequestCount: Int { 0 }
        public var debugSearchState: GhosttyTerminalSearchDebugState { terminalView.debugSearchState }
        public func debugVisibleSurfaceText() -> String? {
            if let renderedSnapshotText = terminalView.renderedSnapshotText(), !renderedSnapshotText.isEmpty { return renderedSnapshotText }
            if let snapshot = currentSnapshot() { return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot) }
            return terminalView.snapshotText()
        }

        /// Delegates to the mirror view's own selection readback: the mirror surface is what paints the
        /// daemon-projected shared selection from streamed frames, so it is the source of truth here too.
        public func debugSurfaceSelectionText() -> String? { terminalView.debugSurfaceSelectionText }

        func debugSetBindingActionHandler(_ handler: (@MainActor (String) -> Bool)?) { terminalView.debugBindingActionHandler = handler }

        /// Whether the pane is painting its own scrollback replay rather than the session's frames.
        var debugIsShowingLocalScrollbackFrame: Bool { isShowingLocalScrollbackFrame }
        /// Where `output.log` ended as of the newest state payload this host has applied, which is what a
        /// gesture compares its replay against before reading a continuation.
        var debugLatestTranscriptEndByteOffset: UInt64? { latestTranscriptEndByteOffset }
        /// Whether a load is holding the pane's replay off the main actor, which is the window a gesture's
        /// rows buffer in rather than scrolling the replay.
        var debugLoadHoldsLocalScrollbackReplay: Bool {
            guard case .loading(_, let model, _) = localScrollbackState else { return false }
            return model != nil
        }
        /// Fires on the main actor the moment a continuation load takes the pane's replay off it, for both
        /// hand-overs a continuation has (appending its bytes, and rebuilding from a served suffix), so a
        /// test can act inside that window. The pane's state is already the state it holds for the whole
        /// hop, and the hop itself is microseconds of libghostty-vt work on a test's page, far too narrow
        /// for a test to aim an enqueued gesture at.
        var debugOnLocalScrollbackReplayHandedToLoad: (@MainActor () -> Void)?
        var debugJumpToBottomControlIsVisible: Bool { terminalView.debugJumpToBottomControlIsVisible }
        var debugJumpToBottomControlShowsNewOutput: Bool { terminalView.debugJumpToBottomControlShowsNewOutput }
        /// Activates the jump-to-bottom control the way a click does, through the control itself, so a
        /// test exercises the wiring the user's click travels.
        func debugActivateJumpToBottom() { terminalView.debugActivateJumpToBottomControl() }
        var debugRecordedBindingActions: [String] { terminalView.debugRecordedBindingActions }

        /// Awaits the serial input queue's current tail, so a test can observe every send enqueued so far
        /// — including one discarded by a `cancelAll()` triggered mid-chain — has settled, instead of
        /// guessing how long that takes.
        func drainInputQueueForTesting() async { await inputQueue.drain() }

        /// How many settle turns have been started (see `handleViewportSizeChange`). A re-measurement of
        /// the size already waiting must not start another one, and that is otherwise invisible: both
        /// behaviors send the same size on a quiet stream, and the difference only shows as a resize held
        /// back across a busy one.
        private(set) var debugViewportSettleScheduleCount = 0

        /// Awaits the pending viewport resize, if any — first the settle turn a measured size waits out
        /// (`handleViewportSizeChange`), then the send task it starts. Resize runs off `inputQueue` in its
        /// own detached task, so a test needs this rather than `drainInputQueueForTesting` to observe its
        /// outcome (including its `reportInputFailure` call) instead of guessing how long it takes.
        func drainPendingResizeForTesting() async {
            await pendingViewportSettleTask?.value
            await pendingViewportResizeTask?.value
        }

        public var effectiveTitle: String {
            ensureStateStreamStartedIfNeeded()
            return latestState?.title ?? latestState?.runtimeState?.title ?? launchConfiguration.title
        }

        public var effectiveWorkingDirectory: String {
            ensureStateStreamStartedIfNeeded()
            return latestState?.workingDirectory ?? latestState?.runtimeState?.workingDirectory ?? launchConfiguration.workingDirectory
        }

        private func ensureStateStreamStartedIfNeeded(now: Date = Date()) {
            if let stateStreamSubscriber {
                startDirectStateStreamIfNeeded(stateStreamSubscriber: stateStreamSubscriber, now: now)
                return
            }
            if terminalServiceRequestSender != nil {
                requestDirectStateRefresh(reason: TerminalRemoteSessionStateReason.initial.rawValue)
                return
            }
            // No device-backed state route was injected (e.g. unit tests). A
            // non-interactive session has no live source and no on-disk final-render
            // cache, so there is nothing to attach.
            guard isInteractiveRuntimeStateForControl() else { return }
            if stateStreamClient?.isConnected == true { return }
            if let lastSubscriptionAttemptAt, now.timeIntervalSince(lastSubscriptionAttemptAt) < 0.5 { return }
            lastSubscriptionAttemptAt = now
            let client = GhosttyRemoteSessionStateStreamClient(
                socketPath: paths.subscriptionSocketPath, onEvent: { [weak self] payload in self?.submitToStatePipeline(payload) },
                onDisconnect: { [weak self] in self?.handleStreamDisconnect() })
            do {
                try client.start()
                stateStreamClient = client
            } catch { stateStreamClient = nil }
        }

        private func startDirectStateStreamIfNeeded(stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber, now: Date) {
            // Register with the device-backed state model even for non-interactive
            // sessions: the model's catch-up `.state` request delivers the final
            // render, replacing the former on-disk final-render cache.
            if directStateStreamClient != nil { return }
            if let lastSubscriptionAttemptAt, now.timeIntervalSince(lastSubscriptionAttemptAt) < 0.5 { return }
            lastSubscriptionAttemptAt = now
            do {
                // The event callback fires off the main actor and submits from there: reduction is the
                // expensive part and it does not need the main actor, so a payload reaches the pipeline
                // without a main-actor hop at all. The capture is weak so a client that outlives this
                // host cannot keep the pipeline reducing frames for an owner that is gone.
                let client = try stateStreamSubscriber(
                    launchConfiguration.sessionID,
                    { [weak statePipeline = statePipeline, pendingFullFrameSubmission] payload in
                        // `submitToStatePipeline`'s body, inlined because this callback deliberately does
                        // not touch `self` (see the capture note above); the marking rule is the same.
                        if payload.renderUpdateKind == .full { pendingFullFrameSubmission.mark() }
                        statePipeline?.submit(payload)
                    },
                    { [weak self] _ in
                        Task { @MainActor [weak self] in
                            // Stop before dropping the reference. The handle this holds is a listener on the
                            // state model's shared subscription, and the model keeps that listener attached
                            // until the handle says otherwise, so releasing it silently would leave this
                            // host's callbacks in the fan-out while the next subscribe below registers a
                            // second listener on top (issue #537).
                            self?.directStateStreamClient?.stop()
                            self?.directStateStreamClient = nil
                            self?.handleStreamDisconnect()
                        }
                    })
                directStateStreamClient = client
            } catch { directStateStreamClient = nil }
        }

        private func requestDirectStateRefresh(reason _: String) {
            guard stateStreamSubscriber == nil else { return }
            requestDirectStateFetch()
        }

        /// A resync means this host has no full frame to draw from: a frame-bearing payload failed to
        /// apply (missing baseline, revision or owner-epoch mismatch), its frame was refused as stale, or
        /// an attach found no frame at all. Each direct `.state` fetch opens a transient connection on the
        /// daemon's subscription socket, so an unthrottled retry loop floods the daemon with
        /// unicast initial exports without converging; space the retries so the stream's own
        /// recovery (the forced full-frame broadcast) can land in between.
        ///
        /// The throttle paces requests; it never discards one. A `.state` read can answer with no render
        /// update at all — the session exports none while its capture holds nothing visible — and it stamps
        /// the throttle just the same, so the next reducer-required resync can land inside a window that
        /// repaired nothing. Dropping it there would leave a session that emits one delta and goes quiet
        /// with a blank pane until some unrelated later event, so a suppressed request arms exactly one
        /// delayed retry at the window boundary instead.
        private func requestRenderUpdateStateResync(owedBy ordering: TerminalResyncOwedOrdering) {
            let now = Date()
            if let lastRenderUpdateResyncAt {
                let elapsed = now.timeIntervalSince(lastRenderUpdateResyncAt)
                if elapsed < renderUpdateResyncInterval {
                    scheduleTrailingRenderUpdateResync(after: renderUpdateResyncInterval - elapsed, owedBy: ordering)
                    return
                }
            }
            // The open-throttle path owes the same guarantee as the throttled one: a fetch already in
            // flight was issued before this resync was owed, so stamping the throttle and letting
            // `requestDirectStateFetch` refuse on `directStateFetchInFlight` would consume the request
            // unsent. Arm the trailing retry instead, exactly as a throttled request does.
            guard !directStateFetchInFlight else {
                scheduleTrailingRenderUpdateResync(after: renderUpdateResyncInterval, owedBy: ordering)
                return
            }
            lastRenderUpdateResyncAt = now
            requestDirectStateFetch()
        }

        /// Arms the one delayed request a throttled resync is owed, and records the ordering that request
        /// has to be answered at. Coalesced: a second suppressed request while this is pending is already
        /// covered by the same timer, so it must not stack a competing one — it only raises the debt to
        /// whichever failure is later (`TerminalResyncOwedOrdering.merged`).
        ///
        /// Cleared when it sends, when a frame covering the recorded ordering lands (`applyReducedState`),
        /// and when the host is torn down (`deinit`), alongside the pane's other pending tasks — so a dead
        /// host can never dial the device.
        ///
        /// The mirror case needs no machinery: an in-flight fetch that completes frameless while nothing is
        /// armed owes nothing, because nothing has failed to reduce since it was issued. Whatever payload
        /// next fails asks again through `requestRenderUpdateStateResync`, and a session that goes quiet
        /// with no payload at all is covered on the far side — the daemon holds its subscriber-baseline arm
        /// until a broadcast actually carries a full frame.
        private func scheduleTrailingRenderUpdateResync(after delay: TimeInterval, owedBy ordering: TerminalResyncOwedOrdering) {
            owedRenderUpdateResyncOrdering = owedRenderUpdateResyncOrdering?.merged(with: ordering) ?? ordering
            armTrailingRenderUpdateResync(after: delay)
        }

        /// The timer behind a request already recorded as owed.
        ///
        /// The request stays owed until a fetch genuinely starts. A `.state` read already in flight refuses
        /// this one (`directStateFetchInFlight`), and that read was issued before this resync was owed, so
        /// it can answer with no render update and repair nothing; treating the refusal as delivery is how
        /// the owed request would go missing. So a retry that lands on one waits out another full window
        /// instead — no spin, the pacing is unchanged since nothing was sent, and the recorded ordering
        /// rides along untouched because the same debt is still outstanding.
        private func armTrailingRenderUpdateResync(after delay: TimeInterval) {
            guard pendingRenderUpdateResyncTask == nil else { return }
            pendingRenderUpdateResyncTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.pendingRenderUpdateResyncTask = nil
                // An ended pane showing its own scrollback replay renders from the transcript, not from
                // session state, so a fetch here would repair nothing it will ever display: the request is
                // abandoned rather than re-armed, and the debt goes with it. A live pane's replay is
                // different - the session's frames keep arriving underneath it and are what the pane shows
                // again the moment the user leaves the replay - so it keeps asking.
                guard self.isInteractiveRuntimeStateForControl() || !self.isLocalScrollbackReplayActive else {
                    self.owedRenderUpdateResyncOrdering = nil
                    return
                }
                guard !self.directStateFetchInFlight else {
                    self.armTrailingRenderUpdateResync(after: self.renderUpdateResyncInterval)
                    return
                }
                self.owedRenderUpdateResyncOrdering = nil
                self.lastRenderUpdateResyncAt = Date()
                self.requestDirectStateFetch()
            }
        }

        private func cancelTrailingRenderUpdateResync() {
            pendingRenderUpdateResyncTask?.cancel()
            pendingRenderUpdateResyncTask = nil
            owedRenderUpdateResyncOrdering = nil
        }

        private func requestDirectStateFetch() {
            guard let terminalServiceRequestSender else { return }
            guard !directStateFetchInFlight else { return }
            directStateFetchInFlight = true
            let sessionID = launchConfiguration.sessionID
            Task { @MainActor [weak self] in
                let result = await Task.detached(priority: .utility) {
                    Self.fetchDirectState(sessionID: sessionID, requestSender: terminalServiceRequestSender)
                }.value
                guard let self else { return }
                self.directStateFetchInFlight = false
                switch result {
                case .success(let fetchResult):
                    // The agent signals are independent of the session's screen state, so they are applied
                    // and acknowledged whatever happens to the render payload below — dropping them would
                    // lose events no later broadcast repeats.
                    self.applyAndAcknowledgeAgentSignals(fetchResult.agentSignals)
                    // Through the same pipeline as the subscription's payloads: a fetched full frame is
                    // the head of a new render-update chain, so it must not overtake a delta already
                    // queued behind it. Marked out-of-band so the reducer can refuse it if the stream has
                    // already carried the session past what this read captured.
                    self.submitToStatePipeline(fetchResult.payload, isOutOfBand: true)
                case .failure(let error):
                    TerminalPerformance.logMetric(
                        "terminal_remote_state_fetch", target: "session=\(sessionID)", elapsedMS: 0, success: false,
                        detail: "error=\(String(describing: error))")
                }
            }
        }

        private struct DirectStateFetchResult: Sendable {
            let payload: GhosttyRemoteSessionStatePayload
            let agentSignals: [TerminalServiceAgentSignalEvent]
        }

        private nonisolated static func fetchDirectState(sessionID: String, requestSender: RemoteGhosttyTerminalServiceRequestSender) -> Result<
            DirectStateFetchResult, Error
        > {
            do {
                let response = try requestSender(TerminalServiceRequest(command: .state(.init(sessionID: sessionID))))
                guard response.ok else { throw remoteTerminalRequestError(response.message) }
                guard let payload = response.sessionState else { throw remoteTerminalRequestError("Remote spacesd did not return terminal state.") }
                return .success(DirectStateFetchResult(payload: payload, agentSignals: response.agentSignals ?? []))
            } catch { return .failure(error) }
        }

        private func applyAndAcknowledgeAgentSignals(_ events: [TerminalServiceAgentSignalEvent]) {
            guard !events.isEmpty, let agentSignalHandler, let terminalServiceRequestSender else { return }
            let acknowledgedIDs: [String]
            do { acknowledgedIDs = try agentSignalHandler(events) } catch {
                TerminalPerformance.logMetric(
                    "terminal_remote_agent_signal_apply", target: "session=\(launchConfiguration.sessionID)", elapsedMS: 0, success: false,
                    detail: "error=\(String(describing: error))")
                return
            }
            guard !acknowledgedIDs.isEmpty else { return }
            let sessionID = launchConfiguration.sessionID
            Task.detached(priority: .utility) {
                _ = try? terminalServiceRequestSender(
                    TerminalServiceRequest(command: .ackAgentSignals(.init(sessionID: sessionID, eventIDs: acknowledgedIDs))))
            }
        }

        private func handleStreamDisconnect() {
            stateStreamClient = nil
            lastSubscriptionAttemptAt = Date()
        }

        /// Hands a payload to the reduction pipeline, noting first whether it carries a full frame this
        /// host has yet to apply (see `pendingFullFrameSubmission`). The note is taken *before* the submit
        /// because the apply that retires it can land as soon as the payload is in.
        ///
        /// `isOutOfBand` marks the response to a direct `.state` read, which the reducer orders against its
        /// own baseline when the payload reaches the head of the queue — the only place that can see a
        /// newer stream payload submitted ahead of it and still reducing.
        private func submitToStatePipeline(_ payload: GhosttyRemoteSessionStatePayload, isOutOfBand: Bool = false) {
            if payload.renderUpdateKind == .full { pendingFullFrameSubmission.mark() }
            statePipeline.submit(payload, isOutOfBand: isOutOfBand)
        }

        /// Tells the pipeline whether this pane's screen updates may wait for the pane to come back on
        /// screen (see `TerminalRemoteStateReductionPipeline.setHoldsScreenUpdates`).
        ///
        /// They may once the pane is off screen AND already holds a frame. The second half is what keeps
        /// a pane from stranding itself: a pane opens with its terminal container hidden, so it is off
        /// screen from the start, and the pane controller unhides that container only once the pane
        /// reports it has content to show (`hasRenderableSurface`), which it can only report after a
        /// frame has been applied. Holding that first frame would leave the pane hidden forever, waiting
        /// to be displayed so it could apply the frame that is what would let it be displayed.
        ///
        /// Called on every display transition and at the end of every apply, so both halves are read
        /// where they change. The compare keeps a displayed pane's per-apply call free of the mailbox
        /// lock.
        ///
        /// `releaseRendererSurface` drops the retained frame, so a pane whose surface is released while
        /// it is off screen keeps holding with nothing left to show. That cannot strand the pane: the
        /// pane controller strips the container on release and re-attaches when the pane is next shown,
        /// and that attach both puts the view back in a window (releasing the hold) and asks for a
        /// resync when it finds no frame. Falling past the warm-surface cap does not reach this case at
        /// all, since the MRU frees the mirror through `evictMirrorSurface` and keeps the frame.
        private func updateHeldScreenUpdates() {
            let holds = !terminalView.isDisplayed && terminalView.hasRenderedSurfaceContent
            guard holds != lastHeldScreenUpdates else { return }
            lastHeldScreenUpdates = holds
            statePipeline.setHoldsScreenUpdates(holds)
        }

        private func isInteractiveRuntimeStateForControl() -> Bool {
            if let runtimeState = latestState?.runtimeState { return runtimeState.state.isInteractive }
            return true
        }

        private static func isReadOnlyBindingAction(_ action: String) -> Bool {
            switch action {
            case "copy_to_clipboard", "select_all", "end_search": return true
            default: return false
            }
        }

        /// Applies one payload the pipeline reduced. Everything here needs the main actor: the terminal
        /// view, the state the clipboard one-shot reads, the resync request, the metrics, and the
        /// notifications.
        private func applyReducedState(_ output: TerminalRemoteStateReductionOutput) {
            // Any apply at all retires the pending-full-frame note, whichever payload it describes; see
            // `pendingFullFrameSubmission` for why matching them would be the wrong rule.
            pendingFullFrameSubmission.clear()
            let incomingPayload = output.incomingPayload
            // The one-shot runs first and unconditionally: a clipboard write is an event, not state, and
            // whichever route delivered it may have done so out of order with respect to the state
            // payloads around it (see `DeviceTerminalSessionStateModel.apply`). Running it ahead of the
            // `latestState` move below is what keeps its ownership check reading the same state it read
            // when the reduction was inline.
            applyClipboardWrite(from: incomingPayload)
            // A `clipboard_write` payload carries nothing else to apply — the reason exports no screen
            // state, and its runtime/attachment snapshot is a repeat of the output turn that carried the
            // escape sequence, so the pipeline reduces nothing for it.
            guard let reduction = output.reduction else { return }
            let payload = reduction.payload
            let decodedFrame = reduction.frameToApply
            let decodedUpdate = reduction.decodedUpdate
            let decodeMS = output.reduceMS
            let dropReason = reduction.dropReason
            latestState = reduction.storedPayload
            // Covers a resync the pipeline's apply mailbox inherited from an output it coalesced away:
            // the superseded frame is not worth drawing, but the full frame it could not build is.
            //
            // The ordering the resync is owed at comes from this output's own decoded update even when the
            // request was inherited: the surviving output is never older than the one it replaced, so its
            // target is at or past the failure's, and an output with no decodable target records `unknown`,
            // which no frame retires.
            if output.requestsResync { requestRenderUpdateStateResync(owedBy: .forFailedUpdate(decodedUpdate)) }
            lastSubscriptionAttemptAt = nil
            let frameForUpdate = reduction.frameToApply
            // A frame that covers the failure the pending resync was armed for repaired the chain, so that
            // resync is no longer owed. Covering it is what makes the retirement sound — a fetch answered
            // before the failure was owed lands a frame that applies and yet leaves this host behind the
            // session (see `TerminalResyncOwedOrdering`). Ordered after the request above so an output that
            // both carries a frame and inherits a coalesced-away resync retires that request rather than
            // leaving it armed.
            if let frameForUpdate, let owed = owedRenderUpdateResyncOrdering,
                owed.isSatisfied(byFrameOwnerEpoch: frameForUpdate.ownerEpoch, sessionRevision: frameForUpdate.sessionRevision)
            {
                cancelTrailingRenderUpdateResync()
            }
            let applyStartedAt = Date()
            // A relaunch truncates `output.log`, so a replay built from the previous run's bytes describes
            // a transcript that is gone: discard it and let the new run's frames render. Detected by run
            // rather than by the session becoming interactive, because a relaunch-and-exit unobserved by
            // this client (disconnected, or between refreshes) surfaces as another *ended* payload, which
            // an interactive check alone would miss.
            if let armedRunKey = localScrollbackRunKey, TerminalSessionRuntimeState.runKey(for: currentRunIdentity()) != armedRunKey {
                discardLocalScrollback()
            }
            // Kept whether or not it is painted: a pane showing its replay repaints this when the user
            // leaves the replay, which is what makes that jump cost no request (see `handleJumpToBottom`).
            if let frameForUpdate { latestLiveRenderFrame = frameForUpdate }
            discardLocalScrollbackIfGridChanged(frame: frameForUpdate)
            // Covers a clear issued by any other client, whose only news of it is this payload: the daemon
            // records the clear in the transcript and broadcasts it under this reason, stamping no
            // transcript end, so the offset and `.output` rules below would leave a replay holding the very
            // rows the clear removed until the next payload that does report output. Asked of the union of
            // this apply and everything the mailbox folded into it, because a clear the main actor was too
            // busy to apply on its own arrives folded into the next full frame, whose own reason says
            // nothing about it.
            if output.reportsClearScreen { discardLocalScrollback() }
            // Two things at once, both from this payload's own report of where `output.log` ends.
            //
            // That offset is what a gesture compares its replay against before paying for a continuation
            // read, and the newest payload's report wins outright, decreases included: a head-trim
            // rewrites the file and moves its end backwards, and a gesture has to hear about that to read
            // again (the transcript file the read names is what turns it into a rebuild).
            //
            // Its moving is also what proves the session printed, which is what the jump control's
            // new-output mark reports. A frame's mere arrival is not proof: a resize, an appearance
            // repaint, and another viewer's shared-selection change all export a fresh full frame with
            // nothing new in the transcript, and counting those would tell a reader scrolled into history
            // there is new output to come back to when there is none. Only `.output` payloads stamp the
            // offset, so a payload carrying none is read by its reason instead, which is the same rule
            // the phone reads a payload by (`TerminalViewerModel.outputCarriesNewLocalScrollbackOutput`),
            // since both clients are answering the same question about the same apply.
            //
            // Both halves are asked of the union of this apply and everything the mailbox folded into it
            // (`reportedOutputEndByteOffset`, `reportsTranscriptOutput`). A main actor that fell behind
            // leaves the `.output` payload folded into a later full frame that stamps no offset and
            // carries another reason, and reading only the survivor's own fields would leave a replay
            // built before that output never asking for the bytes it is missing.
            //
            // A reported offset of zero is read as no report: the daemon stamps the offset by seeking to
            // the end of `output.log` after appending the bytes it just wrote, so a real `.output` report
            // always lands past zero. Requiring a positive value is also what makes the unsigned
            // conversion below total.
            let reportsNewOutput: Bool
            if let outputEndByteOffset = output.reportedOutputEndByteOffset, outputEndByteOffset > 0 {
                reportsNewOutput = UInt64(outputEndByteOffset) != latestTranscriptEndByteOffset
                latestTranscriptEndByteOffset = UInt64(outputEndByteOffset)
            } else {
                reportsNewOutput = output.reportsTranscriptOutput
            }
            if !isLocalScrollbackReplayActive, frameForUpdate != nil || !terminalView.hasRenderedSurfaceContent {
                terminalView.update(frame: frameForUpdate, renderStateKey: currentRenderStateKey())
            } else if isLocalScrollbackReplayActive {
                // The pane is committed to its replay, so this state's frame is kept rather than painted.
                // Output that arrived while the pane is committed is marked on the jump control even before
                // a replay frame is on screen (a gesture can still be waiting on its first page), because
                // that page's install is what will show the rows this output landed beneath.
                if reportsNewOutput { terminalView.setLocalScrollbackHasNewOutput(true) }
                // Repaint the replay viewport when the state update arrives on a surface that was released
                // and recreated underneath it.
                repaintLocalReplayViewportIfSurfaceEmpty()
            }
            let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
            // An off-screen pane starts holding its screen updates as soon as it has a frame to show, and
            // this apply is what can have given it one.
            updateHeldScreenUpdates()
            if attachedMode == .owner { sendCurrentViewportResizeIfNeeded(force: false) }
            // The pane has a frame, so it has a grid to build a replay at: read its first page now so the
            // user's first wheel event scrolls instead of waiting out a round trip.
            prefetchLocalScrollbackIfNeeded()
            // The attribute dictionary below is ~20 string conversions per payload on a path that runs
            // at the session's flush rate, so it is built only when something is listening. `emittedAt`
            // is parsed inside the same gate for the same reason: it feeds nothing but these metrics.
            let deviceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
            if deviceLoggingEnabled || TerminalPerformance.isEnabled {
                let emittedAt = GhosttyRemoteSessionStateTimestamp.date(from: payload.emittedAt) ?? Date()
                var renderUpdateAttributes = GhosttyRenderFrameMetrics.attributes(
                    reason: payload.reason, frame: decodedFrame, frameByteCount: incomingPayload.renderUpdate?.count, decodeMS: decodeMS,
                    outputByteCount: payload.outputByteCount, screenStateRevision: payload.screenStateRevision,
                    dropped: incomingPayload.renderUpdate == nil ? nil : dropReason != nil, dropReason: dropReason, renderMode: "ghostty-mirror",
                    frameKind: decodedUpdate?.frameKindMetricValue, baseRevision: decodedUpdate?.baseRevision,
                    targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
                    appliedRevision: frameForUpdate == nil ? nil : (payload.screenStateRevision ?? frameForUpdate?.sessionRevision), applyMS: applyMS,
                    operationCount: decodedUpdate?.operationCount, changedCellCount: decodedUpdate?.changedCellCount,
                    scrollOperationCount: decodedUpdate?.scrollOperationCount, fullFrameFallbackReason: decodedUpdate?.fallbackReason,
                    resyncCount: output.requestsResync ? 1 : nil)
                renderUpdateAttributes["render_update"] = incomingPayload.renderUpdate == nil ? "0" : "1"
                // The codec blob's bytes: `JSONDecoder` has already undone the wire's base64, and the codec
                // has not yet inflated the compressed body, so this is neither the wire size nor the
                // decoded body size. Matches the iOS sibling emit so the two lanes' numbers compare.
                renderUpdateAttributes["render_update_bytes"] = String(incomingPayload.renderUpdate?.count ?? 0)
                // The payloads this apply superseded report nothing of their own; this is their trace.
                renderUpdateAttributes["coalesced_applies"] = String(output.coalescedAwayCount)
                if deviceLoggingEnabled {
                    SpacesDeviceTerminalPerformanceLogger.emit(
                        .init(
                            sessionID: payload.sessionID, source: "mac-mirror", name: "render_frame_payload_receive",
                            elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt), count: incomingPayload.renderUpdate?.count,
                            attributes: renderUpdateAttributes))
                }
                TerminalPerformance.logMetric(
                    "terminal_remote_state_receive", target: "session=\(payload.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt), success: true,
                    detail:
                        "reason=\(payload.reason) render_update=\(incomingPayload.renderUpdate == nil ? 0 : 1) bytes=\(payload.outputByteCount ?? 0) render_update_bytes=\(incomingPayload.renderUpdate?.count ?? 0)"
                )
                TerminalPerformance.logMetric(
                    "terminal_render_frame_payload_receive", target: "session=\(payload.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt), success: dropReason == nil,
                    detail: GhosttyRenderFrameMetrics.detailString(renderUpdateAttributes))
            }
            postLocalNotifications(for: output)
        }

        /// Applies a program's OSC 52 copy to this machine's pasteboard when this client owns the
        /// session and the write is addressed to it.
        ///
        /// The payload fans out to every subscriber, so the target check is what makes it the owner's
        /// clipboard and nobody else's. Read from the incoming payload rather than `latestState`: the
        /// merge deliberately drops the field, so the write is applied exactly once, on arrival — and on
        /// arrival is before any state reduction, so no ordering rule can swallow it.
        private func applyClipboardWrite(from payload: GhosttyRemoteSessionStatePayload) {
            guard let clipboardWrite = payload.clipboardWrite else { return }
            // Ownership comes from the state this host currently holds, never from `attachedMode`: that is
            // the mode this pane last REQUESTED, and it still reads `.owner` after a takeover elsewhere
            // demoted this one (the demotion releases the surface without re-attaching as a viewer) and
            // after the session ended. Because the copy deliberately bypasses timestamp ordering, a delayed
            // event addressed to the former owner would otherwise overwrite this Mac's clipboard while
            // another device owns the session.
            guard let attachedClientID = attachedClient?.id, currentOwnerClientID() == attachedClientID else { return }
            guard clipboardWrite.targetClientID == attachedClientID else { return }
            GhosttyClipboardBridge.writePlainText(clipboardWrite.text, to: clipboardPasteboardOverrideForTesting ?? .general)
        }

        /// Posts `output.notificationNames`, the union across every reason this apply stands for: its
        /// own plus every reason it collapsed away. A collapsed-away `runtime_state` never reaches this
        /// call on its own apply, but it still owes its consumer a refresh, so the survivor posts for it.
        private func postLocalNotifications(for output: TerminalRemoteStateReductionOutput) {
            let sessionID = output.incomingPayload.sessionID
            for name in output.notificationNames { TerminalSessionNotification.post(name, sessionID: sessionID) }
        }

        private func currentSnapshot() -> GhosttyTerminalSnapshot? { latestSnapshotIfCompatible() }

        private func currentRenderFrameForRenderUpdate() -> GhosttyRenderFrame? {
            guard let frame = latestState?.decodedRenderUpdate?.fullFrame,
                Self.shouldUseRenderFrameSnapshot(frame.snapshot, runtimeState: latestState?.runtimeState, reason: latestState?.reasonKind)
            else {
                guard !terminalView.hasRenderedSurfaceContent else { return nil }
                return nil
            }
            return frame
        }

        private func latestSnapshotIfCompatible() -> GhosttyTerminalSnapshot? {
            guard let snapshot = latestState?.renderSnapshot,
                Self.shouldUseRenderFrameSnapshot(snapshot, runtimeState: latestState?.runtimeState, reason: latestState?.reasonKind)
            else { return nil }
            return snapshot
        }

        private func latestSnapshotTextIfCompatible() -> String? {
            guard let snapshot = latestSnapshotIfCompatible() else { return nil }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot)
        }

        private func currentRenderStateKey() -> String {
            let snapshot = currentSnapshot()
            let snapshotColumns = snapshot?.columns ?? 0
            let snapshotRows = snapshot?.rows ?? 0
            let runtimeColumns = latestState?.runtimeState?.columns ?? 0
            let runtimeRows = latestState?.runtimeState?.rows ?? 0
            let ownerEpoch = latestState?.renderOwnerEpoch ?? 0
            return "runtime=\(runtimeColumns)x\(runtimeRows)|frame=\(snapshotColumns)x\(snapshotRows)|ownerEpoch=\(ownerEpoch)"
        }

        private func sendRemoteInput(_ text: String, asPaste: Bool) {
            guard isInteractiveRuntimeStateForControl() else {
                TerminalPerformance.logLine("spaces: input_trace point=send_input_not_interactive session=\(launchConfiguration.sessionID)\n")
                return
            }
            guard let client = attachedClient else {
                TerminalPerformance.logLine("spaces: input_trace point=send_input_no_client session=\(launchConfiguration.sessionID)\n")
                return
            }
            leaveLocalScrollbackForInput()
            scrollCoalescer.flush()
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let ownerEpoch = latestState?.renderOwnerEpoch
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            let inputFailureHandler = self.inputFailureHandler
            let queue = inputQueue
            queue.enqueue(
                priority: .userInitiated,
                operation: {
                    _ = try Self.sendControlRequest(
                        TerminalControlRequest(
                            command: .send(
                                .init(text: text, bytes: nil, clientID: clientID, ownerEpoch: ownerEpoch, appendNewline: false, asPaste: asPaste))),
                        sessionID: sessionID, socketPath: socketPath, requestSender: requestSender)
                    if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "input") } }
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) })
        }

        private func sendRemoteKey(_ key: String) {
            guard isInteractiveRuntimeStateForControl() else {
                TerminalPerformance.logLine("spaces: input_trace point=send_key_not_interactive session=\(launchConfiguration.sessionID)\n")
                return
            }
            if TerminalKeyInput.hostAction(for: key) == .clearScreenAndScrollback {
                sendRemoteClearScreenAndScrollback()
                return
            }
            guard let client = attachedClient else {
                TerminalPerformance.logLine("spaces: input_trace point=send_key_no_client session=\(launchConfiguration.sessionID)\n")
                return
            }
            leaveLocalScrollbackForInput()
            scrollCoalescer.flush()
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let ownerEpoch = latestState?.renderOwnerEpoch
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            let inputFailureHandler = self.inputFailureHandler
            let queue = inputQueue
            queue.enqueue(
                priority: .userInitiated,
                operation: {
                    _ = try Self.sendControlRequest(
                        TerminalControlRequest(command: .key(.init(key: key, clientID: clientID, ownerEpoch: ownerEpoch))), sessionID: sessionID,
                        socketPath: socketPath, requestSender: requestSender)
                    if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "input") } }
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) })
        }

        /// Sends one button press or release. Deliberately not coalesced the way scroll is: a click is a
        /// discrete event whose press/release ordering the application depends on, so it rides the same
        /// user-initiated input queue as a key, flushing any pending scroll batch first so the
        /// application sees the two in the order the user produced them.
        private func sendRemoteMouseButton(button: UInt8, pressed: Bool, pointerPosition: TerminalScrollPointerPosition?) {
            guard isInteractiveRuntimeStateForControl() else { return }
            guard let client = attachedClient, attachedMode == .owner else { return }
            scrollCoalescer.flush()
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let ownerEpoch = latestState?.renderOwnerEpoch
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            let inputFailureHandler = self.inputFailureHandler
            let queue = inputQueue
            queue.enqueue(
                priority: .userInitiated,
                operation: {
                    _ = try Self.sendControlRequest(
                        TerminalControlRequest(
                            command: .mouseButton(
                                .init(
                                    clientID: clientID, ownerEpoch: ownerEpoch, button: button, pressed: pressed, pointerX: pointerPosition?.x,
                                    pointerY: pointerPosition?.y, pointerMods: pointerPosition?.mods))), sessionID: sessionID, socketPath: socketPath,
                        requestSender: requestSender)
                    if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "mouse_button") } }
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) })
        }

        /// Clears the terminal's shared selection. Not owner-gated (matches the daemon's
        /// `clearSelection` command): any attached client's plain click can clear a selection any
        /// other client set.
        private func sendRemoteClearSelection() {
            guard isInteractiveRuntimeStateForControl(), let client = attachedClient else { return }
            guard !isShowingLocalScrollbackFrame else { return }
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let inputFailureHandler = self.inputFailureHandler
            let queue = inputQueue
            queue.enqueue(
                priority: .userInitiated,
                operation: {
                    _ = try Self.sendControlRequest(
                        TerminalControlRequest(command: .clearSelection(.init(clientID: clientID))), sessionID: sessionID, socketPath: socketPath,
                        requestSender: requestSender)
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) })
        }

        /// Reports a completed local drag as the terminal's new shared selection, in absolute
        /// screen-space coordinates. Not owner-gated, matching the daemon's `setSelection` command.
        /// The response's `selectionText` is the single writer for this pasteboard write: see
        /// `GhosttyMirrorAppService`'s suppressed `GHOSTTY_CLIPBOARD_SELECTION` write for why the
        /// mirror's own local copy-on-select must not also write here. The write is therefore a round
        /// trip behind the drag, which is inherent to writing the daemon's authoritative text: a paste
        /// issued inside that window still sees the previous clipboard, and a copy the user makes
        /// inside it wins over the response via the change-count guard below.
        private func sendRemoteSetSelection(startColumn: UInt16, startRow: UInt32, endColumn: UInt16, endRow: UInt32, isRectangle: Bool) {
            guard isInteractiveRuntimeStateForControl(), let client = attachedClient else { return }
            // A drag over the replay selects rows out of the pane's own copy of the transcript, whose
            // coordinates mean nothing to the session: the shared selection stays where the session put it,
            // and the drag is the mirror surface's own local selection, copyable on its own.
            guard !isShowingLocalScrollbackFrame else { return }
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let inputFailureHandler = self.inputFailureHandler
            selectionCommitGeneration += 1
            let commitGeneration = selectionCommitGeneration
            let pasteboardChangeCountAtCommit = terminalView.selectionPasteboardChangeCount
            let queue = inputQueue
            queue.enqueue(
                priority: .userInitiated,
                operation: { [weak self] in
                    let response = try Self.sendControlRequest(
                        TerminalControlRequest(
                            command: .setSelection(
                                .init(
                                    clientID: clientID, startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow,
                                    rectangle: isRectangle))), sessionID: sessionID, socketPath: socketPath, requestSender: requestSender)
                    // A direct cross-actor call (`await self?.method(...)`), not a nested `Task` closure:
                    // wrapping this in another closure would carry `self` through the same
                    // nonisolated-into-main-actor capture the compiler flags as a data-race risk.
                    if let selectionText = response.selectionText {
                        await self?.writeSelectionTextToPasteboard(
                            selectionText, forCommitGeneration: commitGeneration, ifPasteboardUnchangedSince: pasteboardChangeCountAtCommit)
                    }
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) })
        }

        /// Monotonic count of committed drags, so only the NEWEST commit's response may write the
        /// pasteboard. Two drags can finish inside one round trip; without this gate the earlier
        /// response's write would move the pasteboard change count and make the newer response's
        /// unchanged-pasteboard guard reject the newer text.
        private var selectionCommitGeneration = 0

        /// Writes `setSelection`'s confirmed selection text to the pasteboard. Called from
        /// `sendRemoteSetSelection`'s off-main input queue via a direct cross-actor call. Writes only
        /// for the newest committed drag, and only while the pasteboard still holds what it held at
        /// that commit, so a copy the user made during the round trip is never overwritten.
        private func writeSelectionTextToPasteboard(
            _ text: String, forCommitGeneration commitGeneration: Int, ifPasteboardUnchangedSince changeCount: Int
        ) {
            guard commitGeneration == selectionCommitGeneration else { return }
            terminalView.writeSelectionTextToPasteboard(text, ifPasteboardUnchangedSince: changeCount)
        }

        private func sendRemoteClearScreenAndScrollback() {
            guard isInteractiveRuntimeStateForControl() else { return }
            guard let client = attachedClient else { return }
            leaveLocalScrollbackForInput()
            // The daemon records the clear in the transcript, so a fresh read reproduces it while the
            // replay already built predates it: discarded unconditionally, not just when a replay is on
            // screen the way `leaveLocalScrollbackForInput` is, because a clear sent from the live bottom
            // leaves the prefetched replay holding the very rows the clear removed.
            //
            // Discarded here at the send rather than left to the `.clearScreen` payload the daemon
            // broadcasts back, so a gesture made during the round trip cannot scroll the stale rows.
            discardLocalScrollback()
            scrollCoalescer.flush()
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let ownerEpoch = latestState?.renderOwnerEpoch
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            let inputFailureHandler = self.inputFailureHandler
            let queue = inputQueue
            queue.enqueue(
                priority: .userInitiated,
                operation: {
                    _ = try Self.sendControlRequest(
                        TerminalControlRequest(command: .clearScreen(.init(clientID: clientID, ownerEpoch: ownerEpoch))), sessionID: sessionID,
                        socketPath: socketPath, requestSender: requestSender)
                    if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "clear_screen") } }
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) })
        }

        /// Sends the jump-to-bottom control's request. Gated exactly like `sendRemoteScroll`: only an
        /// owner on an interactive session can move the shared viewport, which is also the condition the
        /// control itself is hidden behind (`GhosttyMirrorTerminalView.updateJumpToBottomControlVisibility`).
        /// This guard is what makes that visibility gate load-bearing rather than cosmetic.
        private func sendRemoteScrollToBottom() {
            guard isInteractiveRuntimeStateForControl() else { return }
            guard let client = attachedClient, attachedMode == .owner else { return }
            // Flush first: a scroll batch already queued behind this call would otherwise land after the
            // jump and walk the viewport back up into scrollback the instant it arrives.
            scrollCoalescer.flush()
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let ownerEpoch = latestState?.renderOwnerEpoch
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            let inputFailureHandler = self.inputFailureHandler
            let queue = inputQueue
            queue.enqueue(
                priority: .userInitiated,
                operation: {
                    _ = try Self.sendControlRequest(
                        TerminalControlRequest(command: .scrollToBottom(.init(clientID: clientID, ownerEpoch: ownerEpoch))), sessionID: sessionID,
                        socketPath: socketPath, requestSender: requestSender)
                    if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "scroll_to_bottom") } }
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) })
        }

        private func sendRemoteScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?) {
            routeScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
        }

        // MARK: - Client-local scrollback replay

        /// Where one wheel gesture's events go, decided at the gesture's first event from the session's
        /// own newest frame and held for the rest of the gesture (`routeScroll` expires the latch, so a
        /// latched route here is by definition still the current gesture's):
        ///
        /// - An ended session has no live renderer left to scroll, so its gesture is always local.
        /// - A session on the alternate screen has no scrollback of its own (the gesture belongs to the
        ///   full-screen program), and one tracking the mouse wants the wheel as a mouse report. Both
        ///   forward every event to the daemon.
        /// - Everything else scrolls this pane's own replay of the session's transcript. The daemon is
        ///   never told, so the session's viewport stays where it is for every client watching it, and no
        ///   wheel event costs a round trip (issue #693).
        ///
        /// A pane watching a session another device owns never gets here: it holds no mirror surface at
        /// all, because the pane controller shows the takeover status UI in place of terminal content, so
        /// this routing only ever runs for the pane that owns the session or for an ended session's final
        /// frame.
        ///
        /// Read from the session's frame, never from the replay's: the replay's flags describe the bytes
        /// it has replayed, while the question here is what the session the user is scrolling is doing.
        private func scrollRoute() -> ScrollRoute {
            if let latchedScrollRoute { return latchedScrollRoute }
            guard isInteractiveRuntimeStateForControl() else { return .localReplay }
            // A pane with no frame yet cannot say what the session is doing, and has no replay to scroll
            // either (a replay is read only once a frame has been painted), so its gesture goes where every
            // gesture went before panes had a local viewport at all.
            guard let snapshot = latestLiveRenderFrame?.snapshot else { return .daemon }
            return snapshot.alternateScreenActive || snapshot.mouseReportingActive ? .daemon : .localReplay
        }

        /// Routes one wheel event, latching the gesture on its first and ending the latch when the
        /// trackpad reports the momentum is over or the wheel has gone quiet.
        private func routeScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?) {
            let now = scrollGestureClock()
            // Ending the idle gesture BEFORE the route is decided is what makes the first event after a
            // pause a gesture *start*. A mouse wheel's clicks and a slow trackpad drag never report a
            // momentum phase, so the pause is the only thing that ends those gestures, and a latch left
            // standing across it would leave every later burst mid-gesture: the route would never be
            // re-decided and no burst would pay for the continuation read that brings the replay up to
            // date with what the session wrote in between.
            expireLatchedScrollRouteIfIdle(now: now)
            // A gesture the user cancelled by leaving history goes nowhere for the rest of its life: not
            // to the replay, and not to the daemon either. The clock keeps running so the idle boundary
            // measures from this gesture's last event, and a momentum report ends it as it ends any other.
            guard !isScrollGestureCancelled else {
                lastScrollEventAt = now
                endScrollGestureIfMomentumFinished(scrollMods: scrollMods)
                return
            }
            let route = scrollRoute()
            let isGestureStart = latchedScrollRoute == nil
            latchedScrollRoute = route
            lastScrollEventAt = now
            switch route {
            case .daemon:
                // A gesture rerouted to the daemon must not drive a hidden screen: leave the stale replay
                // before its wheel reaches the program that changed screens underneath it.
                if isGestureStart, isShowingLocalScrollbackFrame { returnToLiveScreenFromLocalScrollback() }
                if isInteractiveRuntimeStateForControl(), attachedClient != nil, attachedMode == .owner {
                    scrollCoalescer.append(
                        horizontal: Double(horizontal), vertical: Double(vertical), scrollMods: scrollMods, pointerPosition: pointerPosition)
                }
            case .localReplay:
                if isGestureStart { loadLocalScrollbackContinuationIfBehind() }
                scrollLocalReplay(vertical: vertical, scrollMods: scrollMods)
            }
            endScrollGestureIfMomentumFinished(scrollMods: scrollMods)
        }

        /// A flick's last event says the momentum is over, which ends the gesture without waiting out the
        /// idle pause, so the next flick starts a fresh one and pays for its own continuation read.
        private func endScrollGestureIfMomentumFinished(scrollMods: Int32) {
            switch TerminalScrollModifiers.momentumPhase(scrollMods) {
            case .ended, .cancelled: endScrollGesture()
            case .none, .changed, .mayBegin: break
            }
        }

        /// Ends a latched gesture that has gone quiet for `scrollGestureIdleInterval`, which is the only
        /// end a phase-less wheel gesture ever gets.
        private func expireLatchedScrollRouteIfIdle(now: Date) {
            guard let lastScrollEventAt, now.timeIntervalSince(lastScrollEventAt) >= Self.scrollGestureIdleInterval else { return }
            endScrollGesture()
        }

        /// Forgets everything that belongs to the gesture that just ended, so the next event is a gesture
        /// start: it re-decides its route, pays for its own continuation read, and scrolls even when the
        /// gesture before it was cancelled.
        private func endScrollGesture() {
            latchedScrollRoute = nil
            lastScrollEventAt = nil
            isScrollGestureCancelled = false
        }

        /// Marks the gesture in flight cancelled, for the two things that leave history on purpose while
        /// one is running: typing, and the jump-to-bottom control. Only a gesture actually in flight can
        /// be cancelled, since with no latch there is nothing whose remaining deltas could paint history
        /// back over the screen the user just returned to.
        private func cancelActiveScrollGesture() {
            guard latchedScrollRoute != nil else { return }
            isScrollGestureCancelled = true
            // The rows this gesture put on a load that has not installed yet go with it, for the reason the
            // rest of its deltas do: the pane is leaving the replay, and applying them at the install would
            // paint history back over the screen the user just returned to.
            guard case .loading(let pendingDeltaRows, let model, let grid) = localScrollbackState, pendingDeltaRows != 0 else { return }
            localScrollbackState = .loading(pendingDeltaRows: 0, model: model, grid: grid)
        }

        /// Scrolls the replay by one wheel event's worth of rows, reading the first page if this pane has
        /// none yet.
        private func scrollLocalReplay(vertical: CGFloat, scrollMods: Int32) {
            guard attachedClient != nil else { return }
            discardLocalScrollbackIfAppearanceChanged()
            let deltaRows = localScrollDeltaNormalizer.terminalViewportDeltaRows(vertical: Double(vertical), scrollMods: scrollMods)
            switch localScrollbackState {
            case .unavailable: return
            case .ready(let model):
                guard deltaRows != 0 else { return }
                applyLocalScroll(deltaRows: deltaRows, model: model)
            case .loading(let pendingDeltaRows, let model, let grid):
                // The replay belongs to the load while it is held, so the rows wait here and are applied
                // when the install hands it back.
                localScrollbackState = .loading(pendingDeltaRows: pendingDeltaRows + deltaRows, model: model, grid: grid)
            case .idle:
                // A sub-cell nudge normalizes to zero rows; wait for a real scroll before paying to read
                // and replay the transcript.
                guard deltaRows != 0 else { return }
                loadLocalScrollbackPage(
                    maxBytes: TerminalScrollbackBudget.initialLocalScrollbackPageBytes, deepening: nil, pendingDeltaRows: deltaRows, kind: .gesture)
            }
        }

        /// Applies one scroll to the replay and paints what it produced. A gesture that runs into the
        /// oldest row the replay holds reads the whole scrollback budget once and rebuilds from it,
        /// carrying the rows the replay could not apply onto the deeper replay so a flick that crosses the
        /// boundary does not lose everything past it.
        private func applyLocalScroll(deltaRows: Int, model: TerminalLocalScrollbackModel) {
            let scroll = model.scroll(deltaRows: deltaRows)
            showLocalScrollbackPosition(model, snapshot: scroll.snapshot)
            guard deltaRows < 0, model.isAtTop, model.hasDeeperHistory else { return }
            loadLocalScrollbackPage(
                maxBytes: TerminalScrollbackBudget.defaultMaxBytes, deepening: model, pendingDeltaRows: scroll.unappliedRows, kind: .full)
        }

        /// Paints where the replay now sits, or hands the pane back to the session's own frame when the
        /// replay sits on its newest row. At the bottom the live frame *is* the current screen, while the
        /// replay's newest row is only as fresh as the transcript page it was read from: painting the
        /// replay there would hide everything the session has written since and leave the jump control
        /// offering a return the user has already made by hand.
        ///
        /// The gesture that got here is left running rather than cancelled. Its remaining downward deltas
        /// find the replay already at the bottom and do nothing, and an upward one re-enters the replay
        /// the handback rewound, with no read to pay for.
        private func showLocalScrollbackPosition(_ model: TerminalLocalScrollbackModel, snapshot: GhosttyTerminalSnapshot?) {
            guard model.rowsFromBottom > 0 else {
                // A load that lands here still owes the live paints it suppressed while it held the
                // gesture's rows, and the return below paints only a pane that was showing a replay frame,
                // so a pane that was not gets that paint from the repaint above it.
                repaintLiveFrameUnlessShowingReplay()
                returnToLiveScreenFromLocalScrollback()
                return
            }
            guard let snapshot else { return }
            presentLocalScrollbackFrame(snapshot, offsetRows: model.rowsFromBottom)
        }

        /// Paints one replay frame. It carries a local revision so the mirror's frame-dedupe never drops a
        /// scrolled viewport, and the session's current owner epoch so it is applied like any other frame.
        private func presentLocalScrollbackFrame(_ snapshot: GhosttyTerminalSnapshot, offsetRows: Int) {
            localScrollbackRevision &+= 1
            let frame = GhosttyRenderFrame(
                sessionRevision: localScrollbackRevision, ownerEpoch: latestState?.renderOwnerEpoch ?? 0, snapshot: snapshot)
            isShowingLocalScrollbackFrame = true
            terminalView.isShowingLocalScrollbackFrame = true
            terminalView.update(frame: frame, renderStateKey: currentRenderStateKey())
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(
                    sessionID: launchConfiguration.sessionID, source: "mac-mirror", name: "scroll_local_frame",
                    attributes: ["offset_rows": String(offsetRows)]))
        }

        /// Returns the pane to the session's own screen, with no request to the daemon: the session's
        /// viewport never moved, so the live frame this host already holds *is* the current screen. The
        /// replay survives, rewound to its newest row, because its bytes are still this session's
        /// transcript: the next gesture continues from there instead of paying for the page again.
        private func returnToLiveScreenFromLocalScrollback() {
            guard isShowingLocalScrollbackFrame else { return }
            switch localScrollbackState {
            case .ready(let model): model.scrollToRowsFromBottom(0)
            // A load holds the replay until it installs, so the rewind is owed rather than done here.
            case .loading(_, let model, _) where model != nil: pendingLocalScrollbackRewind = true
            case .idle, .loading, .unavailable: break
            }
            clearLocalScrollbackDisplay()
            terminalView.update(frame: latestLiveRenderFrame, renderStateKey: currentRenderStateKey())
        }

        /// Drops the pane out of the replay without repainting, for the callers that paint something else
        /// themselves (a live frame landing after a discard) or that discard the replay outright.
        private func clearLocalScrollbackDisplay() {
            isShowingLocalScrollbackFrame = false
            localScrollDeltaNormalizer = TerminalScrollDeltaNormalizer()
            terminalView.isShowingLocalScrollbackFrame = false
            terminalView.setLocalScrollbackHasNewOutput(false)
        }

        /// Typing returns the pane to the live screen: what the user types appears at the session's own
        /// bottom row, and a replay left on screen would hide it. The replay is discarded rather than
        /// rewound because the input itself changes the transcript it was read from; the next painted
        /// frame reads a fresh page.
        ///
        /// A replay still reading its first page counts as owning the pane too, which is what
        /// `isLocalScrollbackReplayActive` says: it holds the rows the user has scrolled onto it, and
        /// without the discard the read would land after the keystroke and paint that history over the
        /// live screen the keystroke belongs to. Discarding drops those rows with it. A pane with no gesture
        /// in flight and no movement on it is untouched, so ordinary typing at the live bottom costs nothing.
        private func leaveLocalScrollbackForInput() {
            // A gesture scrolling this pane's own replay is cancelled whether or not it has painted
            // anything yet, because a latch that has not crossed a whole row still has the rest of its
            // deltas and its momentum behind it, and routing those after the keystroke would paint history
            // over the live screen it belongs to. A gesture forwarded to the daemon keeps every delta: the
            // program receiving the wheel decides what typing means for it, and none of those events paint
            // this pane's history over anything.
            if case .localReplay? = latchedScrollRoute { cancelActiveScrollGesture() }
            guard isLocalScrollbackReplayActive else { return }
            returnToLiveScreenFromLocalScrollback()
            discardLocalScrollback()
        }

        /// The jump-to-bottom control's action. A pane showing its replay jumps locally, with no request
        /// to the daemon at all; a pane whose live frame is itself scrolled back (the daemon's own
        /// viewport, moved by whoever owns it) asks the session to jump, exactly as before.
        private func handleJumpToBottom() {
            if isShowingLocalScrollbackFrame {
                // Jumping during a flick's momentum has to end that flick too: the replay survives the
                // jump, so its remaining deltas would scroll the user straight back off the live screen.
                cancelActiveScrollGesture()
                returnToLiveScreenFromLocalScrollback()
                return
            }
            sendRemoteScrollToBottom()
        }

        /// Reads the pane's first page of transcript once it has painted a frame. The frame is what says
        /// the session is worth a replay and at which grid to build it, and reading now is what lets the
        /// user's first wheel event scroll instead of waiting out a round trip.
        private func prefetchLocalScrollbackIfNeeded() {
            guard !hasRequestedLocalScrollbackPrefetch, transcriptProvider != nil else { return }
            guard case .idle = localScrollbackState else { return }
            guard terminalView.hasRenderedSurfaceContent else { return }
            hasRequestedLocalScrollbackPrefetch = true
            loadLocalScrollbackPage(
                maxBytes: TerminalScrollbackBudget.initialLocalScrollbackPageBytes, deepening: nil, pendingDeltaRows: 0, kind: .prefetch)
        }

        /// What a page read was started for. It names the read in the performance log, and it is what tells
        /// a read that a gesture is waiting on from the prefetch that runs on its own: the two
        /// gesture-initiated reads take the gesture down with them when they install nothing.
        private enum LocalScrollbackPageReadKind: String {
            case prefetch
            case gesture
            case full

            var isGestureInitiated: Bool { self != .prefetch }
        }

        /// Reads a page of transcript and installs it as this pane's replay: the prefetch after the first
        /// painted frame, the first read a gesture on a pane whose prefetch failed pays for, and the
        /// whole-budget read a gesture that reaches the replay's oldest row asks for. `deepening` is the
        /// replay being replaced, whose distance above the newest row the rebuilt replay restores so the
        /// rows on screen do not move across the rebuild.
        private func loadLocalScrollbackPage(
            maxBytes: Int, deepening: TerminalLocalScrollbackModel?, pendingDeltaRows: Int, kind: LocalScrollbackPageReadKind
        ) {
            guard let transcriptProvider else {
                localScrollbackState = .unavailable
                return
            }
            let grid = localScrollbackGrid()
            let appearance = currentTerminalAppearance()
            let theme = ActiveTheme.descriptor.terminal(for: appearance)
            let rowsFromBottom = deepening?.rowsFromBottom
            localScrollbackState = .loading(pendingDeltaRows: pendingDeltaRows, model: deepening, grid: grid)
            // Arm the replay against the run these bytes are read from. Every non-idle state descends from
            // this one transition, so recording the run once here covers the `.loading`, `.ready`, and
            // `.unavailable` outcomes; `applyReducedState` compares it against later payloads to discard a
            // replay whose run is gone.
            let armedRunKey = TerminalSessionRuntimeState.runKey(for: currentRunIdentity())
            localScrollbackRunKey = armedRunKey
            localScrollbackAppearance = appearance
            // Pin this read to the current generation. A relaunch, a typed key, or a grid change discards
            // the replay and bumps the generation, so the checks below reject a stale result instead of
            // installing it under a later state. The in-flight read itself is not cancelled: it runs on
            // this pane's dedicated `DeviceAPIRequestClientBox.transcriptClient`, so an obsolete page can
            // only delay the next scrollback page, never keystrokes or controls, which travel on the
            // separate control client. `SpacesDeviceAPIRequestSessionClient.send` is a blocking round trip
            // that Swift task cancellation cannot interrupt, and `cancel()` takes the same request lock
            // the send holds, so aborting it would mean tearing the connection down mid-send. The accepted
            // cost is a discard (resize, relaunch, keystroke) landing while a deep page is in flight on a
            // slow link: the next page waits behind the stale one for as long as that read's own
            // size-derived deadline allows (10s plus a second per 64 KiB the read asked for, see
            // `SpacesDeviceAPICommandDescriptor`), while live frames keep painting on the unaffected
            // control path.
            let generation = localScrollbackGeneration
            let startedAt = Date()
            Task { @MainActor [weak self] in
                let transcript: RemoteGhosttyTranscript
                do { transcript = try await transcriptProvider(maxBytes, nil, nil) } catch {
                    // A transport failure (timeout, daemon restarting, remote device offline) is transient:
                    // return to idle so the next gesture retries the read. The gesture this read was started
                    // for is cancelled with it, because idle is where a delta starts a read: without the
                    // cancel every remaining delta of one flick at an unreachable device would start another
                    // read that fails the same way, so the rest of the flick is absorbed and the gesture
                    // after the idle boundary is the retry.
                    guard let self, generation == self.localScrollbackGeneration, case .loading = self.localScrollbackState else { return }
                    self.localScrollbackState = .idle
                    if kind.isGestureInitiated { self.cancelActiveScrollGesture() }
                    self.repaintLiveFrameUnlessShowingReplay()
                    return
                }
                guard let self, generation == self.localScrollbackGeneration, case .loading = self.localScrollbackState else { return }
                self.logScrollbackPageRead(byteCount: transcript.data.count, kind: kind.rawValue, startedAt: startedAt)
                guard self.transcriptBelongsToArmedRun(transcript, armedRunKey: armedRunKey) else {
                    // The identity in the response can lag the relaunch by one write-behind commit of the
                    // runtime state, so a mismatch is a stale label to retry, not a verdict: the replay is
                    // discarded back to `.idle` and the next painted frame or gesture reads again.
                    self.discardLocalScrollback()
                    self.repaintLiveFrameUnlessShowingReplay()
                    return
                }
                guard !transcript.data.isEmpty else {
                    // Nothing to replay yet, which is definitive only for a session that has ended: its
                    // transcript is complete, so an empty one means that run wrote nothing and never will.
                    // A live session is merely ahead of its own output (a first frame painted before the
                    // child wrote a byte, and the `.sessionNotAvailable` read of an `output.log` that does
                    // not exist yet, which the client maps to an empty transcript), so latching there would
                    // absorb every scroll for the rest of the run. It returns to `.idle` instead, the same
                    // retryable state a transport failure leaves, and the next gesture reads again. `.idle`
                    // rather than a `.ready` empty replay keeps one path: every replay this host holds was
                    // built from transcript bytes. The prefetch flag stays set, so the retry is the
                    // gesture's, not every later frame's. That retry is the *next* gesture: a live session's
                    // empty page cancels the gesture its read was started for, for the reason a failed read
                    // does, so one flick cannot spend a read per delta on a transcript that has no bytes yet.
                    self.localScrollbackState = self.isInteractiveRuntimeStateForControl() ? .idle : .unavailable
                    if case .idle = self.localScrollbackState, kind.isGestureInitiated { self.cancelActiveScrollGesture() }
                    self.repaintLiveFrameUnlessShowingReplay()
                    return
                }
                let model = await self.buildLocalScrollbackModel(
                    transcript: transcript, requestedByteCount: maxBytes, grid: grid, theme: theme, appearance: appearance,
                    rowsFromBottom: rowsFromBottom)
                guard generation == self.localScrollbackGeneration, case .loading(let pendingRows, _, _) = self.localScrollbackState else { return }
                guard let model else {
                    self.localScrollbackState = .unavailable
                    self.repaintLiveFrameUnlessShowingReplay()
                    return
                }
                self.localScrollbackState = .ready(model)
                self.applyPendingLocalScrollbackRewind(to: model)
                if pendingRows != 0 {
                    self.applyLocalScroll(deltaRows: pendingRows, model: model)
                } else if self.isShowingLocalScrollbackFrame {
                    // A deepening read that consumed its whole delta still has to repaint: the rebuilt
                    // replay is a different vt session showing the same rows. A rebuild that lands on the
                    // newest row hands the pane back to the live frame instead, by the same rule a gesture
                    // that reaches the bottom follows.
                    self.showLocalScrollbackPosition(model, snapshot: model.currentSnapshot())
                }
            }
        }

        /// Brings the replay up to date with what the session has written since it was built, once per
        /// gesture. Skipped entirely when the session has written nothing since: an ended pane never
        /// writes again, so it never asks twice.
        private func loadLocalScrollbackContinuationIfBehind() {
            guard case .ready(let model) = localScrollbackState, localScrollbackContinuationRead == nil else { return }
            guard let latestTranscriptEndByteOffset, latestTranscriptEndByteOffset != model.transcriptEndByteOffset else { return }
            guard let transcriptProvider else { return }
            let maxBytes = TerminalScrollbackBudget.initialLocalScrollbackPageBytes
            let fromByteOffset = model.transcriptEndByteOffset
            let fileIdentity = model.transcriptFileIdentity
            let armedRunKey = localScrollbackRunKey
            let generation = localScrollbackGeneration
            localScrollbackContinuationRead = LocalScrollbackContinuationRead(generation: generation, model: model)
            let startedAt = Date()
            Task { @MainActor [weak self] in
                let transcript: RemoteGhosttyTranscript
                do { transcript = try await transcriptProvider(maxBytes, fromByteOffset, fileIdentity) } catch {
                    // Transient, like any other read: the replay keeps the bytes it has and the next
                    // gesture asks again.
                    self?.finishLocalScrollbackContinuationRead(generation: generation, model: model)
                    return
                }
                guard let self else { return }
                self.finishLocalScrollbackContinuationRead(generation: generation, model: model)
                guard generation == self.localScrollbackGeneration, case .ready(let currentModel) = self.localScrollbackState, currentModel === model
                else { return }
                self.logScrollbackPageRead(byteCount: transcript.data.count, kind: "continuation", startedAt: startedAt)
                guard self.transcriptBelongsToArmedRun(transcript, armedRunKey: armedRunKey) else {
                    // Retryable for the reason the first page's mismatch is: the label can be one
                    // write-behind commit behind the relaunch. The replay is dropped rather than kept,
                    // because bytes from another run cannot be appended to it.
                    self.discardLocalScrollback()
                    self.repaintLiveFrameUnlessShowingReplay()
                    return
                }
                guard !transcript.data.isEmpty else { return }
                // The daemon could not serve a continuation (a head-trim moved the bytes the offset named,
                // or the session outran the page), so the payload is a fresh replayable suffix and the
                // replay is rebuilt from it rather than appended to.
                if transcript.isSuffixRebuild {
                    await self.rebuildLocalScrollback(from: model, transcript: transcript, requestedByteCount: maxBytes, generation: generation)
                    return
                }
                // Replaying a page of transcript through libghostty-vt is tens of milliseconds of work, so
                // the append runs off the main actor exactly as the first build does, and the replay belongs
                // to that hop alone while it runs (the model is `@unchecked Sendable` for this handover).
                // `.loading` is what parks the pane meanwhile: a gesture arriving accumulates its rows
                // instead of scrolling a replay that is not here, and the install applies them.
                let bytes = transcript.data
                let endByteOffset = transcript.endByteOffset
                self.localScrollbackState = .loading(pendingDeltaRows: 0, model: model, grid: (columns: model.columns, rows: model.rows))
                self.debugOnLocalScrollbackReplayHandedToLoad?()
                let appended = await Task.detached(priority: .userInitiated) { model.append(bytes, transcriptEndByteOffset: endByteOffset) }.value
                // The same checks the build's install makes, for the same reason: a discard (a keystroke, a
                // resize, a relaunch) can have landed while the append ran, and its bytes must not come back
                // under the state that replaced it.
                guard generation == self.localScrollbackGeneration, case .loading(let pendingRows, let held, _) = self.localScrollbackState,
                    held === model
                else { return }
                guard appended else {
                    // A replay that cannot take the bytes is no longer a faithful continuation of the
                    // transcript, so it stops rather than showing a screen the session never had.
                    self.localScrollbackState = .unavailable
                    self.repaintLiveFrameUnlessShowingReplay()
                    return
                }
                self.localScrollbackState = .ready(model)
                self.applyPendingLocalScrollbackRewind(to: model)
                // Ghostty keeps the viewport pinned while output appends below it, so an append moves
                // nothing on screen and needs no repaint; only the rows a gesture scrolled while the replay
                // was away have anything to paint.
                if pendingRows != 0 { self.applyLocalScroll(deltaRows: pendingRows, model: model) }
            }
        }

        /// Applies a rewind the pane owed a replay a load was holding (see `pendingLocalScrollbackRewind`),
        /// at the install that hands that replay back.
        private func applyPendingLocalScrollbackRewind(to model: TerminalLocalScrollbackModel) {
            guard pendingLocalScrollbackRewind else { return }
            pendingLocalScrollbackRewind = false
            model.scrollToRowsFromBottom(0)
        }

        /// Retires a continuation read, and only the one that is actually in flight. A read whose replay
        /// was discarded and reopened underneath it resolves against a mark that belongs to the current
        /// replay's own read, and clearing that would let the next gesture start a second read of the
        /// same range while the first is still running.
        private func finishLocalScrollbackContinuationRead(generation: UInt64, model: TerminalLocalScrollbackModel) {
            guard let read = localScrollbackContinuationRead, read.generation == generation, read.model === model else { return }
            localScrollbackContinuationRead = nil
        }

        /// Replaces the replay with one built from a served suffix, at the rows the user is looking at.
        ///
        /// The pane is parked in `.loading` holding the replay across the build, exactly as the append
        /// parks it: the rebuilt replay is put the distance above its newest row that the replay it
        /// replaces sat at when the build started, so rows scrolled onto the old replay meanwhile would be
        /// thrown away by the install. They buffer in `pendingDeltaRows` instead and are applied to the
        /// replay that comes back, and a jump or a keystroke meanwhile is the rewind the install pays.
        private func rebuildLocalScrollback(
            from model: TerminalLocalScrollbackModel, transcript: RemoteGhosttyTranscript, requestedByteCount: Int, generation: UInt64
        ) async {
            let grid = localScrollbackGrid()
            let appearance = currentTerminalAppearance()
            let theme = ActiveTheme.descriptor.terminal(for: appearance)
            let rowsFromBottom = model.rowsFromBottom
            localScrollbackState = .loading(pendingDeltaRows: 0, model: model, grid: grid)
            debugOnLocalScrollbackReplayHandedToLoad?()
            let rebuilt = await buildLocalScrollbackModel(
                transcript: transcript, requestedByteCount: requestedByteCount, grid: grid, theme: theme, appearance: appearance,
                rowsFromBottom: rowsFromBottom)
            guard generation == localScrollbackGeneration, case .loading(let pendingRows, let held, _) = localScrollbackState, held === model else {
                return
            }
            guard let rebuilt else {
                localScrollbackState = .unavailable
                repaintLiveFrameUnlessShowingReplay()
                return
            }
            localScrollbackAppearance = appearance
            localScrollbackState = .ready(rebuilt)
            applyPendingLocalScrollbackRewind(to: rebuilt)
            if pendingRows != 0 {
                applyLocalScroll(deltaRows: pendingRows, model: rebuilt)
            } else if isShowingLocalScrollbackFrame {
                // The rebuilt replay is a different vt session showing the same rows, so a pane already
                // painting the replay it replaces has to be repainted from it even with no rows of its own
                // to apply.
                showLocalScrollbackPosition(rebuilt, snapshot: rebuilt.currentSnapshot())
            }
        }

        /// Builds a replay off the main actor (replaying a page of transcript through a vt session is
        /// slow enough to drop frames if it ran on it) and puts its viewport `rowsFromBottom` rows above
        /// the newest row, which is what keeps the rows on screen still across a rebuild.
        private func buildLocalScrollbackModel(
            transcript: RemoteGhosttyTranscript, requestedByteCount: Int, grid: (columns: Int, rows: Int), theme: GhosttyThemeExport,
            appearance: ThemeAppearance, rowsFromBottom: Int?
        ) async -> TerminalLocalScrollbackModel? {
            await Task.detached(priority: .userInitiated) {
                let model = TerminalLocalScrollbackModel(
                    columns: grid.columns, rows: grid.rows, theme: theme, appearance: appearance, transcript: transcript.data,
                    transcriptStartByteOffset: transcript.startByteOffset, transcriptEndByteOffset: transcript.endByteOffset,
                    requestedByteCount: requestedByteCount, transcriptFileIdentity: transcript.fileIdentity, runIdentity: transcript.runIdentity)
                if let rowsFromBottom { model?.scrollToRowsFromBottom(rowsFromBottom) }
                return model
            }.value
        }

        /// Whether a read's bytes belong to the run the replay is armed against. The response carries the
        /// run the server read it from: a relaunch that lands after a read started but before this client
        /// observes a new state payload leaves the generation and the armed run unchanged, yet truncates
        /// `output.log`, so the bytes can belong to the new run. A read the server could not attribute
        /// (`runIdentity` nil, the missing-output path) is accepted, since it carries no evidence either
        /// way and its emptiness is handled on its own.
        ///
        /// A mismatch is transient, never a verdict. The identity the endpoint reports is read from the
        /// runtime state SQLite holds, which a relaunch updates write-behind, so a pane that paints before
        /// that commit lands gets the new run's bytes under the previous run's label. Callers discard the
        /// replay instead of latching `.unavailable`, which returns the pane to `.idle` and lets the next
        /// painted frame or gesture read again once the labels agree.
        private func transcriptBelongsToArmedRun(_ transcript: RemoteGhosttyTranscript, armedRunKey: String?) -> Bool {
            guard let responseRunKey = TerminalSessionRuntimeState.runKey(for: transcript.runIdentity), let armedRunKey else { return true }
            return responseRunKey == armedRunKey
        }

        /// The grid a replay is built at: the grid the pane's own frames carry, so the replay wraps every
        /// row exactly as the session did. A pane with no frame yet falls back to the session's reported
        /// runtime grid, and then to the conventional 80x24 every grid-less reader assumes.
        private func localScrollbackGrid() -> (columns: Int, rows: Int) {
            let snapshot = latestLiveRenderFrame?.snapshot
            return (snapshot?.columns ?? latestState?.runtimeState?.columns ?? 80, snapshot?.rows ?? latestState?.runtimeState?.rows ?? 24)
        }

        private func currentTerminalAppearance() -> ThemeAppearance {
            terminalView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }

        private var isLocalScrollbackReplayActive: Bool {
            if isShowingLocalScrollbackFrame { return true }
            // A gesture whose first page is still being read owns the pane too: its rows are accumulating,
            // and a live frame painted in the meantime would be replaced the moment the page lands.
            if case .loading(let pendingDeltaRows, _, _) = localScrollbackState, pendingDeltaRows != 0 { return true }
            return false
        }

        /// Repaints the replay viewport after the mirror surface was released and recreated (the pane
        /// controller releases the surface before reattaching). Live-frame repaints are suppressed while
        /// the replay owns the pane, so without this the recreated surface stays blank until the next
        /// scroll gesture.
        private func repaintLocalReplayViewportIfSurfaceEmpty() {
            guard !terminalView.hasRenderedSurfaceContent else { return }
            switch localScrollbackState {
            case .ready(let model) where isShowingLocalScrollbackFrame:
                presentLocalScrollbackFrame(model.currentSnapshot(), offsetRows: model.rowsFromBottom)
            case .idle, .loading, .ready, .unavailable:
                // No replay frame to restore - show the session's own frame until one exists.
                terminalView.update(frame: currentRenderFrameForRenderUpdate(), renderStateKey: currentRenderStateKey())
            }
        }

        /// Repaints the session's own frame wherever a page load ends with no replay frame to show, which
        /// is every exit that installs no replay and the install that lands the replay on its newest row.
        /// The rows that load held suppressed live paints while it ran (`isLocalScrollbackReplayActive`),
        /// leaving the frames that landed meanwhile cached in `latestLiveRenderFrame` and unpainted. A live
        /// session would repaint on its next frame, but one that ended during the load never sends another,
        /// so the pane would sit on the frame it had when the load started for good. A pane showing a
        /// replay frame keeps showing it: those rows are the ones the user is reading.
        private func repaintLiveFrameUnlessShowingReplay() {
            guard !isShowingLocalScrollbackFrame else { return }
            // A load that ends here can have marked new output while a gesture waited on it (see the mark
            // above); the live frame this paints already carries that output, so the mark would otherwise
            // outlive the reason it existed.
            terminalView.setLocalScrollbackHasNewOutput(false)
            terminalView.update(frame: latestLiveRenderFrame, renderStateKey: currentRenderStateKey())
        }

        /// Drops the replay and everything armed with it: the model (freeing its vt session), the run it
        /// was armed against, the accumulated scroll delta, and any `.unavailable` verdict, which a later
        /// state may well contradict. The generation bump invalidates every read still in flight for the
        /// replay being dropped, so none of their results can install under a later one.
        private func discardLocalScrollback() {
            localScrollbackGeneration &+= 1
            localScrollbackState = .idle
            localScrollbackRunKey = nil
            localScrollbackAppearance = nil
            hasRequestedLocalScrollbackPrefetch = false
            // The read this drops is still running: it resolves against a generation this bump has left
            // behind, so it retires nothing and installs nothing.
            localScrollbackContinuationRead = nil
            // The replay the rewind was owed to is gone with everything else armed for it.
            pendingLocalScrollbackRewind = false
            clearLocalScrollbackDisplay()
        }

        /// A theme switch under a built replay: its rows are painted in the other appearance's colors, so
        /// it is rebuilt at the current one rather than kept.
        private func discardLocalScrollbackIfAppearanceChanged() {
            guard let localScrollbackAppearance, localScrollbackAppearance != currentTerminalAppearance() else { return }
            returnToLiveScreenFromLocalScrollback()
            discardLocalScrollback()
        }

        /// A resize reflows every row, so a replay built at the previous grid wraps its transcript
        /// differently from the session that produced it. It is dropped and read again at the new grid.
        ///
        /// A read still in flight is dropped for the same reason and by the same comparison: it was
        /// started at the pane's grid at the time and would install a replay wrapped at a grid the session
        /// has left. The generation bump the discard carries is what rejects its result when it lands, and
        /// the rows scrolled onto it go with it, exactly as a built replay's scroll position does. The
        /// read is not reissued here: the discard returns the pane to `.idle`, and this payload's own
        /// `prefetchLocalScrollbackIfNeeded` reads again at the grid the frame just established.
        private func discardLocalScrollbackIfGridChanged(frame: GhosttyRenderFrame?) {
            guard let frame else { return }
            let grid: (columns: Int, rows: Int)
            switch localScrollbackState {
            case .ready(let model): grid = (model.columns, model.rows)
            case .loading(_, _, let loadingGrid): grid = loadingGrid
            case .idle, .unavailable: return
            }
            guard grid.columns != frame.snapshot.columns || grid.rows != frame.snapshot.rows else { return }
            discardLocalScrollback()
        }

        /// Run identity for the run `latestState` describes, in the shared
        /// `TerminalSessionRuntimeState.runIdentity` format the transcript response also carries. `nil`
        /// when there is no runtime state yet.
        private func currentRunIdentity() -> String? { latestState?.runtimeState?.runIdentity }

        /// Mirrors the phone's client-local scrollback events so a shaped run on either client produces
        /// comparable lines. Rides the same sink as `render_frame_payload_receive`, whose autoclosure
        /// builds nothing while the logger is off.
        private func logScrollbackPageRead(byteCount: Int, kind: String, startedAt: Date) {
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(
                    sessionID: launchConfiguration.sessionID, source: "mac-mirror", name: "scrollback_page_fetch",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), count: byteCount, attributes: ["kind": kind]))
        }

        private func enqueueRemoteScrollBatch(_ batch: TerminalScrollCoalescer.Batch, onFinished: @escaping TerminalScrollCoalescer.FinishHandler) {
            guard isInteractiveRuntimeStateForControl(), let client = attachedClient, attachedMode == .owner else {
                onFinished()
                return
            }
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let ownerEpoch = latestState?.renderOwnerEpoch
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            let inputFailureHandler = self.inputFailureHandler
            let queue = inputQueue
            queue.enqueue(
                priority: .userInitiated,
                operation: {
                    defer { Task { @MainActor in onFinished() } }
                    _ = try Self.sendControlRequest(
                        TerminalControlRequest(
                            command: .scroll(
                                .init(
                                    clientID: clientID, ownerEpoch: ownerEpoch, scrollHorizontal: batch.horizontal, scrollVertical: batch.vertical,
                                    scrollMods: batch.scrollMods == 0 ? nil : batch.scrollMods, scrollPointerX: batch.pointerPosition?.x,
                                    scrollPointerY: batch.pointerPosition?.y, scrollPointerMods: batch.pointerPosition?.mods))), sessionID: sessionID,
                        socketPath: socketPath, requestSender: requestSender)
                    if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "scroll") } }
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) },
                onDiscarded: { await MainActor.run { onFinished() } })
        }

        private func sendCurrentViewportResizeIfNeeded(force: Bool) {
            guard isInteractiveRuntimeStateForControl(), attachedMode == .owner, let size = terminalView.surfaceCellSize() else { return }
            handleViewportSizeChange(columns: size.columns, rows: size.rows, force: force)
        }

        /// The owner attach's viewport send. It forces the request past the dedup's stale-state skips only
        /// when the mirror surface was rebuilt since the last attach — a rebuilt surface negotiated its own
        /// grid, so the size the daemon last heard was measured against a surface that no longer exists.
        /// The force is about the dedup, not the timing: like every other measurement it is announced only
        /// once the layout settles, so the attach cannot publish a pre-layout grid.
        /// Re-attaching to the same live surface sends nothing: the daemon would answer that resize by
        /// early-outing as a no-op, after a control hop onto the queue that carries every session's
        /// keystrokes, and every refocus of an already-open pane re-attaches. The force cannot revive a
        /// request the session's own reported size proves is a no-op; `shouldSendViewportResize` drops that
        /// one either way.
        private func sendViewportResizeForOwnerAttach() {
            guard isInteractiveRuntimeStateForControl(), attachedMode == .owner else { return }
            // Reading the cell size builds the mirror when the pane is displayed, so the generation is read
            // after any rebuild this attach itself triggered.
            guard let size = terminalView.surfaceCellSize() else { return }
            let surfaceGeneration = terminalView.surfaceGeneration
            let surfaceWasRebuilt = surfaceGeneration != lastAttachedSurfaceGeneration
            lastAttachedSurfaceGeneration = surfaceGeneration
            handleViewportSizeChange(columns: size.columns, rows: size.rows, force: surfaceWasRebuilt)
        }

        /// The single point where a measured viewport size leaves for the daemon, and the point that
        /// holds it for one main-actor turn before it does.
        ///
        /// A pane reports its grid from the middle of layout, not only once layout is done. Re-showing a
        /// workspace adds the panel to the detail container before the panel's edge constraints are
        /// active, and rebuilding an evicted mirror surface inside that `addSubview` forces a window-level
        /// layout pass — so the pane momentarily solves to its fitting size and reports that tiny grid,
        /// then reports the real one microseconds later when the constraints activate. Both land while the
        /// main actor is still inside the same synchronous switch, so deferring by a turn lets the second
        /// replace the first and only the settled size is ever sent. The daemon is spared a resize pair
        /// that costs the shell two SIGWINCHes (whose prompt redraw destroys a line of scrollback per
        /// switch) and a remote session a full reflowed frame at the tiny grid; a switch back to unchanged
        /// bounds sends nothing at all, because `shouldSendViewportResize` drops the unchanged size.
        ///
        /// A user dragging the window resizes across many turns and keeps flowing: each turn's final size
        /// is sent on the next one.
        private func handleViewportSizeChange(columns: Int, rows: Int, force: Bool = false) {
            pendingViewportSettleForce = pendingViewportSettleForce || force
            // A measurement identical to the one already waiting keeps that wait rather than restarting
            // it. Every state payload re-measures the viewport, and a session under steady output
            // delivers them continuously: restarting the turn on each one would hold a genuinely pending
            // resize back for as long as the stream stays busy.
            if pendingViewportSettleSize?.columns == columns, pendingViewportSettleSize?.rows == rows { return }
            pendingViewportSettleTask?.cancel()
            pendingViewportSettleSize = (columns, rows)
            debugViewportSettleScheduleCount &+= 1
            pendingViewportSettleTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.pendingViewportSettleTask = nil
                self.pendingViewportSettleSize = nil
                let force = self.pendingViewportSettleForce
                self.pendingViewportSettleForce = false
                self.sendViewportResize(columns: columns, rows: rows, force: force)
            }
        }

        private func sendViewportResize(columns: Int, rows: Int, force: Bool) {
            guard isInteractiveRuntimeStateForControl(), attachedMode == .owner, let client = attachedClient else { return }
            // The size was measured a turn ago, and in that turn the pane can have left the screen and had
            // its surface freed by `GhosttyMirrorSurfaceMRU` — which frees it on the view itself, with
            // nothing that tells this host. A pane that can no longer measure a viewport must not resize
            // its session to one it took off a surface that is gone: the same rule that keeps an
            // off-screen pane from reporting the `cellMetrics()` estimate. The real grid comes back with
            // the surface rebuilt when the pane is displayed again.
            guard terminalView.surfaceCellSize() != nil else { return }
            let requestedSize: (columns: Int, rows: Int) = (columns, rows)
            let runtimeSize = latestState?.runtimeState.map { runtimeState in (columns: runtimeState.columns ?? 0, rows: runtimeState.rows ?? 0) }
            guard
                Self.shouldSendViewportResize(
                    requestedSize: requestedSize, lastRequestedSize: lastRequestedViewportSize, pendingSize: pendingViewportResizeSize,
                    runtimeSize: runtimeSize, force: force)
            else { return }
            pendingViewportResizeTask?.cancel()
            pendingViewportResizeSize = requestedSize
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            resizeSerial &+= 1
            let currentResizeSerial = resizeSerial
            let ownerEpoch = latestState?.renderOwnerEpoch
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            let inputFailureHandler = self.inputFailureHandler
            let queue = inputQueue
            let finishResizeRequest: @MainActor @Sendable (Bool) -> Void = { [weak self, requestedSize] success in
                guard let self else { return }
                if let pendingViewportResizeSize = self.pendingViewportResizeSize, pendingViewportResizeSize == requestedSize {
                    self.pendingViewportResizeSize = nil
                }
                if success { self.lastRequestedViewportSize = requestedSize }
                self.pendingViewportResizeTask = nil
            }
            pendingViewportResizeTask = Task.detached(priority: .utility) {
                // Resize runs off `inputQueue` (it must not wait behind buffered typing), so its failure
                // cannot ride that queue's `onError` and is reported directly here instead. A `try?` here
                // used to swallow the thrown error entirely; a resize on a dead link deserves the same
                // prompt lost-link notice as a keystroke, not silence.
                let response: TerminalControlResponse?
                do {
                    response = try Self.sendControlRequest(
                        TerminalControlRequest(
                            command: .resize(
                                .init(clientID: clientID, columns: columns, rows: rows, ownerEpoch: ownerEpoch, resizeSerial: currentResizeSerial))),
                        sessionID: sessionID, socketPath: socketPath, requestSender: requestSender)
                } catch {
                    response = nil
                    await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue)
                }
                if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "resize") } }
                await finishResizeRequest(response?.ok == true)
            }
        }

        private nonisolated static func sendControlRequest(
            _ request: TerminalControlRequest, sessionID: String, socketPath: String, requestSender: RemoteGhosttyTerminalServiceRequestSender?
        ) throws -> TerminalControlResponse {
            guard let requestSender else { return try TerminalControlClient.send(request: request, socketPath: socketPath) }
            let response = try requestSender(TerminalServiceRequest(command: .control(.init(sessionID: sessionID, controlRequest: request))))
            guard response.ok else { throw remoteTerminalRequestError(response.message) }
            let controlResponse = response.controlResponse ?? TerminalControlResponse(ok: response.ok, message: response.message)
            guard controlResponse.ok else { throw remoteTerminalRequestError(controlResponse.message) }
            return controlResponse
        }

        private nonisolated static func remoteTerminalRequestError(_ message: String) -> NSError {
            NSError(domain: "RemoteGhosttySessionHost", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        /// Reports one interactive control send's failure to `inputFailureHandler` and, only when the
        /// failure is CONCLUSIVE proof the link is gone (not merely a timed-out round trip — see the
        /// handler's own doc), discards this pane's queued input backlog rather than letting it drain and
        /// deliver late — including any Enter — once the link recovers. A bare timeout still reaches the
        /// handler and still gets whatever failure surfacing it does, but leaves the backlog queued: the
        /// serial chain already tolerates a thrown predecessor (each enqueued task awaits its predecessor's
        /// `.result`, not its success), so the next queued send simply attempts on its own. Shared by every
        /// interactive control path: the four still chained on `inputQueue`'s `onError` (input, key,
        /// clear-screen, scroll), and the resize path, which sends off that queue in its own detached task
        /// and so calls this directly instead of through `onError`. `self`-free so every call site can
        /// capture it by value into a closure or task body built off the main actor.
        private nonisolated static func reportInputFailure(
            _ error: any Error, inputFailureHandler: RemoteGhosttyInputFailureHandler?, inputQueue: TerminalInputSerialQueue
        ) async {
            guard await inputFailureHandler?(error) == true else { return }
            inputQueue.cancelAll()
        }

        nonisolated static func snapshot(_ snapshot: GhosttyTerminalSnapshot, matches runtimeState: TerminalSessionRuntimeState?) -> Bool {
            guard let runtimeState else { return true }
            guard let columns = runtimeState.columns, let rows = runtimeState.rows, columns > 0, rows > 0 else { return true }
            return snapshot.columns == columns && snapshot.rows == rows
        }

        nonisolated static func shouldUseRenderFrameSnapshot(
            _ snapshot: GhosttyTerminalSnapshot, runtimeState: TerminalSessionRuntimeState?, reason: TerminalRemoteSessionStateReason?
        ) -> Bool {
            guard reason == .resize else { return true }
            return Self.snapshot(snapshot, matches: runtimeState)
        }

        nonisolated static func shouldSendViewportResize(
            requestedSize: (columns: Int, rows: Int), lastRequestedSize: (columns: Int, rows: Int)?, pendingSize: (columns: Int, rows: Int)?,
            runtimeSize: (columns: Int, rows: Int)?, force: Bool
        ) -> Bool {
            guard requestedSize.columns > 0, requestedSize.rows > 0 else { return false }
            let hasMatchingPendingSize = pendingSize?.columns == requestedSize.columns && pendingSize?.rows == requestedSize.rows
            let hasMatchingRuntimeSize = runtimeSize?.columns == requestedSize.columns && runtimeSize?.rows == requestedSize.rows
            let hasMatchingLastRequestedSize = lastRequestedSize?.columns == requestedSize.columns && lastRequestedSize?.rows == requestedSize.rows
            if hasMatchingPendingSize, !force { return false }
            if hasMatchingRuntimeSize, hasMatchingLastRequestedSize { return false }
            if hasMatchingLastRequestedSize, runtimeSize == nil, !force { return false }
            return true
        }
    }

    /// One host's note that a full frame is in its reduction pipeline, unapplied. Lock-guarded because the
    /// state stream submits payloads from its own thread while the main actor reads and clears it. See
    /// `RemoteGhosttySessionHost.pendingFullFrameSubmission` for the rule it encodes.
    private final class PendingFullFrameSubmission: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false

        var isPending: Bool { lock.withLock { pending } }

        func mark() { lock.withLock { pending = true } }

        func clear() { lock.withLock { pending = false } }
    }
#endif
