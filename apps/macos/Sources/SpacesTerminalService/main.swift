import AppKit
import Dispatch
import Foundation
import spacesterminalcore
import spacesterminalghostty

@MainActor private final class SpacesTerminalServiceController {
    private let socketPath: String
    private let serverQueue = DispatchQueue(label: "spaces.terminal.service")
    private lazy var server = TerminalServiceServer(socketPath: socketPath, queue: serverQueue) { [weak self] request in
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let self else { return TerminalServiceResponse(ok: false, message: "Terminal service is shutting down.") }
                return self.handle(request)
            }
        }
    }
    private var hosts: [String: GhosttyEmbeddedSessionHost] = [:]
    private var lifecycleTimer: Timer?

    init() throws { socketPath = try TerminalServicePaths.socketPath() }

    func start() throws {
        try recoverStaleSessions()
        try server.start()
        startLifecycleTimer()
    }

    func shutdown() {
        lifecycleTimer?.invalidate()
        lifecycleTimer = nil
        for sessionID in Array(hosts.keys) { _ = terminateSession(id: sessionID) }
        server.stop()
    }

    private func handle(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        switch request.command {
        case "ping": return TerminalServiceResponse(ok: true, message: "pong")
        case "create":
            guard let launchConfiguration = request.launchConfiguration else {
                return TerminalServiceResponse(ok: false, message: "Missing terminal launch configuration.")
            }
            return createSession(launchConfiguration)
        case "terminate":
            guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                return TerminalServiceResponse(ok: false, message: "Missing session ID.")
            }
            return terminateSession(id: sessionID)
        case "list": return listSessions()
        default: return TerminalServiceResponse(ok: false, message: "Unsupported terminal service command '\(request.command)'.")
        }
    }

    private func createSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) -> TerminalServiceResponse {
        do {
            let host = try host(for: launchConfiguration)
            try host.startIfNeeded()
            return TerminalServiceResponse(
                ok: true, message: "Started terminal session \(launchConfiguration.sessionID).",
                session: try sessionSummary(for: launchConfiguration.sessionID))
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error)) }
    }

    private func listSessions() -> TerminalServiceResponse {
        do {
            let configurations = try TerminalSessionPersistence.listKnownSessions()
            let sessions = try configurations.compactMap { configuration in try summaryIfLive(for: configuration) }
            return TerminalServiceResponse(ok: true, message: "Listed terminal sessions.", sessions: sessions)
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error)) }
    }

    private func terminateSession(id sessionID: String) -> TerminalServiceResponse {
        do {
            if let host = hosts.removeValue(forKey: sessionID) {
                host.terminate()
                return TerminalServiceResponse(
                    ok: true, message: "Stopped terminal session \(sessionID).", session: try? sessionSummary(for: sessionID))
            }

            if let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(
                paths: try TerminalSessionPaths.forSession(id: sessionID))
            {
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let now = ISO8601DateFormatter().string(from: Date())
                let runtimeState =
                    (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
                    ?? TerminalSessionRuntimeState(
                        sessionID: sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: nil, state: .exited,
                        updatedAt: now, exitedAt: now, title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory)
                let exitedState = TerminalSessionRuntimeState(
                    sessionID: runtimeState.sessionID, backend: runtimeState.backend, servicePID: runtimeState.servicePID,
                    childPID: runtimeState.childPID, state: .exited, updatedAt: now, exitedAt: now,
                    title: runtimeState.title ?? launchConfiguration.title,
                    workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                    rows: runtimeState.rows)
                try? TerminalSessionPersistence.writeRuntimeState(exitedState, paths: paths)
                try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
            }
            return TerminalServiceResponse(ok: true, message: "Terminal session \(sessionID) is not active.")
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error)) }
    }

    private func host(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> GhosttyEmbeddedSessionHost {
        if let existing = hosts[launchConfiguration.sessionID] { return existing }
        let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
        let created = GhosttyEmbeddedSessionHost(launchConfiguration: launchConfiguration, paths: paths)
        hosts[launchConfiguration.sessionID] = created
        return created
    }

    private func sessionSummary(for sessionID: String) throws -> TerminalServiceSessionSummary {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let launchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        return try summary(for: launchConfiguration, paths: paths)
    }

    private func summaryIfLive(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary? {
        let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath), FileManager.default.fileExists(atPath: paths.statePath) else {
            return nil
        }
        guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return nil }
        guard runtimeState.state == .starting || runtimeState.state == .running else { return nil }
        guard Self.isProcessAlive(pid: Int(runtimeState.servicePID)) else { return nil }
        return try summary(for: launchConfiguration, paths: paths)
    }

    private func summary(for launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) throws
        -> TerminalServiceSessionSummary
    {
        let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
        return TerminalServiceSessionSummary(
            id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
            workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
            lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
            childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
    }

    private func startLifecycleTimer() {
        lifecycleTimer?.invalidate()
        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.reapInactiveSessions() }
        }
        if let lifecycleTimer { RunLoop.main.add(lifecycleTimer, forMode: .common) }
    }

    private func reapInactiveSessions() {
        for (sessionID, host) in hosts {
            guard host.launchConfiguration.lifetimePolicy == .whileAttached else { continue }
            guard let liveAttachments = try? TerminalSessionPersistence.liveAttachments(paths: host.paths), liveAttachments.isEmpty else { continue }
            _ = terminateSession(id: sessionID)
        }
    }

    private func recoverStaleSessions() throws {
        for launchConfiguration in try TerminalSessionPersistence.listKnownSessions() {
            let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
            guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { continue }
            guard runtimeState.state == .starting || runtimeState.state == .running else { continue }
            guard !Self.isProcessAlive(pid: Int(runtimeState.servicePID)) else { continue }

            let now = ISO8601DateFormatter().string(from: Date())
            let failedState = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: runtimeState.childPID,
                state: .failed, updatedAt: now, exitedAt: now, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                rows: runtimeState.rows)
            try? TerminalSessionPersistence.writeRuntimeState(failedState, paths: paths)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
        }
    }

    private static func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}

@MainActor private final class SpacesTerminalServiceAppDelegate: NSObject, NSApplicationDelegate {
    private let controller: SpacesTerminalServiceController

    init(controller: SpacesTerminalServiceController) { self.controller = controller }

    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
}

@main struct SpacesTerminalServiceMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        do {
            let controller = try MainActor.assumeIsolated { try SpacesTerminalServiceController() }
            let delegate = SpacesTerminalServiceAppDelegate(controller: controller)
            app.delegate = delegate
            try MainActor.assumeIsolated { try controller.start() }
            app.run()
        } catch {
            fputs("spaces-terminal-service: \(error)\n", stderr)
            exit(1)
        }
    }
}
