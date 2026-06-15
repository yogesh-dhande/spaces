import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct TerminalServiceRequest: Codable, Sendable, Equatable {
    public let command: String
    public let authToken: String?
    public let launchConfiguration: TerminalSessionLaunchConfiguration?
    public let sessionID: String?
    public let runtimeManifest: TerminalServiceWorkspaceRuntimeManifest?
    public let worktreeRefresh: TerminalServiceWorktreeRefreshRequest?
    public let workspaceCommand: TerminalServiceWorkspaceCommandRequest?
    public let controlRequest: TerminalControlRequest?
    public let terminalLink: String?
    public let terminalLinkID: String?
    public let chunkOffset: Int64?
    public let chunkLimit: Int?
    public let agentSignal: TerminalServiceAgentSignalEvent?
    public let agentSignalEventIDs: [String]?
    public let profileCommand: TerminalServiceProfileCommandRequest?
    public let mobileCredentialRequest: TerminalServiceMobileCredentialRequest?

    public init(
        command: String, authToken: String? = nil, launchConfiguration: TerminalSessionLaunchConfiguration? = nil, sessionID: String? = nil,
        runtimeManifest: TerminalServiceWorkspaceRuntimeManifest? = nil, worktreeRefresh: TerminalServiceWorktreeRefreshRequest? = nil,
        workspaceCommand: TerminalServiceWorkspaceCommandRequest? = nil, controlRequest: TerminalControlRequest? = nil, terminalLink: String? = nil,
        terminalLinkID: String? = nil, chunkOffset: Int64? = nil, chunkLimit: Int? = nil, agentSignal: TerminalServiceAgentSignalEvent? = nil,
        agentSignalEventIDs: [String]? = nil, profileCommand: TerminalServiceProfileCommandRequest? = nil,
        mobileCredentialRequest: TerminalServiceMobileCredentialRequest? = nil
    ) {
        self.command = command
        self.authToken = authToken
        self.launchConfiguration = launchConfiguration
        self.sessionID = sessionID
        self.runtimeManifest = runtimeManifest
        self.worktreeRefresh = worktreeRefresh
        self.workspaceCommand = workspaceCommand
        self.controlRequest = controlRequest
        self.terminalLink = terminalLink
        self.terminalLinkID = terminalLinkID
        self.chunkOffset = chunkOffset
        self.chunkLimit = chunkLimit
        self.agentSignal = agentSignal
        self.agentSignalEventIDs = agentSignalEventIDs
        self.profileCommand = profileCommand
        self.mobileCredentialRequest = mobileCredentialRequest
    }

    public init(
        command: String, authToken: String? = nil, launchConfiguration: TerminalSessionLaunchConfiguration? = nil, sessionID: String? = nil,
        runtimeManifest: TerminalServiceWorkspaceRuntimeManifest? = nil, worktreeRefresh: TerminalServiceWorktreeRefreshRequest? = nil,
        workspaceCommand: TerminalServiceWorkspaceCommandRequest? = nil, controlRequest: TerminalControlRequest? = nil, terminalLink: String? = nil,
        terminalLinkID: String? = nil, chunkOffset: Int64? = nil, chunkLimit: Int? = nil, agentSignal: TerminalServiceAgentSignalEvent? = nil,
        agentSignalEventIDs: [String]? = nil
    ) {
        self.init(
            command: command, authToken: authToken, launchConfiguration: launchConfiguration, sessionID: sessionID, runtimeManifest: runtimeManifest,
            worktreeRefresh: worktreeRefresh, workspaceCommand: workspaceCommand, controlRequest: controlRequest, terminalLink: terminalLink,
            terminalLinkID: terminalLinkID, chunkOffset: chunkOffset, chunkLimit: chunkLimit, agentSignal: agentSignal,
            agentSignalEventIDs: agentSignalEventIDs, profileCommand: nil, mobileCredentialRequest: nil)
    }

    public func withAuthToken(_ authToken: String?) -> TerminalServiceRequest {
        TerminalServiceRequest(
            command: command, authToken: authToken, launchConfiguration: launchConfiguration, sessionID: sessionID, runtimeManifest: runtimeManifest,
            worktreeRefresh: worktreeRefresh, workspaceCommand: workspaceCommand, controlRequest: controlRequest, terminalLink: terminalLink,
            terminalLinkID: terminalLinkID, chunkOffset: chunkOffset, chunkLimit: chunkLimit, agentSignal: agentSignal,
            agentSignalEventIDs: agentSignalEventIDs, profileCommand: profileCommand, mobileCredentialRequest: mobileCredentialRequest)
    }
}

public enum TerminalServiceMobileCredentialOperation: String, Codable, Sendable, Equatable {
    case issue
    case revoke
    case list
}

public struct TerminalServiceMobileCredentialRequest: Codable, Sendable, Equatable {
    public let operation: TerminalServiceMobileCredentialOperation
    public let installationID: String?
    public let deviceName: String?
    public let platform: String?

    public init(
        operation: TerminalServiceMobileCredentialOperation, installationID: String? = nil, deviceName: String? = nil, platform: String? = nil
    ) {
        self.operation = operation
        self.installationID = installationID
        self.deviceName = deviceName
        self.platform = platform
    }
}

public struct TerminalServiceMobileCredential: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let installationID: String
    public let deviceName: String?
    public let platform: String?
    public let scopes: [String]
    public let createdAt: String
    public let lastUsedAt: String?
    public let revokedAt: String?

    public init(
        id: String, installationID: String, deviceName: String?, platform: String?, scopes: [String], createdAt: String, lastUsedAt: String?,
        revokedAt: String?
    ) {
        self.id = id
        self.installationID = installationID
        self.deviceName = deviceName
        self.platform = platform
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
    }
}

public enum TerminalServiceProfileCommandOperation: String, Codable, Sendable, Equatable {
    case projectList
    case workspaceList
    case workspaceCreate
    case workspaceStart
    case workspaceRestart
    case agentSignal
    case terminalList
    case terminalSend
    case terminalTail
}

public struct TerminalServiceProfileCommandRequest: Codable, Sendable, Equatable {
    public let operation: TerminalServiceProfileCommandOperation
    public let projectID: String?
    public let includeArchived: Bool?
    public let workspaceID: String?
    public let branch: String?
    public let hostID: String?
    public let title: String?
    public let targetBranch: String?
    public let existingBranch: Bool?
    public let terminalSessionID: String?
    public let agentEvent: String?
    public let terminalText: String?
    public let terminalBytes: Data?
    public let appendNewline: Bool?
    public let lineCount: Int?

    public init(
        operation: TerminalServiceProfileCommandOperation, projectID: String? = nil, includeArchived: Bool? = nil, workspaceID: String? = nil,
        branch: String? = nil, hostID: String? = nil, title: String? = nil, targetBranch: String? = nil, existingBranch: Bool? = nil,
        terminalSessionID: String? = nil, agentEvent: String? = nil, terminalText: String? = nil, terminalBytes: Data? = nil,
        appendNewline: Bool? = nil, lineCount: Int? = nil
    ) {
        self.operation = operation
        self.projectID = projectID
        self.includeArchived = includeArchived
        self.workspaceID = workspaceID
        self.branch = branch
        self.hostID = hostID
        self.title = title
        self.targetBranch = targetBranch
        self.existingBranch = existingBranch
        self.terminalSessionID = terminalSessionID
        self.agentEvent = agentEvent
        self.terminalText = terminalText
        self.terminalBytes = terminalBytes
        self.appendNewline = appendNewline
        self.lineCount = lineCount
    }
}

public struct TerminalServiceProfileProjectSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public let isCollapsed: Bool

    public init(id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, isCollapsed: Bool) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.isCollapsed = isCollapsed
    }
}

public struct TerminalServiceProfileWorkspaceRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let hostID: String
    public let title: String
    public let dir: String
    public let runtimePath: String
    public let dirname: String?
    public let branch: String?
    public let targetBranch: String?
    public let isDefault: Bool
    public let isArchived: Bool
    public let isHidden: Bool
    public let isRunning: Bool
    public let lastLaunchedAt: String?
    public let notes: String?

    public init(
        id: String, projectID: String, hostID: String, title: String, dir: String, runtimePath: String, dirname: String?, branch: String?,
        targetBranch: String?, isDefault: Bool, isArchived: Bool, isHidden: Bool, isRunning: Bool, lastLaunchedAt: String?, notes: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.hostID = hostID
        self.title = title
        self.dir = dir
        self.runtimePath = runtimePath
        self.dirname = dirname
        self.branch = branch
        self.targetBranch = targetBranch
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isRunning = isRunning
        self.lastLaunchedAt = lastLaunchedAt
        self.notes = notes
    }
}

public struct TerminalServiceProfileCommandResponse: Codable, Sendable, Equatable {
    public let message: String
    public let projects: [TerminalServiceProfileProjectSummary]?
    public let workspaces: [TerminalServiceProfileWorkspaceRecord]?
    public let workspace: TerminalServiceProfileWorkspaceRecord?
    public let terminalSessions: [TerminalServiceSessionSummary]?
    public let terminalOutput: String?

    public init(
        message: String, projects: [TerminalServiceProfileProjectSummary]? = nil, workspaces: [TerminalServiceProfileWorkspaceRecord]? = nil,
        workspace: TerminalServiceProfileWorkspaceRecord? = nil, terminalSessions: [TerminalServiceSessionSummary]? = nil,
        terminalOutput: String? = nil
    ) {
        self.message = message
        self.projects = projects
        self.workspaces = workspaces
        self.workspace = workspace
        self.terminalSessions = terminalSessions
        self.terminalOutput = terminalOutput
    }
}

public enum TerminalServiceWorkspaceLocation: String, Codable, Sendable, Equatable {
    case local
    case remote
}

public struct TerminalServiceWorkspaceRuntimePortMapping: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let port: Int

    public init(id: String, name: String, port: Int) {
        self.id = id
        self.name = name
        self.port = port
    }
}

public struct TerminalServiceWorkspaceRuntimeManifest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let projectID: String
    public let computeHostID: String?
    public let location: TerminalServiceWorkspaceLocation
    public let localPath: String
    public let remotePath: String?
    public let branch: String?
    public let targetBranch: String?
    public let gitRemoteURL: String?
    public let namedPorts: [TerminalServiceWorkspaceRuntimePortMapping]
    public let processEnvironment: [String: String]
    public let allowedFileRoots: [String]

    public init(
        workspaceID: String, projectID: String, computeHostID: String?, location: TerminalServiceWorkspaceLocation, localPath: String,
        remotePath: String?, branch: String?, targetBranch: String?, gitRemoteURL: String?, namedPorts: [TerminalServiceWorkspaceRuntimePortMapping],
        processEnvironment: [String: String], allowedFileRoots: [String]
    ) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.computeHostID = computeHostID
        self.location = location
        self.localPath = localPath
        self.remotePath = remotePath
        self.branch = branch
        self.targetBranch = targetBranch
        self.gitRemoteURL = gitRemoteURL
        self.namedPorts = namedPorts
        self.processEnvironment = processEnvironment
        self.allowedFileRoots = allowedFileRoots
    }
}

public struct TerminalServiceWorktreeRefreshRequest: Codable, Sendable, Equatable {
    public let path: String
    public let branch: String
    public let hostName: String

    public init(path: String, branch: String, hostName: String) {
        self.path = path
        self.branch = branch
        self.hostName = hostName
    }
}

public struct TerminalServiceWorkspaceCommandRequest: Codable, Sendable, Equatable {
    public let command: String
    public let workingDirectory: String
    public let environment: [String: String]
    public let logPath: String?

    public init(command: String, workingDirectory: String, environment: [String: String] = [:], logPath: String? = nil) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.logPath = logPath
    }
}

public struct TerminalServiceCommandResult: Codable, Sendable, Equatable {
    public let exitCode: Int
    public let logPath: String

    public init(exitCode: Int, logPath: String) {
        self.exitCode = exitCode
        self.logPath = logPath
    }
}

public struct TerminalServiceAgentSignalEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let workspaceID: String?
    public let workspacePath: String?
    public let type: String
    public let provider: String
    public let label: String?
    public let terminalTrackingID: String?
    public let terminalNativeID: String?
    public let codexThreadID: String?
    public let environmentKeys: [String]
    public let createdAt: String

    public init(
        id: String, sessionID: String, workspaceID: String?, workspacePath: String?, type: String, provider: String = "spaces", label: String? = nil,
        terminalTrackingID: String? = nil, terminalNativeID: String? = nil, codexThreadID: String? = nil, environmentKeys: [String] = [],
        createdAt: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.workspacePath = workspacePath
        self.type = type
        self.provider = provider
        self.label = label
        self.terminalTrackingID = terminalTrackingID
        self.terminalNativeID = terminalNativeID
        self.codexThreadID = codexThreadID
        self.environmentKeys = environmentKeys
        self.createdAt = createdAt
    }
}

public struct TerminalServiceTerminalLinkMetadata: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: String
    public let originalLink: String
    public let displayName: String
    public let contentType: String?
    public let mediaKind: String?
    public let byteCount: Int64?
    public let externalURL: String?

    public init(
        id: String, source: String, originalLink: String, displayName: String, contentType: String?, mediaKind: String?, byteCount: Int64?,
        externalURL: String?
    ) {
        self.id = id
        self.source = source
        self.originalLink = originalLink
        self.displayName = displayName
        self.contentType = contentType
        self.mediaKind = mediaKind
        self.byteCount = byteCount
        self.externalURL = externalURL
    }
}

public struct TerminalServiceTerminalLinkChunk: Codable, Sendable, Equatable {
    public let linkID: String
    public let offset: Int64
    public let byteCount: Int
    public let isFinal: Bool
    public let base64Data: String

    public init(linkID: String, offset: Int64, byteCount: Int, isFinal: Bool, base64Data: String) {
        self.linkID = linkID
        self.offset = offset
        self.byteCount = byteCount
        self.isFinal = isFinal
        self.base64Data = base64Data
    }
}

public struct TerminalServiceSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let workingDirectory: String
    public let backend: TerminalSessionBackendKind
    public let lifetimePolicy: TerminalSessionLifetimePolicy
    public let state: TerminalSessionState
    public let servicePID: Int32
    public let childPID: Int32?
    public let controlSocketPath: String
    public let outputPath: String
    public let launchConfiguration: TerminalSessionLaunchConfiguration?
    public let runtimeState: TerminalSessionRuntimeState?
    public let attachmentSnapshot: TerminalSessionAttachmentSnapshot?
    public let hasFinalRender: Bool

    public init(
        id: String, title: String, workingDirectory: String, backend: TerminalSessionBackendKind, lifetimePolicy: TerminalSessionLifetimePolicy,
        state: TerminalSessionState, servicePID: Int32, childPID: Int32?, controlSocketPath: String, outputPath: String,
        launchConfiguration: TerminalSessionLaunchConfiguration? = nil, runtimeState: TerminalSessionRuntimeState? = nil,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot? = nil, hasFinalRender: Bool = false
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.backend = backend
        self.lifetimePolicy = lifetimePolicy
        self.state = state
        self.servicePID = servicePID
        self.childPID = childPID
        self.controlSocketPath = controlSocketPath
        self.outputPath = outputPath
        self.launchConfiguration = launchConfiguration
        self.runtimeState = runtimeState
        self.attachmentSnapshot = attachmentSnapshot
        self.hasFinalRender = hasFinalRender
    }
}

public struct TerminalServiceResponse: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case ok
        case message
        case session
        case sessions
        case servicePID
        case commandResult
        case sessionState
        case controlResponse
        case terminalLinkMetadata
        case terminalLinkChunk
        case agentSignals
        case profile
        case mobileCredentialToken
        case mobileCredentials
    }

    public let ok: Bool
    public let message: String
    public let session: TerminalServiceSessionSummary?
    public let sessions: [TerminalServiceSessionSummary]?
    public let servicePID: Int32?
    public let commandResult: TerminalServiceCommandResult?
    public let sessionState: GhosttyRemoteSessionStatePayload?
    public let controlResponse: TerminalControlResponse?
    public let terminalLinkMetadata: TerminalServiceTerminalLinkMetadata?
    public let terminalLinkChunk: TerminalServiceTerminalLinkChunk?
    public let agentSignals: [TerminalServiceAgentSignalEvent]?
    public let profile: TerminalServiceProfileCommandResponse?
    public let mobileCredentialToken: String?
    public let mobileCredentials: [TerminalServiceMobileCredential]?
    let streamSocketPath: String?

    public init(
        ok: Bool, message: String, session: TerminalServiceSessionSummary? = nil, sessions: [TerminalServiceSessionSummary]? = nil,
        servicePID: Int32? = nil, commandResult: TerminalServiceCommandResult? = nil, sessionState: GhosttyRemoteSessionStatePayload? = nil,
        controlResponse: TerminalControlResponse? = nil, terminalLinkMetadata: TerminalServiceTerminalLinkMetadata? = nil,
        terminalLinkChunk: TerminalServiceTerminalLinkChunk? = nil, agentSignals: [TerminalServiceAgentSignalEvent]? = nil,
        profile: TerminalServiceProfileCommandResponse? = nil, mobileCredentialToken: String? = nil,
        mobileCredentials: [TerminalServiceMobileCredential]? = nil, streamSocketPath: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.session = session
        self.sessions = sessions
        self.servicePID = servicePID
        self.commandResult = commandResult
        self.sessionState = sessionState
        self.controlResponse = controlResponse
        self.terminalLinkMetadata = terminalLinkMetadata
        self.terminalLinkChunk = terminalLinkChunk
        self.agentSignals = agentSignals
        self.profile = profile
        self.mobileCredentialToken = mobileCredentialToken
        self.mobileCredentials = mobileCredentials
        self.streamSocketPath = streamSocketPath
    }

    public init(
        ok: Bool, message: String, session: TerminalServiceSessionSummary? = nil, sessions: [TerminalServiceSessionSummary]? = nil,
        servicePID: Int32? = nil, commandResult: TerminalServiceCommandResult? = nil, sessionState: GhosttyRemoteSessionStatePayload? = nil,
        controlResponse: TerminalControlResponse? = nil, terminalLinkMetadata: TerminalServiceTerminalLinkMetadata? = nil,
        terminalLinkChunk: TerminalServiceTerminalLinkChunk? = nil, agentSignals: [TerminalServiceAgentSignalEvent]? = nil
    ) {
        self.init(
            ok: ok, message: message, session: session, sessions: sessions, servicePID: servicePID, commandResult: commandResult,
            sessionState: sessionState, controlResponse: controlResponse, terminalLinkMetadata: terminalLinkMetadata,
            terminalLinkChunk: terminalLinkChunk, agentSignals: agentSignals, profile: nil)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ok: try container.decode(Bool.self, forKey: .ok), message: try container.decode(String.self, forKey: .message),
            session: try container.decodeIfPresent(TerminalServiceSessionSummary.self, forKey: .session),
            sessions: try container.decodeIfPresent([TerminalServiceSessionSummary].self, forKey: .sessions),
            servicePID: try container.decodeIfPresent(Int32.self, forKey: .servicePID),
            commandResult: try container.decodeIfPresent(TerminalServiceCommandResult.self, forKey: .commandResult),
            sessionState: try container.decodeIfPresent(GhosttyRemoteSessionStatePayload.self, forKey: .sessionState),
            controlResponse: try container.decodeIfPresent(TerminalControlResponse.self, forKey: .controlResponse),
            terminalLinkMetadata: try container.decodeIfPresent(TerminalServiceTerminalLinkMetadata.self, forKey: .terminalLinkMetadata),
            terminalLinkChunk: try container.decodeIfPresent(TerminalServiceTerminalLinkChunk.self, forKey: .terminalLinkChunk),
            agentSignals: try container.decodeIfPresent([TerminalServiceAgentSignalEvent].self, forKey: .agentSignals),
            profile: try container.decodeIfPresent(TerminalServiceProfileCommandResponse.self, forKey: .profile),
            mobileCredentialToken: try container.decodeIfPresent(String.self, forKey: .mobileCredentialToken),
            mobileCredentials: try container.decodeIfPresent([TerminalServiceMobileCredential].self, forKey: .mobileCredentials))
    }
}

enum TerminalServiceCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeRequest(_ request: TerminalServiceRequest) throws -> Data { try encoder.encode(request) }
    static func decodeRequest(_ data: Data) throws -> TerminalServiceRequest { try decoder.decode(TerminalServiceRequest.self, from: data) }
    static func encodeResponse(_ response: TerminalServiceResponse) throws -> Data { try encoder.encode(response) }
    static func decodeResponse(_ data: Data) throws -> TerminalServiceResponse { try decoder.decode(TerminalServiceResponse.self, from: data) }
}

public final class TerminalServiceServer {
    private let socketPath: String
    private let queue: DispatchQueue
    private let handleRequest: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(
        socketPath: String, queue: DispatchQueue, handleRequest: @escaping @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    ) {
        self.socketPath = socketPath
        self.queue = queue
        self.handleRequest = handleRequest
    }

    public func start() throws {
        try removeSocketIfPresent()
        let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = try makeSocketAddress(path: socketPath)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }

        chmod(socketPath, S_IRUSR | S_IWUSR)

        guard listen(socketFD, 16) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        try setNonBlocking(socketFD)

        listenSocketFD = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReadyConnections() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenSocketFD >= 0 { close(self.listenSocketFD) }
            try? self.removeSocketIfPresent()
        }
        acceptSource = source
        source.resume()
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    private func acceptReadyConnections() {
        while true {
            let clientFD = accept(listenSocketFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                return
            }

            do {
                try setBlocking(clientFD)
                let requestData = try Self.readAll(from: clientFD)
                let request = try TerminalServiceCodec.decodeRequest(requestData)
                let response = try handleRequest(request)
                let responseData = try TerminalServiceCodec.encodeResponse(response)
                try Self.writeAll(data: responseData, to: clientFD)
            } catch {
                let fallback = TerminalServiceResponse(ok: false, message: String(describing: error))
                if let data = try? TerminalServiceCodec.encodeResponse(fallback) { try? Self.writeAll(data: data, to: clientFD) }
            }

            Self.shutdownSocket(clientFD)
            close(clientFD)
        }
    }

    private func removeSocketIfPresent() throws {
        if FileManager.default.fileExists(atPath: socketPath) { try FileManager.default.removeItem(atPath: socketPath) }
    }

    private func makeSocketAddress(path: String) throws -> sockaddr_un {
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

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    fileprivate static func writeAll(data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                if written < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                bytesRemaining -= written
                offset += written
            }
        }
    }

    fileprivate static func readAll(from fileDescriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func shutdownSocket(_ fileDescriptor: Int32) {
        #if canImport(Darwin)
            shutdown(fileDescriptor, SHUT_RDWR)
        #else
            shutdown(fileDescriptor, Int32(SHUT_RDWR))
        #endif
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }
}

public enum TerminalServiceClient {
    public static func send(request: TerminalServiceRequest, socketPath: String, timeout: TimeInterval = 5) throws -> TerminalServiceResponse {
        let socketFD = socket(AF_UNIX, streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(socketFD) }

        var address = try makeSocketAddress(path: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var timeValue = timeval(timeout)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))

        let payload = try TerminalServiceCodec.encodeRequest(request)
        try writeAll(data: payload, to: socketFD)
        shutdownSocketWrite(socketFD)

        let responseData = try readAll(from: socketFD)
        return try TerminalServiceCodec.decodeResponse(responseData)
    }

    public static func send(request: TerminalServiceRequest, host: String, port: Int, authToken: String? = nil, timeout: TimeInterval = 15) throws
        -> TerminalServiceResponse
    {
        let socketFD = try connectSocket(host: host, port: port)
        defer { close(socketFD) }

        var timeValue = timeval(timeout)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))

        let payload = try TerminalServiceCodec.encodeRequest(request.withAuthToken(authToken ?? request.authToken))
        try writeAll(data: payload, to: socketFD)
        shutdownSocketWrite(socketFD)

        let responseData = try readAll(from: socketFD)
        return try TerminalServiceCodec.decodeResponse(responseData)
    }

    private static func makeSocketAddress(path: String) throws -> sockaddr_un {
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

    private static func writeAll(data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                if written < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                bytesRemaining -= written
                offset += written
            }
        }
    }

    private static func readAll(from fileDescriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func connectSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamSocketType

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else { throw POSIXError(.EHOSTUNREACH) }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var lastErrno: Int32 = EIO
        while let info = current {
            let socketFD = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if socketFD >= 0 {
                if connect(socketFD, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return socketFD }
                lastErrno = errno
                close(socketFD)
            } else {
                lastErrno = errno
            }
            current = info.pointee.ai_next
        }
        throw POSIXError(POSIXErrorCode(rawValue: lastErrno) ?? .EIO)
    }

    private static func shutdownSocketWrite(_ fileDescriptor: Int32) {
        #if canImport(Darwin)
            shutdown(fileDescriptor, SHUT_WR)
        #else
            shutdown(fileDescriptor, Int32(SHUT_WR))
        #endif
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }
}

public final class TerminalServiceTCPServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let authToken: String?
    private let queue: DispatchQueue
    private let handleRequest: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public private(set) var listeningPort: Int = 0

    public init(
        host: String, port: Int, authToken: String? = nil, queue: DispatchQueue,
        handleRequest: @escaping @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    ) {
        self.host = host
        self.port = port
        self.authToken = authToken
        self.queue = queue
        self.handleRequest = handleRequest
    }

    public func start() throws {
        let socketFD = socket(AF_INET, Self.streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close(socketFD)
            throw POSIXError(.EADDRNOTAVAIL)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }

        guard listen(socketFD, 16) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        try setNonBlocking(socketFD)

        listeningPort = try Self.resolveListeningPort(socketFD: socketFD)
        listenSocketFD = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReadyConnections() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenSocketFD >= 0 { close(self.listenSocketFD) }
        }
        acceptSource = source
        source.resume()
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    private func acceptReadyConnections() {
        while true {
            let clientFD = accept(listenSocketFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                return
            }

            do {
                try setBlocking(clientFD)
                let requestData = try TerminalServiceServer.readAll(from: clientFD)
                let request = try TerminalServiceCodec.decodeRequest(requestData)
                let response = try validateAndHandle(request: request)
                let responseData = try TerminalServiceCodec.encodeResponse(response)
                try TerminalServiceServer.writeAll(data: responseData, to: clientFD)
            } catch {
                let fallback = TerminalServiceResponse(ok: false, message: String(describing: error))
                if let data = try? TerminalServiceCodec.encodeResponse(fallback) { try? TerminalServiceServer.writeAll(data: data, to: clientFD) }
            }

            Self.shutdownSocket(clientFD)
            close(clientFD)
        }
    }

    private func validateAndHandle(request: TerminalServiceRequest) throws -> TerminalServiceResponse {
        if let authToken, authToken != request.authToken { return TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.") }
        return try handleRequest(request)
    }

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func resolveListeningPort(socketFD: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(socketFD, sockaddrPointer, &length) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func shutdownSocket(_ fileDescriptor: Int32) {
        #if canImport(Darwin)
            shutdown(fileDescriptor, SHUT_RDWR)
        #else
            shutdown(fileDescriptor, Int32(SHUT_RDWR))
        #endif
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }
}

extension timeval {
    fileprivate init(_ seconds: TimeInterval) {
        let wholeSeconds = Int(seconds.rounded(.down))
        #if canImport(Glibc)
            let microseconds = Int((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        #else
            let microseconds = Int32((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        #endif
        self.init(tv_sec: wholeSeconds, tv_usec: microseconds)
    }
}
