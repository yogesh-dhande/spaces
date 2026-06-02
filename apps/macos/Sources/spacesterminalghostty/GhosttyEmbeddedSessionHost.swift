import AppKit
import Darwin
import Foundation
import spacesterminalcore

private let ghosttyEmbeddedSessionTraceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_TERMINAL_TRACE"] == "1"

private func ghosttyEmbeddedSessionTrace(_ sessionID: String, _ message: @autoclosure () -> String) {
    guard ghosttyEmbeddedSessionTraceEnabled else { return }
    fputs("spaces-mobile-terminal-trace t=\(ghosttyEmbeddedSessionTraceSeconds()) mac-host session=\(sessionID) \(message())\n", stderr)
    fflush(stderr)
}

private func ghosttyEmbeddedSessionTraceSeconds() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

extension Notification.Name {
    public static let spacesTerminalAttachmentStateDidChange = Notification.Name("spaces.terminal.attachment-state-did-change")
    public static let spacesTerminalSessionMetadataDidChange = Notification.Name("spaces.terminal.session-metadata-did-change")
    public static let spacesTerminalRuntimeStateDidChange = Notification.Name("spaces.terminal.runtime-state-did-change")
    public static let spacesTerminalOutputDidChange = Notification.Name("spaces.terminal.output-did-change")
}

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
    @discardableResult func synchronizeSurfaceGeometry() -> Bool
    func hasRenderableSurface() -> Bool
    func requestSurfaceRefresh()
    func prepareRenderStateExport()
    func snapshot() -> GhosttyTerminalSnapshot?
    func snapshotText() -> String?
    func sessionSnapshot() -> GhosttyTerminalSnapshot?
    func sessionSnapshotText() -> String?
    func copySelectionToPasteboard() -> Bool
    func pasteClipboardContents() -> Bool
    @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool
    var debugSurfaceRefreshRequestCount: Int { get }
    func debugVisibleSurfaceText() -> String?
}

@MainActor public protocol TerminalGhosttySessionHosting: TerminalGhosttySessionInfoProviding, TerminalGhosttyRendererHosting {}

@MainActor public final class GhosttyHeadlessRendererHost: TerminalGhosttyRendererHosting {
    private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
    private var isOwnerClient: (@MainActor (String) -> Bool)?
    private var inputActivityHandler: (@MainActor () -> Void)?

    init(sessionDriver: GhosttyEmbeddedTerminalSessionDriver) { self.sessionDriver = sessionDriver }

    func setOwnerClientResolver(_ resolver: @escaping @MainActor (String) -> Bool) { isOwnerClient = resolver }

    func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { sessionDriver.setOutputHandler(handler) }

    func setInputActivityHandler(_ handler: (@MainActor () -> Void)?) { inputActivityHandler = handler }

    func startSessionIfNeeded() throws { try sessionDriver.startIfNeeded() }

    public func requestSurfaceRefresh() { sessionDriver.requestSurfaceRefresh() }

    public func prepareRenderStateExport() {
        sessionDriver.requestSurfaceRefresh()
        GhosttyEmbeddedAppService.shared.tick()
    }

    func sendRawBytes(_ data: Data) {
        sessionDriver.sendRawBytes(data)
        inputActivityHandler?()
    }

    func foregroundPID() -> Int32? { sessionDriver.foregroundPID() }

    func surfaceCellSize() -> (columns: Int, rows: Int)? { sessionDriver.surfaceCellSize() }

    @discardableResult func resizeCellGrid(columns: Int, rows: Int) -> Bool { sessionDriver.resizeCellGrid(columns: columns, rows: rows) }

    func terminateSession() { sessionDriver.terminate() }

    func setSurfaceFocused(_ focused: Bool) { sessionDriver.setFocused(focused) }

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
        _ = client
        _ = mode
        _ = container
        try startSessionIfNeeded()
    }

    public func releaseRendererSurface() {}

    public func setFocused(_ focused: Bool, for clientID: String) { sessionDriver.setFocused(isOwnerClient?(clientID) == true && focused) }

    public func focusWindow(_ window: NSWindow?) {
        guard let window else { return }
        if !window.isVisible { window.orderFront(nil) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
    }

    @discardableResult public func synchronizeSurfaceGeometry() -> Bool { false }

    public func hasRenderableSurface() -> Bool { sessionDriver.snapshot() != nil }

    public func snapshot() -> GhosttyTerminalSnapshot? { sessionDriver.snapshot() }

    public func snapshotText() -> String? { sessionDriver.snapshotText() }

    public func sessionSnapshot() -> GhosttyTerminalSnapshot? { sessionDriver.snapshot() }

    public func sessionSnapshotText() -> String? { sessionDriver.snapshotText() }

    public func copySelectionToPasteboard() -> Bool { false }

    public func pasteClipboardContents() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        sendRawBytes(Data(text.utf8))
        return true
    }

    @discardableResult public func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        sessionDriver.sendScroll(horizontal: horizontal, vertical: vertical)
    }

    public var debugSurfaceRefreshRequestCount: Int { sessionDriver.debugRefreshRequestCount }

    public func debugVisibleSurfaceText() -> String? { sessionDriver.snapshotText() }
}

@MainActor public final class GhosttyEmbeddedSessionCore {
    private static let incomingOutputCoalescingInterval: Duration = .milliseconds(4)

    private final class IncomingOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingData = Data()
        private var flushScheduled = false

        func append(_ data: Data) -> Bool {
            guard !data.isEmpty else { return false }
            lock.lock()
            defer { lock.unlock() }
            pendingData.append(data)
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
        }

        func drain() -> Data {
            lock.lock()
            defer { lock.unlock() }
            let drained = pendingData
            pendingData = Data()
            flushScheduled = false
            return drained
        }
    }

    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let paths: TerminalSessionPaths

    private let controlQueue: DispatchQueue
    private let stateStreamQueue: DispatchQueue
    private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
    private lazy var rendererHostStorage = GhosttyHeadlessRendererHost(sessionDriver: sessionDriver)
    private let requestSurfaceRefreshAction: @MainActor () -> Void
    private var runtimeStateTimer: Timer?
    private var controlServer: TerminalControlServer?
    private var stateStreamServer: GhosttyRemoteSessionStateStreamServer?
    private var outputHandle: FileHandle?
    private var started = false
    private var currentTitle: String?
    private var currentWorkingDirectory: String?
    private var lastKnownChildPID: Int32?
    private var lastKnownSurfaceSize: (columns: Int, rows: Int)?
    private var lastSessionStateRevision: UInt64?
    private var lastSessionStateFlags: GhosttyEmbeddedSessionStateChange.Flags?
    private var lastScreenStateRevision: UInt64?
    private var lastPersistedRuntimeState: TerminalSessionRuntimeState?
    private var lastRuntimeStateWriteAt: Date?
    private var sessionStartedAt: Date?
    private var didLogFirstOutput = false
    private let incomingOutputBuffer = IncomingOutputBuffer()
    private var inputStateBroadcastScheduled = false
    private var pendingInputOutputResync = false
    private var inputOutputResyncWorkItem: DispatchWorkItem?
    private var ownerEpoch: UInt64 = 0
    private var lastResizeSerialByClientID: [String: UInt64] = [:]
    private let onSessionClosed: (@MainActor (GhosttyEmbeddedSessionCore) -> Void)?

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        requestSurfaceRefreshAction: (@MainActor () -> Void)? = nil, onSessionClosed: (@MainActor (GhosttyEmbeddedSessionCore) -> Void)? = nil
    ) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        self.onSessionClosed = onSessionClosed
        controlQueue = DispatchQueue(label: "spaces.terminal.session-host.control.\(launchConfiguration.sessionID)")
        stateStreamQueue = DispatchQueue(label: "spaces.terminal.session-host.state-stream.\(launchConfiguration.sessionID)")
        sessionDriver = GhosttyEmbeddedTerminalSessionDriver(launchConfiguration: launchConfiguration)
        self.requestSurfaceRefreshAction = requestSurfaceRefreshAction ?? { [sessionDriver] in sessionDriver.requestSurfaceRefresh() }
        sessionDriver.onActionEvent = { [weak self] event in self?.applyActionEvent(event) }
        sessionDriver.onSessionStateChanged = { [weak self] change in self?.applySessionStateChange(change) }
        sessionDriver.onSurfaceCellSizeChanged = { [weak self] columns, rows in
            guard let self else { return }
            self.lastKnownSurfaceSize = (columns, rows)
            self.refreshRuntimeState(force: true)
        }
        rendererHostStorage.setOwnerClientResolver { [weak self] clientID in self?.isOwner(clientID: clientID) ?? false }
        rendererHostStorage.setInputActivityHandler { [weak self] in self?.handleOwnerInputActivity() }
        sessionDriver.onSurfaceClosed = { [weak self] in self?.handleSessionClosed() }
    }

    public func startIfNeeded() throws {
        guard !started else { return }
        let startedAt = Date()
        do {
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            try ensureOutputHandle()
            rendererHostStorage.setOutputHandler { [weak self] data in self?.enqueueIncomingOutput(data) }
            rendererHostStorage.setInputActivityHandler { [weak self] in self?.handleOwnerInputActivity() }
            try rendererHostStorage.startSessionIfNeeded()
            try startControlServer()
            try startStateStreamServer()
            startRuntimeStateTimer()
            refreshRuntimeState(force: true)
            started = true
            sessionStartedAt = startedAt
            didLogFirstOutput = false
            broadcastCurrentState(reason: "initial")
            TerminalPerformance.logMetric(
                "terminal_session_start", target: "session=\(launchConfiguration.sessionID) backend=\(launchConfiguration.backend.rawValue)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        } catch {
            TerminalPerformance.logMetric(
                "terminal_session_start", target: "session=\(launchConfiguration.sessionID) backend=\(launchConfiguration.backend.rawValue)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            throw error
        }
    }

    public func attachClient(_ client: TerminalClient, mode: TerminalAttachmentMode) throws {
        try startIfNeeded()
        let activeAttachments = (try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []
        let currentAttachment = activeAttachments.first { $0.clientID == client.id }
        let previousOwnerClientID = activeAttachments.first { $0.mode == .owner }?.clientID
        if currentAttachment?.mode != mode {
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: client, mode: mode, paths: paths,
                attachedAt: ISO8601DateFormatter().string(from: Date()))
            if mode == .owner, previousOwnerClientID != client.id { advanceOwnerEpoch(reason: "attach") }
            postAttachmentStateDidChange()
        }
        refreshRuntimeState(force: true)
    }

    public func detach(clientID: String) throws {
        let detachedClientWasOwner = isOwner(clientID: clientID)
        try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
        var remainingOwnerClientID = activeOwnerClientID()
        if detachedClientWasOwner, remainingOwnerClientID == nil, let localOwnerClientID = activeLocalWindowClientID(excluding: clientID) {
            let transferredAt = ISO8601DateFormatter().string(from: Date())
            try TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: localOwnerClientID, paths: paths, transferredAt: transferredAt)
            remainingOwnerClientID = localOwnerClientID
            advanceOwnerEpoch(reason: "detach_transfer")
        }
        if Self.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: detachedClientWasOwner, remainingOwnerClientID: remainingOwnerClientID) {
            rendererHostStorage.setSurfaceFocused(false)
        }
        if remainingOwnerClientID == nil, rendererHostStorage.hasRenderableSurface() { rendererHostStorage.releaseRendererSurface() }
        postAttachmentStateDidChange()
        refreshRuntimeState(force: true)
    }

    public func takeover(client: TerminalClient) throws { try attachClient(client, mode: .owner) }

    public func isOwner(clientID: String) -> Bool {
        ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).contains { $0.clientID == clientID && $0.mode == .owner }
    }

    public func activeOwnerClientID() -> String? {
        ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
    }

    private func hasActiveAttachments() -> Bool { !((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).isEmpty }

    private func activeLocalWindowClientID(excluding excludedClientID: String) -> String? {
        guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths) else { return nil }
        let clientsByID = Dictionary(uniqueKeysWithValues: snapshot.clients.map { ($0.id, $0) })
        return snapshot.attachments.filter { $0.detachedAt == nil && $0.clientID != excludedClientID }.compactMap { attachment -> TerminalClient? in
            guard let client = clientsByID[attachment.clientID], client.kind == .localWindow, client.disconnectedAt == nil else { return nil }
            return client
        }.first?.id
    }

    public var rendererHost: any TerminalGhosttyRendererHosting { rendererHostStorage }
    public func terminate() {
        let now = ISO8601DateFormatter().string(from: Date())
        let childPID = observedChildPID()
        runtimeStateTimer?.invalidate()
        runtimeStateTimer = nil
        inputOutputResyncWorkItem?.cancel()
        inputOutputResyncWorkItem = nil
        controlServer?.stop()
        controlServer = nil
        try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
        started = false
        rendererHostStorage.terminateSession()
        try? outputHandle?.synchronize()
        try? outputHandle?.close()
        outputHandle = nil
        let exitedState = TerminalSessionRuntimeState(
            sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: childPID, state: .exited,
            updatedAt: now, exitedAt: now, title: effectiveTitle, workingDirectory: effectiveWorkingDirectory, columns: lastKnownSurfaceSize?.columns,
            rows: lastKnownSurfaceSize?.rows)
        try? TerminalSessionPersistence.writeRuntimeState(exitedState, paths: paths)
        lastPersistedRuntimeState = exitedState
        postRuntimeStateDidChange()
        postAttachmentStateDidChange()
        broadcastCurrentState(reason: "terminated")
        stateStreamServer?.stop()
        stateStreamServer = nil
        try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
    }

    private func handleSessionClosed() {
        terminate()
        onSessionClosed?(self)
    }

    public func childPID() -> Int32? { observedChildPID() }
    public var effectiveTitle: String { currentTitle ?? launchConfiguration.title }
    public var effectiveWorkingDirectory: String { currentWorkingDirectory ?? launchConfiguration.workingDirectory }

    private func startControlServer() throws {
        let controlServer = TerminalControlServer(socketPath: paths.controlSocketPath, queue: controlQueue) { [weak self] request in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self else { return TerminalControlResponse(ok: false, message: "Terminal session is shutting down.") }
                    return self.handleControlRequest(request)
                }
            }
        }
        try controlServer.start()
        self.controlServer = controlServer
    }

    private func startStateStreamServer() throws {
        let stateStreamServer = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: stateStreamQueue) {
            [weak self] in
            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.currentRemoteSessionState(reason: "initial", outputByteCount: nil) } }
        }
        try stateStreamServer.start()
        self.stateStreamServer = stateStreamServer
    }

    func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        switch request.command {
        case "attach": controlResponseForAttachRequest(request)
        case "detach": controlResponseForDetachRequest(request)
        case "heartbeat": controlResponseForHeartbeatRequest(request)
        case "send": controlResponseForSendRequest(request)
        case "key": controlResponseForKeyRequest(request)
        case "takeover": controlResponseForTakeoverRequest(request)
        case "resize": controlResponseForResizeRequest(request)
        case "scroll": controlResponseForScrollRequest(request)
        default: TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(request.command)'.")
        }
    }

    private func ownerRequestRejection(for request: TerminalControlRequest, commandName: String, startedAt: Date) -> TerminalControlResponse? {
        guard let clientID = request.clientID else { return nil }
        guard isOwner(clientID: clientID) else {
            TerminalPerformance.logMetric(
                "terminal_control_\(commandName)", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "owner=stale")
            return TerminalControlResponse(ok: false, message: "Only the active owner can \(commandName) the terminal.")
        }
        guard let requestedOwnerEpoch = request.ownerEpoch else { return nil }
        guard requestedOwnerEpoch == ownerEpoch else {
            TerminalPerformance.logMetric(
                "terminal_control_\(commandName)", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false,
                detail: "owner_epoch=\(requestedOwnerEpoch) current_owner_epoch=\(ownerEpoch)")
            return TerminalControlResponse(
                ok: false, message: "Ignoring stale owner epoch \(requestedOwnerEpoch); current owner epoch is \(ownerEpoch).")
        }
        return nil
    }

    private func staleResizeSerialRejection(for request: TerminalControlRequest, startedAt: Date) -> TerminalControlResponse? {
        guard let clientID = request.clientID, let resizeSerial = request.resizeSerial else { return nil }
        guard let lastResizeSerial = lastResizeSerialByClientID[clientID], resizeSerial <= lastResizeSerial else { return nil }
        TerminalPerformance.logMetric(
            "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: false, detail: "resize_serial=\(resizeSerial) last_resize_serial=\(lastResizeSerial)")
        return TerminalControlResponse(
            ok: false, message: "Ignoring stale resize serial \(resizeSerial); latest accepted serial is \(lastResizeSerial).")
    }

    private func recordAcceptedResizeSerial(from request: TerminalControlRequest) {
        guard let clientID = request.clientID, let resizeSerial = request.resizeSerial else { return }
        lastResizeSerialByClientID[clientID] = resizeSerial
    }

    private func advanceOwnerEpoch(reason: String) {
        ownerEpoch &+= 1
        lastResizeSerialByClientID.removeAll(keepingCapacity: true)
        trace("owner_epoch_advanced reason=\(reason) owner_epoch=\(ownerEpoch) owner=\(activeOwnerClientID() ?? "nil")")
    }

    private func controlResponseForAttachRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        guard let client = request.client else {
            TerminalPerformance.logMetric(
                "terminal_control_attach", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            return TerminalControlResponse(ok: false, message: "Missing client payload.")
        }
        let mode = request.attachmentMode ?? .viewer
        let attachedAt = nowISO8601()
        let authoritativeClient = Self.clientForAttachLease(client, attachedAt: attachedAt)
        do {
            let previousOwnerClientID = activeOwnerClientID()
            try TerminalSessionPersistence.upsertClient(authoritativeClient, paths: paths)
            let currentAttachment = try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == authoritativeClient.id }
            if currentAttachment?.mode != mode {
                try TerminalSessionPersistence.attachClient(
                    sessionID: launchConfiguration.sessionID, client: authoritativeClient, mode: mode, paths: paths, attachedAt: attachedAt)
                if mode == .owner, previousOwnerClientID != authoritativeClient.id { advanceOwnerEpoch(reason: "control_attach") }
                postAttachmentStateDidChange()
            }
            refreshRuntimeState(force: true)
            TerminalPerformance.logMetric(
                "terminal_control_attach", target: "session=\(launchConfiguration.sessionID) client=\(authoritativeClient.id)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "mode=\(mode.rawValue)")
            return TerminalControlResponse(ok: true, message: "Attached \(mode.rawValue) client.")
        } catch {
            TerminalPerformance.logMetric(
                "terminal_control_attach", target: "session=\(launchConfiguration.sessionID) client=\(authoritativeClient.id)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "mode=\(mode.rawValue)")
            return TerminalControlResponse(ok: false, message: String(describing: error))
        }
    }

    private func controlResponseForDetachRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        guard let clientID = request.clientID else {
            TerminalPerformance.logMetric(
                "terminal_control_detach", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            return TerminalControlResponse(ok: false, message: "Missing client ID.")
        }
        do {
            let hasActiveAttachment = try TerminalSessionPersistence.activeAttachments(paths: paths).contains { $0.clientID == clientID }
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
            return TerminalControlResponse(ok: false, message: "Missing client ID.")
        }
        do {
            try TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601())
            TerminalPerformance.logMetric(
                "terminal_control_heartbeat", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
            return TerminalControlResponse(ok: true, message: "Refreshed terminal client lease.")
        } catch {
            TerminalPerformance.logMetric(
                "terminal_control_heartbeat", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            return TerminalControlResponse(ok: false, message: String(describing: error))
        }
    }

    private func controlResponseForSendRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        if let clientID = request.clientID { try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601()) }
        if let rejection = ownerRequestRejection(for: request, commandName: "send", startedAt: startedAt) { return rejection }
        guard let text = request.text else { return TerminalControlResponse(ok: false, message: "Missing text payload.") }
        let payload = text + (request.appendNewline ? "\n" : "")
        rendererHostStorage.sendRawBytes(Data(payload.utf8))
        TerminalPerformance.logMetric(
            "terminal_control_send", target: "session=\(launchConfiguration.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: true, detail: "bytes=\(payload.utf8.count)")
        return TerminalControlResponse(ok: true, message: "Sent input.")
    }

    private func controlResponseForKeyRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        if let clientID = request.clientID { try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601()) }
        if let rejection = ownerRequestRejection(for: request, commandName: "key", startedAt: startedAt) { return rejection }
        guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
            TerminalPerformance.logMetric(
                "terminal_control_key", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            return TerminalControlResponse(ok: false, message: "Unsupported terminal key.")
        }
        rendererHostStorage.sendRawBytes(Data(bytes))
        TerminalPerformance.logMetric(
            "terminal_control_key", target: "session=\(launchConfiguration.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: true, detail: "key=\(key)")
        return TerminalControlResponse(ok: true, message: "Sent key.")
    }

    private func controlResponseForScrollRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        if let clientID = request.clientID { try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601()) }
        if let rejection = ownerRequestRejection(for: request, commandName: "scroll", startedAt: startedAt) { return rejection }
        let horizontal = CGFloat(request.scrollHorizontal ?? 0)
        let vertical = CGFloat(request.scrollVertical ?? 0)
        guard horizontal != 0 || vertical != 0 else { return TerminalControlResponse(ok: false, message: "Missing scroll delta.") }
        let scrolled = rendererHostStorage.sendScroll(horizontal: horizontal, vertical: vertical)
        if scrolled { broadcastCurrentState(reason: TerminalRemoteSessionStateReason.scroll) }
        TerminalPerformance.logMetric(
            "terminal_control_scroll", target: "session=\(launchConfiguration.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: scrolled)
        return TerminalControlResponse(ok: scrolled, message: scrolled ? "Scrolled terminal." : "Unable to scroll terminal.")
    }

    private func controlResponseForTakeoverRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        guard let clientID = request.clientID else { return TerminalControlResponse(ok: false, message: "Missing client ID.") }
        do {
            try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601())
            flushPendingIncomingOutputForStateExport()
            let previousOwnerClientID = activeOwnerClientID()
            try TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: clientID, paths: paths,
                transferredAt: ISO8601DateFormatter().string(from: Date()))
            if previousOwnerClientID != clientID { advanceOwnerEpoch(reason: "takeover") }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.postAttachmentStateDidChange()
                self.refreshRuntimeState(force: true)
            }
            TerminalPerformance.logMetric(
                "terminal_control_takeover", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
            return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
        } catch {
            TerminalPerformance.logMetric(
                "terminal_control_takeover", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            return TerminalControlResponse(ok: false, message: String(describing: error))
        }
    }

    private func controlResponseForResizeRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        if let clientID = request.clientID { try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601()) }
        if let rejection = ownerRequestRejection(for: request, commandName: "resize", startedAt: startedAt) { return rejection }
        if let rejection = staleResizeSerialRejection(for: request, startedAt: startedAt) { return rejection }
        guard let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 else {
            return TerminalControlResponse(ok: false, message: "Missing terminal size.")
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
        let resized = rendererHostStorage.resizeCellGrid(columns: columns, rows: rows)
        refreshRuntimeState(force: true)
        trace("resize_request_result resized=\(resized ? 1 : 0) runtime_after=\(traceSize(observedSurfaceSize()))")
        TerminalPerformance.logMetric(
            "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: resized, detail: "columns=\(columns) rows=\(rows)")
        if resized {
            recordAcceptedResizeSerial(from: request)
            broadcastCurrentState(reason: "resize")
        }
        return TerminalControlResponse(ok: resized, message: resized ? "Resized terminal." : "Unable to match the requested terminal size.")
    }

    private func startRuntimeStateTimer() {
        runtimeStateTimer?.invalidate()
        runtimeStateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.expireStaleRemoteClientsIfNeeded()
                self.refreshRuntimeState(force: false)
            }
        }
        if let runtimeStateTimer { RunLoop.main.add(runtimeStateTimer, forMode: .common) }
    }

    private func refreshRuntimeState(force: Bool) {
        let now = Date()
        let foregroundPID = rendererHostStorage.foregroundPID()
        if let foregroundPID {
            lastKnownChildPID = foregroundPID
        } else if started, let lastKnownChildPID, !hasActiveAttachments(), !Self.isProcessAlive(pid: lastKnownChildPID) {
            handleSessionClosed()
            return
        }
        let state = TerminalSessionRuntimeState(
            sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(),
            childPID: foregroundPID ?? lastKnownChildPID, state: .running, updatedAt: ISO8601DateFormatter().string(from: now), title: effectiveTitle,
            workingDirectory: effectiveWorkingDirectory, columns: observedSurfaceSize()?.columns, rows: observedSurfaceSize()?.rows)
        let shouldPersist = force || shouldPersistRuntimeState(state, now: now)
        guard shouldPersist else { return }
        let previousSignature = lastPersistedRuntimeState.map(runtimeStateSignature(for:))
        let nextSignature = runtimeStateSignature(for: state)
        try? TerminalSessionPersistence.writeRuntimeState(state, paths: paths)
        lastPersistedRuntimeState = state
        lastRuntimeStateWriteAt = now
        if previousSignature != nextSignature { postRuntimeStateDidChange() }
    }

    @discardableResult func expireStaleRemoteClientsIfNeeded(now: Date = Date()) -> [String] {
        guard let staleClientIDs = try? TerminalSessionPersistence.staleRemoteClientIDs(paths: paths, now: now), !staleClientIDs.isEmpty else {
            return []
        }
        let activeAttachmentsBeforeExpiry = (try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []
        let staleClientIDSet = Set(staleClientIDs)
        let detachedClientWasOwner = activeAttachmentsBeforeExpiry.contains {
            $0.mode == .owner && $0.detachedAt == nil && staleClientIDSet.contains($0.clientID)
        }
        let detachedAt = ISO8601DateFormatter().string(from: now)
        for clientID in staleClientIDs { try? TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: detachedAt) }
        var remainingOwnerClientID = activeOwnerClientID()
        if detachedClientWasOwner, remainingOwnerClientID == nil, let localOwnerClientID = activeLocalWindowClientID(excluding: "") {
            try? TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: localOwnerClientID, paths: paths, transferredAt: detachedAt)
            remainingOwnerClientID = localOwnerClientID
            advanceOwnerEpoch(reason: "stale_client_transfer")
        }
        if Self.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: remainingOwnerClientID) {
            rendererHostStorage.setSurfaceFocused(false)
        }
        if remainingOwnerClientID == nil, rendererHostStorage.hasRenderableSurface() { rendererHostStorage.releaseRendererSurface() }
        postAttachmentStateDidChange()
        refreshRuntimeState(force: true)
        return staleClientIDs
    }

    private func appendOutput(_ data: Data) {
        let startedAt = Date()
        do {
            let outputHandle = try ensureOutputHandle()
            try outputHandle.write(contentsOf: data)
            let outputEndByteOffset = (try? outputHandle.seekToEnd()).map(Self.clampedInt)
            postOutputDidChange(data: data, outputEndByteOffset: outputEndByteOffset)
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
        } catch {
            TerminalPerformance.logMetric(
                "terminal_output_write", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "bytes=\(data.count)")
            fputs("spaces: ghostty output write failed: \(error)\n", stderr)
        }
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

    func applyActionEvent(_ event: GhosttyActionEvent) {
        switch event {
        case .setTitle(let title): currentTitle = Self.normalizedSessionMetadataValue(title)
        case .setWorkingDirectory(let path): currentWorkingDirectory = Self.normalizedSessionMetadataValue(path)
        }
        postSessionMetadataDidChange()
        refreshRuntimeState(force: true)
    }

    func applySessionStateChange(_ change: GhosttyEmbeddedSessionStateChange) {
        lastSessionStateRevision = change.revision
        lastSessionStateFlags = change.flags
        if change.flags.contains(.screen) { lastScreenStateRevision = change.revision }
        if change.flags.contains(.screen) { requestSurfaceRefreshAction() }
        var metadataChanged = false

        if change.flags.contains(.title) {
            let nextTitle = Self.normalizedSessionMetadataValue(change.title)
            if currentTitle != nextTitle {
                currentTitle = nextTitle
                metadataChanged = true
            }
        }

        if change.flags.contains(.workingDirectory) {
            let nextWorkingDirectory = Self.normalizedSessionMetadataValue(change.workingDirectory)
            if currentWorkingDirectory != nextWorkingDirectory {
                currentWorkingDirectory = nextWorkingDirectory
                metadataChanged = true
            }
        }

        if metadataChanged { postSessionMetadataDidChange() }

        if change.flags.contains(.foregroundProcess), let foregroundPID = rendererHostStorage.foregroundPID() { lastKnownChildPID = foregroundPID }
        if change.flags.contains(.size), let size = rendererHostStorage.surfaceCellSize() { lastKnownSurfaceSize = size }

        if metadataChanged || !change.flags.intersection(.runtimeState).isEmpty { refreshRuntimeState(force: true) }
    }

    private func observedChildPID() -> Int32? {
        if let foregroundPID = rendererHostStorage.foregroundPID() {
            lastKnownChildPID = foregroundPID
            return foregroundPID
        }
        return lastKnownChildPID
    }

    private func observedSurfaceSize() -> (columns: Int, rows: Int)? {
        if let size = rendererHostStorage.surfaceCellSize() {
            lastKnownSurfaceSize = size
            return size
        }
        return lastKnownSurfaceSize
    }

    private func postAttachmentStateDidChange() {
        NotificationCenter.default.post(
            name: .spacesTerminalAttachmentStateDidChange, object: nil, userInfo: ["sessionID": launchConfiguration.sessionID])
        broadcastCurrentState(reason: "attachment_state")
    }

    private func postSessionMetadataDidChange() {
        NotificationCenter.default.post(
            name: .spacesTerminalSessionMetadataDidChange, object: nil, userInfo: ["sessionID": launchConfiguration.sessionID])
        broadcastCurrentState(reason: "session_metadata")
    }

    private func postRuntimeStateDidChange() {
        NotificationCenter.default.post(
            name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": launchConfiguration.sessionID])
        broadcastCurrentState(reason: "runtime_state")
    }

    private func postOutputDidChange(data: Data, outputEndByteOffset: Int?) {
        NotificationCenter.default.post(
            name: .spacesTerminalOutputDidChange, object: nil, userInfo: ["sessionID": launchConfiguration.sessionID, "byteCount": data.count])
        if pendingInputOutputResync || inputOutputResyncWorkItem != nil {
            pendingInputOutputResync = false
            scheduleInputOutputResync()
        }
        broadcastCurrentState(reason: "output", outputByteCount: data.count, outputEndByteOffset: outputEndByteOffset)
    }

    private func handleOwnerInputActivity() {
        guard let ownerClient = activeOwnerClient() else { return }
        if ownerClient.kind == .localWindow {
            pendingInputOutputResync = true
            return
        }
        scheduleInputStateBroadcast()
    }

    private func scheduleInputStateBroadcast() {
        guard !inputStateBroadcastScheduled else { return }
        inputStateBroadcastScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inputStateBroadcastScheduled = false
                self.requestSurfaceRefreshAction()
                GhosttyEmbeddedAppService.shared.tick()
                self.broadcastCurrentState(reason: "input")
            }
        }
    }

    private func scheduleInputOutputResync() {
        inputOutputResyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inputOutputResyncWorkItem = nil
                self.requestSurfaceRefreshAction()
                GhosttyEmbeddedAppService.shared.tick()
                self.broadcastCurrentState(reason: "input_output")
            }
        }
        inputOutputResyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: workItem)
    }

    private func nowISO8601() -> String { ISO8601DateFormatter().string(from: Date()) }

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
        guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
            let attachment = snapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })
        else { return nil }
        return snapshot.clients.first(where: { $0.id == attachment.clientID })
    }

    nonisolated static func shouldClearFocusAfterDetachingClient(detachedClientWasOwner: Bool, remainingOwnerClientID: String?) -> Bool {
        detachedClientWasOwner || remainingOwnerClientID == nil
    }

    private func shouldPersistRuntimeState(_ state: TerminalSessionRuntimeState, now: Date) -> Bool {
        if let lastPersistedRuntimeState, runtimeStateSignature(for: lastPersistedRuntimeState) != runtimeStateSignature(for: state) { return true }
        guard let lastRuntimeStateWriteAt else { return true }
        return now.timeIntervalSince(lastRuntimeStateWriteAt) >= 5
    }

    private func runtimeStateSignature(for state: TerminalSessionRuntimeState) -> String {
        "\(state.sessionID)|\(state.backend.rawValue)|\(state.servicePID)|\(state.childPID.map(String.init) ?? "nil")|\(state.title ?? "nil")|\(state.workingDirectory ?? "nil")|\(state.columns.map(String.init) ?? "nil")|\(state.rows.map(String.init) ?? "nil")|\(state.state.rawValue)|\(state.exitedAt ?? "nil")"
    }

    private static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private nonisolated func enqueueIncomingOutput(_ data: Data) {
        guard incomingOutputBuffer.append(data) else { return }
        Task { [weak self] in
            do { try await Task.sleep(for: Self.incomingOutputCoalescingInterval) } catch { return }
            guard let self else { return }
            let coalescedData = incomingOutputBuffer.drain()
            guard !coalescedData.isEmpty else { return }
            await MainActor.run {
                self.requestSurfaceRefreshAction()
                self.appendOutput(coalescedData)
            }
        }
    }

    private func flushPendingIncomingOutputForStateExport() {
        let coalescedData = incomingOutputBuffer.drain()
        guard !coalescedData.isEmpty else { return }
        appendOutput(coalescedData)
    }

    func prepareRenderStateExport() { flushPendingIncomingOutputForStateExport() }

    private func broadcastCurrentState(reason: String, outputByteCount: Int? = nil, outputEndByteOffset: Int? = nil) {
        let startedAt = Date()
        let ownerClient = activeOwnerClient()
        let includeScreenState = Self.remoteStateShouldIncludeScreenState(reason: reason, ownerKind: ownerClient?.kind)
        trace(
            "broadcast_state_begin reason=\(reason) include_screen=\(includeScreenState ? 1 : 0) runtime=\(traceSize(observedSurfaceSize())) output_bytes=\(outputByteCount ?? 0)"
        )
        guard let stateStreamServer,
            let payload = currentRemoteSessionState(reason: reason, outputByteCount: outputByteCount, outputEndByteOffset: outputEndByteOffset)
        else { return }
        let payloadEncodeStartedAt = Date()
        let encodedPayload = try? GhosttyRemoteSessionStateCodec.encodeLine(payload)
        let payloadEncodeMS = TerminalPerformance.elapsedMS(since: payloadEncodeStartedAt)
        stateStreamServer.broadcast(payload)
        let payloadBytes = encodedPayload?.count ?? 0
        let decodedFrame = payload.decodedRenderFrame
        let renderFrameAttributes = GhosttyRenderFrameMetrics.attributes(
            reason: reason, frame: decodedFrame, frameByteCount: payload.renderFrame?.count, payloadByteCount: payloadBytes,
            payloadEncodeMS: payloadEncodeMS, outputByteCount: outputByteCount, screenStateRevision: payload.screenStateRevision)
        logMobileTakeoverPerformance(
            name: "remote_state_publish", count: payloadBytes,
            attributes: [
                "reason": reason, "owner_kind": ownerClient?.kind.rawValue ?? "nil", "render_frame": payload.renderFrame == nil ? "0" : "1",
                "output_bytes": String(outputByteCount ?? 0), "payload_bytes": String(payloadBytes),
                "frame_bytes": String(payload.renderFrame?.count ?? 0),
            ])
        logMobileTakeoverPerformance(
            name: "render_frame_payload_publish", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), count: payloadBytes,
            attributes: renderFrameAttributes)
        trace(
            "broadcast_state_end reason=\(reason) render_frame=\(payload.renderFrame == nil ? 0 : 1) runtime=\(traceSize(columns: payload.runtimeState?.columns, rows: payload.runtimeState?.rows)) owner_epoch=\(ownerEpoch)"
        )
        TerminalPerformance.logMetric(
            "terminal_remote_state_publish", target: "session=\(launchConfiguration.sessionID)",
            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail:
                "reason=\(reason) render_frame=\(payload.renderFrame == nil ? 0 : 1) bytes=\(outputByteCount ?? 0) payload_bytes=\(payloadBytes) frame_bytes=\(payload.renderFrame?.count ?? 0)"
        )
        TerminalPerformance.logMetric(
            "terminal_render_frame_payload_publish", target: "session=\(launchConfiguration.sessionID)",
            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: GhosttyRenderFrameMetrics.detailString(renderFrameAttributes))
    }

    private func currentRemoteSessionState(reason: String, outputByteCount: Int?, outputEndByteOffset: Int? = nil)
        -> GhosttyRemoteSessionStatePayload?
    {
        let runtimeState = (try? TerminalSessionPersistence.readRuntimeState(paths: paths)) ?? lastPersistedRuntimeState
        let attachmentSnapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
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
            let resolvedScreenState = resolveRemoteScreenState(runtimeState: runtimeState, reason: reason, ownerKind: ownerClient?.kind)
            let snapshot = resolvedScreenState.snapshot
            let frame = snapshot.map { GhosttyRenderFrame(sessionRevision: lastSessionStateRevision, ownerEpoch: ownerEpoch, snapshot: $0) }
            let renderFrameEncodeStartedAt = Date()
            let renderFrame = frame.flatMap { try? GhosttyRenderFrame.encode($0) }
            let renderFrameEncodeMS = TerminalPerformance.elapsedMS(since: renderFrameEncodeStartedAt)
            trace(
                "render_frame_export_end reason=\(reason) render_frame=\(renderFrame == nil ? 0 : 1) frame_size=\(traceSize(columns: snapshot?.columns, rows: snapshot?.rows)) source=\(resolvedScreenState.source) owner_epoch=\(ownerEpoch)"
            )
            var renderFrameAttributes = GhosttyRenderFrameMetrics.attributes(
                reason: reason, frame: frame, frameByteCount: renderFrame?.count, frameEncodeMS: renderFrameEncodeMS,
                outputByteCount: outputByteCount, screenStateRevision: lastScreenStateRevision)
            renderFrameAttributes["source"] = resolvedScreenState.source
            renderFrameAttributes["owner_kind"] = ownerClient?.kind.rawValue ?? "nil"
            logMobileTakeoverPerformance(
                name: "render_frame_export_end", elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt), count: renderFrame?.count,
                attributes: renderFrameAttributes)
            TerminalPerformance.logMetric(
                "terminal_render_frame_export", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt), success: renderFrame != nil,
                detail: GhosttyRenderFrameMetrics.detailString(renderFrameAttributes))
            return GhosttyRemoteSessionStatePayload(
                sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
                sessionStateRevision: lastSessionStateRevision, sessionStateFlags: lastSessionStateFlags?.rawValue,
                screenStateRevision: lastScreenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
                title: effectiveTitle, workingDirectory: effectiveWorkingDirectory, renderFrame: renderFrame,
                outputByteCount: bootstrapOutputByteCount, outputEndByteOffset: bootstrapOutputEndByteOffset)
        }
        return GhosttyRemoteSessionStatePayload(
            sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
            sessionStateRevision: lastSessionStateRevision, sessionStateFlags: lastSessionStateFlags?.rawValue,
            screenStateRevision: lastScreenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot, title: effectiveTitle,
            workingDirectory: effectiveWorkingDirectory, renderFrame: nil, outputByteCount: bootstrapOutputByteCount,
            outputEndByteOffset: bootstrapOutputEndByteOffset)
    }

    private func resolveRemoteScreenState(runtimeState: TerminalSessionRuntimeState?, reason: String, ownerKind: TerminalClientKind?) -> (
        snapshot: GhosttyTerminalSnapshot?, snapshotText: String?, source: String
    ) {
        let liveSessionScreenState = captureLiveSessionScreenState()
        let sessionSnapshot = liveSessionScreenState.snapshot
        let sessionSnapshotText = liveSessionScreenState.snapshotText
        if Self.remoteScreenStateHasVisibleContent(snapshot: sessionSnapshot, snapshotText: sessionSnapshotText) {
            return (snapshot: sessionSnapshot, snapshotText: sessionSnapshotText, source: "session")
        }

        let isLiveRuntime = runtimeState?.state == .running || runtimeState?.state == .starting
        return (snapshot: nil, snapshotText: nil, source: isLiveRuntime ? "session_empty" : "session_unavailable")
    }

    private func captureLiveSessionScreenState() -> (snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) {
        flushPendingIncomingOutputForStateExport()
        rendererHostStorage.prepareRenderStateExport()
        let sessionSnapshot = rendererHostStorage.sessionSnapshot()
        let sessionSnapshotText = sessionSnapshot == nil ? rendererHostStorage.sessionSnapshotText() : nil
        return (snapshot: sessionSnapshot, snapshotText: sessionSnapshotText)
    }

    static func remoteStateShouldIncludeScreenState(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
        TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: reason, ownerKind: ownerKind)
    }

    static func remoteScreenStateHasVisibleContent(snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) -> Bool {
        TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: snapshot, snapshotText: snapshotText)
    }

    var debugCurrentTitle: String? { currentTitle }
    var debugCurrentWorkingDirectory: String? { currentWorkingDirectory }
    func debugHandleIncomingOutput(_ data: Data) {
        requestSurfaceRefreshAction()
        appendOutput(data)
    }
    func debugHandleOwnerInputActivity() { handleOwnerInputActivity() }
    func debugPersistRuntimeState(force: Bool = true) { refreshRuntimeState(force: force) }
    func debugSetLastKnownChildPID(_ pid: Int32?) { lastKnownChildPID = pid }
    func debugSetLastKnownSurfaceSize(columns: Int, rows: Int) { lastKnownSurfaceSize = (columns, rows) }
    func debugHandleSessionClosed() { handleSessionClosed() }
    func debugMarkStartedForTesting() { started = true }

    private func trace(_ message: @autoclosure () -> String) { ghosttyEmbeddedSessionTrace(launchConfiguration.sessionID, message()) }

    private func traceSize(_ size: (columns: Int, rows: Int)?) -> String {
        guard let size else { return "nil" }
        return "\(size.columns)x\(size.rows)"
    }

    private func traceSize(columns: Int?, rows: Int?) -> String {
        guard let columns, let rows else { return "nil" }
        return "\(columns)x\(rows)"
    }

    private func logMobileTakeoverPerformance(name: String, elapsedMS: Int? = nil, count: Int? = nil, attributes: [String: String] = [:]) {
        SpacesMobileTerminalPerformanceLogger.emit(
            .init(
                sessionID: launchConfiguration.sessionID, source: "mac-host", name: name, elapsedMS: elapsedMS, count: count, attributes: attributes))
    }
}

@MainActor public final class GhosttyEmbeddedSessionHost {
    public let core: GhosttyEmbeddedSessionCore

    public var launchConfiguration: TerminalSessionLaunchConfiguration { core.launchConfiguration }
    public var paths: TerminalSessionPaths { core.paths }
    public var rendererHost: any TerminalGhosttyRendererHosting { core.rendererHost }

    init(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        requestSurfaceRefreshAction: (@MainActor () -> Void)? = nil
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
            try core.rendererHost.attach(client: client, mode: mode, into: container)
            try core.attachClient(client, mode: mode)
            if mode == .owner, let container {
                core.rendererHost.requestSurfaceRefresh()
                core.rendererHost.focusWindow(container.window)
            }
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

    public func takeover(client: TerminalClient, into container: NSView?) throws { try attach(client: client, mode: .owner, into: container) }

    public func releaseRendererSurface() { core.rendererHost.releaseRendererSurface() }

    public func setFocused(_ focused: Bool, for clientID: String) { core.rendererHost.setFocused(focused, for: clientID) }

    public func focusWindow(_ window: NSWindow?) { core.rendererHost.focusWindow(window) }

    @discardableResult public func synchronizeSurfaceGeometry() -> Bool { core.rendererHost.synchronizeSurfaceGeometry() }

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

    @discardableResult public func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        core.rendererHost.sendScroll(horizontal: horizontal, vertical: vertical)
    }

    public var debugSurfaceRefreshRequestCount: Int { core.rendererHost.debugSurfaceRefreshRequestCount }
    public func debugVisibleSurfaceText() -> String? { return core.rendererHost.debugVisibleSurfaceText() }

    public func terminate() { core.terminate() }

    public func childPID() -> Int32? { core.childPID() }

    public var effectiveTitle: String { core.effectiveTitle }

    public var effectiveWorkingDirectory: String { core.effectiveWorkingDirectory }

    func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse { core.handleControlRequest(request) }
    func applyActionEvent(_ event: GhosttyActionEvent) { core.applyActionEvent(event) }
    func applySessionStateChange(_ change: GhosttyEmbeddedSessionStateChange) { core.applySessionStateChange(change) }
    @discardableResult func expireStaleRemoteClientsIfNeeded(now: Date = Date()) -> [String] { core.expireStaleRemoteClientsIfNeeded(now: now) }

    nonisolated static func shouldClearFocusAfterDetachingClient(detachedClientWasOwner: Bool, remainingOwnerClientID: String?) -> Bool {
        GhosttyEmbeddedSessionCore.shouldClearFocusAfterDetachingClient(
            detachedClientWasOwner: detachedClientWasOwner, remainingOwnerClientID: remainingOwnerClientID)
    }

    var debugCurrentTitle: String? { core.debugCurrentTitle }
    var debugCurrentWorkingDirectory: String? { core.debugCurrentWorkingDirectory }
    func debugHandleIncomingOutput(_ data: Data) { core.debugHandleIncomingOutput(data) }
    func debugHandleOwnerInputActivity() { core.debugHandleOwnerInputActivity() }
    func debugPersistRuntimeState(force: Bool = true) { core.debugPersistRuntimeState(force: force) }
    func debugSetLastKnownChildPID(_ pid: Int32?) { core.debugSetLastKnownChildPID(pid) }
    func debugHandleSessionClosed() { core.debugHandleSessionClosed() }
    func debugMarkStartedForTesting() { core.debugMarkStartedForTesting() }
}

extension GhosttyEmbeddedSessionHost: TerminalGhosttySessionHosting {}
