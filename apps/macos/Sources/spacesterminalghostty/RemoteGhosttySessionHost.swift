import AppKit
import Foundation
import spacesterminalcore

@MainActor public final class RemoteGhosttySessionHost: TerminalGhosttySessionHosting {
    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let paths: TerminalSessionPaths
    private let snapshotStream: GhosttyVTSnapshotStream
    private let terminalView: GhosttyRemoteReplayTerminalView
    private var latestState: GhosttyRemoteSessionStatePayload?
    private var stateStreamClient: GhosttyRemoteSessionStateStreamClient?
    private var lastSubscriptionAttemptAt: Date?
    private var attachedClient: TerminalClient?
    private var attachedMode: TerminalAttachmentMode = .viewer
    private var lastRequestedViewportSize: (columns: Int, rows: Int)?
    private var pendingViewportResizeSize: (columns: Int, rows: Int)?
    private var pendingViewportResizeTask: Task<Void, Never>?
    private let inputQueue = TerminalInputSerialQueue()
    private var cachedReplayHistorySeed: (byteCount: Int, data: Data)?

    public init(launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        snapshotStream = GhosttyVTSnapshotStream(sessionID: launchConfiguration.sessionID, outputPath: paths.outputPath)
        terminalView = GhosttyRemoteReplayTerminalView(launchConfiguration: launchConfiguration)
        ensureStateStreamStartedIfNeeded()
    }

    deinit {
        stateStreamClient?.stop()
        pendingViewportResizeTask?.cancel()
        inputQueue.cancelAll()
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
        terminalView.update(
            snapshot: currentSnapshotForReplayUpdate(), replayStateKey: currentReplayStateKey(), historySeed: currentReplayHistorySeed(),
            outputData: nil, outputEventToken: nil)
        if mode == .owner { sendCurrentViewportResizeIfNeeded(force: true) }
    }

    public func parkSurfaceInHiddenHostWindow() { terminalView.parkInHiddenHostWindowIfNeeded() }

    public func setFocused(_ focused: Bool, for clientID: String) {
        guard clientID == attachedClient?.id else {
            if !focused, terminalView.window?.firstResponder === terminalView { terminalView.window?.makeFirstResponder(nil) }
            return
        }
        if focused { terminalView.focusWindow(terminalView.window) }
    }

    public func focusWindow(_ window: NSWindow?) { terminalView.focusWindow(window) }

    public func activeOwnerClientID() -> String? {
        ensureStateStreamStartedIfNeeded()
        if let attachmentSnapshot = latestState?.attachmentSnapshot {
            return attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        }
        return ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
    }

    public func hasRenderableSurface() -> Bool { terminalView.surface != nil }

    public var prefersOutputFallbackWhenSurfaceUnavailable: Bool { false }

    public func snapshot() -> GhosttyTerminalSnapshot? {
        ensureStateStreamStartedIfNeeded()
        if let snapshot = currentSnapshot() { return snapshot }
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return snapshotStream.snapshot(columns: runtimeState?.columns, rows: runtimeState?.rows)
    }

    public func snapshotText() -> String? {
        ensureStateStreamStartedIfNeeded()
        if let outputLogSnapshotText = currentOutputLogSnapshotText() { return outputLogSnapshotText }
        if let transcriptTail = currentTranscriptTail(), !transcriptTail.isEmpty { return transcriptTail }
        if let snapshotText = latestSnapshotTextIfCompatible() { return snapshotText }
        if let snapshotText = terminalView.snapshotText(), !snapshotText.isEmpty { return snapshotText }
        if let snapshot = currentSnapshot() { return GhosttyTerminalSnapshotRenderer.render(snapshot).string }
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return snapshotStream.snapshotText(columns: runtimeState?.columns, rows: runtimeState?.rows)
    }

    public func sessionSnapshot() -> GhosttyTerminalSnapshot? { snapshot() }

    public func sessionSnapshotText() -> String? { snapshotText() }

    public func copySelectionToPasteboard() -> Bool { terminalView.copySelectionToPasteboard() }

    public func pasteClipboardContents() -> Bool { terminalView.pasteClipboardContents() }

    @discardableResult public func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        terminalView.sendScroll(horizontal: horizontal, vertical: vertical)
    }

    public var debugSurfaceRefreshRequestCount: Int { 0 }
    public func debugVisibleSurfaceText() -> String? {
        if let replayedText = terminalView.replayedText(), !replayedText.isEmpty { return replayedText }
        if terminalView.hasReplaySurfaceContent, let snapshotText = terminalView.snapshotText(), !snapshotText.isEmpty { return snapshotText }
        if let snapshot = currentSnapshot() { return GhosttyTerminalSnapshotLayout.plainText(for: snapshot) }
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

    private func applyRemoteState(_ payload: GhosttyRemoteSessionStatePayload) {
        latestState = latestState?.merged(with: payload) ?? payload
        lastSubscriptionAttemptAt = nil
        terminalView.update(
            snapshot: currentSnapshotForReplayUpdate(), replayStateKey: currentReplayStateKey(), historySeed: currentReplayHistorySeed(),
            outputData: payload.outputData, outputEventToken: payload.outputData == nil ? nil : payload.emittedAt)
        if attachedMode == .owner { sendCurrentViewportResizeIfNeeded(force: false) }
        let emittedAt = GhosttyRemoteSessionStateTimestamp.date(from: payload.emittedAt) ?? Date()
        TerminalPerformance.logMetric(
            "terminal_remote_state_receive", target: "session=\(payload.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt),
            success: true,
            detail:
                "reason=\(payload.reason) snapshot=\(payload.snapshot == nil ? 0 : 1) snapshot_text=\(payload.snapshotText == nil ? 0 : 1) bytes=\(payload.outputByteCount ?? 0) streamed=\(payload.outputData?.count ?? 0)"
        )
        postLocalNotifications(for: payload)
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

    private func currentSnapshot() -> GhosttyTerminalSnapshot? {
        if let snapshot = latestState?.snapshot,
            Self.shouldUseLiveSnapshot(snapshot, runtimeState: latestState?.runtimeState, reason: latestState?.reason)
        {
            return snapshot
        }
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return snapshotStream.snapshot(columns: runtimeState?.columns, rows: runtimeState?.rows)
    }

    private func currentSnapshotForReplayUpdate() -> GhosttyTerminalSnapshot? {
        if let snapshot = latestState?.snapshot,
            Self.shouldUseLiveSnapshot(snapshot, runtimeState: latestState?.runtimeState, reason: latestState?.reason)
        {
            return snapshot
        }
        guard !terminalView.hasReplaySurfaceContent else { return nil }
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return snapshotStream.snapshot(columns: runtimeState?.columns, rows: runtimeState?.rows)
    }

    private func currentReplayHistorySeed() -> (id: String, data: Data)? {
        guard let history = TerminalReplayOutputHistory.load(path: paths.outputPath) else { return nil }
        guard let data = history.data, !data.isEmpty else { return nil }
        if cachedReplayHistorySeed?.byteCount != history.totalByteCount || cachedReplayHistorySeed?.data.count != data.count {
            cachedReplayHistorySeed = (history.totalByteCount, data)
        }
        guard let cachedReplayHistorySeed else { return nil }
        return ("history|\(cachedReplayHistorySeed.byteCount)", cachedReplayHistorySeed.data)
    }

    private func currentTranscriptTail() -> String? {
        if terminalView.hasReplaySurfaceContent, let snapshotText = terminalView.snapshotText(), !snapshotText.isEmpty { return snapshotText }
        if let transcriptTail = latestState?.transcriptTail, !transcriptTail.isEmpty { return transcriptTail }
        if let snapshotText = latestSnapshotTextIfCompatible(), !snapshotText.isEmpty { return snapshotText }
        return nil
    }

    private func latestSnapshotTextIfCompatible() -> String? {
        guard let snapshotText = latestState?.snapshotText, !snapshotText.isEmpty else { return nil }
        if let snapshot = latestState?.snapshot,
            !Self.shouldUseLiveSnapshot(snapshot, runtimeState: latestState?.runtimeState, reason: latestState?.reason)
        {
            return nil
        }
        return snapshotText
    }

    private func currentOutputLogSnapshotText() -> String? {
        let runtimeState = latestState?.runtimeState ?? (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
        guard let snapshotText = snapshotStream.snapshotText(columns: runtimeState?.columns, rows: runtimeState?.rows) else { return nil }
        guard TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: nil, snapshotText: snapshotText) else { return nil }
        return snapshotText
    }

    private func currentReplayStateKey() -> String {
        let snapshot = currentSnapshot()
        let snapshotColumns = snapshot?.columns ?? 0
        let snapshotRows = snapshot?.rows ?? 0
        let runtimeColumns = latestState?.runtimeState?.columns ?? 0
        let runtimeRows = latestState?.runtimeState?.rows ?? 0
        return "runtime=\(runtimeColumns)x\(runtimeRows)|snapshot=\(snapshotColumns)x\(snapshotRows)"
    }

    private func sendRemoteInput(_ text: String) {
        guard let client = attachedClient else { return }
        let socketPath = paths.controlSocketPath
        let clientID = client.id
        inputQueue.enqueue(priority: .userInitiated) {
            _ = try TerminalControlClient.send(
                request: TerminalControlRequest(command: "send", text: text, clientID: clientID), socketPath: socketPath)
        }
    }

    private func sendRemoteKey(_ key: String) {
        guard let client = attachedClient else { return }
        let socketPath = paths.controlSocketPath
        let clientID = client.id
        inputQueue.enqueue(priority: .userInitiated) {
            _ = try TerminalControlClient.send(request: TerminalControlRequest(command: "key", key: key, clientID: clientID), socketPath: socketPath)
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
                request: TerminalControlRequest(command: "resize", clientID: clientID, columns: columns, rows: rows), socketPath: socketPath)
            await finishResizeRequest(response?.ok == true)
        }
    }

    nonisolated static func snapshot(_ snapshot: GhosttyTerminalSnapshot, matches runtimeState: TerminalSessionRuntimeState?) -> Bool {
        guard let runtimeState else { return true }
        guard let columns = runtimeState.columns, let rows = runtimeState.rows, columns > 0, rows > 0 else { return true }
        return snapshot.columns == columns && snapshot.rows == rows
    }

    nonisolated static func shouldUseLiveSnapshot(_ snapshot: GhosttyTerminalSnapshot, runtimeState: TerminalSessionRuntimeState?, reason: String?)
        -> Bool
    {
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
