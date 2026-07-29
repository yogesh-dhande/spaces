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
    /// (`DeviceTerminalSessionStateModel.isTransportFailureEvidenceOfLostLink`) knows whether a given
    /// failure is evidence about the link.
    ///
    /// Returns whether the failure itself proves the link is gone. When `true`, the host discards this
    /// pane's queued input (`TerminalInputSerialQueue.cancelAll()`) instead of letting a backlog typed
    /// during the outage drain and deliver late — including any Enter — once the link recovers.
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
        /// send that cannot reach the device is the earliest proof the link is gone — a silently dead
        /// network path leaves the subscription's socket looking healthy until TCP keepalive gives up a
        /// minute or more later. See `reportInputFailure`, the shared call point every one of those
        /// requests funnels its failure through.
        private let inputFailureHandler: RemoteGhosttyInputFailureHandler?
        private let terminalView: GhosttyMirrorTerminalView
        private var latestState: GhosttyRemoteSessionStatePayload?
        private var stateReducer = TerminalRemoteStateReducer()
        private var stateStreamClient: GhosttyRemoteSessionStateStreamClient?
        private var directStateStreamClient: (any TerminalRemoteStateStreamClient)?
        private var lastSubscriptionAttemptAt: Date?
        private var directStateFetchInFlight = false
        private var lastRenderUpdateResyncAt: Date?
        private var attachedClient: TerminalClient?
        private var attachedMode: TerminalAttachmentMode = .viewer
        private var lastRequestedViewportSize: (columns: Int, rows: Int)?
        /// The mirror surface generation the last owner attach measured its viewport against. An attach
        /// that finds a different generation is looking at a rebuilt surface and re-sends the viewport.
        private var lastAttachedSurfaceGeneration: UInt64?
        private var pendingViewportResizeSize: (columns: Int, rows: Int)?
        private var pendingViewportResizeTask: Task<Void, Never>?
        /// The one-turn deferral every measured viewport size waits out before it is sent (see
        /// `handleViewportSizeChange`). Cancel-and-replace: a newer measurement discards the pending
        /// one, so only the size the layout settled on is ever sent.
        private var pendingViewportSettleTask: Task<Void, Never>?
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
            // Same rule as applyRemoteState: while the ended-session replay is showing a scrolled
            // viewport, a re-attach must not clobber it with the daemon's final frame. But if the
            // surface was released and recreated between detach and this attach, repaint the replay
            // viewport so the recreated surface is not left blank.
            if !isEndedScrollbackReplayActive {
                terminalView.update(frame: currentRenderFrameForRenderUpdate(), renderStateKey: currentRenderStateKey())
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
            guard isInteractiveRuntimeStateForControl() else { return nil }
            return latestState?.attachmentSnapshot?.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        }

        public func hasRenderableSurface() -> Bool { terminalView.hasRenderedContent }

        public func requestSurfaceRefresh() {
            requestDirectStateRefresh(reason: TerminalRemoteSessionStateReason.stateChange)
            // Same rule as applyRemoteState: a refresh must not clobber a scrolled ended viewport, but
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
                socketPath: paths.subscriptionSocketPath, onEvent: { [weak self] payload in self?.applyRemoteState(payload) },
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
                let client = try stateStreamSubscriber(
                    launchConfiguration.sessionID, { [weak self] payload in Task { @MainActor [weak self] in self?.applyRemoteState(payload) } },
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

        /// A resync means a frame-bearing payload failed to apply (missing baseline, revision or
        /// owner-epoch mismatch). Each direct `.state` fetch opens a transient connection on the
        /// daemon's subscription socket, so an unthrottled retry loop floods the daemon with
        /// unicast initial exports without converging; space the retries so the stream's own
        /// recovery (the forced full-frame broadcast) can land in between.
        private func requestRenderUpdateStateResync() {
            let now = Date()
            if let lastRenderUpdateResyncAt, now.timeIntervalSince(lastRenderUpdateResyncAt) < 1 { return }
            lastRenderUpdateResyncAt = now
            requestDirectStateFetch()
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
                    self.applyRemoteState(fetchResult.payload)
                    self.applyAndAcknowledgeAgentSignals(fetchResult.agentSignals)
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

        private func applyRemoteState(_ incomingPayload: GhosttyRemoteSessionStatePayload, postNotifications: Bool = true) {
            let decodeStartedAt = Date()
            let reduction = stateReducer.reduce(
                incomingPayload: incomingPayload, previousPayload: latestState,
                shouldUseFrame: { frame, payload in
                    Self.shouldUseRenderFrameSnapshot(frame.snapshot, runtimeState: payload.runtimeState, reason: payload.reason)
                }, requestResyncOnApplyFailure: true)
            let payload = reduction.payload
            let decodedFrame = reduction.frameToApply
            let decodedUpdate = reduction.decodedUpdate
            let decodeMS = TerminalPerformance.elapsedMS(since: decodeStartedAt)
            let dropReason = reduction.dropReason
            latestState = reduction.storedPayload
            if reduction.didRequestResync { requestRenderUpdateStateResync() }
            lastSubscriptionAttemptAt = nil
            let frameForUpdate = reduction.frameToApply
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
                resyncCount: reduction.didRequestResync ? 1 : nil)
            renderUpdateAttributes["materialized_render_update_bytes"] = String(payload.renderUpdate?.count ?? 0)
            renderUpdateAttributes["render_update"] = incomingPayload.renderUpdate == nil ? "0" : "1"
            renderUpdateAttributes["render_update_bytes"] = String(incomingPayload.renderUpdate?.count ?? 0)
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(
                    sessionID: payload.sessionID, source: "mac-mirror", name: "render_frame_payload_receive",
                    elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt), count: incomingPayload.renderUpdate?.count,
                    attributes: renderUpdateAttributes))
            TerminalPerformance.logMetric(
                "terminal_remote_state_receive", target: "session=\(payload.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt),
                success: true,
                detail:
                    "reason=\(payload.reason) render_update=\(incomingPayload.renderUpdate == nil ? 0 : 1) bytes=\(payload.outputByteCount ?? 0) render_update_bytes=\(incomingPayload.renderUpdate?.count ?? 0)"
            )
            TerminalPerformance.logMetric(
                "terminal_render_frame_payload_receive", target: "session=\(payload.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt), success: dropReason == nil,
                detail: GhosttyRenderFrameMetrics.detailString(renderUpdateAttributes))
            if postNotifications { postLocalNotifications(for: payload) }
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
                // `.ready`, and `.unavailable` outcomes; `applyRemoteState` compares it to later payloads
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
            pendingViewportSettleTask?.cancel()
            pendingViewportSettleForce = pendingViewportSettleForce || force
            pendingViewportSettleTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.pendingViewportSettleTask = nil
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
        /// failure is itself proof the link is gone, discards this pane's queued input backlog rather than
        /// letting it drain and deliver late — including any Enter — once the link recovers. Shared by
        /// every interactive control path: the four still chained on `inputQueue`'s `onError` (input, key,
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
#endif
