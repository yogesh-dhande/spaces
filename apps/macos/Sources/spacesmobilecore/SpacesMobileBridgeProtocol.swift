import Foundation
import spacesterminalcore

public enum SpacesMobileFirstPartyPolicy { public static let allowedBundleID = "com.yogeshdhande.spacesmobile" }

public struct SpacesMobileClientApp: Codable, Sendable, Equatable {
    public let installationID: String
    public let bundleID: String
    public let platform: String
    public let deviceName: String
    public let appVersion: String?

    public init(installationID: String, bundleID: String, platform: String, deviceName: String, appVersion: String?) {
        self.installationID = installationID
        self.bundleID = bundleID
        self.platform = platform
        self.deviceName = deviceName
        self.appVersion = appVersion
    }
}

public struct SpacesMobileWorkspaceSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let projectName: String
    public let title: String
    public let branch: String?
    public let targetBranch: String?
    public let dir: String
    public let isRunning: Bool
    public let isArchived: Bool
    public let isHidden: Bool
    public let isDefault: Bool
    public let sessionCount: Int

    public init(
        id: String, projectID: String, projectName: String, title: String, branch: String?, targetBranch: String?, dir: String, isRunning: Bool,
        isArchived: Bool, isHidden: Bool, isDefault: Bool, sessionCount: Int
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.title = title
        self.branch = branch
        self.targetBranch = targetBranch
        self.dir = dir
        self.isRunning = isRunning
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isDefault = isDefault
        self.sessionCount = sessionCount
    }
}

public struct SpacesMobileTerminalSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let workingDirectory: String
    public let state: TerminalSessionState
    public let backend: TerminalSessionBackendKind
    public let lifetimePolicy: TerminalSessionLifetimePolicy
    public let servicePID: Int32
    public let childPID: Int32?
    public let workspaceID: String?
    public let workspaceTitle: String?
    public let projectID: String?
    public let projectName: String?
    public let createdAt: String
    public let updatedAt: String
    public let isControlAvailable: Bool
    public let isSubscriptionAvailable: Bool
    public let attachmentSnapshot: TerminalSessionAttachmentSnapshot

    public init(
        id: String, title: String, workingDirectory: String, state: TerminalSessionState, backend: TerminalSessionBackendKind,
        lifetimePolicy: TerminalSessionLifetimePolicy, servicePID: Int32, childPID: Int32?, workspaceID: String?, workspaceTitle: String?,
        projectID: String?, projectName: String?, createdAt: String, updatedAt: String, isControlAvailable: Bool, isSubscriptionAvailable: Bool,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.state = state
        self.backend = backend
        self.lifetimePolicy = lifetimePolicy
        self.servicePID = servicePID
        self.childPID = childPID
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.projectID = projectID
        self.projectName = projectName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isControlAvailable = isControlAvailable
        self.isSubscriptionAvailable = isSubscriptionAvailable
        self.attachmentSnapshot = attachmentSnapshot
    }
}

public struct SpacesMobileOverviewPayload: Codable, Sendable, Equatable {
    public let workspaces: [SpacesMobileWorkspaceSummary]
    public let sessions: [SpacesMobileTerminalSessionSummary]

    public init(workspaces: [SpacesMobileWorkspaceSummary], sessions: [SpacesMobileTerminalSessionSummary]) {
        self.workspaces = workspaces
        self.sessions = sessions
    }
}

public struct SpacesMobileBridgeRequest: Codable, Sendable, Equatable {
    public let command: String
    public let authToken: String?
    public let pairingCode: String?
    public let clientApp: SpacesMobileClientApp?
    public let sessionID: String?
    public let clientID: String?
    public let client: TerminalClient?
    public let attachmentMode: TerminalAttachmentMode?
    public let text: String?
    public let key: String?
    public let appendNewline: Bool

    public init(
        command: String, authToken: String? = nil, pairingCode: String? = nil, clientApp: SpacesMobileClientApp? = nil, sessionID: String? = nil,
        clientID: String? = nil, client: TerminalClient? = nil, attachmentMode: TerminalAttachmentMode? = nil, text: String? = nil,
        key: String? = nil, appendNewline: Bool = false
    ) {
        self.command = command
        self.authToken = authToken
        self.pairingCode = pairingCode
        self.clientApp = clientApp
        self.sessionID = sessionID
        self.clientID = clientID
        self.client = client
        self.attachmentMode = attachmentMode
        self.text = text
        self.key = key
        self.appendNewline = appendNewline
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case authToken
        case pairingCode
        case clientApp
        case sessionID
        case clientID
        case client
        case attachmentMode
        case text
        case key
        case appendNewline
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        pairingCode = try container.decodeIfPresent(String.self, forKey: .pairingCode)
        clientApp = try container.decodeIfPresent(SpacesMobileClientApp.self, forKey: .clientApp)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        client = try container.decodeIfPresent(TerminalClient.self, forKey: .client)
        attachmentMode = try container.decodeIfPresent(TerminalAttachmentMode.self, forKey: .attachmentMode)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(authToken, forKey: .authToken)
        try container.encodeIfPresent(pairingCode, forKey: .pairingCode)
        try container.encodeIfPresent(clientApp, forKey: .clientApp)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(clientID, forKey: .clientID)
        try container.encodeIfPresent(client, forKey: .client)
        try container.encodeIfPresent(attachmentMode, forKey: .attachmentMode)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(appendNewline, forKey: .appendNewline)
    }
}

public struct SpacesMobileBridgeResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String
    public let overview: SpacesMobileOverviewPayload?
    public let issuedAuthToken: String?
    public let sessionState: GhosttyRemoteSessionStatePayload?

    public init(
        ok: Bool, message: String, overview: SpacesMobileOverviewPayload? = nil, issuedAuthToken: String? = nil,
        sessionState: GhosttyRemoteSessionStatePayload? = nil
    ) {
        self.ok = ok
        self.message = message
        self.overview = overview
        self.issuedAuthToken = issuedAuthToken
        self.sessionState = sessionState
    }
}

public enum SpacesMobileBridgeCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encodeRequest(_ request: SpacesMobileBridgeRequest) throws -> Data { try encoder.encode(request) }

    public static func decodeRequest(_ data: Data) throws -> SpacesMobileBridgeRequest {
        try decoder.decode(SpacesMobileBridgeRequest.self, from: data)
    }

    public static func encodeResponse(_ response: SpacesMobileBridgeResponse) throws -> Data { try encoder.encode(response) }

    public static func decodeResponse(_ data: Data) throws -> SpacesMobileBridgeResponse {
        try decoder.decode(SpacesMobileBridgeResponse.self, from: data)
    }
}
