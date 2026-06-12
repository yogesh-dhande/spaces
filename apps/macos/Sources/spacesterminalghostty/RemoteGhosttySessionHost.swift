#if canImport(AppKit)
    import AppKit
    import Foundation
    import spacesterminalcore

    public typealias RemoteGhosttyTerminalServiceRequestSender = @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    public typealias RemoteGhosttyAgentSignalHandler = @MainActor @Sendable ([TerminalServiceAgentSignalEvent]) throws -> [String]

    @MainActor public final class RemoteGhosttySessionHost: TerminalGhosttySessionHosting {
        private let launchConfiguration: TerminalSessionLaunchConfiguration
        private let paths: TerminalSessionPaths
        private let terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender?
        private let agentSignalHandler: RemoteGhosttyAgentSignalHandler?
        private let terminalView: GhosttyMirrorTerminalView
        private var latestState: GhosttyRemoteSessionStatePayload?
        private var persistedFinalStateLoaded = false
        private var persistedFinalStateLoadInProgress = false
        private var renderUpdateBaseline: GhosttyRenderUpdateBaseline?
        private var stateStreamClient: GhosttyRemoteSessionStateStreamClient?
        private var lastSubscriptionAttemptAt: Date?
        private var directStatePollingTask: Task<Void, Never>?
        private var directStateFetchInFlight = false
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
        private static let directStatePollingInterval: Duration = .milliseconds(750)

        public init(
            launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
            terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender? = nil, agentSignalHandler: RemoteGhosttyAgentSignalHandler? = nil
        ) {
            self.launchConfiguration = launchConfiguration
            self.paths = paths
            self.terminalServiceRequestSender = terminalServiceRequestSender
            self.agentSignalHandler = agentSignalHandler
            terminalView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
            ensureStateStreamStartedIfNeeded()
        }

        deinit {
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                stateStreamClient?.stop()
                directStatePollingTask?.cancel()
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
            if let attachmentSnapshot = latestState?.attachmentSnapshot {
                return attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
            }
            return ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
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
            return latestState?.title ?? ((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.title) ?? launchConfiguration.title
        }

        public var effectiveWorkingDirectory: String {
            ensureStateStreamStartedIfNeeded()
            return latestState?.workingDirectory ?? ((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.workingDirectory)
                ?? launchConfiguration.workingDirectory
        }

        private func ensureStateStreamStartedIfNeeded(now: Date = Date()) {
            if terminalServiceRequestSender != nil {
                startDirectStatePollingIfNeeded()
                requestDirectStateRefresh(reason: TerminalRemoteSessionStateReason.initial)
                return
            }
            guard isInteractiveRuntimeStateForControl() else {
                loadPersistedFinalStateIfAvailable()
                return
            }
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

        private func startDirectStatePollingIfNeeded() {
            guard directStatePollingTask == nil else { return }
            directStatePollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.requestDirectStateRefresh(reason: "poll")
                    try? await Task.sleep(for: Self.directStatePollingInterval)
                }
            }
        }

        private func stopDirectStatePolling() {
            directStatePollingTask?.cancel()
            directStatePollingTask = nil
        }

        private func requestDirectStateRefresh(reason _: String) {
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
                    if fetchResult.payload.runtimeState?.state.isInteractive == false { self.stopDirectStatePolling() }
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
                let response = try requestSender(TerminalServiceRequest(command: "state", sessionID: sessionID))
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
                    TerminalServiceRequest(command: "ackAgentSignals", sessionID: sessionID, agentSignalEventIDs: acknowledgedIDs))
            }
        }

        private func handleStreamDisconnect() {
            stateStreamClient = nil
            lastSubscriptionAttemptAt = Date()
            if !isInteractiveRuntimeStateForControl() { loadPersistedFinalStateIfAvailable() }
        }

        @discardableResult private func loadPersistedFinalStateIfAvailable() -> Bool {
            guard !persistedFinalStateLoaded, !persistedFinalStateLoadInProgress else { return latestState != nil }
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), runtimeState.state.isInteractive { return false }
            guard let payload = try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) else { return false }
            guard payload.runtimeState?.state.isInteractive != true else { return false }
            persistedFinalStateLoadInProgress = true
            persistedFinalStateLoaded = true
            defer { persistedFinalStateLoadInProgress = false }
            applyRemoteState(payload, postNotifications: false)
            return true
        }

        private func isInteractiveRuntimeStateForControl() -> Bool {
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) { return runtimeState.state.isInteractive }
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
            if incomingPayload.runtimeState?.state.isInteractive == true { persistedFinalStateLoaded = false }
            let decodeStartedAt = Date()
            let incomingPayloadBytes = (try? GhosttyRemoteSessionStateCodec.encodeLine(incomingPayload).count) ?? 0
            let resolvedRenderState = payloadByResolvingRenderUpdate(incomingPayload)
            let payload = resolvedRenderState.payload
            let decodedFrame = payload.decodedRenderUpdate?.fullFrame
            let decodedUpdate = resolvedRenderState.decodedUpdate
            let decodeMS = TerminalPerformance.elapsedMS(since: decodeStartedAt)
            let dropReason = renderUpdateDropReason(for: payload, decodedFrame: decodedFrame) ?? resolvedRenderState.dropReason
            latestState = latestState?.merged(with: payload) ?? payload
            try? TerminalSessionPersistence.writeRemoteStateMirror(latestState ?? payload, paths: paths)
            lastSubscriptionAttemptAt = nil
            let frameForUpdate = currentRenderFrameForRenderUpdate()
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
                dropReason: dropReason, renderMode: "ghostty-mirror", frameKind: decodedUpdate?.frameKindMetricValue ?? "full",
                baseRevision: decodedUpdate?.baseRevision, targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
                appliedRevision: frameForUpdate == nil ? nil : (payload.screenStateRevision ?? frameForUpdate?.sessionRevision), applyMS: applyMS,
                operationCount: decodedUpdate?.operationCount, changedCellCount: decodedUpdate?.changedCellCount,
                scrollOperationCount: decodedUpdate?.scrollOperationCount, fullFrameFallbackReason: decodedUpdate?.fallbackReason)
            renderUpdateAttributes["materialized_render_update_bytes"] = String(payload.renderUpdate?.count ?? 0)
            renderUpdateAttributes["render_update"] = incomingPayload.renderUpdate == nil ? "0" : "1"
            renderUpdateAttributes["render_update_bytes"] = String(incomingPayload.renderUpdate?.count ?? 0)
            SpacesMobileTerminalPerformanceLogger.emit(
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

        private func renderUpdateDropReason(for payload: GhosttyRemoteSessionStatePayload, decodedFrame: GhosttyRenderFrame?) -> String? {
            guard payload.renderUpdate != nil else { return nil }
            guard let decodedFrame else { return "decode_failed" }
            guard Self.shouldUseRenderFrameSnapshot(decodedFrame.snapshot, runtimeState: payload.runtimeState, reason: payload.reason) else {
                return "stale_resize_grid"
            }
            return nil
        }

        private func payloadByResolvingRenderUpdate(_ payload: GhosttyRemoteSessionStatePayload) -> (
            payload: GhosttyRemoteSessionStatePayload, decodedUpdate: GhosttyRenderUpdate?, dropReason: String?
        ) {
            guard payload.renderUpdate != nil else { return (payload, nil, nil) }
            guard let decodedUpdate = payload.decodedRenderUpdate else {
                return (payload.replacingRenderUpdate(nil), nil, "render_update_decode_failed")
            }
            do {
                let baseline = try GhosttyRenderUpdateApplier.apply(decodedUpdate, to: renderUpdateBaseline)
                renderUpdateBaseline = baseline
                let frame = GhosttyRenderFrame(
                    sessionRevision: baseline.sessionRevision, ownerEpoch: baseline.ownerEpoch, snapshot: baseline.snapshot)
                let materializedUpdate = try? GhosttyRenderUpdateBinaryCodec.encode(.full(frame))
                return (payload.replacingRenderUpdate(materializedUpdate), decodedUpdate, nil)
            } catch {
                renderUpdateBaseline = nil
                return (payload.replacingRenderUpdate(nil), decodedUpdate, Self.renderUpdateDropReason(for: error))
            }
        }

        private static func renderUpdateDropReason(for error: Error) -> String {
            switch error as? GhosttyRenderUpdateApplyError {
            case .missingBaseline: "missing_baseline"
            case .versionMismatch: "version_mismatch"
            case .missingFullFrame: "missing_full_frame"
            case .missingDelta: "missing_delta"
            case .resyncRequired: "resync_required"
            case .baseRevisionMismatch: "base_revision_mismatch"
            case .ownerEpochMismatch: "owner_epoch_mismatch"
            case .dimensionMismatch: "dimension_mismatch"
            case .invalidOperation: "invalid_operation"
            case nil: "render_update_apply_failed"
            }
        }

        private func postLocalNotifications(for payload: GhosttyRemoteSessionStatePayload) {
            let sessionID = payload.sessionID
            switch payload.reason {
            case "attachment_state":
                NotificationCenter.default.post(name: .spacesTerminalAttachmentStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
                NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
            case "session_metadata":
                NotificationCenter.default.post(name: .spacesTerminalSessionMetadataDidChange, object: nil, userInfo: ["sessionID": sessionID])
                NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
            case "output":
                NotificationCenter.default.post(
                    name: .spacesTerminalOutputDidChange, object: nil, userInfo: ["sessionID": sessionID, "byteCount": payload.outputByteCount ?? 0])
            case "initial", "runtime_state", "terminated":
                NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
            default: NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
            }
        }

        private func currentSnapshot() -> GhosttyTerminalSnapshot? { latestSnapshotIfCompatible() }

        private func currentSnapshotForRenderUpdate() -> GhosttyTerminalSnapshot? {
            if let snapshot = latestSnapshotIfCompatible() { return snapshot }
            guard !terminalView.hasRenderedSurfaceContent else { return nil }
            return nil
        }

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
            inputQueue.enqueue(priority: .userInitiated) {
                _ = try Self.sendControlRequest(
                    TerminalControlRequest(command: "send", text: text, clientID: clientID, ownerEpoch: ownerEpoch), sessionID: sessionID,
                    socketPath: socketPath, requestSender: requestSender)
                if requestSender != nil { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "input") } }
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
            inputQueue.enqueue(priority: .userInitiated) {
                _ = try Self.sendControlRequest(
                    TerminalControlRequest(command: "key", key: key, clientID: clientID, ownerEpoch: ownerEpoch), sessionID: sessionID,
                    socketPath: socketPath, requestSender: requestSender)
                if requestSender != nil { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "input") } }
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
            inputQueue.enqueue(priority: .userInitiated) {
                _ = try Self.sendControlRequest(
                    TerminalControlRequest(command: "clearScreen", clientID: clientID, ownerEpoch: ownerEpoch), sessionID: sessionID,
                    socketPath: socketPath, requestSender: requestSender)
                if requestSender != nil { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "clear_screen") } }
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
            inputQueue.enqueue(priority: .userInitiated) {
                defer { Task { @MainActor in onFinished() } }
                _ = try Self.sendControlRequest(
                    TerminalControlRequest(
                        command: "scroll", clientID: clientID, ownerEpoch: ownerEpoch, scrollHorizontal: batch.horizontal,
                        scrollVertical: batch.vertical, scrollMods: batch.scrollMods == 0 ? nil : batch.scrollMods), sessionID: sessionID,
                    socketPath: socketPath, requestSender: requestSender)
                if requestSender != nil { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "scroll") } }
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
                        command: "resize", clientID: clientID, columns: columns, rows: rows, ownerEpoch: ownerEpoch, resizeSerial: currentResizeSerial
                    ), sessionID: sessionID, socketPath: socketPath, requestSender: requestSender)
                if requestSender != nil { Task { @MainActor [weak self] in self?.requestDirectStateRefresh(reason: "resize") } }
                await finishResizeRequest(response?.ok == true)
            }
        }

        private nonisolated static func sendControlRequest(
            _ request: TerminalControlRequest, sessionID: String, socketPath: String, requestSender: RemoteGhosttyTerminalServiceRequestSender?
        ) throws -> TerminalControlResponse {
            guard let requestSender else { return try TerminalControlClient.send(request: request, socketPath: socketPath) }
            let response = try requestSender(TerminalServiceRequest(command: "control", sessionID: sessionID, controlRequest: request))
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
