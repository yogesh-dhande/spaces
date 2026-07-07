#if canImport(AppKit)
    import AppKit
    import Foundation
    import spacesterminalcore

    public typealias RemoteGhosttyTerminalServiceRequestSender = @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    public typealias RemoteGhosttyAgentSignalHandler = @MainActor @Sendable ([TerminalServiceAgentSignalEvent]) throws -> [String]
    public typealias RemoteGhosttyStateStreamSubscriber =
        @Sendable (
            _ sessionID: String, _ onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void,
            _ onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) throws -> any TerminalRemoteStateStreamClient

    @MainActor public final class RemoteGhosttySessionHost: TerminalGhosttySessionHosting {
        private let launchConfiguration: TerminalSessionLaunchConfiguration
        private let paths: TerminalSessionPaths
        private let terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender?
        private let stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber?
        private let agentSignalHandler: RemoteGhosttyAgentSignalHandler?
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
        private var pendingViewportResizeSize: (columns: Int, rows: Int)?
        private var pendingViewportResizeTask: Task<Void, Never>?
        private var resizeSerial: UInt64 = 0
        private let inputQueue = TerminalInputSerialQueue()
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
            stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber? = nil, agentSignalHandler: RemoteGhosttyAgentSignalHandler? = nil
        ) {
            self.launchConfiguration = launchConfiguration
            self.paths = paths
            self.terminalServiceRequestSender = terminalServiceRequestSender
            self.stateStreamSubscriber = stateStreamSubscriber
            self.agentSignalHandler = agentSignalHandler
            terminalView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
            ensureStateStreamStartedIfNeeded()
        }

        deinit {
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                stateStreamClient?.stop()
                directStateStreamClient?.stop()
                pendingViewportResizeTask?.cancel()
                scrollCoalescer.cancel()
                inputQueue.cancelAll()
            }
        }

        public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
            attachedClient = client
            let isInteractive = isInteractiveRuntimeStateForControl()
            attachedMode = isInteractive ? mode : .viewer
            if mode != .owner {
                pendingViewportResizeTask?.cancel()
                pendingViewportResizeTask = nil
                pendingViewportResizeSize = nil
            } else {
                pendingViewportResizeTask?.cancel()
                pendingViewportResizeTask = nil
                pendingViewportResizeSize = nil
                lastRequestedViewportSize = nil
            }
            terminalView.acceptsTerminalInput = isInteractive && mode == .owner
            terminalView.onSendText = { [weak self] text in self?.sendRemoteInput(text) }
            terminalView.onSendKey = { [weak self] key in self?.sendRemoteKey(key) }
            terminalView.onSendScroll = { [weak self] horizontal, vertical, scrollMods in
                self?.sendRemoteScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods)
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
            terminalView.update(frame: currentRenderFrameForRenderUpdate(), renderStateKey: currentRenderStateKey())
            if isInteractive && mode == .owner { sendCurrentViewportResizeIfNeeded(force: true) }
        }

        public func releaseRendererSurface() { terminalView.releaseSurface() }

        public func setFocused(_ focused: Bool, for clientID: String) {
            guard clientID == attachedClient?.id else {
                if !focused, terminalView.window?.firstResponder === terminalView { terminalView.window?.makeFirstResponder(nil) }
                return
            }
            if focused { terminalView.focusWindow(terminalView.window) }
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
            terminalView.update(frame: currentRenderFrameForRenderUpdate(), renderStateKey: currentRenderStateKey())
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

        @discardableResult public func performBindingAction(_ action: String) -> Bool {
            let permitsFinalRenderReadOnlyAction = !isInteractiveRuntimeStateForControl() && Self.isReadOnlyBindingAction(action)
            guard attachedMode == .owner || permitsFinalRenderReadOnlyAction else { return false }
            return terminalView.performBindingAction(action)
        }

        @discardableResult public func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32) -> Bool {
            guard isInteractiveRuntimeStateForControl() else { return false }
            return terminalView.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods)
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
            let incomingPayloadBytes = (try? GhosttyRemoteSessionStateCodec.encodeLine(incomingPayload).count) ?? 0
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
            if frameForUpdate != nil || !terminalView.hasRenderedSurfaceContent {
                terminalView.update(frame: frameForUpdate, renderStateKey: currentRenderStateKey())
            }
            let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
            if attachedMode == .owner { sendCurrentViewportResizeIfNeeded(force: false) }
            let emittedAt = GhosttyRemoteSessionStateTimestamp.date(from: payload.emittedAt) ?? Date()
            var renderUpdateAttributes = GhosttyRenderFrameMetrics.attributes(
                reason: payload.reason, frame: decodedFrame, frameByteCount: incomingPayload.renderUpdate?.count,
                payloadByteCount: incomingPayloadBytes, decodeMS: decodeMS, outputByteCount: payload.outputByteCount,
                screenStateRevision: payload.screenStateRevision, dropped: incomingPayload.renderUpdate == nil ? nil : dropReason != nil,
                dropReason: dropReason, renderMode: "ghostty-mirror", frameKind: decodedUpdate?.frameKindMetricValue,
                baseRevision: decodedUpdate?.baseRevision, targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
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
                    "reason=\(payload.reason) render_update=\(incomingPayload.renderUpdate == nil ? 0 : 1) bytes=\(payload.outputByteCount ?? 0) payload_bytes=\(incomingPayloadBytes) render_update_bytes=\(incomingPayload.renderUpdate?.count ?? 0)"
            )
            TerminalPerformance.logMetric(
                "terminal_render_frame_payload_receive", target: "session=\(payload.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt), success: dropReason == nil,
                detail: GhosttyRenderFrameMetrics.detailString(renderUpdateAttributes))
            if postNotifications { postLocalNotifications(for: payload) }
        }

        private func postLocalNotifications(for payload: GhosttyRemoteSessionStatePayload) {
            let sessionID = payload.sessionID
            switch payload.reason {
            case "attachment_state":
                TerminalSessionNotification.post(.spacesTerminalAttachmentStateDidChange, sessionID: sessionID)
                TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: sessionID)
            case "session_metadata":
                TerminalSessionNotification.post(.spacesTerminalSessionMetadataDidChange, sessionID: sessionID)
                TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: sessionID)
            case "output":
                TerminalSessionNotification.post(.spacesTerminalOutputDidChange, sessionID: sessionID)
            case "initial", "runtime_state", "terminated":
                TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: sessionID)
            default: TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: sessionID)
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

        private func sendRemoteInput(_ text: String) {
            guard isInteractiveRuntimeStateForControl() else { return }
            guard let client = attachedClient else { return }
            scrollCoalescer.flush()
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let ownerEpoch = latestState?.renderOwnerEpoch
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            inputQueue.enqueue(priority: .userInitiated) {
                _ = try Self.sendControlRequest(
                    TerminalControlRequest(
                        command: .send(.init(text: text, bytes: nil, clientID: clientID, ownerEpoch: ownerEpoch, appendNewline: false))),
                    sessionID: sessionID, socketPath: socketPath, requestSender: requestSender)
                if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "input") } }
            }
        }

        private func sendRemoteKey(_ key: String) {
            guard isInteractiveRuntimeStateForControl() else { return }
            if TerminalKeyInput.hostAction(for: key) == .clearScreenAndScrollback {
                sendRemoteClearScreenAndScrollback()
                return
            }
            guard let client = attachedClient else { return }
            scrollCoalescer.flush()
            let socketPath = paths.controlSocketPath
            let clientID = client.id
            let ownerEpoch = latestState?.renderOwnerEpoch
            let sessionID = launchConfiguration.sessionID
            let requestSender = terminalServiceRequestSender
            let shouldRefreshAfterControl = requestSender != nil && stateStreamSubscriber == nil
            inputQueue.enqueue(priority: .userInitiated) {
                _ = try Self.sendControlRequest(
                    TerminalControlRequest(command: .key(.init(key: key, clientID: clientID, ownerEpoch: ownerEpoch))), sessionID: sessionID,
                    socketPath: socketPath, requestSender: requestSender)
                if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "input") } }
            }
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
            inputQueue.enqueue(priority: .userInitiated) {
                _ = try Self.sendControlRequest(
                    TerminalControlRequest(command: .clearScreen(.init(clientID: clientID, ownerEpoch: ownerEpoch))), sessionID: sessionID,
                    socketPath: socketPath, requestSender: requestSender)
                if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "clear_screen") } }
            }
        }

        private func sendRemoteScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32) {
            guard isInteractiveRuntimeStateForControl(), attachedClient != nil, attachedMode == .owner else { return }
            scrollCoalescer.append(horizontal: Double(horizontal), vertical: Double(vertical), scrollMods: scrollMods)
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
            inputQueue.enqueue(priority: .userInitiated) {
                defer { Task { @MainActor in onFinished() } }
                _ = try Self.sendControlRequest(
                    TerminalControlRequest(
                        command: .scroll(
                            .init(
                                clientID: clientID, ownerEpoch: ownerEpoch, scrollHorizontal: batch.horizontal, scrollVertical: batch.vertical,
                                scrollMods: batch.scrollMods == 0 ? nil : batch.scrollMods))), sessionID: sessionID, socketPath: socketPath,
                    requestSender: requestSender)
                if shouldRefreshAfterControl { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "scroll") } }
            }
        }

        private func sendCurrentViewportResizeIfNeeded(force: Bool) {
            guard isInteractiveRuntimeStateForControl(), attachedMode == .owner, let size = terminalView.surfaceCellSize() else { return }
            handleViewportSizeChange(columns: size.columns, rows: size.rows, force: force)
        }

        private func handleViewportSizeChange(columns: Int, rows: Int, force: Bool = false) {
            guard isInteractiveRuntimeStateForControl(), attachedMode == .owner, let client = attachedClient else { return }
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
            let finishResizeRequest: @MainActor @Sendable (Bool) -> Void = { [weak self, requestedSize] success in
                guard let self else { return }
                if let pendingViewportResizeSize = self.pendingViewportResizeSize, pendingViewportResizeSize == requestedSize {
                    self.pendingViewportResizeSize = nil
                }
                if success { self.lastRequestedViewportSize = requestedSize }
                self.pendingViewportResizeTask = nil
            }
            pendingViewportResizeTask = Task.detached(priority: .utility) {
                let response = try? Self.sendControlRequest(
                    TerminalControlRequest(
                        command: .resize(
                            .init(clientID: clientID, columns: columns, rows: rows, ownerEpoch: ownerEpoch, resizeSerial: currentResizeSerial))),
                    sessionID: sessionID, socketPath: socketPath, requestSender: requestSender)
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
