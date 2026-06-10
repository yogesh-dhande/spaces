import Foundation
import UniformTypeIdentifiers
import spacesterminalcore

public enum SpacesMobileFirstPartyPolicy { public static let allowedBundleID = "dev.usespaces.spacesmobile" }

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

public struct SpacesMobileProjectSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public let isCollapsed: Bool

    public init(id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.isCollapsed = isCollapsed
    }
}

public enum SpacesMobileRunState: String, Codable, Sendable, Equatable, Hashable {
    case notStarted
    case running
    case exited
}

public enum SpacesMobileCodingAgentActivityState: String, Codable, Sendable, Equatable, Hashable {
    case idle
    case spinning
    case waiting
    case done
}

public struct SpacesMobileWorkspaceProcessRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let name: String
    public let command: String
    public let templateID: String?
    public let processID: String?
    public let sessionID: String?
    public let runState: SpacesMobileRunState
    public let canRun: Bool
    public let canStop: Bool
    public let canRestart: Bool

    public init(
        id: String, workspaceID: String, name: String, command: String, templateID: String? = nil, processID: String?, sessionID: String?,
        runState: SpacesMobileRunState, canRun: Bool, canStop: Bool, canRestart: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.command = command
        self.templateID = templateID
        self.processID = processID
        self.sessionID = sessionID
        self.runState = runState
        self.canRun = canRun
        self.canStop = canStop
        self.canRestart = canRestart
    }
}

public struct SpacesMobileWorkspaceCodingAgentRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let name: String
    public let command: String
    public let launcherID: String?
    public let agentID: String?
    public let sessionID: String?
    public let isConfigured: Bool
    public let runState: SpacesMobileRunState
    public let activityState: SpacesMobileCodingAgentActivityState
    public let canRun: Bool
    public let canStop: Bool
    public let canRestart: Bool

    public init(
        id: String, workspaceID: String, name: String, command: String, launcherID: String? = nil, agentID: String?, sessionID: String?,
        isConfigured: Bool, runState: SpacesMobileRunState, activityState: SpacesMobileCodingAgentActivityState, canRun: Bool, canStop: Bool,
        canRestart: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.command = command
        self.launcherID = launcherID
        self.agentID = agentID
        self.sessionID = sessionID
        self.isConfigured = isConfigured
        self.runState = runState
        self.activityState = activityState
        self.canRun = canRun
        self.canStop = canStop
        self.canRestart = canRestart
    }
}

public struct SpacesMobileWorkspaceTerminalRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let title: String
    public let workingDirectory: String
    public let sessionID: String?
    public let runState: SpacesMobileRunState
    public let canOpenTerminal: Bool
    public let canStop: Bool

    public init(
        id: String, workspaceID: String, title: String, workingDirectory: String, sessionID: String?, runState: SpacesMobileRunState,
        canOpenTerminal: Bool, canStop: Bool = false
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.runState = runState
        self.canOpenTerminal = canOpenTerminal
        self.canStop = canStop
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID
        case title
        case workingDirectory
        case sessionID
        case runState
        case canOpenTerminal
        case canStop
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        title = try container.decode(String.self, forKey: .title)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        runState = try container.decode(SpacesMobileRunState.self, forKey: .runState)
        canOpenTerminal = try container.decode(Bool.self, forKey: .canOpenTerminal)
        canStop = try container.decodeIfPresent(Bool.self, forKey: .canStop) ?? false
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
    public let processRows: [SpacesMobileWorkspaceProcessRow]
    public let codingAgentRows: [SpacesMobileWorkspaceCodingAgentRow]
    public let terminalRows: [SpacesMobileWorkspaceTerminalRow]

    public init(
        id: String, projectID: String, projectName: String, title: String, branch: String?, targetBranch: String?, dir: String, isRunning: Bool,
        isArchived: Bool, isHidden: Bool, isDefault: Bool, sessionCount: Int, processRows: [SpacesMobileWorkspaceProcessRow] = [],
        codingAgentRows: [SpacesMobileWorkspaceCodingAgentRow] = [], terminalRows: [SpacesMobileWorkspaceTerminalRow] = []
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
        self.processRows = processRows
        self.codingAgentRows = codingAgentRows
        self.terminalRows = terminalRows
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case projectName
        case title
        case branch
        case targetBranch
        case dir
        case isRunning
        case isArchived
        case isHidden
        case isDefault
        case sessionCount
        case processRows
        case codingAgentRows
        case terminalRows
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decode(String.self, forKey: .projectID)
        projectName = try container.decode(String.self, forKey: .projectName)
        title = try container.decode(String.self, forKey: .title)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        targetBranch = try container.decodeIfPresent(String.self, forKey: .targetBranch)
        dir = try container.decode(String.self, forKey: .dir)
        isRunning = try container.decode(Bool.self, forKey: .isRunning)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
        processRows = try container.decodeIfPresent([SpacesMobileWorkspaceProcessRow].self, forKey: .processRows) ?? []
        codingAgentRows = try container.decodeIfPresent([SpacesMobileWorkspaceCodingAgentRow].self, forKey: .codingAgentRows) ?? []
        terminalRows = try container.decodeIfPresent([SpacesMobileWorkspaceTerminalRow].self, forKey: .terminalRows) ?? []
    }
}

public enum SpacesMobileTerminalSessionRowKind: String, Codable, Sendable, Equatable {
    case liveSession
    case process
    case agent
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
    public let rowKind: SpacesMobileTerminalSessionRowKind
    public let rowSourceID: String?
    public let hasFinalRender: Bool

    public init(
        id: String, title: String, workingDirectory: String, state: TerminalSessionState, backend: TerminalSessionBackendKind,
        lifetimePolicy: TerminalSessionLifetimePolicy, servicePID: Int32, childPID: Int32?, workspaceID: String?, workspaceTitle: String?,
        projectID: String?, projectName: String?, createdAt: String, updatedAt: String, isControlAvailable: Bool, isSubscriptionAvailable: Bool,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot, rowKind: SpacesMobileTerminalSessionRowKind = .liveSession, rowSourceID: String? = nil,
        hasFinalRender: Bool = false
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
        self.rowKind = rowKind
        self.rowSourceID = rowSourceID
        self.hasFinalRender = hasFinalRender
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case workingDirectory
        case state
        case backend
        case lifetimePolicy
        case servicePID
        case childPID
        case workspaceID
        case workspaceTitle
        case projectID
        case projectName
        case createdAt
        case updatedAt
        case isControlAvailable
        case isSubscriptionAvailable
        case attachmentSnapshot
        case rowKind
        case rowSourceID
        case hasFinalRender
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        state = try container.decode(TerminalSessionState.self, forKey: .state)
        backend = try container.decode(TerminalSessionBackendKind.self, forKey: .backend)
        lifetimePolicy = try container.decode(TerminalSessionLifetimePolicy.self, forKey: .lifetimePolicy)
        servicePID = try container.decode(Int32.self, forKey: .servicePID)
        childPID = try container.decodeIfPresent(Int32.self, forKey: .childPID)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        workspaceTitle = try container.decodeIfPresent(String.self, forKey: .workspaceTitle)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        isControlAvailable = try container.decode(Bool.self, forKey: .isControlAvailable)
        isSubscriptionAvailable = try container.decode(Bool.self, forKey: .isSubscriptionAvailable)
        attachmentSnapshot =
            try container.decodeIfPresent(TerminalSessionAttachmentSnapshot.self, forKey: .attachmentSnapshot) ?? TerminalSessionAttachmentSnapshot()
        rowKind = try container.decodeIfPresent(SpacesMobileTerminalSessionRowKind.self, forKey: .rowKind) ?? .liveSession
        rowSourceID = try container.decodeIfPresent(String.self, forKey: .rowSourceID)
        hasFinalRender = try container.decodeIfPresent(Bool.self, forKey: .hasFinalRender) ?? false
    }
}

public struct SpacesMobileOverviewPayload: Codable, Sendable, Equatable {
    public let projects: [SpacesMobileProjectSummary]
    public let workspaces: [SpacesMobileWorkspaceSummary]
    public let sessions: [SpacesMobileTerminalSessionSummary]

    public init(
        projects: [SpacesMobileProjectSummary] = [], workspaces: [SpacesMobileWorkspaceSummary], sessions: [SpacesMobileTerminalSessionSummary]
    ) {
        self.projects = projects
        self.workspaces = workspaces
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case workspaces
        case sessions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([SpacesMobileProjectSummary].self, forKey: .projects) ?? []
        workspaces = try container.decodeIfPresent([SpacesMobileWorkspaceSummary].self, forKey: .workspaces) ?? []
        sessions = try container.decodeIfPresent([SpacesMobileTerminalSessionSummary].self, forKey: .sessions) ?? []
    }
}

public struct SpacesMobileWorkspaceCreateOptions: Codable, Sendable, Equatable {
    public let projects: [SpacesMobileProjectSummary]
    public let selectedProjectID: String?
    public let branchOptions: [String]

    public init(projects: [SpacesMobileProjectSummary], selectedProjectID: String?, branchOptions: [String]) {
        self.projects = projects
        self.selectedProjectID = selectedProjectID
        self.branchOptions = branchOptions
    }
}

public enum SpacesMobileTerminalLinkMediaKind: String, Codable, Sendable, Equatable {
    case image
    case video
}

public enum SpacesMobileTerminalLinkSource: String, Codable, Sendable, Equatable {
    case localFile
    case externalURL
}

public struct SpacesMobileTerminalLinkMetadata: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: SpacesMobileTerminalLinkSource
    public let originalLink: String
    public let displayName: String
    public let contentType: String?
    public let mediaKind: SpacesMobileTerminalLinkMediaKind?
    public let byteCount: Int64?
    public let externalURL: String?

    public init(
        id: String, source: SpacesMobileTerminalLinkSource, originalLink: String, displayName: String, contentType: String?,
        mediaKind: SpacesMobileTerminalLinkMediaKind?, byteCount: Int64?, externalURL: String?
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

public struct SpacesMobileTerminalLinkChunk: Codable, Sendable, Equatable {
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

public enum SpacesMobileTerminalLinkClassifier {
    public static func mediaKind(contentType: String?, pathExtension: String?) -> SpacesMobileTerminalLinkMediaKind? {
        let trimmedContentType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedContentType, !trimmedContentType.isEmpty, let type = UTType(mimeType: trimmedContentType) { return mediaKind(for: type) }

        let trimmedExtension = pathExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        if let trimmedExtension, !trimmedExtension.isEmpty, let type = UTType(filenameExtension: trimmedExtension) { return mediaKind(for: type) }

        return nil
    }

    public static func preferredContentType(pathExtension: String?) -> String? {
        let trimmedExtension = pathExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        guard let trimmedExtension, !trimmedExtension.isEmpty else { return nil }
        return UTType(filenameExtension: trimmedExtension)?.preferredMIMEType
    }

    public static func preferredFilenameExtension(contentType: String?, fallback: String?) -> String {
        if let contentType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines), !contentType.isEmpty,
            let preferred = UTType(mimeType: contentType)?.preferredFilenameExtension
        {
            return preferred
        }
        let fallback = fallback?.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) ?? ""
        return fallback.isEmpty ? "dat" : fallback
    }

    private static func mediaKind(for type: UTType) -> SpacesMobileTerminalLinkMediaKind? {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }
}

public struct SpacesMobileBridgeRequest: Codable, Sendable, Equatable {
    public let command: String
    public let authToken: String?
    public let pairingCode: String?
    public let pairingNonce: String?
    public let clientApp: SpacesMobileClientApp?
    public let sessionID: String?
    public let clientID: String?
    public let client: TerminalClient?
    public let attachmentMode: TerminalAttachmentMode?
    public let text: String?
    public let key: String?
    public let columns: Int?
    public let rows: Int?
    public let ownerEpoch: UInt64?
    public let resizeSerial: UInt64?
    public let scrollHorizontal: Double?
    public let scrollVertical: Double?
    public let scrollMods: Int32?
    public let appendNewline: Bool
    public let projectID: String?
    public let workspaceID: String?
    public let workspaceTitle: String?
    public let branch: String?
    public let targetBranch: String?
    public let directoryName: String?
    public let allowExistingBranchReuse: Bool
    public let processKey: String?
    public let processID: String?
    public let processTemplateID: String?
    public let agentName: String?
    public let agentID: String?
    public let agentLauncherID: String?
    public let terminalLink: String?
    public let terminalLinkID: String?
    public let chunkOffset: Int64?
    public let chunkLimit: Int?

    public init(
        command: String, authToken: String? = nil, pairingCode: String? = nil, pairingNonce: String? = nil, clientApp: SpacesMobileClientApp? = nil,
        sessionID: String? = nil, clientID: String? = nil, client: TerminalClient? = nil, attachmentMode: TerminalAttachmentMode? = nil,
        text: String? = nil, key: String? = nil, columns: Int? = nil, rows: Int? = nil, ownerEpoch: UInt64? = nil, resizeSerial: UInt64? = nil,
        scrollHorizontal: Double? = nil, scrollVertical: Double? = nil, scrollMods: Int32? = nil, appendNewline: Bool = false,
        projectID: String? = nil, workspaceID: String? = nil, workspaceTitle: String? = nil, branch: String? = nil, targetBranch: String? = nil,
        directoryName: String? = nil, allowExistingBranchReuse: Bool = false, processKey: String? = nil, processID: String? = nil,
        processTemplateID: String? = nil, agentName: String? = nil, agentID: String? = nil, agentLauncherID: String? = nil,
        terminalLink: String? = nil, terminalLinkID: String? = nil, chunkOffset: Int64? = nil, chunkLimit: Int? = nil
    ) {
        self.command = command
        self.authToken = authToken
        self.pairingCode = pairingCode
        self.pairingNonce = pairingNonce
        self.clientApp = clientApp
        self.sessionID = sessionID
        self.clientID = clientID
        self.client = client
        self.attachmentMode = attachmentMode
        self.text = text
        self.key = key
        self.columns = columns
        self.rows = rows
        self.ownerEpoch = ownerEpoch
        self.resizeSerial = resizeSerial
        self.scrollHorizontal = scrollHorizontal
        self.scrollVertical = scrollVertical
        self.scrollMods = scrollMods
        self.appendNewline = appendNewline
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.branch = branch
        self.targetBranch = targetBranch
        self.directoryName = directoryName
        self.allowExistingBranchReuse = allowExistingBranchReuse
        self.processKey = processKey
        self.processID = processID
        self.processTemplateID = processTemplateID
        self.agentName = agentName
        self.agentID = agentID
        self.agentLauncherID = agentLauncherID
        self.terminalLink = terminalLink
        self.terminalLinkID = terminalLinkID
        self.chunkOffset = chunkOffset
        self.chunkLimit = chunkLimit
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case authToken
        case pairingCode
        case pairingNonce
        case clientApp
        case sessionID
        case clientID
        case client
        case attachmentMode
        case text
        case key
        case columns
        case rows
        case ownerEpoch
        case resizeSerial
        case scrollHorizontal
        case scrollVertical
        case scrollMods
        case appendNewline
        case projectID
        case workspaceID
        case workspaceTitle
        case branch
        case targetBranch
        case directoryName
        case allowExistingBranchReuse
        case processKey
        case processID
        case processTemplateID
        case agentName
        case agentID
        case agentLauncherID
        case terminalLink
        case terminalLinkID
        case chunkOffset
        case chunkLimit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        pairingCode = try container.decodeIfPresent(String.self, forKey: .pairingCode)
        pairingNonce = try container.decodeIfPresent(String.self, forKey: .pairingNonce)
        clientApp = try container.decodeIfPresent(SpacesMobileClientApp.self, forKey: .clientApp)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        client = try container.decodeIfPresent(TerminalClient.self, forKey: .client)
        attachmentMode = try container.decodeIfPresent(TerminalAttachmentMode.self, forKey: .attachmentMode)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        ownerEpoch = try container.decodeIfPresent(UInt64.self, forKey: .ownerEpoch)
        resizeSerial = try container.decodeIfPresent(UInt64.self, forKey: .resizeSerial)
        scrollHorizontal = try container.decodeIfPresent(Double.self, forKey: .scrollHorizontal)
        scrollVertical = try container.decodeIfPresent(Double.self, forKey: .scrollVertical)
        scrollMods = try container.decodeIfPresent(Int32.self, forKey: .scrollMods)
        appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? false
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        workspaceTitle = try container.decodeIfPresent(String.self, forKey: .workspaceTitle)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        targetBranch = try container.decodeIfPresent(String.self, forKey: .targetBranch)
        directoryName = try container.decodeIfPresent(String.self, forKey: .directoryName)
        allowExistingBranchReuse = try container.decodeIfPresent(Bool.self, forKey: .allowExistingBranchReuse) ?? false
        processKey = try container.decodeIfPresent(String.self, forKey: .processKey)
        processID = try container.decodeIfPresent(String.self, forKey: .processID)
        processTemplateID = try container.decodeIfPresent(String.self, forKey: .processTemplateID)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        agentLauncherID = try container.decodeIfPresent(String.self, forKey: .agentLauncherID)
        terminalLink = try container.decodeIfPresent(String.self, forKey: .terminalLink)
        terminalLinkID = try container.decodeIfPresent(String.self, forKey: .terminalLinkID)
        chunkOffset = try container.decodeIfPresent(Int64.self, forKey: .chunkOffset)
        chunkLimit = try container.decodeIfPresent(Int.self, forKey: .chunkLimit)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(authToken, forKey: .authToken)
        try container.encodeIfPresent(pairingCode, forKey: .pairingCode)
        try container.encodeIfPresent(pairingNonce, forKey: .pairingNonce)
        try container.encodeIfPresent(clientApp, forKey: .clientApp)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(clientID, forKey: .clientID)
        try container.encodeIfPresent(client, forKey: .client)
        try container.encodeIfPresent(attachmentMode, forKey: .attachmentMode)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(columns, forKey: .columns)
        try container.encodeIfPresent(rows, forKey: .rows)
        try container.encodeIfPresent(ownerEpoch, forKey: .ownerEpoch)
        try container.encodeIfPresent(resizeSerial, forKey: .resizeSerial)
        try container.encodeIfPresent(scrollHorizontal, forKey: .scrollHorizontal)
        try container.encodeIfPresent(scrollVertical, forKey: .scrollVertical)
        try container.encodeIfPresent(scrollMods, forKey: .scrollMods)
        try container.encode(appendNewline, forKey: .appendNewline)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(workspaceTitle, forKey: .workspaceTitle)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encodeIfPresent(targetBranch, forKey: .targetBranch)
        try container.encodeIfPresent(directoryName, forKey: .directoryName)
        try container.encode(allowExistingBranchReuse, forKey: .allowExistingBranchReuse)
        try container.encodeIfPresent(processKey, forKey: .processKey)
        try container.encodeIfPresent(processID, forKey: .processID)
        try container.encodeIfPresent(processTemplateID, forKey: .processTemplateID)
        try container.encodeIfPresent(agentName, forKey: .agentName)
        try container.encodeIfPresent(agentID, forKey: .agentID)
        try container.encodeIfPresent(agentLauncherID, forKey: .agentLauncherID)
        try container.encodeIfPresent(terminalLink, forKey: .terminalLink)
        try container.encodeIfPresent(terminalLinkID, forKey: .terminalLinkID)
        try container.encodeIfPresent(chunkOffset, forKey: .chunkOffset)
        try container.encodeIfPresent(chunkLimit, forKey: .chunkLimit)
    }
}

public struct SpacesMobileBridgeResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String
    public let overview: SpacesMobileOverviewPayload?
    public let issuedAuthToken: String?
    public let sessionState: GhosttyRemoteSessionStatePayload?
    public let workspaceCreateOptions: SpacesMobileWorkspaceCreateOptions?
    public let workspaceID: String?
    public let sessionID: String?
    public let terminalLinkMetadata: SpacesMobileTerminalLinkMetadata?
    public let terminalLinkChunk: SpacesMobileTerminalLinkChunk?

    public init(
        ok: Bool, message: String, overview: SpacesMobileOverviewPayload? = nil, issuedAuthToken: String? = nil,
        sessionState: GhosttyRemoteSessionStatePayload? = nil, workspaceCreateOptions: SpacesMobileWorkspaceCreateOptions? = nil,
        workspaceID: String? = nil, sessionID: String? = nil, terminalLinkMetadata: SpacesMobileTerminalLinkMetadata? = nil,
        terminalLinkChunk: SpacesMobileTerminalLinkChunk? = nil
    ) {
        self.ok = ok
        self.message = message
        self.overview = overview
        self.issuedAuthToken = issuedAuthToken
        self.sessionState = sessionState
        self.workspaceCreateOptions = workspaceCreateOptions
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.terminalLinkMetadata = terminalLinkMetadata
        self.terminalLinkChunk = terminalLinkChunk
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
