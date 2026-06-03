import AppKit
import Foundation
import spacesterminalcore

@MainActor public final class RemoteGhosttySessionHost: TerminalGhosttySessionHosting {
    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let paths: TerminalSessionPaths
    private let terminalView: GhosttyMirrorTerminalView
    private var latestState: GhosttyRemoteSessionStatePayload?
    private var renderUpdateBaseline: GhosttyRenderUpdateBaseline?
    private var stateStreamClient: GhosttyRemoteSessionStateStreamClient?
    private var lastSubscriptionAttemptAt: Date?
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

    public init(launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        terminalView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        ensureStateStreamStartedIfNeeded()
    }

    deinit {
        MainActor.assumeIsolated {
            stateStreamClient?.stop()
            pendingViewportResizeTask?.cancel()
            scrollCoalescer.cancel()
            inputQueue.cancelAll()
        }
    }

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
        attachedClient = client
        attachedMode = mode
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
        terminalView.acceptsTerminalInput = mode == .owner
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
        if mode == .owner { sendCurrentViewportResizeIfNeeded(force: true) }
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
        guard clientID == attachedClient?.id, attachedMode == .owner else { return false }
        return terminalView.handleTerminalKeyEvent(event, requireFirstResponder: false)
    }

    @discardableResult public func synchronizeSurfaceGeometry() -> Bool {
        guard attachedMode == .owner else { return false }
        sendCurrentViewportResizeIfNeeded(force: true)
        return true
    }

    public func activeOwnerClientID() -> String? {
        ensureStateStreamStartedIfNeeded()
        if let attachmentSnapshot = latestState?.attachmentSnapshot {
            return attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        }
        return ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
    }

    public func hasRenderableSurface() -> Bool { terminalView.hasRenderedContent }

    public func requestSurfaceRefresh() { terminalView.update(frame: currentRenderFrameForRenderUpdate(), renderStateKey: currentRenderStateKey()) }

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

    @discardableResult public func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32) -> Bool {
        terminalView.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods)
    }

    @discardableResult public func clearScreenAndScrollback() -> Bool {
        guard attachedClient != nil, attachedMode == .owner else { return false }
        sendRemoteClearScreenAndScrollback()
        return true
    }

    public var debugSurfaceRefreshRequestCount: Int { 0 }
    public func debugVisibleSurfaceText() -> String? {
        if let renderedSnapshotText = terminalView.renderedSnapshotText(), !renderedSnapshotText.isEmpty { return renderedSnapshotText }
        if let snapshot = currentSnapshot() { return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot) }
        return terminalView.snapshotText()
    }

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

    private func handleStreamDisconnect() {
        stateStreamClient = nil
        lastSubscriptionAttemptAt = Date()
    }

    private func applyRemoteState(_ incomingPayload: GhosttyRemoteSessionStatePayload) {
        let decodeStartedAt = Date()
        let resolvedRenderState = payloadByResolvingRenderUpdate(incomingPayload)
        let payload = resolvedRenderState.payload
        let decodedFrame = payload.decodedRenderFrame
        let decodedUpdate = resolvedRenderState.decodedUpdate
        let decodeMS = TerminalPerformance.elapsedMS(since: decodeStartedAt)
        let dropReason = renderFrameDropReason(for: payload, decodedFrame: decodedFrame)
        latestState = latestState?.merged(with: payload) ?? payload
        lastSubscriptionAttemptAt = nil
        let frameForUpdate = currentRenderFrameForRenderUpdate()
        let applyStartedAt = Date()
        if frameForUpdate != nil || !terminalView.hasRenderedSurfaceContent {
            terminalView.update(frame: frameForUpdate, renderStateKey: currentRenderStateKey())
        }
        let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
        if attachedMode == .owner { sendCurrentViewportResizeIfNeeded(force: false) }
        let emittedAt = GhosttyRemoteSessionStateTimestamp.date(from: payload.emittedAt) ?? Date()
        let payloadBytes = (try? GhosttyRemoteSessionStateCodec.encodeLine(payload).count) ?? 0
        var renderFrameAttributes = GhosttyRenderFrameMetrics.attributes(
            reason: payload.reason, frame: decodedFrame, frameByteCount: payload.renderFrame?.count, payloadByteCount: payloadBytes,
            decodeMS: decodeMS, outputByteCount: payload.outputByteCount, screenStateRevision: payload.screenStateRevision,
            dropped: payload.renderFrame == nil ? nil : dropReason != nil, dropReason: resolvedRenderState.dropReason ?? dropReason,
            renderMode: "ghostty-mirror", frameKind: decodedUpdate?.frameKindMetricValue ?? "full", baseRevision: decodedUpdate?.baseRevision,
            targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
            appliedRevision: frameForUpdate == nil ? nil : (payload.screenStateRevision ?? frameForUpdate?.sessionRevision), applyMS: applyMS,
            operationCount: decodedUpdate?.operationCount, changedCellCount: decodedUpdate?.changedCellCount,
            scrollOperationCount: decodedUpdate?.scrollOperationCount, fullFrameFallbackReason: decodedUpdate?.fallbackReason)
        renderFrameAttributes["render_update"] = payload.renderUpdate == nil ? "0" : "1"
        renderFrameAttributes["render_update_bytes"] = String(payload.renderUpdate?.count ?? 0)
        SpacesMobileTerminalPerformanceLogger.emit(
            .init(
                sessionID: payload.sessionID, source: "mac-mirror", name: "render_frame_payload_receive",
                elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt), count: payload.renderFrame?.count, attributes: renderFrameAttributes))
        TerminalPerformance.logMetric(
            "terminal_remote_state_receive", target: "session=\(payload.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt),
            success: true,
            detail:
                "reason=\(payload.reason) render_frame=\(payload.renderFrame == nil ? 0 : 1) bytes=\(payload.outputByteCount ?? 0) payload_bytes=\(payloadBytes) frame_bytes=\(payload.renderFrame?.count ?? 0)"
        )
        TerminalPerformance.logMetric(
            "terminal_render_frame_payload_receive", target: "session=\(payload.sessionID)",
            elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt), success: dropReason == nil,
            detail: GhosttyRenderFrameMetrics.detailString(renderFrameAttributes))
        postLocalNotifications(for: payload)
    }

    private func renderFrameDropReason(for payload: GhosttyRemoteSessionStatePayload, decodedFrame: GhosttyRenderFrame?) -> String? {
        guard payload.renderFrame != nil else { return nil }
        guard let decodedFrame else { return "decode_failed" }
        guard Self.shouldUseRenderFrameSnapshot(decodedFrame.snapshot, runtimeState: payload.runtimeState, reason: payload.reason) else {
            return "stale_resize_grid"
        }
        return nil
    }

    private func payloadByResolvingRenderUpdate(_ payload: GhosttyRemoteSessionStatePayload) -> (
        payload: GhosttyRemoteSessionStatePayload, decodedUpdate: GhosttyRenderUpdate?, dropReason: String?
    ) {
        guard payload.renderUpdate != nil else {
            if let decodedFrame = payload.decodedRenderFrame { renderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: decodedFrame) }
            return (payload, nil, nil)
        }
        guard let decodedUpdate = payload.decodedRenderUpdate else { return (payload, nil, "render_update_decode_failed") }
        do {
            let baseline = try GhosttyRenderUpdateApplier.apply(decodedUpdate, to: renderUpdateBaseline)
            renderUpdateBaseline = baseline
            let frame = GhosttyRenderFrame(sessionRevision: baseline.sessionRevision, ownerEpoch: baseline.ownerEpoch, snapshot: baseline.snapshot)
            let renderFrame = try? GhosttyRenderFrame.encode(frame)
            return (
                payload.replacingRenderState(
                    renderFrame: renderFrame, renderUpdate: payload.renderUpdate, renderUpdateEncoding: payload.renderUpdateEncoding), decodedUpdate,
                nil
            )
        } catch {
            renderUpdateBaseline = nil
            if let decodedFrame = payload.decodedRenderFrame { renderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: decodedFrame) }
            return (payload, decodedUpdate, Self.renderUpdateDropReason(for: error))
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
        guard let frame = latestState?.decodedRenderFrame,
            Self.shouldUseRenderFrameSnapshot(frame.snapshot, runtimeState: latestState?.runtimeState, reason: latestState?.reason)
        else {
            guard !terminalView.hasRenderedSurfaceContent else { return nil }
            return nil
        }
        return frame
    }

    private func latestSnapshotIfCompatible() -> GhosttyTerminalSnapshot? {
        guard let snapshot = latestState?.renderFrameSnapshot,
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
        let ownerEpoch = latestState?.renderFrameOwnerEpoch ?? 0
        return "runtime=\(runtimeColumns)x\(runtimeRows)|frame=\(snapshotColumns)x\(snapshotRows)|ownerEpoch=\(ownerEpoch)"
    }

    private func sendRemoteInput(_ text: String) {
        guard let client = attachedClient else { return }
        scrollCoalescer.flush()
        let socketPath = paths.controlSocketPath
        let clientID = client.id
        let ownerEpoch = latestState?.renderFrameOwnerEpoch
        inputQueue.enqueue(priority: .userInitiated) {
            _ = try TerminalControlClient.send(
                request: TerminalControlRequest(command: "send", text: text, clientID: clientID, ownerEpoch: ownerEpoch), socketPath: socketPath)
        }
    }

    private func sendRemoteKey(_ key: String) {
        if TerminalKeyInput.hostAction(for: key) == .clearScreenAndScrollback {
            sendRemoteClearScreenAndScrollback()
            return
        }
        guard let client = attachedClient else { return }
        scrollCoalescer.flush()
        let socketPath = paths.controlSocketPath
        let clientID = client.id
        let ownerEpoch = latestState?.renderFrameOwnerEpoch
        inputQueue.enqueue(priority: .userInitiated) {
            _ = try TerminalControlClient.send(
                request: TerminalControlRequest(command: "key", key: key, clientID: clientID, ownerEpoch: ownerEpoch), socketPath: socketPath)
        }
    }

    private func sendRemoteClearScreenAndScrollback() {
        guard let client = attachedClient else { return }
        scrollCoalescer.flush()
        let socketPath = paths.controlSocketPath
        let clientID = client.id
        let ownerEpoch = latestState?.renderFrameOwnerEpoch
        inputQueue.enqueue(priority: .userInitiated) {
            _ = try TerminalControlClient.send(
                request: TerminalControlRequest(command: "clearScreen", clientID: clientID, ownerEpoch: ownerEpoch), socketPath: socketPath)
        }
    }

    private func sendRemoteScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32) {
        guard attachedClient != nil, attachedMode == .owner else { return }
        scrollCoalescer.append(horizontal: Double(horizontal), vertical: Double(vertical), scrollMods: scrollMods)
    }

    private func enqueueRemoteScrollBatch(_ batch: TerminalScrollCoalescer.Batch, onFinished: @escaping TerminalScrollCoalescer.FinishHandler) {
        guard let client = attachedClient, attachedMode == .owner else {
            onFinished()
            return
        }
        let socketPath = paths.controlSocketPath
        let clientID = client.id
        let ownerEpoch = latestState?.renderFrameOwnerEpoch
        inputQueue.enqueue(priority: .userInitiated) {
            defer { Task { @MainActor in onFinished() } }
            _ = try TerminalControlClient.send(
                request: TerminalControlRequest(
                    command: "scroll", clientID: clientID, ownerEpoch: ownerEpoch, scrollHorizontal: batch.horizontal, scrollVertical: batch.vertical,
                    scrollMods: batch.scrollMods == 0 ? nil : batch.scrollMods), socketPath: socketPath)
        }
    }

    private func sendCurrentViewportResizeIfNeeded(force: Bool) {
        guard attachedMode == .owner, let size = terminalView.surfaceCellSize() else { return }
        handleViewportSizeChange(columns: size.columns, rows: size.rows, force: force)
    }

    private func handleViewportSizeChange(columns: Int, rows: Int, force: Bool = false) {
        guard attachedMode == .owner, let client = attachedClient else { return }
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
        resizeSerial &+= 1
        let currentResizeSerial = resizeSerial
        let ownerEpoch = latestState?.renderFrameOwnerEpoch
        let finishResizeRequest: @MainActor @Sendable (Bool) -> Void = { [weak self, requestedSize] success in
            guard let self else { return }
            if let pendingViewportResizeSize = self.pendingViewportResizeSize, pendingViewportResizeSize == requestedSize {
                self.pendingViewportResizeSize = nil
            }
            if success { self.lastRequestedViewportSize = requestedSize }
            self.pendingViewportResizeTask = nil
        }
        pendingViewportResizeTask = Task.detached(priority: .utility) {
            let response = try? TerminalControlClient.send(
                request: TerminalControlRequest(
                    command: "resize", clientID: clientID, columns: columns, rows: rows, ownerEpoch: ownerEpoch, resizeSerial: currentResizeSerial),
                socketPath: socketPath)
            await finishResizeRequest(response?.ok == true)
        }
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
