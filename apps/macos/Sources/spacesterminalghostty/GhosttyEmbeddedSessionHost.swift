import AppKit
import Foundation
import spacesterminalcore

extension Notification.Name {
    public static let spacesTerminalAttachmentStateDidChange = Notification.Name("spaces.terminal.attachment-state-did-change")
    public static let spacesTerminalSessionMetadataDidChange = Notification.Name("spaces.terminal.session-metadata-did-change")
    public static let spacesTerminalRuntimeStateDidChange = Notification.Name("spaces.terminal.runtime-state-did-change")
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
}

@MainActor public final class GhosttyEmbeddedSessionHost {
    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let paths: TerminalSessionPaths

    private let controlQueue: DispatchQueue
    private let terminalView: GhosttyEmbeddedTerminalView
    private let requestSurfaceRefreshAction: @MainActor () -> Void
    private var runtimeStateTimer: Timer?
    private var controlServer: TerminalControlServer?
    private var outputHandle: FileHandle?
    private var started = false
    private var currentTitle: String?
    private var currentWorkingDirectory: String?
    private var lastKnownChildPID: Int32?
    private var lastPersistedRuntimeState: TerminalSessionRuntimeState?
    private var lastRuntimeStateWriteAt: Date?
    private var sessionStartedAt: Date?
    private var didLogFirstOutput = false

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
    }

    public func startIfNeeded() throws {
        guard !started else { return }
        let startedAt = Date()
        do {
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            try ensureOutputHandle()
            terminalView.setOutputHandler { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.requestSurfaceRefreshAction()
                    self?.appendOutput(data)
                }
            }
            terminalView.ensureHostingWindowForSurface()
            try startControlServer()
            startRuntimeStateTimer()
            refreshRuntimeState(force: true)
            started = true
            sessionStartedAt = startedAt
            didLogFirstOutput = false
            GhosttyEmbeddedPerformance.logMetric(
                "terminal_session_start", target: "session=\(launchConfiguration.sessionID) backend=\(launchConfiguration.backend.rawValue)",
                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: true)
        } catch {
            GhosttyEmbeddedPerformance.logMetric(
                "terminal_session_start", target: "session=\(launchConfiguration.sessionID) backend=\(launchConfiguration.backend.rawValue)",
                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: false)
            throw error
        }
    }

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
        let startedAt = Date()
        do {
            try startIfNeeded()
            let activeAttachments = (try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []
            let currentAttachment = activeAttachments.first { $0.clientID == client.id }
            if currentAttachment?.mode != mode {
                try TerminalSessionPersistence.attachClient(
                    sessionID: launchConfiguration.sessionID, client: client, mode: mode, paths: paths,
                    attachedAt: ISO8601DateFormatter().string(from: Date()))
                postAttachmentStateDidChange()
            }
            if mode == .owner, let container {
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
                terminalView.requestSurfaceRefresh()
                focusWindow(container.window)
            }
            refreshRuntimeState(force: true)
            GhosttyEmbeddedPerformance.logMetric(
                "terminal_window_attach", target: "session=\(launchConfiguration.sessionID) client=\(client.id)",
                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: true, detail: "mode=\(mode.rawValue)")
        } catch {
            GhosttyEmbeddedPerformance.logMetric(
                "terminal_window_attach", target: "session=\(launchConfiguration.sessionID) client=\(client.id)",
                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: false, detail: "mode=\(mode.rawValue)")
            throw error
        }
    }

    public func detach(clientID: String) throws {
        try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
        if !isOwner(clientID: clientID) { terminalView.setFocused(false) }
        if activeOwnerClientID() == nil, hasRenderableSurface() { terminalView.parkInHiddenHostWindowIfNeeded() }
        postAttachmentStateDidChange()
        refreshRuntimeState(force: true)
    }

    public func takeover(client: TerminalClient, into container: NSView?) throws { try attach(client: client, mode: .owner, into: container) }

    public func parkSurfaceInHiddenHostWindow() {
        guard hasRenderableSurface() else { return }
        terminalView.parkInHiddenHostWindowIfNeeded()
    }

    public func setFocused(_ focused: Bool, for clientID: String) {
        guard isOwner(clientID: clientID) else {
            terminalView.setFocused(false)
            return
        }
        terminalView.setFocused(focused)
    }

    public func focusWindow(_ window: NSWindow?) {
        guard let window else { return }
        if !window.isVisible { window.orderFront(nil) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(terminalView)
        terminalView.setFocused(window.isKeyWindow)
    }

    public func isOwner(clientID: String) -> Bool {
        ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).contains { $0.clientID == clientID && $0.mode == .owner }
    }

    public func activeOwnerClientID() -> String? {
        ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
    }

    public func hasRenderableSurface() -> Bool { terminalView.surface != nil }
    public func copySelectionToPasteboard() -> Bool { terminalView.copySelectionToPasteboard() }
    public func pasteClipboardContents() -> Bool { terminalView.pasteClipboardContents() }

    public func childPID() -> Int32? { observedChildPID() }
    public var effectiveTitle: String { currentTitle ?? launchConfiguration.title }
    public var effectiveWorkingDirectory: String { currentWorkingDirectory ?? launchConfiguration.workingDirectory }

    private func startControlServer() throws {
        let controlServer = TerminalControlServer(socketPath: paths.controlSocketPath, queue: controlQueue) { [weak self] request in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self else { return TerminalControlResponse(ok: false, message: "Terminal session is shutting down.") }
                    switch request.command {
                    case "send":
                        let startedAt = Date()
                        if let clientID = request.clientID, !self.isOwner(clientID: clientID) {
                            GhosttyEmbeddedPerformance.logMetric(
                                "terminal_control_send", target: "session=\(self.launchConfiguration.sessionID)",
                                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: false)
                            return TerminalControlResponse(ok: false, message: "Only the active owner can send input.")
                        }
                        guard let text = request.text else { return TerminalControlResponse(ok: false, message: "Missing text payload.") }
                        let payload = text + (request.appendNewline ? "\n" : "")
                        self.terminalView.sendRawBytes(Data(payload.utf8))
                        GhosttyEmbeddedPerformance.logMetric(
                            "terminal_control_send", target: "session=\(self.launchConfiguration.sessionID)",
                            elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: true, detail: "bytes=\(payload.utf8.count)")
                        return TerminalControlResponse(ok: true, message: "Sent input.")
                    case "key":
                        let startedAt = Date()
                        if let clientID = request.clientID, !self.isOwner(clientID: clientID) {
                            GhosttyEmbeddedPerformance.logMetric(
                                "terminal_control_key", target: "session=\(self.launchConfiguration.sessionID)",
                                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: false)
                            return TerminalControlResponse(ok: false, message: "Only the active owner can send keys.")
                        }
                        guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
                            GhosttyEmbeddedPerformance.logMetric(
                                "terminal_control_key", target: "session=\(self.launchConfiguration.sessionID)",
                                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: false)
                            return TerminalControlResponse(ok: false, message: "Unsupported terminal key.")
                        }
                        self.terminalView.sendRawBytes(Data(bytes))
                        GhosttyEmbeddedPerformance.logMetric(
                            "terminal_control_key", target: "session=\(self.launchConfiguration.sessionID)",
                            elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: true, detail: "key=\(key)")
                        return TerminalControlResponse(ok: true, message: "Sent key.")
                    case "takeover":
                        let startedAt = Date()
                        guard let clientID = request.clientID else { return TerminalControlResponse(ok: false, message: "Missing client ID.") }
                        do {
                            try TerminalSessionPersistence.transferOwnership(
                                sessionID: self.launchConfiguration.sessionID, newOwnerClientID: clientID, paths: self.paths,
                                transferredAt: ISO8601DateFormatter().string(from: Date()))
                            self.postAttachmentStateDidChange()
                            self.refreshRuntimeState(force: true)
                            GhosttyEmbeddedPerformance.logMetric(
                                "terminal_control_takeover", target: "session=\(self.launchConfiguration.sessionID) client=\(clientID)",
                                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: true)
                            return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
                        } catch {
                            GhosttyEmbeddedPerformance.logMetric(
                                "terminal_control_takeover", target: "session=\(self.launchConfiguration.sessionID) client=\(clientID)",
                                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: false)
                            return TerminalControlResponse(ok: false, message: String(describing: error))
                        }
                    default: return TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(request.command)'.")
                    }
                }
            }
        }
        try controlServer.start()
        self.controlServer = controlServer
    }

    private func startRuntimeStateTimer() {
        runtimeStateTimer?.invalidate()
        runtimeStateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshRuntimeState(force: false) }
        }
        if let runtimeStateTimer { RunLoop.main.add(runtimeStateTimer, forMode: .common) }
    }

    private func refreshRuntimeState(force: Bool) {
        let now = Date()
        let observedChildPID = observedChildPID()
        let runtimeState: TerminalSessionState = observedChildPID == nil && hasExitedChildProcess() ? .exited : .running
        let state = TerminalSessionRuntimeState(
            sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(),
            childPID: observedChildPID ?? (runtimeState == .exited ? lastKnownChildPID : nil), state: runtimeState,
            updatedAt: ISO8601DateFormatter().string(from: now), exitedAt: runtimeState == .exited ? ISO8601DateFormatter().string(from: now) : nil)
        let shouldPersist = force || shouldPersistRuntimeState(state, now: now)
        guard shouldPersist else { return }
        let previousSignature = lastPersistedRuntimeState.map(runtimeStateSignature(for:))
        let nextSignature = runtimeStateSignature(for: state)
        try? TerminalSessionPersistence.writeRuntimeState(state, paths: paths)
        lastPersistedRuntimeState = state
        lastRuntimeStateWriteAt = now
        if previousSignature != nextSignature { postRuntimeStateDidChange() }
    }

    private func appendOutput(_ data: Data) {
        do {
            let outputHandle = try ensureOutputHandle()
            try outputHandle.write(contentsOf: data)
            try outputHandle.synchronize()
            if !didLogFirstOutput, !data.isEmpty {
                didLogFirstOutput = true
                if let sessionStartedAt {
                    GhosttyEmbeddedPerformance.logMetric(
                        "terminal_first_output", target: "session=\(launchConfiguration.sessionID)",
                        elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: sessionStartedAt), success: true, detail: "bytes=\(data.count)")
                }
            }
        } catch { fputs("spaces: ghostty output write failed: \(error)\n", stderr) }
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
        if let foregroundPID = terminalView.foregroundPID() {
            lastKnownChildPID = foregroundPID
            return foregroundPID
        }
        if hasExitedChildProcess() { return nil }
        return lastKnownChildPID
    }

    private func hasExitedChildProcess() -> Bool {
        guard let childPID = lastKnownChildPID else { return false }
        return kill(childPID, 0) != 0 && errno == ESRCH
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

    private func shouldPersistRuntimeState(_ state: TerminalSessionRuntimeState, now: Date) -> Bool {
        if let lastPersistedRuntimeState, runtimeStateSignature(for: lastPersistedRuntimeState) != runtimeStateSignature(for: state) { return true }
        guard let lastRuntimeStateWriteAt else { return true }
        return now.timeIntervalSince(lastRuntimeStateWriteAt) >= 5
    }

    private func runtimeStateSignature(for state: TerminalSessionRuntimeState) -> String {
        "\(state.sessionID)|\(state.backend.rawValue)|\(state.servicePID)|\(state.childPID.map(String.init) ?? "nil")|\(state.state.rawValue)|\(state.exitedAt ?? "nil")"
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
