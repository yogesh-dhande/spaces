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
    /// once the link recovers. A bare request timeout answers `false`: the failed send is still reported
    /// (whatever failure surfacing the model does for it — the disconnect notice, the paced reconnect —
    /// runs the same as for any other transport failure), but the timeout alone does not prove the queued
    /// backlog would go nowhere. The interactive control deadline is tight enough
    /// (`DeviceTerminalSessionStateModel.interactiveControlRequestTimeoutSeconds`, 5s) that a live but
    /// congested link can miss it on its own: the send path never touches the main actor
    /// (`TerminalInputSerialQueue.enqueue` hands off to a detached task that talks to the pinned-TLS
    /// connection directly). Interactive sends and the `.state` resync fetch share one per-session
    /// request client, which acquires its request lock before starting the per-operation deadline, so a
    /// keystroke queued behind a grid-sized resync fetch is not charged for that wait — it gets a fresh
    /// 5s window once its turn comes. What actually burns that window is the daemon's own answer running
    /// late: under heavy streaming the daemon's serial terminal-engine queue is saturated, so a
    /// keystroke's response can genuinely time out with nothing wrong with the link. Discarding a live
    /// pane's backlog on that false alarm is the bug this distinction exists to avoid — and a silently
    /// dead link (nothing ever answers) produces the identical timeout, so the timeout by itself is not
    /// conclusive either way. Only a connection-level failure (refused, closed, every candidate address
    /// unreachable) — or a repeat failure during an outage a prior conclusive failure already confirmed —
    /// answers `true`.
    public typealias RemoteGhosttyInputFailureHandler = @Sendable (any Error) async -> Bool
    public typealias RemoteGhosttyStateStreamSubscriber =
        @Sendable (
            _ sessionID: String, _ onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void,
            _ onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) throws -> any TerminalRemoteStateStreamClient

    /// A fetched ended-session transcript plus the run identity the server reported it was read from.
    /// The host validates `runIdentity` against the run its replay was armed against, so a fetch that
    /// straddles a relaunch (which truncates `output.log`) cannot install the new run's bytes under the
    /// old run's final frame. `runIdentity` is nil when the server did not report one (the
    /// missing-output error path maps to an empty transcript with no identity).
    public struct RemoteGhosttyTranscript: Sendable {
        public let data: Data
        public let runIdentity: String?

        public init(data: Data, runIdentity: String?) {
            self.data = data
            self.runIdentity = runIdentity
        }
    }

    /// Fetches a suffix of the session's persisted output transcript (capped at `maxBytes`) for the
    /// ended-session scrollback replay. Read-only; the caller invokes it once, lazily, on the first
    /// scroll of an ended pane.
    public typealias RemoteGhosttyTranscriptProvider = @Sendable (_ maxBytes: Int) async throws -> RemoteGhosttyTranscript

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
                Self.shouldUseRenderFrameSnapshot(frame.snapshot, runtimeState: payload.runtimeState, reason: payload.reason)
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
        private var stateStreamClient: GhosttyRemoteSessionStateStreamClient?
        private var directStateStreamClient: (any TerminalRemoteStateStreamClient)?
        private var lastSubscriptionAttemptAt: Date?
        private var directStateFetchInFlight = false
        /// Counts the render frames this host has applied. A `.state` fetch snapshots it when it is issued,
        /// so its completion can tell whether anything painted while the read was in flight; see
        /// `shouldApplyFetchedRenderPayload`.
        private var appliedRenderFrameGeneration: UInt64 = 0
        /// Where the last applied frame sits in the session's order, recorded with the generation bump
        /// above so a late `.state` response can be compared against what the pane is actually showing.
        private var lastAppliedRenderFrameOrdering: (sessionRevision: UInt64?, ownerEpoch: UInt64)?
        private var lastRenderUpdateResyncAt: Date?
        /// The one delayed `.state` request owed to a resync the throttle turned away; see
        /// `scheduleTrailingRenderUpdateResync`.
        private var pendingRenderUpdateResyncTask: Task<Void, Never>?
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
        /// Lazy state for scrolling an ended pane's scrollback: `idle` until the first scroll, `loading`
        /// while the transcript is fetched and the replay model is built off the main actor (accumulating
        /// deltas), `ready` once the model exists, `unavailable` when there is no transcript to replay.
        private enum EndedScrollbackState {
            case idle
            case loading(pendingDeltaRows: Int)
            case ready(TerminalEndedSessionScrollbackModel)
            case unavailable
        }
        private var endedScrollbackState: EndedScrollbackState = .idle
        /// Invalidates in-flight transcript loads across a relaunch. A fetch started for one ended run
        /// (`.loading`) can still be resolving when the session relaunches and exits again; the second
        /// exit starts a fresh `.loading` in the same enum case, so an enum-only guard would install the
        /// first run's transcript/model under the second run. `discardEndedScrollbackIfActive` bumps this,
        /// and every post-suspension check in `beginLoadingEndedScrollbackModel` requires an unchanged
        /// generation before applying its result.
        private var endedScrollbackGeneration: UInt64 = 0
        /// Identifies the ended run the current replay/verdict belongs to, so an ended->ended transition
        /// to a *different* run (the session relaunched and exited again unobserved by this client) still
        /// discards the stale replay state. `nil` whenever no replay is armed.
        private var endedScrollbackRunIdentity: String?
        /// Monotonic local revision for replay frames, so the mirror's frame-dedupe never drops a
        /// scrolled viewport that happens to match a prior revision.
        private var endedScrollbackRevision: UInt64 = 0
        private var endedScrollDeltaNormalizer = TerminalScrollDeltaNormalizer()
        private lazy var scrollCoalescer = TerminalScrollCoalescer(frameInterval: Self.scrollCoalescingInterval) { [weak self] batch, finish in
            guard let self else {
                finish()
                return
            }
            self.enqueueRemoteScrollBatch(batch, onFinished: finish)
        }

        private static let scrollCoalescingInterval: Duration = .milliseconds(16)
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
            ensureStateStreamStartedIfNeeded()
        }

        deinit {
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                stateStreamClient?.stop()
                directStateStreamClient?.stop()
                pendingViewportSettleTask?.cancel()
                pendingViewportResizeTask?.cancel()
                pendingRenderUpdateResyncTask?.cancel()
                scrollCoalescer.cancel()
                inputQueue.cancelAll()
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
            terminalView.onSendMouseButton = { [weak self] button, pressed, pointerPosition in
                self?.sendRemoteMouseButton(button: button, pressed: pressed, pointerPosition: pointerPosition)
            }
            terminalView.onViewportSizeChanged = { [weak self] columns, rows in self?.handleViewportSizeChange(columns: columns, rows: rows) }

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
            // Same rule as applyReducedState: while the ended-session replay is showing a scrolled
            // viewport, a re-attach must not clobber it with the daemon's final frame. But if the
            // surface was released and recreated between detach and this attach, repaint the replay
            // viewport so the recreated surface is not left blank.
            if !isEndedScrollbackReplayActive {
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
                if frame == nil, !pendingFullFrameSubmission.isPending { requestRenderUpdateStateResync() }
            } else {
                repaintEndedReplayViewportIfSurfaceEmpty()
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
            requestDirectStateRefresh(reason: TerminalRemoteSessionStateReason.stateChange)
            // Same rule as applyReducedState: a refresh must not clobber a scrolled ended viewport, but
            // it must repaint the replay when the surface was released and recreated underneath it.
            if !isEndedScrollbackReplayActive {
                terminalView.update(frame: currentRenderFrameForRenderUpdate(), renderStateKey: currentRenderStateKey())
            } else {
                repaintEndedReplayViewportIfSurfaceEmpty()
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

        @discardableResult public func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?
        ) -> Bool {
            guard isInteractiveRuntimeStateForControl() else {
                return scrollEndedSession(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods)
            }
            return terminalView.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
        }

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

        func debugSetBindingActionHandler(_ handler: (@MainActor (String) -> Bool)?) { terminalView.debugBindingActionHandler = handler }
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
                requestDirectStateRefresh(reason: TerminalRemoteSessionStateReason.initial)
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
        private func requestRenderUpdateStateResync() {
            let now = Date()
            if let lastRenderUpdateResyncAt {
                let elapsed = now.timeIntervalSince(lastRenderUpdateResyncAt)
                if elapsed < renderUpdateResyncInterval {
                    scheduleTrailingRenderUpdateResync(after: renderUpdateResyncInterval - elapsed)
                    return
                }
            }
            // The open-throttle path owes the same guarantee as the throttled one: a fetch already in
            // flight was issued before this resync was owed, so stamping the throttle and letting
            // `requestDirectStateFetch` refuse on `directStateFetchInFlight` would consume the request
            // unsent. Arm the trailing retry instead, exactly as a throttled request does.
            guard !directStateFetchInFlight else {
                scheduleTrailingRenderUpdateResync(after: renderUpdateResyncInterval)
                return
            }
            lastRenderUpdateResyncAt = now
            requestDirectStateFetch()
        }

        /// Arms the one delayed request a throttled resync is owed. Coalesced: a second suppressed request
        /// while this is pending is already covered by it, so it must not stack a competing timer. Cleared
        /// when it sends, when a frame lands (`applyReducedState`), and when the host is torn down
        /// (`deinit`), alongside the pane's other pending tasks — so a dead host can never dial the device.
        ///
        /// The request stays owed until a fetch genuinely starts. A `.state` read already in flight refuses
        /// this one (`directStateFetchInFlight`), and that read was issued before this resync was owed, so
        /// it can answer with no render update and repair nothing; treating the refusal as delivery is how
        /// the owed request would go missing. So a retry that lands on one waits out another full window
        /// instead — no spin, and the pacing is unchanged since nothing was sent.
        ///
        /// The mirror case needs no machinery: an in-flight fetch that completes frameless while nothing is
        /// armed owes nothing, because nothing has failed to reduce since it was issued. Whatever payload
        /// next fails asks again through `requestRenderUpdateStateResync`, and a session that goes quiet
        /// with no payload at all is covered on the far side — the daemon holds its subscriber-baseline arm
        /// until a broadcast actually carries a full frame.
        private func scheduleTrailingRenderUpdateResync(after delay: TimeInterval) {
            guard pendingRenderUpdateResyncTask == nil else { return }
            pendingRenderUpdateResyncTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.pendingRenderUpdateResyncTask = nil
                // An ended pane showing its own scrollback replay renders from the transcript, not from
                // session state, so a fetch here would repair nothing it displays.
                guard !self.isEndedScrollbackReplayActive else { return }
                guard !self.directStateFetchInFlight else {
                    self.scheduleTrailingRenderUpdateResync(after: self.renderUpdateResyncInterval)
                    return
                }
                self.lastRenderUpdateResyncAt = Date()
                self.requestDirectStateFetch()
            }
        }

        private func cancelTrailingRenderUpdateResync() {
            pendingRenderUpdateResyncTask?.cancel()
            pendingRenderUpdateResyncTask = nil
        }

        /// Whether a `.state` response's render payload is still worth applying.
        ///
        /// A response describes the screen as it was when the session answered, and the render-update
        /// applier takes any full frame whatever revision it carries, so a response that lost the race with
        /// the subscription would walk the pane back to an older picture. But arrival order alone cannot
        /// decide that: exporting state flushes the session's pending output into its surface WITHOUT
        /// broadcasting and without moving the stream's delta baseline, so the frame a read returns can be
        /// strictly newer than anything the subscription has sent — and nothing is coming to repeat it.
        /// Ordering is therefore by revision, which the daemon advances monotonically per session within an
        /// owner epoch (and never reuses for different content: `renderFrameRevision` bumps rather than
        /// letting two screens share a revision).
        ///
        /// So the payload is dropped in exactly one case: a frame applied while the read was in flight, the
        /// response belongs to the same owner epoch as that frame, and its revision is not newer — equal
        /// means identical content, older means superseded. Everything else is applied: a strictly newer
        /// revision is the flush-without-broadcast window above, a different owner epoch belongs to the
        /// handoff machinery rather than to this comparison, and a missing revision on either side cannot be
        /// ordered at all. Dropping costs nothing that is owed, either — the same apply that moved the
        /// generation retired any delayed resync.
        private func shouldApplyFetchedRenderPayload(_ payload: GhosttyRemoteSessionStatePayload, issuedAtRenderFrameGeneration: UInt64) -> Bool {
            guard appliedRenderFrameGeneration != issuedAtRenderFrameGeneration else { return true }
            guard let applied = lastAppliedRenderFrameOrdering, let response = payload.renderFrameOrdering else { return true }
            guard response.ownerEpoch == applied.ownerEpoch else { return true }
            guard let appliedRevision = applied.sessionRevision, let responseRevision = response.sessionRevision else { return true }
            return responseRevision > appliedRevision
        }

        private func requestDirectStateFetch() {
            guard let terminalServiceRequestSender else { return }
            guard !directStateFetchInFlight else { return }
            directStateFetchInFlight = true
            let sessionID = launchConfiguration.sessionID
            let issuedAtRenderFrameGeneration = appliedRenderFrameGeneration
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
                    guard self.shouldApplyFetchedRenderPayload(fetchResult.payload, issuedAtRenderFrameGeneration: issuedAtRenderFrameGeneration)
                    else { return }
                    // Through the same pipeline as the subscription's payloads: a fetched full frame is
                    // the head of a new render-update chain, so it must not overtake a delta already
                    // queued behind it.
                    self.submitToStatePipeline(fetchResult.payload)
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
        private func submitToStatePipeline(_ payload: GhosttyRemoteSessionStatePayload) {
            if payload.renderUpdateKind == .full { pendingFullFrameSubmission.mark() }
            statePipeline.submit(payload)
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
            if output.requestsResync { requestRenderUpdateStateResync() }
            lastSubscriptionAttemptAt = nil
            let frameForUpdate = reduction.frameToApply
            // A frame that applied repaired the chain, so any delayed resync still armed for the gap it
            // filled is no longer owed. Ordered after the request above so an output that both carries a
            // frame and inherits a coalesced-away resync retires that request rather than leaving it armed.
            // The generation bump, and the ordering recorded with it, are what let an in-flight `.state`
            // read tell whether it was overtaken.
            if let frameForUpdate {
                appliedRenderFrameGeneration &+= 1
                lastAppliedRenderFrameOrdering = (frameForUpdate.sessionRevision, frameForUpdate.ownerEpoch)
                cancelTrailingRenderUpdateResync()
            }
            let applyStartedAt = Date()
            // A relaunch resurrects the live renderer, so drop any ended-session replay and let live
            // frames render again. While a replay is still active for an ended session, a re-served
            // final payload for the *same* run must not clobber the locally scrolled viewport.
            //
            // A relaunch+exit unobserved by this client (disconnected, or between refreshes) surfaces as
            // another *ended* payload rather than an interactive one, so the interactive check alone would
            // keep replaying the previous run's transcript and suppressing the new run's final frame.
            // Detect it by run identity: when the armed replay belongs to a different ended run than the
            // one now observed, discard so the new run's final frame renders and its transcript re-fetches.
            if isInteractiveRuntimeStateForControl() {
                discardEndedScrollbackIfActive()
            } else if let armedRunIdentity = endedScrollbackRunIdentity, currentEndedRunIdentity() != armedRunIdentity {
                discardEndedScrollbackIfActive()
            }
            if !isEndedScrollbackReplayActive, frameForUpdate != nil || !terminalView.hasRenderedSurfaceContent {
                terminalView.update(frame: frameForUpdate, renderStateKey: currentRenderStateKey())
            } else if isEndedScrollbackReplayActive {
                // The replay guard above suppresses this state's frame; repaint the replay viewport when
                // the state update arrives on a surface that was released and recreated underneath it.
                repaintEndedReplayViewportIfSurfaceEmpty()
            }
            let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
            if attachedMode == .owner { sendCurrentViewportResizeIfNeeded(force: false) }
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
            postLocalNotifications(for: payload)
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

        private func postLocalNotifications(for payload: GhosttyRemoteSessionStatePayload) {
            for name in TerminalRemoteSessionStateNotificationRouting.notifications(forReason: payload.reason) {
                TerminalSessionNotification.post(name, sessionID: payload.sessionID)
            }
        }

        private func currentSnapshot() -> GhosttyTerminalSnapshot? { latestSnapshotIfCompatible() }

        private func currentRenderFrameForRenderUpdate() -> GhosttyRenderFrame? {
            guard let frame = latestState?.decodedRenderUpdate?.fullFrame,
                Self.shouldUseRenderFrameSnapshot(frame.snapshot, runtimeState: latestState?.runtimeState, reason: latestState?.reason)
            else {
                guard !terminalView.hasRenderedSurfaceContent else { return nil }
                return nil
            }
            return frame
        }

        private func latestSnapshotIfCompatible() -> GhosttyTerminalSnapshot? {
            guard let snapshot = latestState?.renderSnapshot,
                Self.shouldUseRenderFrameSnapshot(snapshot, runtimeState: latestState?.runtimeState, reason: latestState?.reason)
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

        private func sendRemoteClearScreenAndScrollback() {
            guard isInteractiveRuntimeStateForControl() else { return }
            guard let client = attachedClient else { return }
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

        private func sendRemoteScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?) {
            guard isInteractiveRuntimeStateForControl() else {
                _ = scrollEndedSession(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods)
                return
            }
            guard attachedClient != nil, attachedMode == .owner else { return }
            scrollCoalescer.append(
                horizontal: Double(horizontal), vertical: Double(vertical), scrollMods: scrollMods, pointerPosition: pointerPosition)
        }

        // MARK: - Ended-session scrollback replay

        /// Scrolls an ended pane's persisted-transcript replay. The live daemon renderer is gone once
        /// the process exits, so scrolling can no longer be forwarded; instead the transcript is
        /// replayed into a client-local vt session and scrolled locally. Runs under the ended pane's
        /// forced `.viewer` final-render attach. Returns true when the scroll is accepted (routed into
        /// the replay), false when there is nothing to scroll (no attach, or no transcript to replay).
        @discardableResult private func scrollEndedSession(horizontal _: CGFloat, vertical: CGFloat, scrollMods: Int32) -> Bool {
            guard attachedClient != nil else { return false }
            let deltaRows = endedScrollDeltaNormalizer.terminalViewportDeltaRows(vertical: Double(vertical), scrollMods: scrollMods)
            switch endedScrollbackState {
            case .unavailable: return false
            case .ready(let model):
                if deltaRows != 0 { applyEndedScroll(deltaRows: deltaRows, model: model) }
                return true
            case .loading(let pendingDeltaRows):
                endedScrollbackState = .loading(pendingDeltaRows: pendingDeltaRows + deltaRows)
                return true
            case .idle:
                // A sub-cell nudge normalizes to zero rows; wait for a real scroll before paying to
                // fetch and replay the transcript, but still report it as accepted.
                guard deltaRows != 0 else { return true }
                // Arm the replay against the current ended run. Every non-idle state descends from this
                // single idle->loading transition, so recording identity once here covers the `.loading`,
                // `.ready`, and `.unavailable` outcomes; `applyReducedState` compares it to later payloads
                // to discard a stale replay when a different ended run is observed.
                endedScrollbackRunIdentity = currentEndedRunIdentity()
                endedScrollbackState = .loading(pendingDeltaRows: deltaRows)
                beginLoadingEndedScrollbackModel()
                return true
            }
        }

        private func beginLoadingEndedScrollbackModel() {
            guard let transcriptProvider else {
                endedScrollbackState = .unavailable
                return
            }
            // Build at the final frame's grid so the replay wraps exactly as the daemon's final frame
            // did; fall back to the runtime-state grid when the final frame is unavailable.
            //
            // The replay seeds at the transcript bottom. The persisted final frame is viewport-only with
            // no scrollback offset, so a process that exited while the user was scrolled above the bottom
            // jumps bottom-relative (or clamps) on the first scroll gesture. Accepted until a scroll
            // offset is persisted with the final frame.
            let finalFrame = latestState?.decodedRenderUpdate?.fullFrame
            let columns = finalFrame?.columns ?? latestState?.runtimeState?.columns ?? 80
            let rows = finalFrame?.rows ?? latestState?.runtimeState?.rows ?? 24
            let appearance: ThemeAppearance = terminalView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            let theme = ActiveTheme.descriptor.terminal(for: appearance)
            let maxBytes = TerminalScrollbackBudget.defaultMaxBytes
            // Pin this load to the current run. If the session relaunches and exits again while the
            // fetch is in flight, `discardEndedScrollbackIfActive` bumps the generation, so the checks
            // below reject this stale result instead of installing it under the newer run's `.loading`.
            let generation = endedScrollbackGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                let transcript: RemoteGhosttyTranscript
                do { transcript = try await transcriptProvider(maxBytes) } catch {
                    // A transport failure (timeout, daemon restarting, remote device offline) is
                    // transient: return to idle so the next scroll gesture retries the fetch.
                    if generation == self.endedScrollbackGeneration, case .loading = self.endedScrollbackState { self.endedScrollbackState = .idle }
                    return
                }
                // A relaunch (session went interactive again) discards the loading state mid-fetch,
                // bumping the generation; a stale-run result is rejected here.
                guard generation == self.endedScrollbackGeneration, case .loading = self.endedScrollbackState else { return }
                // The transcript response carries the run identity the server read it from. A relaunch
                // that lands after the fetch started but before this client observes a new state payload
                // leaves the generation and armed identity unchanged, yet truncates `output.log` — so the
                // fetched bytes can belong to the new run. When the response identity differs from the
                // armed one, the armed run's transcript is definitively gone: latch `.unavailable` (cleared
                // only by a later discard through the interactive or run-identity path). Skip the check
                // when either identity is unknown (nil) and behave as before.
                if let responseIdentity = transcript.runIdentity, let armedIdentity = self.endedScrollbackRunIdentity,
                    responseIdentity != armedIdentity
                {
                    self.endedScrollbackState = .unavailable
                    return
                }
                guard !transcript.data.isEmpty else {
                    // An empty transcript is definitive — there is nothing to replay.
                    self.endedScrollbackState = .unavailable
                    return
                }
                let model = await Task.detached(priority: .userInitiated) {
                    TerminalEndedSessionScrollbackModel(columns: columns, rows: rows, theme: theme, transcript: transcript.data)
                }.value
                guard generation == self.endedScrollbackGeneration, case .loading(let pendingDeltaRows) = self.endedScrollbackState else { return }
                guard let model else {
                    self.endedScrollbackState = .unavailable
                    return
                }
                self.endedScrollbackState = .ready(model)
                if pendingDeltaRows != 0 { self.applyEndedScroll(deltaRows: pendingDeltaRows, model: model) }
            }
        }

        private func applyEndedScroll(deltaRows: Int, model: TerminalEndedSessionScrollbackModel) {
            guard let snapshot = model.scroll(deltaRows: deltaRows) else { return }
            endedScrollbackRevision &+= 1
            let frame = GhosttyRenderFrame(
                sessionRevision: endedScrollbackRevision, ownerEpoch: latestState?.renderOwnerEpoch ?? 0, snapshot: snapshot)
            terminalView.update(frame: frame, renderStateKey: currentRenderStateKey())
        }

        private var isEndedScrollbackReplayActive: Bool {
            switch endedScrollbackState {
            case .loading, .ready: true
            case .idle, .unavailable: false
            }
        }

        /// Repaints the ended-replay viewport after the mirror surface was released and recreated
        /// (the pane controller releases the surface before reattaching an ended viewer). The
        /// replay guard suppresses live-frame repaints, so without this the recreated surface
        /// stays blank until the next scroll gesture.
        private func repaintEndedReplayViewportIfSurfaceEmpty() {
            guard !terminalView.hasRenderedSurfaceContent else { return }
            switch endedScrollbackState {
            case .ready(let model):
                endedScrollbackRevision &+= 1
                let frame = GhosttyRenderFrame(
                    sessionRevision: endedScrollbackRevision, ownerEpoch: latestState?.renderOwnerEpoch ?? 0, snapshot: model.currentSnapshot())
                terminalView.update(frame: frame, renderStateKey: currentRenderStateKey())
            case .loading:
                // No replay model yet — show the daemon's final frame until the load completes.
                terminalView.update(frame: currentRenderFrameForRenderUpdate(), renderStateKey: currentRenderStateKey())
            case .idle, .unavailable: break
            }
        }

        /// Resets ended-scrollback state when the session becomes interactive again (a relaunch): the
        /// live render takes over, so the model is dropped (freeing its vt session), the accumulated
        /// scroll delta is reset, and a previous `.unavailable` verdict is cleared — the relaunched
        /// session will write a fresh transcript, so a later exit must get a fresh replay attempt. The
        /// generation bump invalidates any transcript load still in flight for the run being discarded,
        /// so its result cannot install under a later run's `.loading`.
        private func discardEndedScrollbackIfActive() {
            if case .idle = endedScrollbackState { return }
            endedScrollbackGeneration &+= 1
            endedScrollbackState = .idle
            endedScrollbackRunIdentity = nil
            endedScrollDeltaNormalizer = TerminalScrollDeltaNormalizer()
        }

        /// Run identity for the ended run currently described by `latestState`, delegating to the shared
        /// `TerminalSessionRuntimeState.runIdentity` format so the armed replay identity matches the one
        /// the transcript response carries. `nil` when there is no runtime state yet. Used to detect an
        /// ended->ended transition to a different run and to validate transcript responses.
        private func currentEndedRunIdentity() -> String? { latestState?.runtimeState?.runIdentity }

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
                }, onError: { error in await Self.reportInputFailure(error, inputFailureHandler: inputFailureHandler, inputQueue: queue) })
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
            _ snapshot: GhosttyTerminalSnapshot, runtimeState: TerminalSessionRuntimeState?, reason: String?
        ) -> Bool {
            guard reason == TerminalRemoteSessionStateReason.resize else { return true }
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
