import AppKit
import Dispatch
import Foundation
import spacesmobilebridge
import spacesterminalcore
import spacesterminalghostty
import workspacecore

@MainActor private final class SpacesDaemonController {
    private let socketPath: String
    private let serverQueue = DispatchQueue(label: "spaces.terminal.service")
    private lazy var server = TerminalServiceServer(socketPath: socketPath, queue: serverQueue) { [weak self] request in
        Self.runOnMainActorSynchronously {
            guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.") }
            return self.handle(request)
        }
    }
    private lazy var remoteServer: TerminalServiceTLSServer? = {
        let environment = ProcessInfo.processInfo.environment
        guard let portValue = environment["SPACESD_LISTEN_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines), let port = Int(portValue) else {
            return nil
        }
        let configuredHost = environment["SPACESD_LISTEN_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        if let configuredHost, !configuredHost.isEmpty { host = configuredHost } else { host = "0.0.0.0" }
        let configuredAuthToken = environment["SPACESD_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authToken = configuredAuthToken?.isEmpty == false ? configuredAuthToken : nil
        let identity: TerminalServiceTLSIdentity
        do { identity = try TerminalServiceTLSIdentityStore.loadOrCreate() } catch {
            remoteServerLoadError = error
            return nil
        }
        fputs("spacesd: remote listener fingerprint=\(identity.certificateFingerprint)\n", stderr)
        return TerminalServiceTLSServer(host: host, port: port, authToken: authToken, identity: identity, queue: serverQueue) { [weak self] request in
            Self.runOnMainActorSynchronously {
                guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.") }
                return self.handle(request)
            }
        }
    }()
    private var remoteServerLoadError: (any Error)?
    private var sessionCores: [String: GhosttyEmbeddedSessionCore] = [:]
    private var lifecycleTimer: Timer?
    private let mobileBridgeSupervisor = SpacesMobileBridgeSupervisor()
    private let git = GitClient()

    init() throws { socketPath = try TerminalServicePaths.socketPath() }

    func start() throws {
        try recoverStaleSessions()
        let configuredRemoteServer = remoteServer
        if let remoteServerLoadError { throw remoteServerLoadError }
        try server.start()
        try configuredRemoteServer?.start()
        mobileBridgeSupervisor.start()
        startLifecycleTimer()
    }

    func shutdown() {
        lifecycleTimer?.invalidate()
        lifecycleTimer = nil
        mobileBridgeSupervisor.stop()
        for sessionID in Array(sessionCores.keys) { _ = terminateSession(id: sessionID) }
        remoteServer?.stop()
        server.stop()
    }

    private func handle(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        switch request.command {
        case "ping": return TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid())
        case "shutdown":
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                NSApp.terminate(nil)
            }
            return TerminalServiceResponse(ok: true, message: "spacesd is shutting down.", servicePID: getpid())
        case "create":
            guard let launchConfiguration = request.launchConfiguration else {
                return TerminalServiceResponse(ok: false, message: "Missing terminal launch configuration.")
            }
            return createSession(launchConfiguration, request: request)
        case "prepareWorkspace":
            do {
                try prepareWorkspace(request: request, workingDirectory: request.runtimeManifest?.remotePath ?? request.runtimeManifest?.localPath)
                return TerminalServiceResponse(ok: true, message: "Workspace runtime is prepared.", servicePID: getpid())
            } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
        case "runWorkspaceCommand":
            guard let workspaceCommand = request.workspaceCommand else {
                return TerminalServiceResponse(ok: false, message: "Missing workspace command request.")
            }
            return runWorkspaceCommand(workspaceCommand, request: request)
        case "terminate":
            guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                return TerminalServiceResponse(ok: false, message: "Missing session ID.")
            }
            return terminateSession(id: sessionID)
        case "list": return listSessions()
        default: return TerminalServiceResponse(ok: false, message: "Unsupported spacesd command '\(request.command)'.")
        }
    }

    private func createSession(_ launchConfiguration: TerminalSessionLaunchConfiguration, request: TerminalServiceRequest) -> TerminalServiceResponse
    {
        do {
            try prepareWorkspace(request: request, workingDirectory: launchConfiguration.workingDirectory)
            let sessionCore = try sessionCore(for: launchConfiguration)
            try sessionCore.startIfNeeded()
            return TerminalServiceResponse(
                ok: true, message: "Started terminal session \(launchConfiguration.sessionID).",
                session: try sessionSummaryAfterStart(for: launchConfiguration.sessionID))
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error)) }
    }

    private func runWorkspaceCommand(_ workspaceCommand: TerminalServiceWorkspaceCommandRequest, request: TerminalServiceRequest)
        -> TerminalServiceResponse
    {
        do {
            try prepareWorkspace(request: request, workingDirectory: workspaceCommand.workingDirectory)
            let logPath = try workspaceCommandLogPath(workspaceCommand.logPath)
            let result = try runShellCommand(workspaceCommand, logPath: logPath, manifest: request.runtimeManifest)
            let message = result.exitCode == 0 ? "Workspace command completed." : "Workspace command exited with code \(result.exitCode)."
            return TerminalServiceResponse(ok: true, message: message, servicePID: getpid(), commandResult: result)
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func prepareWorkspace(request: TerminalServiceRequest, workingDirectory: String?) throws {
        if let manifest = request.runtimeManifest {
            if let workingDirectory { try validateWorkspacePath(workingDirectory, manifest: manifest) }
            if manifest.location == .remote { try prepareRemoteWorktree(manifest: manifest, refreshRequest: request.worktreeRefresh) }
        }
        if let refreshRequest = request.worktreeRefresh {
            _ = try git.refreshWorktreeFastForwardOnly(path: refreshRequest.path, branch: refreshRequest.branch, hostName: refreshRequest.hostName)
        }
    }

    private func prepareRemoteWorktree(manifest: TerminalServiceWorkspaceRuntimeManifest, refreshRequest: TerminalServiceWorktreeRefreshRequest?)
        throws
    {
        guard let remotePath = manifest.remotePath?.trimmingCharacters(in: .whitespacesAndNewlines), !remotePath.isEmpty else {
            throw WorkspaceError.invalidArgument(message: "Remote workspace path is missing.")
        }
        try validateWorkspacePath(remotePath, manifest: manifest)
        guard let branch = (refreshRequest?.branch ?? manifest.branch)?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else {
            return
        }
        let remotePathURL = URL(fileURLWithPath: remotePath, isDirectory: true)
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: remotePath, isDirectory: &isDirectory)
        if exists, git.isRepo(path: remotePath) { return }
        if exists, isDirectory.boolValue, try directoryIsEmpty(remotePathURL) {
            try cloneRemoteWorktree(manifest: manifest, branch: branch, remotePath: remotePath)
            return
        }
        if exists {
            throw RemoteWorktreeRefreshBlock(
                hostName: refreshRequest?.hostName ?? "remote host", path: remotePath, branch: branch, reason: .checkoutFailed,
                detail: "Remote workspace path exists but is not an empty Git worktree.")
        }
        try FileManager.default.createDirectory(at: remotePathURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cloneRemoteWorktree(manifest: manifest, branch: branch, remotePath: remotePath)
    }

    private func cloneRemoteWorktree(manifest: TerminalServiceWorkspaceRuntimeManifest, branch: String, remotePath: String) throws {
        guard let remoteURL = manifest.gitRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteURL.isEmpty else {
            throw RemoteWorktreeRefreshBlock(
                hostName: manifest.computeHostID ?? "remote host", path: remotePath, branch: branch, reason: .fetchFailed,
                detail: "Remote workspace path is missing and no Git remote URL was provided.")
        }
        _ = try git.runGitAndCapture(["clone", "--branch", branch, "--single-branch", remoteURL, remotePath], timeout: 120)
    }

    private func validateWorkspacePath(_ path: String, manifest: TerminalServiceWorkspaceRuntimeManifest) throws {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let allowedRoots = manifest.allowedFileRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard allowedRoots.contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") }) else {
            throw WorkspaceError.invalidArgument(message: "Path is outside the workspace runtime roots: \(path)")
        }
    }

    private func directoryIsEmpty(_ url: URL) throws -> Bool {
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return contents.isEmpty
    }

    private func workspaceCommandLogPath(_ requestedPath: String?) throws -> String {
        if let requestedPath = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedPath.isEmpty { return requestedPath }
        let root = try TerminalServicePaths.terminalRootDirectory().appendingPathComponent("workspace-commands", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(UUID().uuidString).log", isDirectory: false).path
    }

    private func runShellCommand(
        _ workspaceCommand: TerminalServiceWorkspaceCommandRequest, logPath: String, manifest: TerminalServiceWorkspaceRuntimeManifest?
    ) throws -> TerminalServiceCommandResult {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", workspaceCommand.command]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceCommand.workingDirectory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        if let manifest { environment.merge(manifest.processEnvironment) { _, new in new } }
        environment.merge(workspaceCommand.environment) { _, new in new }
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()
        try? logHandle.synchronize()
        return TerminalServiceCommandResult(exitCode: Int(process.terminationStatus), logPath: logPath)
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
            if let sessionCore = sessionCores.removeValue(forKey: sessionID) {
                sessionCore.terminate()
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
                if runtimeState.servicePID != getpid(), Self.isLive(runtimeState), Self.isProcessAlive(pid: Int(runtimeState.servicePID)) {
                    return TerminalServiceResponse(
                        ok: false, message: "Terminal session \(sessionID) is owned by another process and was not stopped by spacesd.")
                }
                let exitedState = TerminalSessionRuntimeState(
                    sessionID: runtimeState.sessionID, backend: runtimeState.backend, servicePID: runtimeState.servicePID,
                    childPID: runtimeState.childPID, state: .exited, updatedAt: now, exitedAt: now,
                    title: runtimeState.title ?? launchConfiguration.title,
                    workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                    rows: runtimeState.rows)
                try? TerminalSessionPersistence.writeRuntimeState(exitedState, paths: paths)
                try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
                try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
            }
            return TerminalServiceResponse(ok: true, message: "Terminal session \(sessionID) is not active.")
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error)) }
    }

    private func sessionCore(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> GhosttyEmbeddedSessionCore {
        if let existing = sessionCores[launchConfiguration.sessionID] { return existing }
        let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
        let created = GhosttyEmbeddedSessionCore(
            launchConfiguration: launchConfiguration, paths: paths,
            onSessionClosed: { [weak self] closedCore in
                let sessionID = closedCore.launchConfiguration.sessionID
                guard self?.sessionCores[sessionID] === closedCore else { return }
                self?.sessionCores.removeValue(forKey: sessionID)
            })
        sessionCores[launchConfiguration.sessionID] = created
        return created
    }

    private func sessionSummary(for sessionID: String) throws -> TerminalServiceSessionSummary {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let launchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        return try summary(for: launchConfiguration, paths: paths)
    }

    private func sessionSummaryAfterStart(for sessionID: String) throws -> TerminalServiceSessionSummary {
        let deadline = Date().addingTimeInterval(1)
        var lastError: (any Error)?
        repeat {
            do { return try sessionSummary(for: sessionID) } catch {
                lastError = error
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        } while Date() < deadline
        throw lastError ?? CocoaError(.fileReadUnknown)
    }

    private func summaryIfLive(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary? {
        let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
        guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return nil }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else { return nil }
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
            Task { @MainActor [weak self] in self?.reapInactiveSessions() }
        }
        if let lifecycleTimer { RunLoop.main.add(lifecycleTimer, forMode: .common) }
    }

    private func reapInactiveSessions() {
        for (sessionID, sessionCore) in sessionCores {
            guard sessionCore.launchConfiguration.lifetimePolicy == .whileAttached else { continue }
            guard let liveAttachments = try? TerminalSessionPersistence.liveAttachments(paths: sessionCore.paths), liveAttachments.isEmpty else {
                continue
            }
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
            try? TerminalSessionPersistence.detachActiveClients(paths: paths, detachedAt: now)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
        }
    }

    private static func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private static func isLive(_ runtimeState: TerminalSessionRuntimeState) -> Bool {
        runtimeState.state == .starting || runtimeState.state == .running
    }

    private static func errorMessage(_ error: any Error) -> String {
        if let localizedError = error as? any LocalizedError, let description = localizedError.errorDescription { return description }
        return String(describing: error)
    }

    private nonisolated static func runOnMainActorSynchronously<T: Sendable>(_ work: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        let box = MainActorSyncBox<T>()
        DispatchQueue.main.sync { box.value = MainActor.assumeIsolated { work() } }
        guard let value = box.value else { preconditionFailure("spacesd main-actor work did not return a value.") }
        return value
    }
}

private final class MainActorSyncBox<T>: @unchecked Sendable { var value: T? }

@MainActor private final class SpacesDaemonAppDelegate: NSObject, NSApplicationDelegate {
    private let controller: SpacesDaemonController

    init(controller: SpacesDaemonController) { self.controller = controller }

    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
}

@main struct SpacesDaemonMain {
    static func main() {
        if ProcessInfo.processInfo.environment["SPACESD_PRINT_CERTIFICATE_FINGERPRINT"] == "1" {
            do {
                print(try TerminalServiceTLSIdentityStore.loadOrCreate().certificateFingerprint)
                return
            } catch {
                fputs("spacesd: \(error)\n", stderr)
                exit(1)
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        do {
            let controller = try MainActor.assumeIsolated { try SpacesDaemonController() }
            let delegate = SpacesDaemonAppDelegate(controller: controller)
            app.delegate = delegate
            try MainActor.assumeIsolated { try controller.start() }
            app.run()
        } catch {
            fputs("spacesd: \(error)\n", stderr)
            exit(1)
        }
    }
}
