import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct TerminalServiceRequest: Codable, Sendable, Equatable {
    public let authToken: String?
    public let command: TerminalServiceCommand

    public init(command: TerminalServiceCommand, authToken: String? = nil) {
        self.authToken = authToken
        self.command = command
    }

    public func withAuthToken(_ authToken: String?) -> TerminalServiceRequest { TerminalServiceRequest(command: command, authToken: authToken) }

    public var commandName: String { command.name }
    public var sessionID: String? { command.sessionID }
}

public struct TerminalServiceEmptyPayload: Codable, Sendable, Equatable { public init() {} }

public struct TerminalServiceSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String

    public init(sessionID: String) { self.sessionID = sessionID }
}

public struct TerminalServiceCreateRequest: Codable, Sendable, Equatable {
    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let runtimeManifest: TerminalServiceWorkspaceRuntimeManifest?
    public let worktreeRefresh: TerminalServiceWorktreeRefreshRequest?

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration, runtimeManifest: TerminalServiceWorkspaceRuntimeManifest? = nil,
        worktreeRefresh: TerminalServiceWorktreeRefreshRequest? = nil
    ) {
        self.launchConfiguration = launchConfiguration
        self.runtimeManifest = runtimeManifest
        self.worktreeRefresh = worktreeRefresh
    }
}

public struct TerminalServicePrepareWorkspaceRequest: Codable, Sendable, Equatable {
    public let runtimeManifest: TerminalServiceWorkspaceRuntimeManifest
    public let worktreeRefresh: TerminalServiceWorktreeRefreshRequest?

    public init(runtimeManifest: TerminalServiceWorkspaceRuntimeManifest, worktreeRefresh: TerminalServiceWorktreeRefreshRequest? = nil) {
        self.runtimeManifest = runtimeManifest
        self.worktreeRefresh = worktreeRefresh
    }
}

public struct TerminalServiceRunWorkspaceCommandRequest: Codable, Sendable, Equatable {
    public let runtimeManifest: TerminalServiceWorkspaceRuntimeManifest
    public let worktreeRefresh: TerminalServiceWorktreeRefreshRequest?
    public let workspaceCommand: TerminalServiceWorkspaceCommandRequest

    public init(
        runtimeManifest: TerminalServiceWorkspaceRuntimeManifest, worktreeRefresh: TerminalServiceWorktreeRefreshRequest? = nil,
        workspaceCommand: TerminalServiceWorkspaceCommandRequest
    ) {
        self.runtimeManifest = runtimeManifest
        self.worktreeRefresh = worktreeRefresh
        self.workspaceCommand = workspaceCommand
    }
}

public struct TerminalServiceControlCommandRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let controlRequest: TerminalControlRequest

    public init(sessionID: String, controlRequest: TerminalControlRequest) {
        self.sessionID = sessionID
        self.controlRequest = controlRequest
    }
}

public struct TerminalServiceAgentSignalRequest: Codable, Sendable, Equatable {
    public let event: TerminalServiceAgentSignalEvent

    public init(event: TerminalServiceAgentSignalEvent) { self.event = event }
}

public struct TerminalServiceAgentSignalAcknowledgementRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let eventIDs: [String]

    public init(sessionID: String, eventIDs: [String]) {
        self.sessionID = sessionID
        self.eventIDs = eventIDs
    }
}

public struct TerminalServiceTerminalLinkResolveRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let terminalLink: String?

    public init(sessionID: String, terminalLink: String?) {
        self.sessionID = sessionID
        self.terminalLink = terminalLink
    }
}

public struct TerminalServiceTerminalLinkChunkRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let terminalLinkID: String?
    public let offset: Int64?
    public let limit: Int?

    public init(sessionID: String, terminalLinkID: String?, offset: Int64? = nil, limit: Int? = nil) {
        self.sessionID = sessionID
        self.terminalLinkID = terminalLinkID
        self.offset = offset
        self.limit = limit
    }
}

public enum TerminalServiceCommand: Sendable, Equatable {
    case ping
    case shutdownIfIdle
    case shutdown
    /// FROZEN — this case must never be renamed or removed, and only optional fields may ever be
    /// added to its (currently empty) payload. It is sent by a same-or-older bundled CLI/installer to
    /// any future daemon to trigger an exec-in-place staged-update handoff, so a newer daemon must
    /// keep decoding exactly this shape forever. Carries no payload: the daemon re-execs its own
    /// staged binary; the sender names nothing.
    case applyStagedUpdate
    case create(TerminalServiceCreateRequest)
    case prepareWorkspace(TerminalServicePrepareWorkspaceRequest)
    case runWorkspaceCommand(TerminalServiceRunWorkspaceCommandRequest)
    case terminate(TerminalServiceSessionRequest)
    case list
    case state(TerminalServiceSessionRequest)
    case subscribe(TerminalServiceSessionRequest)
    case control(TerminalServiceControlCommandRequest)
    case agentSignal(TerminalServiceAgentSignalRequest)
    case ackAgentSignals(TerminalServiceAgentSignalAcknowledgementRequest)
    case profileCommand(TerminalServiceProfileCommand)
    case resolveTerminalLink(TerminalServiceTerminalLinkResolveRequest)
    case readTerminalLinkChunk(TerminalServiceTerminalLinkChunkRequest)

    public var name: String {
        switch self {
        case .ping: "ping"
        case .shutdownIfIdle: "shutdownIfIdle"
        case .shutdown: "shutdown"
        case .applyStagedUpdate: "applyStagedUpdate"
        case .create: "create"
        case .prepareWorkspace: "prepareWorkspace"
        case .runWorkspaceCommand: "runWorkspaceCommand"
        case .terminate: "terminate"
        case .list: "list"
        case .state: "state"
        case .subscribe: "subscribe"
        case .control: "control"
        case .agentSignal: "agentSignal"
        case .ackAgentSignals: "ackAgentSignals"
        case .profileCommand: "profileCommand"
        case .resolveTerminalLink: "resolveTerminalLink"
        case .readTerminalLinkChunk: "readTerminalLinkChunk"
        }
    }

    public var sessionID: String? {
        switch self {
        case .terminate(let payload), .state(let payload), .subscribe(let payload): payload.sessionID
        case .control(let payload): payload.sessionID
        case .agentSignal(let payload): payload.event.sessionID
        case .ackAgentSignals(let payload): payload.sessionID
        case .resolveTerminalLink(let payload): payload.sessionID
        case .readTerminalLinkChunk(let payload): payload.sessionID
        default: nil
        }
    }

    public var controlCommandName: String? {
        if case .control(let payload) = self { return payload.controlRequest.command }
        return nil
    }
}

extension TerminalServiceCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case ping
        case shutdownIfIdle
        case shutdown
        case applyStagedUpdate
        case create
        case prepareWorkspace
        case runWorkspaceCommand
        case terminate
        case list
        case state
        case subscribe
        case control
        case agentSignal
        case ackAgentSignals
        case profileCommand
        case resolveTerminalLink
        case readTerminalLinkChunk
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Terminal service command must contain exactly one payload."))
        }
        switch key {
        case .ping:
            _ = try container.decode(TerminalServiceEmptyPayload.self, forKey: key)
            self = .ping
        case .shutdownIfIdle:
            _ = try container.decode(TerminalServiceEmptyPayload.self, forKey: key)
            self = .shutdownIfIdle
        case .shutdown:
            _ = try container.decode(TerminalServiceEmptyPayload.self, forKey: key)
            self = .shutdown
        case .applyStagedUpdate:
            _ = try container.decode(TerminalServiceEmptyPayload.self, forKey: key)
            self = .applyStagedUpdate
        case .create: self = .create(try container.decode(TerminalServiceCreateRequest.self, forKey: key))
        case .prepareWorkspace: self = .prepareWorkspace(try container.decode(TerminalServicePrepareWorkspaceRequest.self, forKey: key))
        case .runWorkspaceCommand: self = .runWorkspaceCommand(try container.decode(TerminalServiceRunWorkspaceCommandRequest.self, forKey: key))
        case .terminate: self = .terminate(try container.decode(TerminalServiceSessionRequest.self, forKey: key))
        case .list:
            _ = try container.decode(TerminalServiceEmptyPayload.self, forKey: key)
            self = .list
        case .state: self = .state(try container.decode(TerminalServiceSessionRequest.self, forKey: key))
        case .subscribe: self = .subscribe(try container.decode(TerminalServiceSessionRequest.self, forKey: key))
        case .control: self = .control(try container.decode(TerminalServiceControlCommandRequest.self, forKey: key))
        case .agentSignal: self = .agentSignal(try container.decode(TerminalServiceAgentSignalRequest.self, forKey: key))
        case .ackAgentSignals: self = .ackAgentSignals(try container.decode(TerminalServiceAgentSignalAcknowledgementRequest.self, forKey: key))
        case .profileCommand: self = .profileCommand(try container.decode(TerminalServiceProfileCommand.self, forKey: key))
        case .resolveTerminalLink: self = .resolveTerminalLink(try container.decode(TerminalServiceTerminalLinkResolveRequest.self, forKey: key))
        case .readTerminalLinkChunk: self = .readTerminalLinkChunk(try container.decode(TerminalServiceTerminalLinkChunkRequest.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping: try container.encode(TerminalServiceEmptyPayload(), forKey: .ping)
        case .shutdownIfIdle: try container.encode(TerminalServiceEmptyPayload(), forKey: .shutdownIfIdle)
        case .shutdown: try container.encode(TerminalServiceEmptyPayload(), forKey: .shutdown)
        case .applyStagedUpdate: try container.encode(TerminalServiceEmptyPayload(), forKey: .applyStagedUpdate)
        case .create(let payload): try container.encode(payload, forKey: .create)
        case .prepareWorkspace(let payload): try container.encode(payload, forKey: .prepareWorkspace)
        case .runWorkspaceCommand(let payload): try container.encode(payload, forKey: .runWorkspaceCommand)
        case .terminate(let payload): try container.encode(payload, forKey: .terminate)
        case .list: try container.encode(TerminalServiceEmptyPayload(), forKey: .list)
        case .state(let payload): try container.encode(payload, forKey: .state)
        case .subscribe(let payload): try container.encode(payload, forKey: .subscribe)
        case .control(let payload): try container.encode(payload, forKey: .control)
        case .agentSignal(let payload): try container.encode(payload, forKey: .agentSignal)
        case .ackAgentSignals(let payload): try container.encode(payload, forKey: .ackAgentSignals)
        case .profileCommand(let payload): try container.encode(payload, forKey: .profileCommand)
        case .resolveTerminalLink(let payload): try container.encode(payload, forKey: .resolveTerminalLink)
        case .readTerminalLinkChunk(let payload): try container.encode(payload, forKey: .readTerminalLinkChunk)
        }
    }
}

public struct TerminalServiceProfileProjectSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?

    public init(id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
    }
}

public struct TerminalServiceProfileWorkspaceRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let dir: String
    public let dirname: String?
    public let branch: String?
    public let baseBranch: String?
    public let isDefault: Bool
    public let isArchived: Bool
    public let isHidden: Bool
    public let isRunning: Bool
    public let lastLaunchedAt: String?
    public let notes: String?

    public init(
        id: String, projectID: String, dir: String, dirname: String?, branch: String?, baseBranch: String?, isDefault: Bool, isArchived: Bool,
        isHidden: Bool, isRunning: Bool, lastLaunchedAt: String?, notes: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.dir = dir
        self.dirname = dirname
        self.branch = branch
        self.baseBranch = baseBranch
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isRunning = isRunning
        self.lastLaunchedAt = lastLaunchedAt
        self.notes = notes
    }

    /// Name shown to users. Git workspaces show their branch; non-git workspaces show the folder name.
    public var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        return (dir as NSString).lastPathComponent
    }
}

public struct TerminalServiceProfileCommandResponse: Codable, Sendable, Equatable {
    public let message: String
    public let projects: [TerminalServiceProfileProjectSummary]?
    public let workspaces: [TerminalServiceProfileWorkspaceRecord]?
    public let workspace: TerminalServiceProfileWorkspaceRecord?
    public let terminalSessions: [TerminalServiceSessionSummary]?
    public let terminalSession: TerminalServiceSessionSummary?
    public let terminalOutput: String?

    public init(
        message: String, projects: [TerminalServiceProfileProjectSummary]? = nil, workspaces: [TerminalServiceProfileWorkspaceRecord]? = nil,
        workspace: TerminalServiceProfileWorkspaceRecord? = nil, terminalSessions: [TerminalServiceSessionSummary]? = nil,
        terminalSession: TerminalServiceSessionSummary? = nil, terminalOutput: String? = nil
    ) {
        self.message = message
        self.projects = projects
        self.workspaces = workspaces
        self.workspace = workspace
        self.terminalSessions = terminalSessions
        self.terminalSession = terminalSession
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
    public let deviceID: String?
    public let location: TerminalServiceWorkspaceLocation
    public let localPath: String
    public let remotePath: String?
    public let branch: String?
    public let baseBranch: String?
    public let gitRemoteURL: String?
    public let namedPorts: [TerminalServiceWorkspaceRuntimePortMapping]
    public let processEnvironment: [String: String]
    public let allowedFileRoots: [String]

    public init(
        workspaceID: String, projectID: String, deviceID: String?, location: TerminalServiceWorkspaceLocation, localPath: String, remotePath: String?,
        branch: String?, baseBranch: String?, gitRemoteURL: String?, namedPorts: [TerminalServiceWorkspaceRuntimePortMapping],
        processEnvironment: [String: String], allowedFileRoots: [String]
    ) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.deviceID = deviceID
        self.location = location
        self.localPath = localPath
        self.remotePath = remotePath
        self.branch = branch
        self.baseBranch = baseBranch
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
    public let environmentKeys: [String]
    public let createdAt: String

    public init(
        id: String, sessionID: String, workspaceID: String?, workspacePath: String?, type: String, provider: String = "spaces", label: String? = nil,
        terminalTrackingID: String? = nil, environmentKeys: [String] = [], createdAt: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.workspacePath = workspacePath
        self.type = type
        self.provider = provider
        self.label = label
        self.terminalTrackingID = terminalTrackingID
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
    public let artifactKind: String?
    public let byteCount: Int64?
    public let externalURL: String?

    public init(
        id: String, source: String, originalLink: String, displayName: String, contentType: String?, artifactKind: String?, byteCount: Int64?,
        externalURL: String?
    ) {
        self.id = id
        self.source = source
        self.originalLink = originalLink
        self.displayName = displayName
        self.contentType = contentType
        self.artifactKind = artifactKind
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

public struct TerminalServiceDaemonStatus: Codable, Sendable, Equatable {
    /// Version of the build this daemon process is *running* — compiled in at build time, so it is
    /// fixed for the life of the process.
    public let version: String
    /// Version of the Spaces build currently *installed* on the daemon's device, read from disk each
    /// time a status is built. It moves ahead of `version` when an update lands while the daemon keeps
    /// running the older build, and it is `nil` when no installed build can be identified (a daemon
    /// launched straight from a development build directory).
    public let installedVersion: String?
    public let certificateFingerprint: String?
    public let activeSessionCount: Int
    /// Wire-contract version the daemon speaks. Client and daemon must match exactly.
    public let protocolVersion: Int
    /// Live tracked processes that a daemon restart would kill (status `running`).
    public let runningProcesses: Int
    /// Coding agents actively working (status `spinning`).
    public let activeAgents: Int
    /// Coding agents awaiting user input (status `waiting`).
    public let waitingAgents: Int
    /// Daemon host OS: `"macOS"` or `"Linux"`. Lets clients tailor restart guidance — e.g. a remote
    /// Linux daemon must be updated from the Mac app.
    public let operatingSystem: String

    /// Protocol version reported when a peer's status omits the field entirely — i.e. a daemon old
    /// enough to predate wire-version negotiation. It must compare as incompatible against any real
    /// `SpacesWireProtocol.version` (which starts at 1) so such a peer is blocked, not mistaken for a
    /// match. See `unknownProtocolVersion` use in `init(from:)`.
    public static let unknownProtocolVersion = 0

    public init(
        version: String, installedVersion: String?, certificateFingerprint: String?, activeSessionCount: Int,
        protocolVersion: Int = SpacesWireProtocol.version, runningProcesses: Int = 0, activeAgents: Int = 0, waitingAgents: Int = 0,
        operatingSystem: String = TerminalServiceDaemonStatus.currentOperatingSystem
    ) {
        self.version = version
        self.installedVersion = installedVersion
        self.certificateFingerprint = certificateFingerprint
        self.activeSessionCount = activeSessionCount
        self.protocolVersion = protocolVersion
        self.runningProcesses = runningProcesses
        self.activeAgents = activeAgents
        self.waitingAgents = waitingAgents
        self.operatingSystem = operatingSystem
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case installedVersion
        case certificateFingerprint
        case activeSessionCount
        case protocolVersion
        case runningProcesses
        case activeAgents
        case waitingAgents
        case operatingSystem
    }

    /// This is the frozen core's contract: its decode must tolerate version skew so an incompatible
    /// peer can still be negotiated and recovered. Every field decodes with `decodeIfPresent` and a
    /// default, so a peer whose field set differs (an older build that omits a field this build added,
    /// or a newer build that adds one) still produces a decodable status instead of throwing
    /// `keyNotFound` on the very handshake meant to keep working. A missing `protocolVersion` defaults
    /// to `unknownProtocolVersion`, which `SpacesWireCompatibility` evaluates as incompatible.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        certificateFingerprint = try container.decodeIfPresent(String.self, forKey: .certificateFingerprint)
        activeSessionCount = try container.decodeIfPresent(Int.self, forKey: .activeSessionCount) ?? 0
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? Self.unknownProtocolVersion
        runningProcesses = try container.decodeIfPresent(Int.self, forKey: .runningProcesses) ?? 0
        activeAgents = try container.decodeIfPresent(Int.self, forKey: .activeAgents) ?? 0
        waitingAgents = try container.decodeIfPresent(Int.self, forKey: .waitingAgents) ?? 0
        operatingSystem = try container.decodeIfPresent(String.self, forKey: .operatingSystem) ?? Self.currentOperatingSystem
    }

    /// The OS of the process building this status (the daemon's own host).
    public static var currentOperatingSystem: String {
        #if os(Linux)
            "Linux"
        #else
            "macOS"
        #endif
    }

    public var isLinuxDaemon: Bool { operatingSystem == "Linux" }

    /// A newer Spaces is installed on the daemon's device than the build the daemon is running, so an
    /// update is staged and applies on its next restart.
    ///
    /// This is a fact about one device, answered by that device, so every client — Mac, iPhone, CLI —
    /// reads the same value. A client must never derive it by comparing the daemon's version against
    /// its *own* build: the iPhone app and the Linux daemon ship on unrelated release trains, so that
    /// comparison says nothing about whether an update is waiting on the other end.
    public var isUpdatePending: Bool {
        guard let installedVersion else { return false }
        return SpacesWireProtocol.isVersion(version, olderThan: installedVersion)
    }
}

public struct TerminalServiceResponse: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case ok
        case message
        case errorCode
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
        case daemonStatus
    }

    public let ok: Bool
    public let message: String
    /// Machine-readable failure category. Nil on success and omitted from the wire when nil.
    public let errorCode: SpacesDeviceErrorCode?
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
    public let daemonStatus: TerminalServiceDaemonStatus?
    let streamSocketPath: String?

    public init(
        ok: Bool, message: String, errorCode: SpacesDeviceErrorCode? = nil, session: TerminalServiceSessionSummary? = nil,
        sessions: [TerminalServiceSessionSummary]? = nil, servicePID: Int32? = nil, commandResult: TerminalServiceCommandResult? = nil,
        sessionState: GhosttyRemoteSessionStatePayload? = nil, controlResponse: TerminalControlResponse? = nil,
        terminalLinkMetadata: TerminalServiceTerminalLinkMetadata? = nil, terminalLinkChunk: TerminalServiceTerminalLinkChunk? = nil,
        agentSignals: [TerminalServiceAgentSignalEvent]? = nil, profile: TerminalServiceProfileCommandResponse? = nil,
        daemonStatus: TerminalServiceDaemonStatus? = nil, streamSocketPath: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.errorCode = errorCode
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
        self.daemonStatus = daemonStatus
        self.streamSocketPath = streamSocketPath
    }

    public init(
        ok: Bool, message: String, errorCode: SpacesDeviceErrorCode? = nil, session: TerminalServiceSessionSummary? = nil,
        sessions: [TerminalServiceSessionSummary]? = nil, servicePID: Int32? = nil, commandResult: TerminalServiceCommandResult? = nil,
        sessionState: GhosttyRemoteSessionStatePayload? = nil, controlResponse: TerminalControlResponse? = nil,
        terminalLinkMetadata: TerminalServiceTerminalLinkMetadata? = nil, terminalLinkChunk: TerminalServiceTerminalLinkChunk? = nil,
        agentSignals: [TerminalServiceAgentSignalEvent]? = nil
    ) {
        self.init(
            ok: ok, message: message, errorCode: errorCode, session: session, sessions: sessions, servicePID: servicePID,
            commandResult: commandResult, sessionState: sessionState, controlResponse: controlResponse, terminalLinkMetadata: terminalLinkMetadata,
            terminalLinkChunk: terminalLinkChunk, agentSignals: agentSignals, profile: nil)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ok: try container.decode(Bool.self, forKey: .ok), message: try container.decode(String.self, forKey: .message),
            errorCode: try container.decodeIfPresent(SpacesDeviceErrorCode.self, forKey: .errorCode),
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
            daemonStatus: try container.decodeIfPresent(TerminalServiceDaemonStatus.self, forKey: .daemonStatus))
    }

    /// Whether delivering this response must close the connection afterward. An unauthorized peer is
    /// not permitted to keep a pipelined connection open, so the daemon hangs up after replying. Both
    /// TLS server transports (Network and OpenSSL) share this single decision, keyed on the typed
    /// error code rather than the human-readable message.
    public var closesConnectionAfterDelivery: Bool { !ok && errorCode == .unauthorized }
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
