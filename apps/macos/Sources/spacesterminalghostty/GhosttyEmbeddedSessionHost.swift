import AppKit
import Foundation
import spacesterminalcore

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
    func copySelectionToPasteboard() -> Bool
    func pasteClipboardContents() -> Bool
    @discardableResult func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool
    var debugSurfaceRefreshRequestCount: Int { get }
}

@MainActor public protocol TerminalGhosttySessionHosting: TerminalGhosttySessionInfoProviding, TerminalGhosttyRendererHosting {}

@MainActor public final class GhosttyEmbeddedRendererHost: TerminalGhosttyRendererHosting {
    private static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let terminalView: GhosttyEmbeddedTerminalView
    private var isOwnerClient: (@MainActor (String) -> Bool)?

    init(launchConfiguration: TerminalSessionLaunchConfiguration, terminalView: GhosttyEmbeddedTerminalView) {
        self.launchConfiguration = launchConfiguration
        self.terminalView = terminalView
    }

    func setOwnerClientResolver(_ resolver: @escaping @MainActor (String) -> Bool) { isOwnerClient = resolver }

    func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { terminalView.setOutputHandler(handler) }

    func ensureHostingWindowForSurface() { terminalView.ensureHostingWindowForSurface() }

    func requestSurfaceRefresh() { terminalView.requestSurfaceRefresh() }

    func sendRawBytes(_ data: Data) { terminalView.sendRawBytes(data) }

    func foregroundPID() -> Int32? { terminalView.foregroundPID() }

    func surfaceCellSize() -> (columns: Int, rows: Int)? { terminalView.surfaceCellSize() }

    func terminateSession() { terminalView.terminateSession() }

    func setSurfaceFocused(_ focused: Bool) { terminalView.setFocused(focused) }

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
        guard mode == .owner, let container else { return }
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

    public func copySelectionToPasteboard() -> Bool { terminalView.copySelectionToPasteboard() }

    public func pasteClipboardContents() -> Bool { terminalView.pasteClipboardContents() }

    @discardableResult public func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        terminalView.sendScroll(horizontal: horizontal, vertical: vertical)
    }

    public var debugSurfaceRefreshRequestCount: Int { terminalView.debugSurfaceRefreshRequestCount }
}

@MainActor public final class GhosttyEmbeddedSessionRegistry {
    public static let shared = GhosttyEmbeddedSessionRegistry()

    private var hosts: [String: GhosttyEmbeddedSessionHost] = [:]

    private init() {}

    public func host(for launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) -> GhosttyEmbeddedSessionHost {
        if let existing = hosts[launchConfiguration.sessionID] { return existing }
        let created = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        hosts[launchConfiguration.sessionID] = created
        return created
    }

    public func existingHost(sessionID: String) -> GhosttyEmbeddedSessionHost? { hosts[sessionID] }

    public func terminate(sessionID: String) {
        guard let host = hosts.removeValue(forKey: sessionID) else { return }
        host.terminate()
    }

    public func terminateAll() { for sessionID in Array(hosts.keys) { terminate(sessionID: sessionID) } }
}

@MainActor public final class GhosttyEmbeddedSessionHost {
    private static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let incomingOutputCoalescingInterval: Duration = .milliseconds(16)

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
    private let terminalView: GhosttyEmbeddedTerminalView
    private lazy var rendererHostStorage = GhosttyEmbeddedRendererHost(launchConfiguration: launchConfiguration, terminalView: terminalView)
    private let requestSurfaceRefreshAction: @MainActor () -> Void
    private var runtimeStateTimer: Timer?
    private var controlServer: TerminalControlServer?
    private var outputHandle: FileHandle?
    private var started = false
    private var currentTitle: String?
    private var currentWorkingDirectory: String?
    private var lastKnownChildPID: Int32?
    private var lastKnownSurfaceSize: (columns: Int, rows: Int)?
    private var lastPersistedRuntimeState: TerminalSessionRuntimeState?
    private var lastRuntimeStateWriteAt: Date?
    private var sessionStartedAt: Date?
    private var didLogFirstOutput = false
    private let incomingOutputBuffer = IncomingOutputBuffer()

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        requestSurfaceRefreshAction: (@MainActor () -> Void)? = nil
    ) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        controlQueue = DispatchQueue(label: "spaces.terminal.session-host.control.\(launchConfiguration.sessionID)")
        terminalView = GhosttyEmbeddedTerminalView(launchConfiguration: launchConfiguration)
        self.requestSurfaceRefreshAction = requestSurfaceRefreshAction ?? { [terminalView] in terminalView.requestSurfaceRefresh() }
        terminalView.onActionEvent = { [weak self] event in self?.applyActionEvent(event) }
        terminalView.onSurfaceCellSizeChanged = { [weak self] columns, rows in
            guard let self else { return }
            self.lastKnownSurfaceSize = (columns, rows)
            self.refreshRuntimeState(force: true)
        }
        rendererHostStorage.setOwnerClientResolver { [weak self] clientID in self?.isOwner(clientID: clientID) ?? false }
    }

    public func startIfNeeded() throws {
        guard !started else { return }
        let startedAt = Date()
        do {
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            try ensureOutputHandle()
            rendererHostStorage.setOutputHandler { [weak self] data in self?.enqueueIncomingOutput(data) }
            rendererHostStorage.ensureHostingWindowForSurface()
            try startControlServer()
            startRuntimeStateTimer()
            refreshRuntimeState(force: true)
            started = true
            sessionStartedAt = startedAt
            didLogFirstOutput = false
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

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
        let startedAt = Date()
        do {
            try startIfNeeded()
            try rendererHostStorage.attach(client: client, mode: mode, into: container)
            let activeAttachments = (try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []
            let currentAttachment = activeAttachments.first { $0.clientID == client.id }
            if currentAttachment?.mode != mode {
                try TerminalSessionPersistence.attachClient(
                    sessionID: launchConfiguration.sessionID, client: client, mode: mode, paths: paths,
                    attachedAt: ISO8601DateFormatter().string(from: Date()))
                postAttachmentStateDidChange()
            }
            if mode == .owner, let container {
                rendererHostStorage.requestSurfaceRefresh()
                rendererHostStorage.focusWindow(container.window)
            }
            refreshRuntimeState(force: true)
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

    public func detach(clientID: String) throws {
        let detachedClientWasOwner = isOwner(clientID: clientID)
        try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
        let remainingOwnerClientID = activeOwnerClientID()
        if Self.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: detachedClientWasOwner, remainingOwnerClientID: remainingOwnerClientID) {
            rendererHostStorage.setSurfaceFocused(false)
        }
        if remainingOwnerClientID == nil, hasRenderableSurface() { rendererHostStorage.parkSurfaceInHiddenHostWindow() }
        postAttachmentStateDidChange()
        refreshRuntimeState(force: true)
    }

    public func takeover(client: TerminalClient, into container: NSView?) throws { try attach(client: client, mode: .owner, into: container) }

    public func parkSurfaceInHiddenHostWindow() { rendererHostStorage.parkSurfaceInHiddenHostWindow() }

    public func setFocused(_ focused: Bool, for clientID: String) { rendererHostStorage.setFocused(focused, for: clientID) }

    public func isOwner(clientID: String) -> Bool {
        ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).contains { $0.clientID == clientID && $0.mode == .owner }
    }

    public func activeOwnerClientID() -> String? {
        ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
    }

    public var rendererHost: any TerminalGhosttyRendererHosting { rendererHostStorage }
    public func focusWindow(_ window: NSWindow?) { rendererHostStorage.focusWindow(window) }
    public func hasRenderableSurface() -> Bool { rendererHostStorage.hasRenderableSurface() }
    public var prefersOutputFallbackWhenSurfaceUnavailable: Bool { rendererHostStorage.prefersOutputFallbackWhenSurfaceUnavailable }
    public func snapshot() -> GhosttyTerminalSnapshot? { rendererHostStorage.snapshot() }
    public func snapshotText() -> String? { rendererHostStorage.snapshotText() }
    public func copySelectionToPasteboard() -> Bool { rendererHostStorage.copySelectionToPasteboard() }
    public func pasteClipboardContents() -> Bool { rendererHostStorage.pasteClipboardContents() }
    @discardableResult public func debugSendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        rendererHostStorage.debugSendScroll(horizontal: horizontal, vertical: vertical)
    }
    public var debugSurfaceRefreshRequestCount: Int { rendererHostStorage.debugSurfaceRefreshRequestCount }
    public func terminate() {
        let now = ISO8601DateFormatter().string(from: Date())
        let childPID = observedChildPID()
        runtimeStateTimer?.invalidate()
        runtimeStateTimer = nil
        controlServer?.stop()
        controlServer = nil
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

    func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
        switch request.command {
        case "attach": controlResponseForAttachRequest(request)
        case "detach": controlResponseForDetachRequest(request)
        case "heartbeat": controlResponseForHeartbeatRequest(request)
        case "send": controlResponseForSendRequest(request)
        case "key": controlResponseForKeyRequest(request)
        case "takeover": controlResponseForTakeoverRequest(request)
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
            try TerminalSessionPersistence.transferOwnership(
                sessionID: launchConfiguration.sessionID, newOwnerClientID: clientID, paths: paths,
                transferredAt: ISO8601DateFormatter().string(from: Date()))
            postAttachmentStateDidChange()
            refreshRuntimeState(force: true)
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
        let state = TerminalSessionRuntimeState(
            sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: observedChildPID(),
            state: .running, updatedAt: ISO8601DateFormatter().string(from: now), title: effectiveTitle, workingDirectory: effectiveWorkingDirectory,
            columns: observedSurfaceSize()?.columns, rows: observedSurfaceSize()?.rows)
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
        let detachedAt = ISO8601DateFormatter().string(from: now)
        for clientID in staleClientIDs { try? TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: detachedAt) }
        let remainingOwnerClientID = activeOwnerClientID()
        if Self.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: remainingOwnerClientID) {
            rendererHostStorage.setSurfaceFocused(false)
        }
        if remainingOwnerClientID == nil, hasRenderableSurface() { rendererHostStorage.parkSurfaceInHiddenHostWindow() }
        postAttachmentStateDidChange()
        refreshRuntimeState(force: true)
        return staleClientIDs
    }

    private func appendOutput(_ data: Data) {
        let startedAt = Date()
        do {
            let outputHandle = try ensureOutputHandle()
            try outputHandle.write(contentsOf: data)
            postOutputDidChange(byteCount: data.count)
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
        case .setTitle(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            currentTitle = trimmed.isEmpty ? nil : trimmed
        case .setWorkingDirectory(let path):
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            currentWorkingDirectory = trimmed.isEmpty ? nil : trimmed
        }
        postSessionMetadataDidChange()
        refreshRuntimeState(force: true)
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
    }

    private func postSessionMetadataDidChange() {
        NotificationCenter.default.post(
            name: .spacesTerminalSessionMetadataDidChange, object: nil, userInfo: ["sessionID": launchConfiguration.sessionID])
    }

    private func postRuntimeStateDidChange() {
        NotificationCenter.default.post(
            name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": launchConfiguration.sessionID])
    }

    private func postOutputDidChange(byteCount: Int) {
        NotificationCenter.default.post(
            name: .spacesTerminalOutputDidChange, object: nil, userInfo: ["sessionID": launchConfiguration.sessionID, "byteCount": byteCount])
    }

    private func nowISO8601() -> String { ISO8601DateFormatter().string(from: Date()) }

    private static func clientForAttachLease(_ client: TerminalClient, attachedAt: String) -> TerminalClient {
        guard client.kind != .localWindow else { return client }
        return TerminalClient(id: client.id, kind: client.kind, identity: client.identity, connectedAt: attachedAt, disconnectedAt: nil)
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

    var debugCurrentTitle: String? { currentTitle }
    var debugCurrentWorkingDirectory: String? { currentWorkingDirectory }
    func debugHandleIncomingOutput(_ data: Data) {
        requestSurfaceRefreshAction()
        appendOutput(data)
    }
    func debugPersistRuntimeState(force: Bool = true) { refreshRuntimeState(force: force) }
    func debugSetLastKnownChildPID(_ pid: Int32?) { lastKnownChildPID = pid }
}

extension GhosttyEmbeddedSessionHost: TerminalGhosttySessionHosting {}
