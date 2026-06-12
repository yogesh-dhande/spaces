import Dispatch
import Foundation
import spacesmobilecore
import spacesruntimecore
import spacesterminalcore
import spacesterminalghostty

#if canImport(AppKit)
    import AppKit
#endif

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(spacesmobilebridge)
    import spacesmobilebridge
#endif

@MainActor private final class SpacesDaemonController {
    private static let ownerGatedTerminalCommands: Set<String> = ["send", "key", "clearScreen", "resize", "scroll"]
    private static let terminalLinkTransferAuthorizationTTL: TimeInterval = 10 * 60

    private struct TerminalLinkTransferAuthorization {
        let sessionID: String
        let resolvedPath: String
        let expiresAt: Date
    }

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
        writeStandardError("spacesd: remote listener fingerprint=\(identity.certificateFingerprint)\n")
        return TerminalServiceTLSServer(host: host, port: port, authToken: authToken, identity: identity, queue: serverQueue) { [weak self] request in
            Self.runOnMainActorSynchronously {
                guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.") }
                return self.handle(request)
            }
        }
    }()
    private var remoteServerLoadError: (any Error)?
    private var sessionCores: [String: GhosttyEmbeddedSessionCore] = [:]
    private var terminalLinkTransferAuthorizations: [String: TerminalLinkTransferAuthorization] = [:]
    private var lifecycleTimer: Timer?
    private let mobileBridgeSupervisor = SpacesDaemonMobileBridgeSupervisor()
    private let git = RemoteWorkspaceGitClient()

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
                Self.terminateProcess()
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
        case "state": return loadTerminalState(request)
        case "control": return handleTerminalControl(request)
        case "agentSignal": return recordAgentSignal(request)
        case "ackAgentSignals": return acknowledgeAgentSignals(request)
        case "resolveTerminalLink": return resolveTerminalLink(request)
        case "readTerminalLinkChunk": return readTerminalLinkChunk(request)
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
            throw SpacesRuntimeError.invalidArgument(message: "Remote workspace path is missing.")
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
            throw RemoteWorkspaceRefreshBlock(
                hostName: refreshRequest?.hostName ?? "remote host", path: remotePath, branch: branch, reason: .checkoutFailed,
                detail: "Remote workspace path exists but is not an empty Git worktree.")
        }
        try FileManager.default.createDirectory(at: remotePathURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cloneRemoteWorktree(manifest: manifest, branch: branch, remotePath: remotePath)
    }

    private func cloneRemoteWorktree(manifest: TerminalServiceWorkspaceRuntimeManifest, branch: String, remotePath: String) throws {
        guard let remoteURL = manifest.gitRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteURL.isEmpty else {
            throw RemoteWorkspaceRefreshBlock(
                hostName: manifest.computeHostID ?? "remote host", path: remotePath, branch: branch, reason: .fetchFailed,
                detail: "Remote workspace path is missing and no Git remote URL was provided.")
        }
        _ = try git.runGitAndCapture(["clone", "--branch", branch, "--single-branch", remoteURL, remotePath], timeout: 120)
    }

    private func validateWorkspacePath(_ path: String, manifest: TerminalServiceWorkspaceRuntimeManifest) throws {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let allowedRoots = manifest.allowedFileRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard allowedRoots.contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") }) else {
            throw SpacesRuntimeError.invalidArgument(message: "Path is outside the workspace runtime roots: \(path)")
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
        _ = FileManager.default.createFile(atPath: logPath, contents: nil)
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

    private func loadTerminalState(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        guard let sessionID = request.sessionID, !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            return TerminalServiceResponse(
                ok: true, message: "Loaded terminal state.", sessionState: try loadCurrentState(sessionID: sessionID),
                agentSignals: try TerminalSessionPersistence.pendingAgentSignals(sessionID: sessionID, paths: paths))
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func recordAgentSignal(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        guard let event = request.agentSignal else { return TerminalServiceResponse(ok: false, message: "Missing agent signal event.") }
        guard !event.sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
        if let requestSessionID = request.sessionID, !requestSessionID.isEmpty, requestSessionID != event.sessionID {
            return TerminalServiceResponse(ok: false, message: "Agent signal session does not match request session.")
        }
        do {
            let paths = try TerminalSessionPaths.forSession(id: event.sessionID)
            try TerminalSessionPersistence.appendPendingAgentSignal(event, paths: paths)
            return TerminalServiceResponse(ok: true, message: "Queued agent signal.", agentSignals: [event])
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func acknowledgeAgentSignals(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        guard let sessionID = request.sessionID, !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
        do {
            try TerminalSessionPersistence.acknowledgeAgentSignals(
                ids: request.agentSignalEventIDs ?? [], sessionID: sessionID, paths: try TerminalSessionPaths.forSession(id: sessionID),
                acknowledgedAt: nowISO8601())
            return TerminalServiceResponse(ok: true, message: "Acknowledged agent signals.")
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func handleTerminalControl(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        guard let sessionID = request.sessionID, !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
        guard let controlRequest = request.controlRequest else {
            return TerminalServiceResponse(ok: false, message: "Missing terminal control request.")
        }
        if Self.ownerGatedTerminalCommands.contains(controlRequest.command),
            controlRequest.clientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            return TerminalServiceResponse(ok: false, message: "Missing mobile client ID.")
        }
        if let liveCore = sessionCores[sessionID] {
            let response = liveCore.handleControlRequest(controlRequest)
            return TerminalServiceResponse(ok: response.ok, message: response.message, controlResponse: response)
        }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                return TerminalServiceResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.")
            }
            guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
                return TerminalServiceResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.")
            }
            let response = try TerminalControlClient.send(request: controlRequest, socketPath: paths.controlSocketPath)
            return TerminalServiceResponse(ok: response.ok, message: response.message, controlResponse: response)
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func resolveTerminalLink(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        guard let sessionID = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.")
        }
        do {
            pruneTerminalLinkTransferAuthorizations(now: Date())
            let metadata: SpacesMobileTerminalLinkMetadata
            if canResolveTerminalLinkWithoutLocalState(request.terminalLink) {
                metadata = try SpacesMobileTerminalLinkResolver.resolve(
                    sessionID: sessionID, link: request.terminalLink, workingDirectory: nil, workspaceRoots: [])
            } else {
                let workingDirectory = try terminalWorkingDirectory(sessionID: sessionID)
                metadata = try SpacesMobileTerminalLinkResolver.resolve(
                    sessionID: sessionID, link: request.terminalLink, workingDirectory: workingDirectory, workspaceRoots: [workingDirectory])
            }
            if metadata.source == .localFile {
                let resolvedPath = try SpacesMobileTerminalLinkResolver.resolvedLocalFilePath(linkID: metadata.id)
                authorizeTerminalLinkTransfer(linkID: metadata.id, sessionID: sessionID, resolvedPath: resolvedPath, now: Date())
            }
            return TerminalServiceResponse(ok: true, message: "Resolved terminal link.", terminalLinkMetadata: terminalServiceLinkMetadata(metadata))
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func readTerminalLinkChunk(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        guard let sessionID = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.")
        }
        do {
            guard let linkID = request.terminalLinkID?.trimmingCharacters(in: .whitespacesAndNewlines), !linkID.isEmpty else {
                throw SpacesMobileTerminalLinkResolverError.invalidLinkID
            }
            guard let authorization = try terminalLinkTransferAuthorization(linkID: linkID, sessionID: sessionID, now: Date()) else {
                throw SpacesMobileTerminalLinkResolverError.invalidLinkID
            }
            let chunk = try SpacesMobileTerminalLinkResolver.readChunk(
                sessionID: sessionID, linkID: linkID, offset: request.chunkOffset, limit: request.chunkLimit,
                workspaceRoots: [authorization.resolvedPath])
            authorizeTerminalLinkTransfer(linkID: linkID, sessionID: sessionID, resolvedPath: authorization.resolvedPath, now: Date())
            return TerminalServiceResponse(ok: true, message: "Read terminal link chunk.", terminalLinkChunk: terminalServiceLinkChunk(chunk))
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
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
            childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath,
            launchConfiguration: launchConfiguration, runtimeState: runtimeState,
            attachmentSnapshot: (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot(),
            hasFinalRender: (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.renderSnapshot != nil)
    }

    private func loadCurrentState(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let liveCore = sessionCores[sessionID],
            let payload = liveCore.currentRemoteStatePayload(reason: TerminalRemoteSessionStateReason.stateChange)
        {
            return payload
        }
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            if let finalState = try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) { return finalState }
            return try endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState)
        }
        guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
            throw NSError(
                domain: "SpacesDaemonController", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' has no live state stream."])
        }

        let socketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
        defer {
            Self.shutdownSocket(socketFD)
            close(socketFD)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socketFD, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
            if let newlineIndex = data.firstIndex(of: 0x0A) {
                data.removeSubrange(newlineIndex..<data.endIndex)
                break
            }
        }

        guard !data.isEmpty else {
            throw NSError(
                domain: "SpacesDaemonController", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' did not return a state payload."])
        }
        return try GhosttyRemoteSessionStateCodec.decodeLine(data)
    }

    private func endedStatePayload(sessionID: String, paths: TerminalSessionPaths, runtimeState: TerminalSessionRuntimeState) throws
        -> GhosttyRemoteSessionStatePayload
    {
        let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot()
        let emittedAt = runtimeState.exitedAt ?? runtimeState.updatedAt
        return GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
            title: runtimeState.title ?? launchConfiguration?.title ?? sessionID,
            workingDirectory: runtimeState.workingDirectory ?? launchConfiguration?.workingDirectory ?? paths.rootDirectory, outputByteCount: nil)
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try setNoSIGPIPE(socketFD)
        var address = try makeUnixSocketAddress(path: path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        return socketFD
    }

    private func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
        }
        return address
    }

    private func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        #if canImport(Darwin)
            var yes: Int32 = 1
            guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        #else
            _ = fileDescriptor
        #endif
    }

    private var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }

    private func authorizeTerminalLinkTransfer(linkID: String, sessionID: String, resolvedPath: String, now: Date) {
        terminalLinkTransferAuthorizations[linkID] = TerminalLinkTransferAuthorization(
            sessionID: sessionID, resolvedPath: resolvedPath, expiresAt: now.addingTimeInterval(Self.terminalLinkTransferAuthorizationTTL))
    }

    private func terminalLinkTransferAuthorization(linkID: String, sessionID: String, now: Date) throws -> TerminalLinkTransferAuthorization? {
        pruneTerminalLinkTransferAuthorizations(now: now)
        guard let authorization = terminalLinkTransferAuthorizations[linkID] else { return nil }
        guard authorization.sessionID == sessionID else { throw SpacesMobileTerminalLinkResolverError.sessionMismatch }
        return authorization
    }

    private func pruneTerminalLinkTransferAuthorizations(now: Date) {
        terminalLinkTransferAuthorizations = terminalLinkTransferAuthorizations.filter { $0.value.expiresAt > now }
    }

    private func canResolveTerminalLinkWithoutLocalState(_ value: String?) -> Bool {
        guard let link = normalizedString(value), let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return scheme != "file"
    }

    private func terminalWorkingDirectory(sessionID: String) throws -> String {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let workingDirectory = normalizedString((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.workingDirectory) {
            return workingDirectory
        }
        return try TerminalSessionPersistence.readLaunchConfiguration(paths: paths).workingDirectory
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func terminalServiceLinkMetadata(_ metadata: SpacesMobileTerminalLinkMetadata) -> TerminalServiceTerminalLinkMetadata {
        TerminalServiceTerminalLinkMetadata(
            id: metadata.id, source: metadata.source.rawValue, originalLink: metadata.originalLink, displayName: metadata.displayName,
            contentType: metadata.contentType, mediaKind: metadata.mediaKind?.rawValue, byteCount: metadata.byteCount,
            externalURL: metadata.externalURL)
    }

    private func terminalServiceLinkChunk(_ chunk: SpacesMobileTerminalLinkChunk) -> TerminalServiceTerminalLinkChunk {
        TerminalServiceTerminalLinkChunk(
            linkID: chunk.linkID, offset: chunk.offset, byteCount: chunk.byteCount, isFinal: chunk.isFinal, base64Data: chunk.base64Data)
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

    private static func shutdownSocket(_ fileDescriptor: Int32) {
        #if canImport(Darwin)
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        #elseif canImport(Glibc)
            Glibc.shutdown(fileDescriptor, Int32(SHUT_RDWR))
        #endif
    }

    private static func terminateProcess() {
        #if canImport(AppKit)
            NSApp.terminate(nil)
        #else
            exit(0)
        #endif
    }

    private func nowISO8601() -> String { GhosttyRemoteSessionStateTimestamp.string(from: Date()) }

    private nonisolated static func runOnMainActorSynchronously<T: Sendable>(_ work: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        let box = MainActorSyncBox<T>()
        DispatchQueue.main.sync { box.value = MainActor.assumeIsolated { work() } }
        guard let value = box.value else { preconditionFailure("spacesd main-actor work did not return a value.") }
        return value
    }
}

private final class MainActorSyncBox<T>: @unchecked Sendable { var value: T? }

@MainActor private final class SpacesDaemonMobileBridgeSupervisor {
    #if canImport(spacesmobilebridge)
        private let supervisor = SpacesMobileBridgeSupervisor()
    #endif

    func start() {
        #if canImport(spacesmobilebridge)
            supervisor.start()
        #endif
    }

    func stop() {
        #if canImport(spacesmobilebridge)
            supervisor.stop()
        #endif
    }
}

#if canImport(AppKit)
    @MainActor private final class SpacesDaemonAppDelegate: NSObject, NSApplicationDelegate {
        private let controller: SpacesDaemonController

        init(controller: SpacesDaemonController) { self.controller = controller }

        func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
    }
#endif

@main struct SpacesDaemonMain {
    static func main() {
        configureProcessSignals()

        if environmentValue("SPACESD_PRINT_CERTIFICATE_FINGERPRINT") == "1" {
            do {
                print(try TerminalServiceTLSIdentityStore.loadOrCreate().certificateFingerprint)
                return
            } catch {
                writeStandardError("spacesd: \(error)\n")
                exit(1)
            }
        }

        #if canImport(AppKit)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)

            do {
                let controller = try MainActor.assumeIsolated { try SpacesDaemonController() }
                let delegate = SpacesDaemonAppDelegate(controller: controller)
                app.delegate = delegate
                try MainActor.assumeIsolated { try controller.start() }
                app.run()
            } catch {
                writeStandardError("spacesd: \(error)\n")
                exit(1)
            }
        #else
            do {
                let controller = try MainActor.assumeIsolated { try SpacesDaemonController() }
                try MainActor.assumeIsolated { try controller.start() }
                RunLoop.main.run()
                MainActor.assumeIsolated { controller.shutdown() }
            } catch {
                writeStandardError("spacesd: \(error)\n")
                exit(1)
            }
        #endif
    }

    private static func configureProcessSignals() {
        #if canImport(Glibc)
            _ = signal(SIGPIPE, SIG_IGN)
        #endif
    }
}

private func writeStandardError(_ message: String) { FileHandle.standardError.write(Data(message.utf8)) }

private func environmentValue(_ name: String) -> String? {
    guard let rawValue = getenv(name) else { return nil }
    return String(cString: rawValue)
}
