import AppKit
import Foundation
import spacesterminalcore

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
    private var runtimeStateTimer: Timer?
    private var controlServer: TerminalControlServer?
    private var outputHandle: FileHandle?
    private var started = false
    private var currentTitle: String?
    private var currentWorkingDirectory: String?
    private var lastKnownChildPID: Int32?

    public init(launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        controlQueue = DispatchQueue(label: "spaces.terminal.session-host.control.\(launchConfiguration.sessionID)")
        terminalView = GhosttyEmbeddedTerminalView(launchConfiguration: launchConfiguration)
        terminalView.onActionEvent = { [weak self] event in self?.applyActionEvent(event) }
    }

    public func startIfNeeded() throws {
        guard !started else { return }
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
        FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
        outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
        try outputHandle?.seekToEnd()
        terminalView.setOutputHandler { [weak self] data in Task { @MainActor [weak self] in self?.appendOutput(data) } }
        try startControlServer()
        startRuntimeStateTimer()
        refreshRuntimeState()
        started = true
    }

    public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
        try startIfNeeded()
        let activeAttachments = (try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []
        let currentAttachment = activeAttachments.first { $0.clientID == client.id }
        if currentAttachment?.mode != mode {
            try TerminalSessionPersistence.attachClient(
                sessionID: launchConfiguration.sessionID, client: client, mode: mode, paths: paths,
                attachedAt: ISO8601DateFormatter().string(from: Date()))
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
            focusWindow(container.window)
        }
        refreshRuntimeState()
    }

    public func detach(clientID: String) throws {
        try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
        if !isOwner(clientID: clientID) { terminalView.setFocused(false) }
        refreshRuntimeState()
    }

    public func takeover(client: TerminalClient, into container: NSView?) throws { try attach(client: client, mode: .owner, into: container) }

    public func setFocused(_ focused: Bool, for clientID: String) {
        guard isOwner(clientID: clientID) else {
            terminalView.setFocused(false)
            return
        }
        terminalView.setFocused(focused)
    }

    public func focusWindow(_ window: NSWindow?) {
        guard let window else { return }
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
                        if let clientID = request.clientID, !self.isOwner(clientID: clientID) {
                            return TerminalControlResponse(ok: false, message: "Only the active owner can send input.")
                        }
                        guard let text = request.text else { return TerminalControlResponse(ok: false, message: "Missing text payload.") }
                        let payload = text + (request.appendNewline ? "\n" : "")
                        self.terminalView.sendRawBytes(Data(payload.utf8))
                        return TerminalControlResponse(ok: true, message: "Sent input.")
                    case "key":
                        if let clientID = request.clientID, !self.isOwner(clientID: clientID) {
                            return TerminalControlResponse(ok: false, message: "Only the active owner can send keys.")
                        }
                        guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
                            return TerminalControlResponse(ok: false, message: "Unsupported terminal key.")
                        }
                        self.terminalView.sendRawBytes(Data(bytes))
                        return TerminalControlResponse(ok: true, message: "Sent key.")
                    case "takeover":
                        guard let clientID = request.clientID else { return TerminalControlResponse(ok: false, message: "Missing client ID.") }
                        do {
                            try TerminalSessionPersistence.transferOwnership(
                                sessionID: self.launchConfiguration.sessionID, newOwnerClientID: clientID, paths: self.paths,
                                transferredAt: ISO8601DateFormatter().string(from: Date()))
                            self.refreshRuntimeState()
                            return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
                        } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
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
        runtimeStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshRuntimeState() }
        }
        if let runtimeStateTimer { RunLoop.main.add(runtimeStateTimer, forMode: .common) }
    }

    private func refreshRuntimeState() {
        try? TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: observedChildPID(),
                state: .running, updatedAt: ISO8601DateFormatter().string(from: Date())), paths: paths)
    }

    private func appendOutput(_ data: Data) {
        guard let outputHandle = outputHandle else { return }
        do {
            try outputHandle.write(contentsOf: data)
            try outputHandle.synchronize()
        } catch { fputs("spaces: ghostty output write failed: \(error)\n", stderr) }
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
        refreshRuntimeState()
    }

    private func observedChildPID() -> Int32? {
        if let foregroundPID = terminalView.foregroundPID() {
            lastKnownChildPID = foregroundPID
            return foregroundPID
        }
        return lastKnownChildPID
    }

    var debugCurrentTitle: String? { currentTitle }
    var debugCurrentWorkingDirectory: String? { currentWorkingDirectory }
}
