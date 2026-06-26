import Dispatch
import Foundation
import spacesdevicecore
import spacesruntimecore
import spacesterminalcore
import spacesterminalghostty
import workspacecore

#if canImport(CryptoKit)
    import CryptoKit
#endif

#if canImport(AppKit)
    import AppKit
#endif

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(spacesdeviceapi)
    import spacesdeviceapi
#endif

@MainActor private final class SpacesDaemonController {
    private static let ownerGatedTerminalCommands: Set<String> = ["send", "key", "clearScreen", "resize", "scroll"]
    private static let mobileTerminalServiceCommands: Set<String> = [
        "list", "state", "subscribe", "control", "resolveTerminalLink", "readTerminalLinkChunk",
    ]
    private static let mobileTerminalControlCommands: Set<String> = [
        "attach", "detach", "heartbeat", "takeover", "send", "key", "clearScreen", "resize", "scroll",
    ]
    private static let terminalLinkTransferAuthorizationTTL: TimeInterval = 10 * 60

    private struct TerminalLinkTransferAuthorization {
        let sessionID: String
        let resolvedPath: String
        let expiresAt: Date
    }

    private let socketPath: String
    private let instanceLock: TerminalServiceInstanceLock
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
        guard let authToken = configuredAuthToken, !authToken.isEmpty else {
            remoteServerLoadError = SpacesRuntimeError.invalidArgument(message: "SPACESD_AUTH_TOKEN is required when SPACESD_LISTEN_PORT is set.")
            return nil
        }
        remoteAdminAuthToken = authToken
        let identity: TerminalServiceTLSIdentity
        do { identity = try TerminalServiceTLSIdentityStore.loadOrCreate() } catch {
            remoteServerLoadError = error
            return nil
        }
        remoteCertificateFingerprint = identity.certificateFingerprint
        writeStandardError("spacesd: remote listener fingerprint=\(identity.certificateFingerprint)\n")
        return TerminalServiceTLSServer(
            host: host, port: port, authToken: nil, identity: identity, queue: serverQueue,
            authorizeRequest: { [weak self] request in
                Self.runOnMainActorSynchronously {
                    guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.") }
                    return self.authorizeRemoteRequest(request)
                }
            }
        ) { [weak self] request in
            Self.runOnMainActorSynchronously {
                guard let self else { return TerminalServiceResponse(ok: false, message: "spacesd is shutting down.") }
                return self.handle(request)
            }
        }
    }()
    private var remoteServerLoadError: (any Error)?
    private var remoteAdminAuthToken: String?
    private var remoteCertificateFingerprint: String?
    private var sessionCores: [String: GhosttyEmbeddedSessionCore] = [:]
    private var terminalLinkTransferAuthorizations: [String: TerminalLinkTransferAuthorization] = [:]
    private var lifecycleTimer: Timer?
    private lazy var deviceAPISupervisor = SpacesDaemonDeviceAPISupervisor(
        builtInTerminalSessionTerminator: { [weak self] sessionID in
            Self.runOnMainActorSynchronously { self?.terminateBuiltInTerminalSession(id: sessionID) }
        },
        builtInTerminalSessionLauncher: { [weak self] launchConfiguration in
            try Self.runOnMainActorSynchronously {
                Result {
                    guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                    return try self.launchBuiltInTerminalSession(launchConfiguration)
                }
            }.get()
        })
    private let git = RemoteWorkspaceGitClient()

    init() throws {
        instanceLock = try TerminalServiceInstanceLock.acquire(path: try TerminalServicePaths.instanceLockPath())
        socketPath = try TerminalServicePaths.socketPath()
    }

    func start() throws {
        try recoverStaleSessions()
        let configuredRemoteServer = remoteServer
        if let remoteServerLoadError { throw remoteServerLoadError }
        try server.start()
        try configuredRemoteServer?.start()
        deviceAPISupervisor.start()
        startLifecycleTimer()
    }

    func shutdown() {
        lifecycleTimer?.invalidate()
        lifecycleTimer = nil
        deviceAPISupervisor.stop()
        for sessionID in Array(sessionCores.keys) { _ = terminateSession(id: sessionID) }
        remoteServer?.stop()
        server.stop()
    }

    private func handle(_ request: TerminalServiceRequest) -> TerminalServiceResponse {
        switch request.command {
        case .ping: return TerminalServiceResponse(ok: true, message: "pong", servicePID: getpid(), daemonStatus: daemonStatus())
        case .shutdownIfIdle: return shutdownIfIdle()
        case .shutdown:
            writeStandardError("spacesd: terminal service shutdown requested\n")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                Self.terminateProcess()
            }
            return TerminalServiceResponse(ok: true, message: "spacesd is shutting down.", servicePID: getpid())
        case .create(let payload): return createSession(payload)
        case .prepareWorkspace(let payload):
            do {
                try prepareWorkspace(
                    runtimeManifest: payload.runtimeManifest, worktreeRefresh: payload.worktreeRefresh,
                    workingDirectory: payload.runtimeManifest.remotePath ?? payload.runtimeManifest.localPath)
                return TerminalServiceResponse(ok: true, message: "Workspace runtime is prepared.", servicePID: getpid())
            } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
        case .runWorkspaceCommand(let payload): return runWorkspaceCommand(payload)
        case .terminate(let payload):
            guard !payload.sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
            return terminateSession(id: payload.sessionID)
        case .list: return listSessions()
        case .state(let payload): return loadTerminalState(sessionID: payload.sessionID)
        case .subscribe(let payload): return subscribeTerminalState(sessionID: payload.sessionID)
        case .control(let payload): return handleTerminalControl(payload)
        case .agentSignal(let payload): return recordAgentSignal(payload)
        case .ackAgentSignals(let payload): return acknowledgeAgentSignals(payload)
        case .profileCommand(let command): return handleProfileCommand(command)
        case .mobileCredential(let credentialRequest): return handleMobileCredential(credentialRequest)
        case .resolveTerminalLink(let payload): return resolveTerminalLink(payload)
        case .readTerminalLinkChunk(let payload): return readTerminalLinkChunk(payload)
        }
    }

    private func daemonStatus() -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: AppVersion.current, artifactVersion: normalizedString(ProcessInfo.processInfo.environment["SPACESD_ARTIFACT_VERSION"]),
            certificateFingerprint: remoteCertificateFingerprint, activeSessionCount: sessionCores.count)
    }

    private func shutdownIfIdle() -> TerminalServiceResponse {
        let status = daemonStatus()
        guard status.activeSessionCount == 0 else {
            return TerminalServiceResponse(
                ok: false, message: "spacesd has \(status.activeSessionCount) active session(s).", servicePID: getpid(), daemonStatus: status)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            Self.terminateProcess()
        }
        return TerminalServiceResponse(ok: true, message: "spacesd is shutting down.", servicePID: getpid(), daemonStatus: status)
    }

    private func authorizeRemoteRequest(_ request: TerminalServiceRequest) -> TerminalServiceResponse? {
        if let remoteAdminAuthToken, request.authToken == remoteAdminAuthToken { return nil }
        guard let token = request.authToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.")
        }
        guard Self.mobileTerminalServiceCommands.contains(request.commandName) else {
            return TerminalServiceResponse(ok: false, message: "Mobile terminal credential cannot call '\(request.commandName)'.")
        }
        if request.commandName == "control", !Self.mobileTerminalControlCommands.contains(request.command.controlCommandName ?? "") {
            return TerminalServiceResponse(ok: false, message: "Mobile terminal credential cannot call this terminal control command.")
        }
        do {
            guard try SpacesDaemonMobileCredentialStore.authorize(token: token) else {
                return TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.")
            }
            return nil
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func handleMobileCredential(_ credentialRequest: TerminalServiceMobileCredentialRequest) -> TerminalServiceResponse {
        do {
            switch credentialRequest.operation {
            case .issue:
                guard let installationID = normalizedString(credentialRequest.installationID) else {
                    return TerminalServiceResponse(ok: false, message: "Missing mobile installation ID.")
                }
                let issued = try SpacesDaemonMobileCredentialStore.issue(
                    installationID: installationID, deviceName: credentialRequest.deviceName, platform: credentialRequest.platform)
                return TerminalServiceResponse(
                    ok: true, message: "Issued mobile terminal credential.", mobileCredentialToken: issued.token, mobileCredentials: [issued.record])
            case .revoke:
                guard let installationID = normalizedString(credentialRequest.installationID) else {
                    return TerminalServiceResponse(ok: false, message: "Missing mobile installation ID.")
                }
                try SpacesDaemonMobileCredentialStore.revoke(installationID: installationID)
                return TerminalServiceResponse(
                    ok: true, message: "Revoked mobile terminal credential.", mobileCredentials: try SpacesDaemonMobileCredentialStore.list())
            case .list:
                return TerminalServiceResponse(
                    ok: true, message: "Listed mobile terminal credentials.", mobileCredentials: try SpacesDaemonMobileCredentialStore.list())
            }
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func createSession(_ request: TerminalServiceCreateRequest) -> TerminalServiceResponse {
        let launchConfiguration = request.launchConfiguration
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: launchConfiguration.workingDirectory)
            let sessionCore = try sessionCore(for: launchConfiguration)
            try sessionCore.startIfNeeded()
            return TerminalServiceResponse(
                ok: true, message: "Started terminal session \(launchConfiguration.sessionID).",
                session: try sessionSummaryAfterStart(for: launchConfiguration.sessionID))
        } catch { return TerminalServiceResponse(ok: false, message: String(describing: error)) }
    }

    private func runWorkspaceCommand(_ request: TerminalServiceRunWorkspaceCommandRequest) -> TerminalServiceResponse {
        let workspaceCommand = request.workspaceCommand
        do {
            try prepareWorkspace(
                runtimeManifest: request.runtimeManifest, worktreeRefresh: request.worktreeRefresh,
                workingDirectory: workspaceCommand.workingDirectory)
            let logPath = try workspaceCommandLogPath(workspaceCommand.logPath)
            let result = try runShellCommand(workspaceCommand, logPath: logPath, manifest: request.runtimeManifest)
            let message = result.exitCode == 0 ? "Workspace command completed." : "Workspace command exited with code \(result.exitCode)."
            return TerminalServiceResponse(ok: true, message: message, servicePID: getpid(), commandResult: result)
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func prepareWorkspace(
        runtimeManifest: TerminalServiceWorkspaceRuntimeManifest?, worktreeRefresh: TerminalServiceWorktreeRefreshRequest?, workingDirectory: String?
    ) throws {
        if worktreeRefresh != nil, runtimeManifest == nil {
            throw SpacesRuntimeError.invalidArgument(message: "Workspace runtime manifest is required for worktree refresh.")
        }
        if let manifest = runtimeManifest {
            if let workingDirectory { try validateWorkspacePath(workingDirectory, manifest: manifest) }
            if manifest.location == .remote { try prepareRemoteWorktree(manifest: manifest, refreshRequest: worktreeRefresh) }
        }
        if let refreshRequest = worktreeRefresh {
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
                hostName: refreshRequest?.hostName ?? "remote device", path: remotePath, branch: branch, reason: .checkoutFailed,
                detail: "Remote workspace path exists but is not an empty Git worktree.")
        }
        try FileManager.default.createDirectory(at: remotePathURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cloneRemoteWorktree(manifest: manifest, branch: branch, remotePath: remotePath)
    }

    private func cloneRemoteWorktree(manifest: TerminalServiceWorkspaceRuntimeManifest, branch: String, remotePath: String) throws {
        guard let remoteURL = manifest.gitRemoteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteURL.isEmpty else {
            throw RemoteWorkspaceRefreshBlock(
                hostName: manifest.deviceID ?? "remote device", path: remotePath, branch: branch, reason: .fetchFailed,
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
        let root = try TerminalServicePaths.terminalRootDirectory().appendingPathComponent("workspace-commands", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let requestedPath = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedPath.isEmpty {
            let normalizedRoot = root.standardizedFileURL.path
            let normalizedPath = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
            guard normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/") else {
                throw SpacesRuntimeError.invalidArgument(message: "Workspace command log path must be under the daemon command log directory.")
            }
            return normalizedPath
        }
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
        var environment = Self.scrubbedChildEnvironment(ProcessInfo.processInfo.environment)
        if let manifest { environment.merge(manifest.processEnvironment) { _, new in new } }
        environment.merge(workspaceCommand.environment) { _, new in new }
        environment = Self.scrubbedChildEnvironment(environment)
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

    private static func scrubbedChildEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            key != "SPACESD_AUTH_TOKEN" && key != "SPACESD_LISTEN_PORT" && key != "SPACESD_LISTEN_HOST" && !key.hasPrefix("SPACESD_AUTH_TOKEN_")
        }
    }

    private func loadTerminalState(sessionID: String) -> TerminalServiceResponse {
        guard !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            return TerminalServiceResponse(
                ok: true, message: "Loaded terminal state.", sessionState: try loadCurrentState(sessionID: sessionID),
                agentSignals: try TerminalSessionPersistence.pendingAgentSignals(sessionID: sessionID, paths: paths))
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func recordAgentSignal(_ request: TerminalServiceAgentSignalRequest) -> TerminalServiceResponse {
        let event = request.event
        guard !event.sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
        do {
            let paths = try TerminalSessionPaths.forSession(id: event.sessionID)
            try TerminalSessionPersistence.appendPendingAgentSignal(event, paths: paths)
            return TerminalServiceResponse(ok: true, message: "Queued agent signal.", agentSignals: [event])
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func acknowledgeAgentSignals(_ request: TerminalServiceAgentSignalAcknowledgementRequest) -> TerminalServiceResponse {
        guard !request.sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
        do {
            try TerminalSessionPersistence.acknowledgeAgentSignals(
                ids: request.eventIDs, sessionID: request.sessionID, paths: try TerminalSessionPaths.forSession(id: request.sessionID),
                acknowledgedAt: nowISO8601())
            return TerminalServiceResponse(ok: true, message: "Acknowledged agent signals.")
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func handleProfileCommand(_ command: TerminalServiceProfileCommandRequest) -> TerminalServiceResponse {
        do {
            let profile = try runProfileCommand(command)
            return TerminalServiceResponse(ok: true, message: profile.message, sessions: profile.terminalSessions, profile: profile)
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func runProfileCommand(_ command: TerminalServiceProfileCommandRequest) throws -> TerminalServiceProfileCommandResponse {
        switch command.operation {
        case .terminalList:
            let response = listSessions()
            guard response.ok else { throw SpacesRuntimeError.invalidArgument(message: response.message) }
            return TerminalServiceProfileCommandResponse(message: response.message, terminalSessions: response.sessions ?? [])
        case .terminalSend: return try sendProfileTerminalInput(command)
        case .terminalTail: return try tailProfileTerminalOutput(command)
        case .projectList:
            let orchestrator = try makeProfileOrchestrator()
            let projects = try orchestrator.listProjects().map(profileProjectSummary)
            return TerminalServiceProfileCommandResponse(message: "Listed projects.", projects: projects)
        case .workspaceList:
            let orchestrator = try makeProfileOrchestrator()
            let includeArchived = command.includeArchived ?? false
            let workspaces: [WorkspaceRecord]
            if let projectID = normalizedProfileArgument(command.projectID) {
                workspaces = try orchestrator.store.workspaces(projectID: projectID, includeArchived: includeArchived)
            } else {
                workspaces = try orchestrator.store.projects().flatMap {
                    try orchestrator.store.workspaces(projectID: $0.id, includeArchived: includeArchived)
                }
            }
            return TerminalServiceProfileCommandResponse(message: "Listed workspaces.", workspaces: workspaces.map(profileWorkspaceRecord))
        case .workspaceCreate:
            let orchestrator = try makeProfileOrchestrator()
            let projectID = try requiredProfileArgument(command.projectID, name: "projectID")
            let branch = try requiredProfileArgument(command.branch, name: "branch")
            guard let project = try orchestrator.store.project(id: projectID) else {
                throw SpacesRuntimeError.invalidArgument(message: "Project not found for id \(projectID).")
            }
            let workspace = try orchestrator.createWorkspaceOnDevice(
                projectID: project.id, name: normalizedProfileArgument(command.title) ?? branch, branch: branch, baseBranch: command.baseBranch,
                allowExistingBranchReuse: command.existingBranch ?? false)
            return TerminalServiceProfileCommandResponse(message: "Created workspace.", workspace: profileWorkspaceRecord(workspace))
        case .workspaceStart:
            let orchestrator = try makeProfileOrchestrator()
            let workspaceID = try requiredProfileArgument(command.workspaceID, name: "workspaceID")
            try orchestrator.upWorkspace(workspaceID: workspaceID, restartIfRunning: false, background: true)
            let workspace = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
            return TerminalServiceProfileCommandResponse(message: "Workspace is running.", workspace: profileWorkspaceRecord(workspace))
        case .workspaceRestart:
            let orchestrator = try makeProfileOrchestrator()
            let workspaceID = try requiredProfileArgument(command.workspaceID, name: "workspaceID")
            try orchestrator.upWorkspace(workspaceID: workspaceID, restartIfRunning: true, background: true)
            let workspace = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
            return TerminalServiceProfileCommandResponse(message: "Workspace restarted.", workspace: profileWorkspaceRecord(workspace))
        case .agentSignal:
            let orchestrator = try makeProfileOrchestrator()
            return try recordProfileAgentSignal(command, orchestrator: orchestrator)
        }
    }

    private func sendProfileTerminalInput(_ command: TerminalServiceProfileCommandRequest) throws -> TerminalServiceProfileCommandResponse {
        let sessionID = try requiredProfileArgument(command.terminalSessionID, name: "terminalSessionID")
        let hasText = command.terminalText != nil
        let hasBytes = command.terminalBytes != nil
        guard hasText || hasBytes else { throw SpacesRuntimeError.invalidArgument(message: "terminalText or terminalBytes is required.") }
        guard !(hasText && hasBytes) else { throw SpacesRuntimeError.invalidArgument(message: "Provide terminalText or terminalBytes, not both.") }
        let controlResponse = try sendProfileTerminalControl(
            sessionID: sessionID,
            request: TerminalControlRequest(
                command: "send", text: command.terminalText, bytes: command.terminalBytes, appendNewline: command.appendNewline ?? false))
        guard controlResponse.ok else { throw SpacesRuntimeError.invalidArgument(message: controlResponse.message) }
        return TerminalServiceProfileCommandResponse(message: controlResponse.message)
    }

    private func sendProfileTerminalControl(sessionID: String, request: TerminalControlRequest) throws -> TerminalControlResponse {
        if let liveCore = sessionCores[sessionID] { return liveCore.handleControlRequest(request) }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return TerminalControlResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.")
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return TerminalControlResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.")
        }
        return try TerminalControlClient.send(request: request, socketPath: paths.controlSocketPath)
    }

    private func tailProfileTerminalOutput(_ command: TerminalServiceProfileCommandRequest) throws -> TerminalServiceProfileCommandResponse {
        let sessionID = try requiredProfileArgument(command.terminalSessionID, name: "terminalSessionID")
        let lineCount = max(command.lineCount ?? 20, 1)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.outputPath) else {
            throw SpacesRuntimeError.invalidArgument(message: "Terminal session '\(sessionID)' has no output yet.")
        }
        let output = try TerminalOutputTail.tail(path: paths.outputPath, lineCount: lineCount)
        return TerminalServiceProfileCommandResponse(message: "Read terminal output.", terminalOutput: output)
    }

    private func makeProfileOrchestrator() throws -> WorkspaceOrchestrator {
        let store = try SQLiteStore(path: try DatabaseLocator.defaultPath())
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalSessionTerminator: { [weak self] sessionID in
                Self.runOnMainActorSynchronously { self?.terminateBuiltInTerminalSession(id: sessionID) }
            },
            builtInTerminalSessionLauncher: { [weak self] launchConfiguration in
                try Self.runOnMainActorSynchronously {
                    Result {
                        guard let self else { throw Self.requestFailedError("spacesd is shutting down.") }
                        return try self.launchBuiltInTerminalSession(launchConfiguration)
                    }
                }.get()
            })
        _ = try orchestrator.syncConfig()
        return orchestrator
    }

    private func terminateBuiltInTerminalSession(id sessionID: String) { _ = terminateSession(id: sessionID) }

    private func launchBuiltInTerminalSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
        let response = createSession(TerminalServiceCreateRequest(launchConfiguration: launchConfiguration))
        guard response.ok else { throw Self.requestFailedError(response.message) }
        guard let session = response.session else { throw Self.requestFailedError("spacesd did not return a session summary.") }
        return session
    }

    private static func requestFailedError(_ message: String) -> NSError {
        NSError(domain: "spacesd", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func profileProjectSummary(_ value: ProjectSummary) -> TerminalServiceProfileProjectSummary {
        TerminalServiceProfileProjectSummary(
            id: value.id, name: value.name, dir: value.dir, isGitRepo: value.isGitRepo, defaultBranch: value.defaultBranch)
    }

    private func profileWorkspaceRecord(_ value: WorkspaceRecord) -> TerminalServiceProfileWorkspaceRecord {
        TerminalServiceProfileWorkspaceRecord(
            id: value.id, projectID: value.projectID, title: value.title, dir: value.dir, runtimePath: value.runtimePath, dirname: value.dirname,
            branch: value.branch, baseBranch: value.baseBranch, isDefault: value.isDefault, isArchived: value.isArchived, isHidden: value.isHidden,
            isRunning: value.isRunning, lastLaunchedAt: value.lastLaunchedAt, notes: value.notes)
    }

    private func requiredProfileWorkspace(id: String, orchestrator: WorkspaceOrchestrator) throws -> WorkspaceRecord {
        guard let workspace = try orchestrator.store.workspace(id: id) else {
            throw SpacesRuntimeError.invalidArgument(message: "Workspace not found for id \(id).")
        }
        return workspace
    }

    private func requiredProfileArgument(_ value: String?, name: String) throws -> String {
        guard let normalized = normalizedProfileArgument(value) else { throw SpacesRuntimeError.invalidArgument(message: "\(name) is required.") }
        return normalized
    }

    private func normalizedProfileArgument(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private enum ProfileAgentEventType: String {
        case `init` = "init"
        case working = "working"
        case blocked = "blocked"
        case done = "done"
        case exit = "exit"

        var status: AgentWindowStatus {
            switch self {
            case .`init`: .idle
            case .working: .spinning
            case .blocked: .waiting
            case .done: .done
            case .exit: .idle
            }
        }

        var establishesAgentFromEvidence: Bool {
            switch self {
            case .working, .blocked, .done: true
            case .`init`, .exit: false
            }
        }
    }

    private func recordProfileAgentSignal(_ command: TerminalServiceProfileCommandRequest, orchestrator: WorkspaceOrchestrator) throws
        -> TerminalServiceProfileCommandResponse
    {
        let workspaceID = try requiredProfileArgument(command.workspaceID, name: "workspaceID")
        let sessionID = try requiredProfileArgument(command.terminalSessionID, name: "terminalSessionID")
        let eventValue = try requiredProfileArgument(command.agentEvent, name: "agentEvent")
        guard let type = ProfileAgentEventType(rawValue: eventValue) else {
            throw SpacesRuntimeError.invalidArgument(message: "Unsupported agent event '\(eventValue)'.")
        }
        _ = try requiredProfileWorkspace(id: workspaceID, orchestrator: orchestrator)
        let existingAgent = try matchingProfileAgentWindow(workspaceID: workspaceID, sessionID: sessionID, orchestrator: orchestrator)
        let signalLabel = profileAgentRuntimeLabel(sessionID: sessionID) ?? normalizedProfileArgument(existingAgent?.label)
        let canRecordSignal = existingAgent != nil || type == .`init` || (type.establishesAgentFromEvidence && signalLabel != nil)
        if !canRecordSignal { return TerminalServiceProfileCommandResponse(message: "Agent \(type.rawValue) ignored.") }

        let environmentKeys = [WorkspaceOrchestrator.terminalTrackingIDEnvVar]
        switch type {
        case .`init`:
            try orchestrator.registerAgentWindow(
                workspaceID: workspaceID, provider: .spaces, label: signalLabel, terminalTrackingID: sessionID, terminalNativeID: sessionID,
                status: existingAgent?.status ?? .idle, eventType: type.rawValue, eventSource: "spaces_agent_signal", environmentKeys: environmentKeys
            )
        case .working, .blocked, .done:
            try orchestrator.updateAgentWindowStatus(
                workspaceID: workspaceID, provider: .spaces, terminalTrackingID: sessionID, codexThreadID: nil, terminalNativeID: sessionID,
                label: signalLabel, status: type.status, eventType: type.rawValue, eventSource: "spaces_agent_signal",
                environmentKeys: environmentKeys)
        case .exit:
            guard let existingAgent else { return TerminalServiceProfileCommandResponse(message: "Agent exit ignored.") }
            try orchestrator.handleAgentExit(
                existingAgent, terminalNativeID: sessionID, eventType: type.rawValue, eventSource: "spaces_agent_signal",
                environmentKeys: environmentKeys)
        }
        postAgentEventNotification()
        return TerminalServiceProfileCommandResponse(message: "Agent \(type.rawValue) recorded.")
    }

    private func matchingProfileAgentWindow(workspaceID: String, sessionID: String, orchestrator: WorkspaceOrchestrator) throws -> AgentWindowRecord?
    {
        try orchestrator.agentWindows(workspaceID: workspaceID).first {
            $0.provider == .spaces && ($0.terminalTrackingID == sessionID || $0.terminalNativeID == sessionID)
        }
    }

    private func profileAgentRuntimeLabel(sessionID: String) -> String? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return nil }
        if let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths), launchConfiguration.kind == .agent {
            return normalizedProfileArgument(launchConfiguration.title)
        }
        guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), let kind = runtimeState.foregroundDetectedAgentKind
        else { return nil }
        return normalizedProfileArgument(runtimeState.foregroundDisplayLabel) ?? kind.displayLabel
    }

    private func postAgentEventNotification() {
        #if os(macOS)
            try? IPCNotification.post(IPCNotification.agentEventFired)
        #endif
    }

    private func handleTerminalControl(_ request: TerminalServiceControlCommandRequest) -> TerminalServiceResponse {
        let sessionID = request.sessionID
        let controlRequest = request.controlRequest
        guard !sessionID.isEmpty else { return TerminalServiceResponse(ok: false, message: "Missing session ID.") }
        if Self.ownerGatedTerminalCommands.contains(controlRequest.command),
            controlRequest.clientID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            return TerminalServiceResponse(ok: false, message: "Missing device client ID.")
        }
        if let liveCore = sessionCores[sessionID] {
            let response = liveCore.handleControlRequest(controlRequest)
            return terminalControlResponse(sessionID: sessionID, controlResponse: response, includeSessionState: controlRequest.command == "takeover")
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
            return terminalControlResponse(sessionID: sessionID, controlResponse: response, includeSessionState: controlRequest.command == "takeover")
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func terminalControlResponse(sessionID: String, controlResponse response: TerminalControlResponse, includeSessionState: Bool)
        -> TerminalServiceResponse
    {
        let sessionState = response.ok && includeSessionState ? try? loadCurrentState(sessionID: sessionID) : nil
        return TerminalServiceResponse(ok: response.ok, message: response.message, sessionState: sessionState, controlResponse: response)
    }

    private func resolveTerminalLink(_ request: TerminalServiceTerminalLinkResolveRequest) -> TerminalServiceResponse {
        let link = request.terminalLink
        guard !request.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.")
        }
        let sessionID = request.sessionID
        do {
            pruneTerminalLinkTransferAuthorizations(now: Date())
            let metadata: SpacesDeviceTerminalLinkMetadata
            if canResolveTerminalLinkWithoutLocalState(link) {
                metadata = try SpacesDeviceTerminalLinkResolver.resolve(sessionID: sessionID, link: link, workingDirectory: nil, workspaceRoots: [])
            } else {
                let workingDirectory = try terminalWorkingDirectory(sessionID: sessionID)
                metadata = try SpacesDeviceTerminalLinkResolver.resolve(
                    sessionID: sessionID, link: link, workingDirectory: workingDirectory, workspaceRoots: [workingDirectory])
            }
            if metadata.source == .localFile {
                let resolvedPath = try SpacesDeviceTerminalLinkResolver.resolvedLocalFilePath(linkID: metadata.id)
                authorizeTerminalLinkTransfer(linkID: metadata.id, sessionID: sessionID, resolvedPath: resolvedPath, now: Date())
            }
            return TerminalServiceResponse(ok: true, message: "Resolved terminal link.", terminalLinkMetadata: terminalServiceLinkMetadata(metadata))
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
    }

    private func readTerminalLinkChunk(_ request: TerminalServiceTerminalLinkChunkRequest) -> TerminalServiceResponse {
        guard !request.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.")
        }
        let sessionID = request.sessionID
        do {
            guard let linkID = request.terminalLinkID?.trimmingCharacters(in: .whitespacesAndNewlines), !linkID.isEmpty else {
                throw SpacesDeviceTerminalLinkResolverError.invalidLinkID
            }
            guard let authorization = try terminalLinkTransferAuthorization(linkID: linkID, sessionID: sessionID, now: Date()) else {
                throw SpacesDeviceTerminalLinkResolverError.invalidLinkID
            }
            let chunk = try SpacesDeviceTerminalLinkResolver.readChunk(
                sessionID: sessionID, linkID: linkID, offset: request.offset, limit: request.limit, workspaceRoots: [authorization.resolvedPath])
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

    private func subscribeTerminalState(sessionID: String) -> TerminalServiceResponse {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TerminalServiceResponse(ok: false, message: "Missing session ID.")
        }
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                return TerminalServiceResponse(ok: false, message: "Terminal session '\(sessionID)' is not live.")
            }
            guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
                return TerminalServiceResponse(ok: false, message: "Terminal session '\(sessionID)' has no live state stream.")
            }
            return TerminalServiceResponse(ok: true, message: "Subscribed to terminal state.", streamSocketPath: paths.subscriptionSocketPath)
        } catch { return TerminalServiceResponse(ok: false, message: Self.errorMessage(error)) }
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
        guard authorization.sessionID == sessionID else { throw SpacesDeviceTerminalLinkResolverError.sessionMismatch }
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

    private func terminalServiceLinkMetadata(_ metadata: SpacesDeviceTerminalLinkMetadata) -> TerminalServiceTerminalLinkMetadata {
        TerminalServiceTerminalLinkMetadata(
            id: metadata.id, source: metadata.source.rawValue, originalLink: metadata.originalLink, displayName: metadata.displayName,
            contentType: metadata.contentType, mediaKind: metadata.mediaKind?.rawValue, byteCount: metadata.byteCount,
            externalURL: metadata.externalURL)
    }

    private func terminalServiceLinkChunk(_ chunk: SpacesDeviceTerminalLinkChunk) -> TerminalServiceTerminalLinkChunk {
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

private enum SpacesDaemonMobileCredentialStore {
    struct IssuedCredential {
        let token: String
        let record: TerminalServiceMobileCredential
    }

    private struct StoredCredential: Codable {
        var id: String
        var installationID: String
        var tokenHash: String
        var deviceName: String?
        var platform: String?
        var scopes: [String]
        var createdAt: String
        var lastUsedAt: String?
        var revokedAt: String?
    }

    private struct StoreFile: Codable { var credentials: [StoredCredential] }

    static func issue(installationID: String, deviceName: String?, platform: String?) throws -> IssuedCredential {
        var file = try load()
        let now = GhosttyRemoteSessionStateTimestamp.string(from: Date())
        for index in file.credentials.indices
        where file.credentials[index].installationID == installationID && file.credentials[index].revokedAt == nil {
            file.credentials[index].revokedAt = now
        }
        let token = "smt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let stored = StoredCredential(
            id: UUID().uuidString, installationID: installationID, tokenHash: hash(token), deviceName: normalized(deviceName),
            platform: normalized(platform), scopes: ["terminal"], createdAt: now, lastUsedAt: nil, revokedAt: nil)
        file.credentials.append(stored)
        try save(file)
        return IssuedCredential(token: token, record: publicRecord(stored))
    }

    static func revoke(installationID: String) throws {
        var file = try load()
        let now = GhosttyRemoteSessionStateTimestamp.string(from: Date())
        for index in file.credentials.indices
        where file.credentials[index].installationID == installationID && file.credentials[index].revokedAt == nil {
            file.credentials[index].revokedAt = now
        }
        try save(file)
    }

    static func list() throws -> [TerminalServiceMobileCredential] { try load().credentials.map(publicRecord) }

    static func authorize(token: String) throws -> Bool {
        var file = try load()
        let tokenHash = hash(token)
        guard let index = file.credentials.firstIndex(where: { $0.tokenHash == tokenHash && $0.revokedAt == nil }) else { return false }
        file.credentials[index].lastUsedAt = GhosttyRemoteSessionStateTimestamp.string(from: Date())
        try save(file)
        return true
    }

    private static func load() throws -> StoreFile {
        let url = try storeURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return StoreFile(credentials: []) }
        return try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: url))
    }

    private static func save(_ file: StoreFile) throws {
        let url = try storeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: [.atomic])
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    private static func storeURL() throws -> URL {
        try TerminalServicePaths.terminalRootDirectory().appendingPathComponent("mobile-terminal-credentials.json", isDirectory: false)
    }

    private static func publicRecord(_ stored: StoredCredential) -> TerminalServiceMobileCredential {
        TerminalServiceMobileCredential(
            id: stored.id, installationID: stored.installationID, deviceName: stored.deviceName, platform: stored.platform, scopes: stored.scopes,
            createdAt: stored.createdAt, lastUsedAt: stored.lastUsedAt, revokedAt: stored.revokedAt)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func hash(_ token: String) -> String {
        #if canImport(CryptoKit)
            let digest = SHA256.hash(data: Data(token.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        #else
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return String(format: "%016llx", hash)
        #endif
    }
}

@MainActor private final class SpacesDaemonDeviceAPISupervisor {
    #if canImport(spacesdeviceapi)
        private let supervisor: SpacesDeviceAPISupervisor
    #endif

    init(
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil
    ) {
        #if canImport(spacesdeviceapi)
            supervisor = SpacesDeviceAPISupervisor(
                builtInTerminalSessionTerminator: builtInTerminalSessionTerminator, builtInTerminalSessionLauncher: builtInTerminalSessionLauncher)
        #endif
    }

    func start() {
        #if canImport(spacesdeviceapi)
            supervisor.start()
        #endif
    }

    func stop() {
        #if canImport(spacesdeviceapi)
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
                let signalSources = installTerminationSignalHandlers(controller: controller)
                try MainActor.assumeIsolated { try controller.start() }
                withExtendedLifetime(signalSources) { RunLoop.main.run() }
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
            _ = signal(SIGHUP, SIG_IGN)
        #endif
    }

    #if canImport(Glibc)
        private static func installTerminationSignalHandlers(controller: SpacesDaemonController) -> [DispatchSourceSignal] {
            [SIGTERM, SIGINT].map { signalNumber in
                _ = signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
                source.setEventHandler {
                    writeStandardError("spacesd: received \(signalName(signalNumber)); shutting down\n")
                    Task { @MainActor in
                        controller.shutdown()
                        exit(0)
                    }
                }
                source.resume()
                return source
            }
        }

        private static func signalName(_ signalNumber: Int32) -> String {
            switch signalNumber {
            case SIGTERM: "SIGTERM"
            case SIGINT: "SIGINT"
            default: "signal \(signalNumber)"
            }
        }
    #else
        private static func installTerminationSignalHandlers(controller _: SpacesDaemonController) -> [DispatchSourceSignal] { [] }
    #endif
}

private func writeStandardError(_ message: String) { FileHandle.standardError.write(Data(message.utf8)) }

private func environmentValue(_ name: String) -> String? {
    guard let rawValue = getenv(name) else { return nil }
    return String(cString: rawValue)
}
