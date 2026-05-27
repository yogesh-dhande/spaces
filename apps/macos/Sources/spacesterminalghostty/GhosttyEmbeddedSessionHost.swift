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
    func parkSurfaceInHiddenHostWindow()
    func setFocused(_ focused: Bool, for clientID: String)
    func focusWindow(_ window: NSWindow?)
    func hasRenderableSurface() -> Bool
    var prefersOutputFallbackWhenSurfaceUnavailable: Bool { get }
    func snapshot() -> GhosttyTerminalSnapshot?
    func snapshotText() -> String?
    func sessionSnapshot() -> GhosttyTerminalSnapshot?
    func sessionSnapshotText() -> String?
    func copySelectionToPasteboard() -> Bool
    func pasteClipboardContents() -> Bool
    @discardableResult func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool
    var debugSurfaceRefreshRequestCount: Int { get }
    func debugVisibleSurfaceText() -> String?
}

@MainActor public protocol TerminalGhosttySessionHosting: TerminalGhosttySessionInfoProviding, TerminalGhosttyRendererHosting {}

@MainActor public final class GhosttyEmbeddedRendererHost: TerminalGhosttyRendererHosting {
    private static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private let terminalView: GhosttyEmbeddedTerminalView
    private var isOwnerClient: (@MainActor (String) -> Bool)?

    init(launchConfiguration: TerminalSessionLaunchConfiguration, terminalView: GhosttyEmbeddedTerminalView) { self.terminalView = terminalView }

    func setOwnerClientResolver(_ resolver: @escaping @MainActor (String) -> Bool) { isOwnerClient = resolver }

    func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { terminalView.setOutputHandler(handler) }

    func setInputActivityHandler(_ handler: (@MainActor () -> Void)?) { terminalView.onInputActivity = handler }

    func ensureHostingWindowForSurface() { terminalView.ensureHostingWindowForSurface() }

    func requestSurfaceRefresh() { terminalView.requestSurfaceRefresh() }

    func sendRawBytes(_ data: Data) { terminalView.sendRawBytes(data) }

    func foregroundPID() -> Int32? { terminalView.foregroundPID() }

    func surfaceCellSize() -> (columns: Int, rows: Int)? { terminalView.sessionCellSize() }

    @discardableResult func resizeCellGrid(columns: Int, rows: Int) -> Bool { terminalView.resizeCellGrid(columns: columns, rows: rows) }

    func terminateSession() { terminalView.terminateSession() }

    func setSurfaceFocused(_ focused: Bool) { terminalView.setFocused(focused) }

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
        guard let container else { return }
        terminalView.setAttachmentMode(mode)
        if terminalView.superview !== container {
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
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }

    public func parkSurfaceInHiddenHostWindow() {
        guard hasRenderableSurface() else { return }
        terminalView.parkInHiddenHostWindowIfNeeded()
    }

    public func setFocused(_ focused: Bool, for clientID: String) {
        guard isOwnerClient?(clientID) == true else {
            terminalView.setFocused(false)
            return
        }
        terminalView.setFocused(focused)
    }

    public func focusWindow(_ window: NSWindow?) {
        guard let window else { return }
        if Self.isRunningUnderXCTest {
            window.makeFirstResponder(terminalView)
            terminalView.setFocused(true)
            return
        }
        if !window.isVisible { window.orderFront(nil) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(terminalView)
        terminalView.setFocused(window.isKeyWindow)
    }

    public func hasRenderableSurface() -> Bool { terminalView.surface != nil }

    public var prefersOutputFallbackWhenSurfaceUnavailable: Bool { false }

    public func snapshot() -> GhosttyTerminalSnapshot? { terminalView.snapshot() }

    public func snapshotText() -> String? { terminalView.snapshotText() }

    public func sessionSnapshot() -> GhosttyTerminalSnapshot? { terminalView.sessionSnapshot() }

    public func sessionSnapshotText() -> String? { terminalView.sessionSnapshotText() }

    public func copySelectionToPasteboard() -> Bool { terminalView.copySelectionToPasteboard() }

    public func pasteClipboardContents() -> Bool { terminalView.pasteClipboardContents() }

    @discardableResult public func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        terminalView.sendScroll(horizontal: horizontal, vertical: vertical)
    }

    public var debugSurfaceRefreshRequestCount: Int { terminalView.debugSurfaceRefreshRequestCount }

    public func debugVisibleSurfaceText() -> String? {
        if let sessionSnapshotText = terminalView.sessionSnapshotText(), !sessionSnapshotText.isEmpty { return sessionSnapshotText }
        if let snapshotText = terminalView.snapshotText(), !snapshotText.isEmpty { return snapshotText }
        return nil
    }
}

@MainActor public final class GhosttyEmbeddedSessionRegistry {
    public static let shared = GhosttyEmbeddedSessionRegistry()

    private var cores: [String: GhosttyEmbeddedSessionCore] = [:]
    private var hosts: [String: GhosttyEmbeddedSessionHost] = [:]

    private init() {}

    public func core(for launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) -> GhosttyEmbeddedSessionCore {
        if let existing = cores[launchConfiguration.sessionID] { return existing }
        let created = GhosttyEmbeddedSessionCore(
            launchConfiguration: launchConfiguration, paths: paths,
            onSessionClosed: { [weak self] closedCore in self?.unregisterClosedCore(closedCore) })
        cores[launchConfiguration.sessionID] = created
        return created
    }

    public func existingCore(sessionID: String) -> GhosttyEmbeddedSessionCore? { cores[sessionID] }

    public func host(for launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) -> GhosttyEmbeddedSessionHost {
        if let existing = hosts[launchConfiguration.sessionID] { return existing }
        let created = GhosttyEmbeddedSessionHost(core: core(for: launchConfiguration, paths: paths))
        hosts[launchConfiguration.sessionID] = created
        return created
    }

    public func existingHost(sessionID: String) -> GhosttyEmbeddedSessionHost? { hosts[sessionID] }

    public func terminate(sessionID: String) {
        hosts.removeValue(forKey: sessionID)
        guard let core = cores.removeValue(forKey: sessionID) else { return }
        core.terminate()
    }

    public func terminateAll() { for sessionID in Array(cores.keys) { terminate(sessionID: sessionID) } }

    private func unregisterClosedCore(_ core: GhosttyEmbeddedSessionCore) {
        let sessionID = core.launchConfiguration.sessionID
        guard cores[sessionID] === core else { return }
        cores.removeValue(forKey: sessionID)
        if hosts[sessionID]?.core === core { hosts.removeValue(forKey: sessionID) }
    }
}

@MainActor public final class GhosttyEmbeddedSessionCore {
    private static let incomingOutputCoalescingInterval: Duration = .milliseconds(16)
    private static let remoteTranscriptLineCount = 2_000

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
    private let terminalView: GhosttyEmbeddedTerminalView
    private lazy var rendererHostStorage = GhosttyEmbeddedRendererHost(launchConfiguration: launchConfiguration, terminalView: terminalView)
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
    private let remoteSnapshotStream: GhosttyVTSnapshotStream
    private var inputStateBroadcastScheduled = false
    private var pendingInputOutputResync = false
    private var inputOutputResyncWorkItem: DispatchWorkItem?
    private var lastCachedSessionSnapshot: GhosttyTerminalSnapshot?
    private var lastCachedSessionSnapshotText: String?
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
        terminalView = GhosttyEmbeddedTerminalView(launchConfiguration: launchConfiguration, sessionDriver: sessionDriver)
        remoteSnapshotStream = GhosttyVTSnapshotStream(sessionID: launchConfiguration.sessionID, outputPath: paths.outputPath)
        self.requestSurfaceRefreshAction = requestSurfaceRefreshAction ?? { [terminalView] in terminalView.requestSurfaceRefresh() }
        terminalView.onActionEvent = { [weak self] event in self?.applyActionEvent(event) }
        sessionDriver.onSessionStateChanged = { [weak self] change in self?.applySessionStateChange(change) }
        terminalView.onSurfaceCellSizeChanged = { [weak self] columns, rows in
            guard let self else { return }
            self.lastKnownSurfaceSize = (columns, rows)
            self.refreshRuntimeState(force: true)
        }
        rendererHostStorage.setOwnerClientResolver { [weak self] clientID in self?.isOwner(clientID: clientID) ?? false }
        rendererHostStorage.setInputActivityHandler { [weak self] in self?.handleOwnerInputActivity() }
        terminalView.onSessionClosed = { [weak self] in self?.handleSessionClosed() }
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
            rendererHostStorage.ensureHostingWindowForSurface()
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
        if currentAttachment?.mode != mode {
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: client, mode: mode, paths: paths,
                attachedAt: ISO8601DateFormatter().string(from: Date()))
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
        }
        if Self.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: detachedClientWasOwner, remainingOwnerClientID: remainingOwnerClientID) {
            rendererHostStorage.setSurfaceFocused(false)
        }
        if remainingOwnerClientID == nil, rendererHostStorage.hasRenderableSurface() { rendererHostStorage.parkSurfaceInHiddenHostWindow() }
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

    public var rendererHost: GhosttyEmbeddedRendererHost { rendererHostStorage }
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
        default: TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(request.command)'.")
        }
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
            try TerminalSessionPersistence.upsertClient(authoritativeClient, paths: paths)
            let currentAttachment = try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == authoritativeClient.id }
            if currentAttachment?.mode != mode {
                try TerminalSessionPersistence.attachClient(
                    sessionID: launchConfiguration.sessionID, client: authoritativeClient, mode: mode, paths: paths, attachedAt: attachedAt)
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
        if let clientID = request.clientID, !isOwner(clientID: clientID) {
            TerminalPerformance.logMetric(
                "terminal_control_send", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            return TerminalControlResponse(ok: false, message: "Only the active owner can send input.")
        }
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
        if let clientID = request.clientID, !isOwner(clientID: clientID) {
            TerminalPerformance.logMetric(
                "terminal_control_key", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            return TerminalControlResponse(ok: false, message: "Only the active owner can send keys.")
        }
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

    private func controlResponseForTakeoverRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        guard let clientID = request.clientID else { return TerminalControlResponse(ok: false, message: "Missing client ID.") }
        do {
            try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601())
            refreshCachedOwnerBootstrapSnapshotBeforeRemoteTakeover()
            try TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: clientID, paths: paths,
                transferredAt: ISO8601DateFormatter().string(from: Date()))
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

    private func refreshCachedOwnerBootstrapSnapshotBeforeRemoteTakeover() {
        guard activeOwnerClient()?.kind == .localWindow else { return }
        let refreshedState = captureLiveSessionScreenState()
        logMobileTakeoverPerformance(
            name: "owner_bootstrap_cache_refresh",
            attributes: ["snapshot": refreshedState.snapshot == nil ? "0" : "1", "snapshot_text": refreshedState.snapshotText == nil ? "0" : "1"])
        trace("takeover_cached_owner_bootstrap_refreshed")
    }

    private func controlResponseForResizeRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        let startedAt = Date()
        if let clientID = request.clientID { try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601()) }
        if let clientID = request.clientID, !isOwner(clientID: clientID) {
            TerminalPerformance.logMetric(
                "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            return TerminalControlResponse(ok: false, message: "Only the active owner can resize the terminal.")
        }
        guard let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 else {
            return TerminalControlResponse(ok: false, message: "Missing terminal size.")
        }
        trace(
            "resize_request client=\(request.clientID ?? "nil") columns=\(columns) rows=\(rows) runtime_before=\(traceSize(observedSurfaceSize())) owner=\(activeOwnerClientID() ?? "nil")"
        )
        let resized = rendererHostStorage.resizeCellGrid(columns: columns, rows: rows)
        refreshRuntimeState(force: true)
        trace("resize_request_result resized=\(resized ? 1 : 0) runtime_after=\(traceSize(observedSurfaceSize()))")
        TerminalPerformance.logMetric(
            "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: resized, detail: "columns=\(columns) rows=\(rows)")
        broadcastCurrentState(reason: "resize")
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
        }
        if Self.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: remainingOwnerClientID) {
            rendererHostStorage.setSurfaceFocused(false)
        }
        if remainingOwnerClientID == nil, rendererHostStorage.hasRenderableSurface() { rendererHostStorage.parkSurfaceInHiddenHostWindow() }
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
            return
        }
        broadcastCurrentState(reason: "output", outputByteCount: data.count, outputData: data, outputEndByteOffset: outputEndByteOffset)
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

    private func broadcastCurrentState(reason: String, outputByteCount: Int? = nil, outputData: Data? = nil, outputEndByteOffset: Int? = nil) {
        let startedAt = Date()
        let ownerClient = activeOwnerClient()
        let includeScreenState = Self.remoteStateShouldIncludeScreenState(reason: reason, ownerKind: ownerClient?.kind)
        trace(
            "broadcast_state_begin reason=\(reason) include_screen=\(includeScreenState ? 1 : 0) runtime=\(traceSize(observedSurfaceSize())) output_bytes=\(outputByteCount ?? 0)"
        )
        guard let stateStreamServer,
            let payload = currentRemoteSessionState(
                reason: reason, outputByteCount: outputByteCount, outputData: outputData, outputEndByteOffset: outputEndByteOffset)
        else { return }
        stateStreamServer.broadcast(payload)
        let payloadBytes = (try? GhosttyRemoteSessionStateCodec.encodeLine(payload).count) ?? 0
        logMobileTakeoverPerformance(
            name: "remote_state_publish", count: payloadBytes,
            attributes: [
                "reason": reason, "owner_kind": ownerClient?.kind.rawValue ?? "nil", "snapshot": payload.snapshot == nil ? "0" : "1",
                "output_bytes": String(payload.outputData?.count ?? 0),
            ])
        trace(
            "broadcast_state_end reason=\(reason) snapshot=\(payload.snapshot == nil ? 0 : 1) snapshot_text=\(payload.snapshotText == nil ? 0 : 1) runtime=\(traceSize(columns: payload.runtimeState?.columns, rows: payload.runtimeState?.rows))"
        )
        TerminalPerformance.logMetric(
            "terminal_remote_state_publish", target: "session=\(launchConfiguration.sessionID)",
            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail:
                "reason=\(reason) snapshot=\(payload.snapshot == nil ? 0 : 1) snapshot_text=\(payload.snapshotText == nil ? 0 : 1) bytes=\(outputByteCount ?? 0) streamed=\(payload.outputData?.count ?? 0)"
        )
    }

    private func currentRemoteSessionState(reason: String, outputByteCount: Int?, outputData: Data? = nil, outputEndByteOffset: Int? = nil)
        -> GhosttyRemoteSessionStatePayload?
    {
        let runtimeState = (try? TerminalSessionPersistence.readRuntimeState(paths: paths)) ?? lastPersistedRuntimeState
        let attachmentSnapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
        let ownerClient = activeOwnerClient()
        let includeScreenState = Self.remoteStateShouldIncludeScreenState(reason: reason, ownerKind: ownerClient?.kind)
        let includeTranscriptTail = Self.remoteStateShouldIncludeTranscriptTail(reason: reason, runtimeState: runtimeState)
        let bootstrapOutputData = outputData
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
            let snapshotText = resolvedScreenState.snapshotText
            trace(
                "snapshot_export_end reason=\(reason) snapshot=\(snapshot == nil ? 0 : 1) snapshot_text=\(snapshotText == nil ? 0 : 1) snapshot_size=\(traceSize(columns: snapshot?.columns, rows: snapshot?.rows)) source=\(resolvedScreenState.source)"
            )
            logMobileTakeoverPerformance(
                name: "snapshot_export_end", elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt),
                attributes: [
                    "reason": reason, "source": resolvedScreenState.source, "snapshot": snapshot == nil ? "0" : "1",
                    "snapshot_columns": String(snapshot?.columns ?? 0), "snapshot_rows": String(snapshot?.rows ?? 0),
                ])
            let transcriptTail =
                includeTranscriptTail
                ? ((try? TerminalOutputTail.tail(path: paths.outputPath, lineCount: Self.remoteTranscriptLineCount)) ?? nil) : nil
            return GhosttyRemoteSessionStatePayload(
                sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
                sessionStateRevision: lastSessionStateRevision, sessionStateFlags: lastSessionStateFlags?.rawValue,
                screenStateRevision: lastScreenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
                title: effectiveTitle, workingDirectory: effectiveWorkingDirectory, snapshot: snapshot, snapshotText: snapshotText,
                transcriptTail: transcriptTail, outputByteCount: outputByteCount ?? bootstrapOutputData?.count, outputData: bootstrapOutputData,
                outputEndByteOffset: outputEndByteOffset)
        }
        let snapshot: GhosttyTerminalSnapshot? = nil
        let snapshotText: String? = nil
        let transcriptTail =
            includeTranscriptTail ? ((try? TerminalOutputTail.tail(path: paths.outputPath, lineCount: Self.remoteTranscriptLineCount)) ?? nil) : nil
        return GhosttyRemoteSessionStatePayload(
            sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
            sessionStateRevision: lastSessionStateRevision, sessionStateFlags: lastSessionStateFlags?.rawValue,
            screenStateRevision: lastScreenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot, title: effectiveTitle,
            workingDirectory: effectiveWorkingDirectory, snapshot: snapshot, snapshotText: snapshotText, transcriptTail: transcriptTail,
            outputByteCount: outputByteCount ?? bootstrapOutputData?.count, outputData: bootstrapOutputData, outputEndByteOffset: outputEndByteOffset)
    }

    private func resolveRemoteScreenState(runtimeState: TerminalSessionRuntimeState?, reason: String, ownerKind: TerminalClientKind?) -> (
        snapshot: GhosttyTerminalSnapshot?, snapshotText: String?, source: String
    ) {
        if Self.remoteStateShouldUseCachedSessionSnapshot(reason: reason, ownerKind: ownerKind) {
            let liveSessionScreenState = captureLiveSessionScreenState()
            if Self.remoteScreenStateHasVisibleContent(snapshot: liveSessionScreenState.snapshot, snapshotText: liveSessionScreenState.snapshotText) {
                return (snapshot: liveSessionScreenState.snapshot, snapshotText: liveSessionScreenState.snapshotText, source: "session")
            }

            let fallbackScreenState = remoteSnapshotStreamScreenState(runtimeState: runtimeState)
            if Self.remoteScreenStateHasVisibleContent(snapshot: fallbackScreenState.snapshot, snapshotText: fallbackScreenState.snapshotText) {
                return (snapshot: fallbackScreenState.snapshot, snapshotText: fallbackScreenState.snapshotText, source: "vt_stream")
            }

            if Self.remoteScreenStateHasVisibleContent(snapshot: lastCachedSessionSnapshot, snapshotText: lastCachedSessionSnapshotText) {
                return (snapshot: lastCachedSessionSnapshot, snapshotText: lastCachedSessionSnapshotText, source: "session_cached")
            }
            return (snapshot: nil, snapshotText: nil, source: "session_cached_empty")
        }

        let liveSessionScreenState = captureLiveSessionScreenState()
        let sessionSnapshot = liveSessionScreenState.snapshot
        let sessionSnapshotText = liveSessionScreenState.snapshotText
        if Self.remoteScreenStateHasVisibleContent(snapshot: sessionSnapshot, snapshotText: sessionSnapshotText) {
            return (snapshot: sessionSnapshot, snapshotText: sessionSnapshotText, source: "session")
        }

        let isLiveRuntime = runtimeState?.state == .running || runtimeState?.state == .starting
        guard !isLiveRuntime else { return (snapshot: nil, snapshotText: nil, source: "session_empty") }

        let fallbackScreenState = remoteSnapshotStreamScreenState(runtimeState: runtimeState)
        if Self.remoteScreenStateHasVisibleContent(snapshot: fallbackScreenState.snapshot, snapshotText: fallbackScreenState.snapshotText) {
            return (snapshot: fallbackScreenState.snapshot, snapshotText: fallbackScreenState.snapshotText, source: "vt_stream")
        }

        return (snapshot: nil, snapshotText: nil, source: "vt_stream_empty")
    }

    private func remoteSnapshotStreamScreenState(runtimeState: TerminalSessionRuntimeState?) -> (
        snapshot: GhosttyTerminalSnapshot?, snapshotText: String?
    ) {
        let snapshot = remoteSnapshotStream.snapshot(columns: runtimeState?.columns, rows: runtimeState?.rows)
        let snapshotText = snapshot == nil ? remoteSnapshotStream.snapshotText(columns: runtimeState?.columns, rows: runtimeState?.rows) : nil
        return (snapshot: snapshot, snapshotText: snapshotText)
    }

    private func captureLiveSessionScreenState() -> (snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) {
        let sessionSnapshot = rendererHostStorage.sessionSnapshot()
        let sessionSnapshotText = sessionSnapshot == nil ? rendererHostStorage.sessionSnapshotText() : nil
        if Self.remoteScreenStateHasVisibleContent(snapshot: sessionSnapshot, snapshotText: sessionSnapshotText) {
            lastCachedSessionSnapshot = sessionSnapshot
            lastCachedSessionSnapshotText = sessionSnapshotText
        }
        return (snapshot: sessionSnapshot, snapshotText: sessionSnapshotText)
    }

    static func remoteStateShouldIncludeScreenState(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
        switch reason {
        case "initial": ownerKind == .remoteViewer
        case "terminated": true
        case "input", "input_output": ownerKind != .remoteViewer
        default: false
        }
    }

    static func remoteStateShouldUseCachedSessionSnapshot(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
        reason == "initial" && ownerKind == .remoteViewer
    }

    static func remoteScreenStateHasVisibleContent(snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) -> Bool {
        if let snapshot {
            let text = GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
            if text.contains(where: { !$0.isWhitespace && !$0.isNewline }) { return true }
        }
        guard let snapshotText else { return false }
        return snapshotText.contains(where: { !$0.isWhitespace && !$0.isNewline })
    }

    private static func remoteStateShouldIncludeTranscriptTail(reason: String, runtimeState: TerminalSessionRuntimeState?) -> Bool {
        switch reason {
        case "terminated": return true
        case "initial":
            let state = runtimeState?.state
            return state != .running && state != .starting
        default: return false
        }
    }

    var debugCurrentTitle: String? { currentTitle }
    var debugCurrentWorkingDirectory: String? { currentWorkingDirectory }
    func debugHandleIncomingOutput(_ data: Data) {
        requestSurfaceRefreshAction()
        appendOutput(data)
    }
    func debugPersistRuntimeState(force: Bool = true) { refreshRuntimeState(force: force) }
    func debugSetLastKnownChildPID(_ pid: Int32?) { lastKnownChildPID = pid }
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

    public init(
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

    public func parkSurfaceInHiddenHostWindow() { core.rendererHost.parkSurfaceInHiddenHostWindow() }

    public func setFocused(_ focused: Bool, for clientID: String) { core.rendererHost.setFocused(focused, for: clientID) }

    public func focusWindow(_ window: NSWindow?) { core.rendererHost.focusWindow(window) }

    public func isOwner(clientID: String) -> Bool { core.isOwner(clientID: clientID) }

    public func activeOwnerClientID() -> String? { core.activeOwnerClientID() }

    public func hasRenderableSurface() -> Bool { core.rendererHost.hasRenderableSurface() }

    public var prefersOutputFallbackWhenSurfaceUnavailable: Bool { core.rendererHost.prefersOutputFallbackWhenSurfaceUnavailable }

    public func snapshot() -> GhosttyTerminalSnapshot? { core.rendererHost.snapshot() }

    public func snapshotText() -> String? { core.rendererHost.snapshotText() }

    public func sessionSnapshot() -> GhosttyTerminalSnapshot? { core.rendererHost.sessionSnapshot() }

    public func sessionSnapshotText() -> String? { core.rendererHost.sessionSnapshotText() }

    public func copySelectionToPasteboard() -> Bool { core.rendererHost.copySelectionToPasteboard() }

    public func pasteClipboardContents() -> Bool { core.rendererHost.pasteClipboardContents() }

    @discardableResult public func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        core.rendererHost.debugSendScroll(horizontal: horizontal, vertical: vertical)
    }

    public var debugSurfaceRefreshRequestCount: Int { core.rendererHost.debugSurfaceRefreshRequestCount }
    public func debugVisibleSurfaceText() -> String? { core.rendererHost.debugVisibleSurfaceText() }

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
    func debugPersistRuntimeState(force: Bool = true) { core.debugPersistRuntimeState(force: force) }
    func debugSetLastKnownChildPID(_ pid: Int32?) { core.debugSetLastKnownChildPID(pid) }
    func debugHandleSessionClosed() { core.debugHandleSessionClosed() }
    func debugMarkStartedForTesting() { core.debugMarkStartedForTesting() }
}

extension GhosttyEmbeddedSessionHost: TerminalGhosttySessionHosting {}
