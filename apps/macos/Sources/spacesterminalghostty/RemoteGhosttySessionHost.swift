import AppKit
import Foundation
import spacesterminalcore

@MainActor public final class RemoteGhosttySessionHost: TerminalGhosttySessionHosting {
    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let paths: TerminalSessionPaths
    private let snapshotStream: GhosttyVTSnapshotStream
    private var latestState: GhosttyRemoteSessionStatePayload?
    private var stateStreamClient: GhosttyRemoteSessionStateStreamClient?
    private var lastSubscriptionAttemptAt: Date?

    public init(launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        snapshotStream = GhosttyVTSnapshotStream(sessionID: launchConfiguration.sessionID, outputPath: paths.outputPath)
        ensureStateStreamStartedIfNeeded()
    }

    deinit { stateStreamClient?.stop() }

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {}

    public func parkSurfaceInHiddenHostWindow() {}

    public func setFocused(_ focused: Bool, for clientID: String) {}

    public func focusWindow(_ window: NSWindow?) {}

    public func activeOwnerClientID() -> String? {
        ensureStateStreamStartedIfNeeded()
        if let attachmentSnapshot = latestState?.attachmentSnapshot {
            return attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        }
        return ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
    }

    public func hasRenderableSurface() -> Bool { false }

    public var prefersOutputFallbackWhenSurfaceUnavailable: Bool { false }

    public func snapshot() -> GhosttyTerminalSnapshot? {
        ensureStateStreamStartedIfNeeded()
        if let snapshot = latestState?.snapshot { return snapshot }
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return snapshotStream.snapshot(columns: runtimeState?.columns, rows: runtimeState?.rows)
    }

    public func snapshotText() -> String? {
        ensureStateStreamStartedIfNeeded()
        if let snapshotText = latestState?.snapshotText { return snapshotText }
        if let snapshot = latestState?.snapshot { return GhosttyTerminalSnapshotRenderer.render(snapshot).string }
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return snapshotStream.snapshotText(columns: runtimeState?.columns, rows: runtimeState?.rows)
    }

    public func copySelectionToPasteboard() -> Bool { false }

    public func pasteClipboardContents() -> Bool { false }

    @discardableResult public func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool { false }

    public var debugSurfaceRefreshRequestCount: Int { 0 }

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
        latestState = payload
        lastSubscriptionAttemptAt = nil
        let emittedAt = GhosttyRemoteSessionStateTimestamp.date(from: payload.emittedAt) ?? Date()
        TerminalPerformance.logMetric(
            "terminal_remote_state_receive", target: "session=\(payload.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt),
            success: true,
            detail:
                "reason=\(payload.reason) snapshot=\(payload.snapshot == nil ? 0 : 1) snapshot_text=\(payload.snapshotText == nil ? 0 : 1) bytes=\(payload.outputByteCount ?? 0)"
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
}
