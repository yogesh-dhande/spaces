import Foundation
import spacesterminalcore

public enum SpacesDeviceFirstPartyPolicy {
    public static let iosBundleID = "dev.usespaces.spacesmobile"
    public static let macOSBundleID = "dev.usespaces.spaces"
    public static let allowedBundleID = iosBundleID

    public static func allows(bundleID: String) -> Bool { bundleID == iosBundleID || bundleID == macOSBundleID }
}

public struct SpacesDeviceClientApp: Codable, Sendable, Equatable {
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

public struct SpacesDeviceServiceDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SpacesDeviceProcessTemplate: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let command: String
    public let kind: String?
    public let onExit: String

    public init(id: String, name: String?, command: String, kind: String? = nil, onExit: String = "none") {
        self.id = id
        self.name = name
        self.command = command
        self.kind = kind
        self.onExit = onExit
    }
}

public struct SpacesDeviceBrowserSession: Codable, Sendable, Equatable {
    public let name: String?
    public let url: String?

    public init(name: String? = nil, url: String? = nil) {
        self.name = name
        self.url = url
    }
}

public struct SpacesDeviceAgentLauncher: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let command: String

    public init(id: String, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

public struct SpacesDeviceWorkspaceConfig: Codable, Sendable, Equatable {
    public let stopScript: String?
    public let ports: [SpacesDeviceServiceDefinition]
    public let processes: [SpacesDeviceProcessTemplate]
    public let browserSessions: [SpacesDeviceBrowserSession]
    public let resolvedBrowserSessions: [SpacesDeviceBrowserSession]
    public let agentLaunchers: [SpacesDeviceAgentLauncher]

    public init(
        stopScript: String? = nil, ports: [SpacesDeviceServiceDefinition] = [], processes: [SpacesDeviceProcessTemplate] = [],
        browserSessions: [SpacesDeviceBrowserSession] = [], resolvedBrowserSessions: [SpacesDeviceBrowserSession] = [],
        agentLaunchers: [SpacesDeviceAgentLauncher] = []
    ) {
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
        self.resolvedBrowserSessions = resolvedBrowserSessions
        self.agentLaunchers = agentLaunchers
    }

    private enum CodingKeys: String, CodingKey {
        case stopScript
        case ports
        case processes
        case browserSessions
        case resolvedBrowserSessions
        case agentLaunchers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stopScript = try container.decodeIfPresent(String.self, forKey: .stopScript)
        ports = try container.decodeIfPresent([SpacesDeviceServiceDefinition].self, forKey: .ports) ?? []
        processes = try container.decodeIfPresent([SpacesDeviceProcessTemplate].self, forKey: .processes) ?? []
        browserSessions = try container.decodeIfPresent([SpacesDeviceBrowserSession].self, forKey: .browserSessions) ?? []
        resolvedBrowserSessions = try container.decodeIfPresent([SpacesDeviceBrowserSession].self, forKey: .resolvedBrowserSessions) ?? []
        agentLaunchers = try container.decodeIfPresent([SpacesDeviceAgentLauncher].self, forKey: .agentLaunchers) ?? []
    }
}

public struct SpacesDeviceProjectConfig: Codable, Sendable, Equatable {
    public let setupScript: String?
    public let stopScript: String?
    public let ports: [SpacesDeviceServiceDefinition]
    public let processes: [SpacesDeviceProcessTemplate]
    public let browserSessions: [SpacesDeviceBrowserSession]
    public let agentLaunchers: [SpacesDeviceAgentLauncher]

    public init(
        setupScript: String? = nil, stopScript: String? = nil, ports: [SpacesDeviceServiceDefinition] = [],
        processes: [SpacesDeviceProcessTemplate] = [], browserSessions: [SpacesDeviceBrowserSession] = [],
        agentLaunchers: [SpacesDeviceAgentLauncher] = []
    ) {
        self.setupScript = setupScript
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
        self.agentLaunchers = agentLaunchers
    }

    private enum CodingKeys: String, CodingKey {
        case setupScript
        case stopScript
        case ports
        case processes
        case browserSessions
        case agentLaunchers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript)
        stopScript = try container.decodeIfPresent(String.self, forKey: .stopScript)
        ports = try container.decodeIfPresent([SpacesDeviceServiceDefinition].self, forKey: .ports) ?? []
        processes = try container.decodeIfPresent([SpacesDeviceProcessTemplate].self, forKey: .processes) ?? []
        browserSessions = try container.decodeIfPresent([SpacesDeviceBrowserSession].self, forKey: .browserSessions) ?? []
        agentLaunchers = try container.decodeIfPresent([SpacesDeviceAgentLauncher].self, forKey: .agentLaunchers) ?? []
    }
}

public struct SpacesDeviceAssignedPort: Codable, Sendable, Equatable {
    public let name: String
    public let port: Int
    /// Derived service URL (`http://<service>.<workspace-slug>.localhost:<routerPort>`), computed by
    /// the daemon which owns the workspace slug and router port. Empty if not provided.
    public let url: String

    public init(name: String, port: Int, url: String = "") {
        self.name = name
        self.port = port
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case port
        case url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        port = try container.decode(Int.self, forKey: .port)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

public enum SpacesDeviceWorkspaceSetupStatus: String, Codable, Sendable, Equatable {
    case pending
    case running
    case succeeded
    case failed
}

public struct SpacesDeviceWorkspaceSetupState: Codable, Sendable, Equatable {
    public let status: SpacesDeviceWorkspaceSetupStatus
    public let errorMessage: String?
    public let startedAt: String?
    public let finishedAt: String?
    public let exitCode: Int?
    public let logPath: String?
    /// Recent setup-log output, captured by the owning daemon. Carried in the overview so a client
    /// (including a remote one that cannot read the daemon's log file by path) can render live setup
    /// progress. Populated only while setup is running or after it failed.
    public let logTail: String?

    public init(
        status: SpacesDeviceWorkspaceSetupStatus, errorMessage: String? = nil, startedAt: String? = nil, finishedAt: String? = nil,
        exitCode: Int? = nil, logPath: String? = nil, logTail: String? = nil
    ) {
        self.status = status
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.logPath = logPath
        self.logTail = logTail
    }
}

public struct SpacesDeviceProjectSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public let config: SpacesDeviceProjectConfig

    public init(
        id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?,
        config: SpacesDeviceProjectConfig = SpacesDeviceProjectConfig()
    ) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.config = config
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case dir
        case isGitRepo
        case defaultBranch
        case config
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        dir = try container.decode(String.self, forKey: .dir)
        isGitRepo = try container.decode(Bool.self, forKey: .isGitRepo)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        config = try container.decodeIfPresent(SpacesDeviceProjectConfig.self, forKey: .config) ?? SpacesDeviceProjectConfig()
    }
}

public enum SpacesDeviceRunState: String, Codable, Sendable, Equatable, Hashable {
    case notStarted
    case running
    case exited
}

public enum SpacesDeviceCodingAgentActivityState: String, Codable, Sendable, Equatable, Hashable {
    case idle
    case spinning
    case waiting
    case done
    /// The agent process ended while its terminal session stayed open. Mirrors `AgentWindowStatus.exited`
    /// over the wire; behaves like `idle` (no alert, not active) but reads as a distinct, gone state.
    case exited
}

public struct SpacesDeviceWorkspaceProcessRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let name: String
    public let command: String
    public let templateID: String?
    public let processID: String?
    public let sessionID: String?
    public let runState: SpacesDeviceRunState
    /// ISO-8601 timestamp the process exited, when known. Drives attention-alert recency without
    /// the client opening the daemon database.
    public let exitedAt: String?
    public let canRun: Bool
    public let canStop: Bool
    public let canRestart: Bool

    public init(
        id: String, workspaceID: String, name: String, command: String, templateID: String? = nil, processID: String?, sessionID: String?,
        runState: SpacesDeviceRunState, exitedAt: String? = nil, canRun: Bool, canStop: Bool, canRestart: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.command = command
        self.templateID = templateID
        self.processID = processID
        self.sessionID = sessionID
        self.runState = runState
        self.exitedAt = exitedAt
        self.canRun = canRun
        self.canStop = canStop
        self.canRestart = canRestart
    }
}

public struct SpacesDeviceWorkspaceCodingAgentRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let name: String
    public let command: String
    public let launcherID: String?
    public let agentID: String?
    public let sessionID: String?
    public let isConfigured: Bool
    public let runState: SpacesDeviceRunState
    public let activityState: SpacesDeviceCodingAgentActivityState
    /// ISO-8601 timestamp of the agent session's last state change, when known. Drives
    /// attention-alert recency and dismissal identity without the client opening the daemon database.
    public let updatedAt: String?
    public let canRun: Bool
    public let canStop: Bool
    public let canRestart: Bool

    public init(
        id: String, workspaceID: String, name: String, command: String, launcherID: String? = nil, agentID: String?, sessionID: String?,
        isConfigured: Bool, runState: SpacesDeviceRunState, activityState: SpacesDeviceCodingAgentActivityState, updatedAt: String? = nil,
        canRun: Bool, canStop: Bool, canRestart: Bool
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
        self.updatedAt = updatedAt
        self.canRun = canRun
        self.canStop = canStop
        self.canRestart = canRestart
    }
}

public struct SpacesDeviceWorkspaceTerminalRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let title: String
    public let workingDirectory: String
    public let sessionID: String?
    public let runState: SpacesDeviceRunState
    public let canOpenTerminal: Bool
    public let canStop: Bool

    public init(
        id: String, workspaceID: String, title: String, workingDirectory: String, sessionID: String?, runState: SpacesDeviceRunState,
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
        runState = try container.decode(SpacesDeviceRunState.self, forKey: .runState)
        canOpenTerminal = try container.decode(Bool.self, forKey: .canOpenTerminal)
        canStop = try container.decodeIfPresent(Bool.self, forKey: .canStop) ?? false
    }
}

public struct SpacesDeviceWorkspaceSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let projectName: String
    public let branch: String?
    public let baseBranch: String?
    public let dir: String
    public let isRunning: Bool
    public let isArchived: Bool
    public let isHidden: Bool
    public let isDefault: Bool
    public let notes: String?
    public let sessionCount: Int
    public let assignedPorts: [SpacesDeviceAssignedPort]
    /// Environment variables the daemon injects into every process and terminal of this workspace
    /// (workspace/project identity and per-service port/host/URL vars), computed authoritatively by
    /// the owning daemon so the settings dialog can display the exact values processes receive.
    public let environment: [String: String]
    public let setupState: SpacesDeviceWorkspaceSetupState?
    public let config: SpacesDeviceWorkspaceConfig
    public let processRows: [SpacesDeviceWorkspaceProcessRow]
    public let codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow]
    public let terminalRows: [SpacesDeviceWorkspaceTerminalRow]

    public init(
        id: String, projectID: String, projectName: String, branch: String?, baseBranch: String?, dir: String, isRunning: Bool, isArchived: Bool,
        isHidden: Bool, isDefault: Bool, notes: String? = nil, sessionCount: Int, assignedPorts: [SpacesDeviceAssignedPort] = [],
        environment: [String: String] = [:], setupState: SpacesDeviceWorkspaceSetupState? = nil,
        config: SpacesDeviceWorkspaceConfig = SpacesDeviceWorkspaceConfig(), processRows: [SpacesDeviceWorkspaceProcessRow] = [],
        codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [], terminalRows: [SpacesDeviceWorkspaceTerminalRow] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.branch = branch
        self.baseBranch = baseBranch
        self.dir = dir
        self.isRunning = isRunning
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isDefault = isDefault
        self.notes = notes
        self.sessionCount = sessionCount
        self.assignedPorts = assignedPorts
        self.environment = environment
        self.setupState = setupState
        self.config = config
        self.processRows = processRows
        self.codingAgentRows = codingAgentRows
        self.terminalRows = terminalRows
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case projectName
        case branch
        case baseBranch
        case dir
        case isRunning
        case isArchived
        case isHidden
        case isDefault
        case notes
        case sessionCount
        case assignedPorts
        case environment
        case setupState
        case config
        case processRows
        case codingAgentRows
        case terminalRows
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decode(String.self, forKey: .projectID)
        projectName = try container.decode(String.self, forKey: .projectName)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch)
        dir = try container.decode(String.self, forKey: .dir)
        isRunning = try container.decode(Bool.self, forKey: .isRunning)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
        assignedPorts = try container.decodeIfPresent([SpacesDeviceAssignedPort].self, forKey: .assignedPorts) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        setupState = try container.decodeIfPresent(SpacesDeviceWorkspaceSetupState.self, forKey: .setupState)
        config = try container.decodeIfPresent(SpacesDeviceWorkspaceConfig.self, forKey: .config) ?? SpacesDeviceWorkspaceConfig()
        processRows = try container.decodeIfPresent([SpacesDeviceWorkspaceProcessRow].self, forKey: .processRows) ?? []
        codingAgentRows = try container.decodeIfPresent([SpacesDeviceWorkspaceCodingAgentRow].self, forKey: .codingAgentRows) ?? []
        terminalRows = try container.decodeIfPresent([SpacesDeviceWorkspaceTerminalRow].self, forKey: .terminalRows) ?? []
    }

    /// Name shown to users. Git workspaces show their branch; non-git workspaces
    /// (whose `dir` is the project directory) show the folder name.
    public var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        return (dir as NSString).lastPathComponent
    }
}

public enum SpacesDeviceTerminalSessionRowKind: String, Codable, Sendable, Equatable {
    case liveSession
    case process
    case agent
}

public struct SpacesDeviceTerminalSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let workingDirectory: String
    /// Shell and launch command from the session's persisted launch configuration, so a
    /// device-backed window shows the same shell/command the daemon launched with rather
    /// than a hard-coded default.
    public let shell: String
    public let command: String?
    public let state: TerminalSessionState
    public let backend: TerminalSessionBackendKind
    public let lifetimePolicy: TerminalSessionLifetimePolicy
    public let servicePID: Int32
    public let childPID: Int32?
    public let workspaceID: String
    public let workspaceTitle: String?
    public let projectID: String?
    public let projectName: String?
    public let createdAt: String
    public let updatedAt: String
    public let isControlAvailable: Bool
    public let isSubscriptionAvailable: Bool
    public let attachmentSnapshot: TerminalSessionAttachmentSnapshot
    public let rowKind: SpacesDeviceTerminalSessionRowKind
    public let rowSourceID: String?
    public let hasFinalRender: Bool
    /// Raw value of the coding-agent kind the daemon's foreground classifier reports for this session's
    /// live runtime state, or nil when none is detected. Carries the daemon's foreground detection over
    /// the wire so a remote `spaces agent spawn` can poll detection-based readiness (the local CLI reads
    /// the same detection from `.terminalList`); it reports a detected kind even before the session's
    /// first hook signal, when no agent-orchestration row exists yet.
    public let foregroundDetectedAgentKind: String?

    public init(
        id: String, title: String, workingDirectory: String, shell: String, command: String?, state: TerminalSessionState,
        backend: TerminalSessionBackendKind, lifetimePolicy: TerminalSessionLifetimePolicy, servicePID: Int32, childPID: Int32?, workspaceID: String,
        workspaceTitle: String?, projectID: String?, projectName: String?, createdAt: String, updatedAt: String, isControlAvailable: Bool,
        isSubscriptionAvailable: Bool, attachmentSnapshot: TerminalSessionAttachmentSnapshot,
        rowKind: SpacesDeviceTerminalSessionRowKind = .liveSession, rowSourceID: String? = nil, hasFinalRender: Bool = false,
        foregroundDetectedAgentKind: String? = nil
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.command = command
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
        self.foregroundDetectedAgentKind = foregroundDetectedAgentKind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case workingDirectory
        case shell
        case command
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
        case foregroundDetectedAgentKind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        shell = try container.decode(String.self, forKey: .shell)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        state = try container.decode(TerminalSessionState.self, forKey: .state)
        backend = try container.decode(TerminalSessionBackendKind.self, forKey: .backend)
        lifetimePolicy = try container.decode(TerminalSessionLifetimePolicy.self, forKey: .lifetimePolicy)
        servicePID = try container.decode(Int32.self, forKey: .servicePID)
        childPID = try container.decodeIfPresent(Int32.self, forKey: .childPID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        workspaceTitle = try container.decodeIfPresent(String.self, forKey: .workspaceTitle)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        isControlAvailable = try container.decode(Bool.self, forKey: .isControlAvailable)
        isSubscriptionAvailable = try container.decode(Bool.self, forKey: .isSubscriptionAvailable)
        attachmentSnapshot =
            try container.decodeIfPresent(TerminalSessionAttachmentSnapshot.self, forKey: .attachmentSnapshot) ?? TerminalSessionAttachmentSnapshot()
        rowKind = try container.decodeIfPresent(SpacesDeviceTerminalSessionRowKind.self, forKey: .rowKind) ?? .liveSession
        rowSourceID = try container.decodeIfPresent(String.self, forKey: .rowSourceID)
        hasFinalRender = try container.decodeIfPresent(Bool.self, forKey: .hasFinalRender) ?? false
        foregroundDetectedAgentKind = try container.decodeIfPresent(String.self, forKey: .foregroundDetectedAgentKind)
    }
}

public struct SpacesDeviceOverviewPayload: Codable, Sendable, Equatable {
    public let projects: [SpacesDeviceProjectSummary]
    public let workspaces: [SpacesDeviceWorkspaceSummary]
    public let sessions: [SpacesDeviceTerminalSessionSummary]
    /// Frozen-core handshake (wire protocol version + restart-impact counts) for the daemon that
    /// produced this overview. Carried inline so a compatible client reads the compatibility verdict
    /// from the same round-trip as the overview, instead of paying a second `daemonStatus` call on
    /// every refresh.
    public let daemonStatus: TerminalServiceDaemonStatus

    public init(
        projects: [SpacesDeviceProjectSummary] = [], workspaces: [SpacesDeviceWorkspaceSummary], sessions: [SpacesDeviceTerminalSessionSummary],
        daemonStatus: TerminalServiceDaemonStatus
    ) {
        self.projects = projects
        self.workspaces = workspaces
        self.sessions = sessions
        self.daemonStatus = daemonStatus
    }
}

public struct SpacesDeviceWorkspaceCreateOptions: Codable, Sendable, Equatable {
    public let projects: [SpacesDeviceProjectSummary]
    public let selectedProjectID: String?
    public let branchOptions: [String]

    public init(projects: [SpacesDeviceProjectSummary], selectedProjectID: String?, branchOptions: [String]) {
        self.projects = projects
        self.selectedProjectID = selectedProjectID
        self.branchOptions = branchOptions
    }
}

public struct SpacesDeviceProjectPreview: Codable, Sendable, Equatable {
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public let config: SpacesDeviceProjectConfig

    public init(name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, config: SpacesDeviceProjectConfig) {
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.config = config
    }
}

public struct SpacesDeviceDirectorySuggestions: Codable, Sendable, Equatable {
    public let paths: [String]

    public init(paths: [String]) { self.paths = paths }
}

public enum SpacesDeviceTerminalLinkSource: String, Codable, Sendable, Equatable {
    case localFile
    case externalURL
}

public struct SpacesDeviceTerminalLinkMetadata: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: SpacesDeviceTerminalLinkSource
    public let originalLink: String
    public let displayName: String
    public let contentType: String?
    public let artifactKind: SpacesDeviceTerminalLinkArtifactKind?
    public let byteCount: Int64?
    public let externalURL: String?

    public init(
        id: String, source: SpacesDeviceTerminalLinkSource, originalLink: String, displayName: String, contentType: String?,
        artifactKind: SpacesDeviceTerminalLinkArtifactKind?, byteCount: Int64?, externalURL: String?
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

public struct SpacesDeviceTerminalLinkChunk: Codable, Sendable, Equatable {
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

public struct SpacesDeviceAPIEmptyPayload: Codable, Sendable, Equatable { public init() {} }

public struct SpacesDevicePairRequest: Codable, Sendable, Equatable {
    public let pairingCode: String?
    public let pairingNonce: String?
    /// The redeeming client's `SpacesWireProtocol.version`. The daemon rejects a request whose
    /// version does not match its own before validating the code, so an incompatible client can
    /// never consume the one-time pairing window. Absent (nil) reads as an incompatible client.
    public let clientProtocolVersion: Int?

    public init(pairingCode: String?, pairingNonce: String?, clientProtocolVersion: Int?) {
        self.pairingCode = pairingCode
        self.pairingNonce = pairingNonce
        self.clientProtocolVersion = clientProtocolVersion
    }
}

public struct SpacesDeviceProjectCreateRequest: Codable, Sendable, Equatable {
    public let projectDir: String?
    public let gitURL: String?
    public let config: SpacesDeviceProjectConfig?

    public init(projectDir: String?, gitURL: String?, config: SpacesDeviceProjectConfig? = nil) {
        self.projectDir = projectDir
        self.gitURL = gitURL
        self.config = config
    }
}

/// Request to load a git repository's `spaces.yaml` for the add-project preview. Only the single file
/// is fetched (no clone); the full clone happens later at Create.
public struct SpacesDeviceGitProjectPreviewRequest: Codable, Sendable, Equatable {
    public let gitURL: String

    public init(gitURL: String) { self.gitURL = gitURL }
}

/// A managed project/workspace directory that already exists for a git URL and would be replaced by
/// importing it. Surfaced so the client can confirm replacement before the daemon clones at Create.
public struct SpacesDeviceManagedDirectoryReplacementCandidate: Codable, Sendable, Equatable {
    public let kind: String
    public let path: String

    public init(kind: String, path: String) {
        self.kind = kind
        self.path = path
    }
}

/// Result of `previewGitProject`: the `spaces.yaml`-derived config for populating the add form, plus
/// any managed directories a later Create would replace (so the client can confirm replacement).
public struct SpacesDeviceGitProjectPreview: Codable, Sendable, Equatable {
    public let config: SpacesDeviceProjectConfig?
    public let replacementCandidates: [SpacesDeviceManagedDirectoryReplacementCandidate]
    /// Whether a `spaces.yaml` was found on the repository's default branch. `false` means the config
    /// is empty because the repo has none, letting the add form show a "not found" hint instead.
    public let spacesYAMLFound: Bool

    public init(config: SpacesDeviceProjectConfig?, replacementCandidates: [SpacesDeviceManagedDirectoryReplacementCandidate], spacesYAMLFound: Bool)
    {
        self.config = config
        self.replacementCandidates = replacementCandidates
        self.spacesYAMLFound = spacesYAMLFound
    }
}

public struct SpacesDeviceProjectReference: Codable, Sendable, Equatable {
    public let projectID: String

    public init(projectID: String) { self.projectID = projectID }
}

public struct SpacesDeviceProjectImportRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let updateAllWorkspaces: Bool

    public init(projectID: String, updateAllWorkspaces: Bool = false) {
        self.projectID = projectID
        self.updateAllWorkspaces = updateAllWorkspaces
    }
}

public struct SpacesDeviceWorkspaceCreateOptionsRequest: Codable, Sendable, Equatable {
    public let projectID: String?

    public init(projectID: String? = nil) { self.projectID = projectID }
}

public struct SpacesDeviceProjectPreviewRequest: Codable, Sendable, Equatable {
    public let dir: String

    public init(dir: String) { self.dir = dir }
}

public struct SpacesDeviceDirectoryListRequest: Codable, Sendable, Equatable {
    public let path: String

    public init(path: String) { self.path = path }
}

public struct SpacesDeviceWorkspaceCreateRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let branch: String?
    public let baseBranch: String?
    public let directoryName: String?
    public let notes: String?
    public let allowExistingBranchReuse: Bool

    public init(
        projectID: String, branch: String?, baseBranch: String?, directoryName: String?, notes: String? = nil, allowExistingBranchReuse: Bool = false
    ) {
        self.projectID = projectID
        self.branch = branch
        self.baseBranch = baseBranch
        self.directoryName = directoryName
        self.notes = notes
        self.allowExistingBranchReuse = allowExistingBranchReuse
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case branch
        case baseBranch
        case directoryName
        case notes
        case allowExistingBranchReuse
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch)
        directoryName = try container.decodeIfPresent(String.self, forKey: .directoryName)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        allowExistingBranchReuse = try container.decodeIfPresent(Bool.self, forKey: .allowExistingBranchReuse) ?? false
    }
}

public struct SpacesDeviceWorkspaceReference: Codable, Sendable, Equatable {
    public let workspaceID: String

    public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct SpacesDeviceWorkspaceLifecycleRequest: Codable, Sendable, Equatable {
    public let workspaceID: String

    public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct SpacesDeviceWorkspaceArchiveRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let deleteLocalBranch: Bool
    public let deleteRemoteBranch: Bool

    public init(workspaceID: String, deleteLocalBranch: Bool = false, deleteRemoteBranch: Bool = false) {
        self.workspaceID = workspaceID
        self.deleteLocalBranch = deleteLocalBranch
        self.deleteRemoteBranch = deleteRemoteBranch
    }
}

public struct SpacesDeviceProjectConfigUpdateRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let config: SpacesDeviceProjectConfig
    public let updateAllWorkspaces: Bool

    public init(projectID: String, config: SpacesDeviceProjectConfig, updateAllWorkspaces: Bool = false) {
        self.projectID = projectID
        self.config = config
        self.updateAllWorkspaces = updateAllWorkspaces
    }
}

public struct SpacesDeviceWorkspaceConfigUpdateRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let config: SpacesDeviceWorkspaceConfig

    public init(workspaceID: String, config: SpacesDeviceWorkspaceConfig) {
        self.workspaceID = workspaceID
        self.config = config
    }
}

public struct SpacesDeviceWorkspaceMetadataUpdateRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let branch: String?
    public let notes: String?
    public let isHidden: Bool?
    public let updatesBranch: Bool
    public let updatesNotes: Bool
    public let updatesHidden: Bool

    public init(
        workspaceID: String, branch: String? = nil, notes: String? = nil, updatesBranch: Bool = false, updatesNotes: Bool = false,
        isHidden: Bool? = nil, updatesHidden: Bool = false
    ) {
        self.workspaceID = workspaceID
        self.branch = branch
        self.notes = notes
        self.isHidden = isHidden
        self.updatesBranch = updatesBranch
        self.updatesNotes = updatesNotes
        self.updatesHidden = updatesHidden
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case branch
        case notes
        case isHidden
        case updatesBranch
        case updatesNotes
        case updatesHidden
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden)
        updatesBranch = try container.decodeIfPresent(Bool.self, forKey: .updatesBranch) ?? false
        updatesNotes = try container.decodeIfPresent(Bool.self, forKey: .updatesNotes) ?? false
        updatesHidden = try container.decodeIfPresent(Bool.self, forKey: .updatesHidden) ?? false
    }
}

public struct SpacesDeviceWorkspaceTerminalRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let sessionID: String

    public init(workspaceID: String, sessionID: String) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }
}

public struct SpacesDeviceTerminalSessionRenameRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let sessionID: String
    public let title: String

    public init(workspaceID: String, sessionID: String, title: String) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.title = title
    }
}

public struct SpacesDeviceRunWorkspaceProcessRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let processKey: String
    public let processTemplateID: String?

    public init(workspaceID: String, processKey: String, processTemplateID: String? = nil) {
        self.workspaceID = workspaceID
        self.processKey = processKey
        self.processTemplateID = processTemplateID
    }
}

public struct SpacesDeviceWorkspaceProcessMutationRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let processID: String?
    public let processKey: String?
    public let processTemplateID: String?

    public init(workspaceID: String, processID: String? = nil, processKey: String? = nil, processTemplateID: String? = nil) {
        self.workspaceID = workspaceID
        self.processID = processID
        self.processKey = processKey
        self.processTemplateID = processTemplateID
    }
}

public struct SpacesDeviceRunCodingAgentRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let agentName: String
    public let agentLauncherID: String?

    public init(workspaceID: String, agentName: String, agentLauncherID: String? = nil) {
        self.workspaceID = workspaceID
        self.agentName = agentName
        self.agentLauncherID = agentLauncherID
    }
}

public struct SpacesDeviceCodingAgentMutationRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let agentID: String?
    public let agentName: String?
    public let agentLauncherID: String?

    public init(workspaceID: String, agentID: String? = nil, agentName: String? = nil, agentLauncherID: String? = nil) {
        self.workspaceID = workspaceID
        self.agentID = agentID
        self.agentName = agentName
        self.agentLauncherID = agentLauncherID
    }
}

public struct SpacesDeviceTerminalSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String

    public init(sessionID: String) { self.sessionID = sessionID }
}

/// One-shot agent input for a terminal session (`spaces terminal send text/bytes --device`). Unlike
/// `terminalControl`, this is not attachment- or owner-epoch-gated: orchestrator agents write into
/// sessions they never render, so the bearer token is the whole authorization.
public struct SpacesDeviceTerminalInputRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let text: String?
    public let bytes: Data?
    public let appendNewline: Bool

    public init(sessionID: String, text: String? = nil, bytes: Data? = nil, appendNewline: Bool = false) {
        self.sessionID = sessionID
        self.text = text
        self.bytes = bytes
        self.appendNewline = appendNewline
    }
}

/// Rendered plain-text tail of a terminal session's output (`spaces terminal tail --device`).
public struct SpacesDeviceTerminalTailRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let lines: Int?

    public init(sessionID: String, lines: Int? = nil) {
        self.sessionID = sessionID
        self.lines = lines
    }
}

public struct SpacesDeviceTerminalOutputResult: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) { self.text = text }
}

/// Raw suffix of a terminal session's persisted output transcript, for client-local ended-session
/// scrollback replay. Read-only and not interactivity-gated — it exposes the same append-only
/// `output.log` bytes `tailTerminalOutput` already renders — and works uniformly for local and
/// remote devices. `maxBytes` bounds how much of the tail the daemon returns.
public struct SpacesDeviceTerminalTranscriptRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let maxBytes: Int

    public init(sessionID: String, maxBytes: Int) {
        self.sessionID = sessionID
        self.maxBytes = maxBytes
    }
}

/// Result of `terminalTranscript`: the requested suffix `data` of the output transcript, the
/// transcript's full `totalBytes` (so a client can tell whether it received the whole log or a
/// budget-capped tail), and the `runIdentity` of the session run the transcript was read from. The
/// client validates `runIdentity` against the run its ended-scrollback replay was armed against, so a
/// fetch that straddles a relaunch (which truncates `output.log`) is rejected rather than replaying
/// the new run's bytes under the old run's final frame. `runIdentity` is nil when no runtime state
/// exists for the session.
public struct SpacesDeviceTerminalTranscriptResult: Codable, Sendable, Equatable {
    public let data: Data
    public let totalBytes: UInt64
    public let runIdentity: String?

    public init(data: Data, totalBytes: UInt64, runIdentity: String? = nil) {
        self.data = data
        self.totalBytes = totalBytes
        self.runIdentity = runIdentity
    }
}

public enum SpacesDeviceTerminalControlAction: String, Codable, Sendable, Equatable {
    case attach
    case detach
    case heartbeat
    case takeover
    case send
    case key
    case clearScreen
    case resize
    case scroll
    case setAppearance
}

public struct SpacesDeviceTerminalControlRequest: Codable, Sendable, Equatable {
    public let action: SpacesDeviceTerminalControlAction
    public let sessionID: String
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
    public let scrollPointerX: Double?
    public let scrollPointerY: Double?
    public let scrollPointerMods: UInt32?
    public let appendNewline: Bool
    public let asPaste: Bool
    /// The attaching client's OS appearance (light/dark), carried on `attach` so a remote daemon can render
    /// its terminal with the client's theme variant. Mirrors `TerminalControlRequest.appearance`; without it
    /// the daemon keeps its default theme on the device-API attach path.
    public let appearance: ThemeAppearance?

    public init(
        action: SpacesDeviceTerminalControlAction, sessionID: String, clientID: String? = nil, client: TerminalClient? = nil,
        attachmentMode: TerminalAttachmentMode? = nil, text: String? = nil, key: String? = nil, columns: Int? = nil, rows: Int? = nil,
        ownerEpoch: UInt64? = nil, resizeSerial: UInt64? = nil, scrollHorizontal: Double? = nil, scrollVertical: Double? = nil,
        scrollMods: Int32? = nil, scrollPointerX: Double? = nil, scrollPointerY: Double? = nil, scrollPointerMods: UInt32? = nil,
        appendNewline: Bool = false, asPaste: Bool = false, appearance: ThemeAppearance? = nil
    ) {
        self.action = action
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
        self.scrollPointerX = scrollPointerX
        self.scrollPointerY = scrollPointerY
        self.scrollPointerMods = scrollPointerMods
        self.appendNewline = appendNewline
        self.asPaste = asPaste
        self.appearance = appearance
    }
}

public struct SpacesDeviceTerminalPasteImageRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let clientID: String
    public let ownerEpoch: UInt64
    public let fileExtension: String
    public let imageData: Data

    public init(sessionID: String, clientID: String, ownerEpoch: UInt64, fileExtension: String, imageData: Data) {
        self.sessionID = sessionID
        self.clientID = clientID
        self.ownerEpoch = ownerEpoch
        self.fileExtension = fileExtension
        self.imageData = imageData
    }
}

public struct SpacesDeviceTerminalSubscriptionRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let clientID: String?

    public init(sessionID: String, clientID: String?) {
        self.sessionID = sessionID
        self.clientID = clientID
    }
}

public struct SpacesDeviceTerminalLinkResolveRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let terminalLink: String

    public init(sessionID: String, terminalLink: String) {
        self.sessionID = sessionID
        self.terminalLink = terminalLink
    }
}

public struct SpacesDeviceTerminalLinkChunkRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let terminalLinkID: String
    public let offset: Int64?
    public let limit: Int?

    public init(sessionID: String, terminalLinkID: String, offset: Int64?, limit: Int?) {
        self.sessionID = sessionID
        self.terminalLinkID = terminalLinkID
        self.offset = offset
        self.limit = limit
    }
}

/// Request to open a raw byte tunnel to a running workspace service. The daemon replies with a single
/// `ok` response line as usual, then the connection stops speaking newline-delimited JSON and becomes a
/// transparent byte pipe to the service (relayed for as long as the underlying connection stays open).
/// The client must finish reading that one response line before writing or reading tunnel bytes; nothing
/// after the line's trailing newline belongs to the Device API framing.
public struct SpacesDeviceServiceTunnelRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let serviceName: String

    public init(workspaceID: String, serviceName: String) {
        self.workspaceID = workspaceID
        self.serviceName = serviceName
    }
}

/// Spawns a coding-agent terminal session on a paired device (`spaces agent spawn --device`). Unlike
/// the local profile spawn, `workspaceID` is required: a remote client has no shared working directory
/// to infer the owning workspace from, so it must name the workspace explicitly. The daemon gates
/// `command` against the supported-agent hook set before spawning, identical to the local path.
public struct SpacesDeviceSpawnAgentSessionRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let command: String
    public let title: String?

    public init(workspaceID: String, command: String, title: String? = nil) {
        self.workspaceID = workspaceID
        self.command = command
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case command
        case title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        command = try container.decode(String.self, forKey: .command)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

/// Lists coding-agent sessions on a paired device (`spaces agent list/status --device`), and drives
/// remote spawn-readiness polling. `workspaceID` narrows to one workspace; `sessionID` narrows to the
/// agent bound to that terminal tracking id. Both optional: omitting them lists every agent.
public struct SpacesDeviceListAgentSessionsRequest: Codable, Sendable, Equatable {
    public let workspaceID: String?
    public let sessionID: String?

    public init(workspaceID: String? = nil, sessionID: String? = nil) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case sessionID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
    }
}

/// Sets (or clears, with an empty note) a coding-agent session's explicit note on a paired device
/// (`spaces agent annotate --device`). `sessionID` is the agent's terminal tracking id.
public struct SpacesDeviceAnnotateAgentSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let note: String

    public init(sessionID: String, note: String) {
        self.sessionID = sessionID
        self.note = note
    }
}

/// Kills a coding-agent session on a paired device by its child terminal session id (`spaces agent kill
/// --device`). Routes through the daemon's `killAgentSession` flow, which mirrors the local `.agentKill`
/// path exactly: a hook-signaled child is told it exited (its subscribers notified) before the stop
/// deletes its row, and a not-yet-signaled `.agent`-kind session is terminated. Unlike
/// `stopWorkspaceTerminal`, no `workspaceID` is carried — the daemon resolves the owning workspace
/// itself, and a pre-signal session has no agent row to resolve it from anyway.
public struct SpacesDeviceKillAgentSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String

    public init(sessionID: String) { self.sessionID = sessionID }
}

/// One coding-agent session as reported to orchestration clients over the Device API
/// (`listAgentSessions`/`annotateAgentSession`). Mirrors `TerminalServiceAgentSessionRow`: the agent's
/// live status, its explicit note, the full project/workspace context, and `lastSignalAt` — the
/// readiness marker, nil until the agent's hooks emit their first lifecycle signal.
public struct SpacesDeviceAgentSessionRow: Codable, Sendable, Equatable {
    public let id: String
    public let terminalSessionID: String?
    public let agent: String?
    public let label: String?
    public let status: String
    public let note: String?
    public let projectID: String
    public let projectName: String
    public let workspaceID: String
    public let workspaceName: String
    /// Absolute path to the workspace's directory (worktree), so an orchestrator can locate it on disk.
    public let workspaceDir: String
    public let branch: String?
    public let updatedAt: String
    public let lastSignalAt: String?

    public init(
        id: String, terminalSessionID: String?, agent: String?, label: String?, status: String, note: String?, projectID: String, projectName: String,
        workspaceID: String, workspaceName: String, workspaceDir: String, branch: String?, updatedAt: String, lastSignalAt: String?
    ) {
        self.id = id
        self.terminalSessionID = terminalSessionID
        self.agent = agent
        self.label = label
        self.status = status
        self.note = note
        self.projectID = projectID
        self.projectName = projectName
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspaceDir = workspaceDir
        self.branch = branch
        self.updatedAt = updatedAt
        self.lastSignalAt = lastSignalAt
    }
}

/// Wraps the agent-session rows returned by `listAgentSessions`/`annotateAgentSession`.
public struct SpacesDeviceAgentSessionsResult: Codable, Sendable, Equatable {
    public let rows: [SpacesDeviceAgentSessionRow]

    public init(rows: [SpacesDeviceAgentSessionRow]) { self.rows = rows }
}

public enum SpacesDeviceAPICommand: Sendable, Equatable {
    case pair(SpacesDevicePairRequest)
    case ping
    /// Frozen-core command: read the daemon's wire protocol + restart-impact status.
    /// Its request/result shape is contractually stable so an incompatible client can
    /// still negotiate versions and read the restart-impact report.
    case daemonStatus
    /// Frozen-core command: ask the daemon to restart itself (graceful shutdown; the OS service
    /// manager respawns it from the updated binary). Used by iOS and remote clients that cannot
    /// restart the daemon out of band. Contractually stable for the same reason as `daemonStatus`.
    case requestDaemonRestart
    case overview
    case createProject(SpacesDeviceProjectCreateRequest)
    case previewGitProject(SpacesDeviceGitProjectPreviewRequest)
    case deleteProject(SpacesDeviceProjectReference)
    case importProject(SpacesDeviceProjectImportRequest)
    case exportProject(SpacesDeviceProjectReference)
    case previewProject(SpacesDeviceProjectPreviewRequest)
    case listDirectories(SpacesDeviceDirectoryListRequest)
    case workspaceCreateOptions(SpacesDeviceWorkspaceCreateOptionsRequest)
    case createWorkspace(SpacesDeviceWorkspaceCreateRequest)
    case launchWorkspace(SpacesDeviceWorkspaceLifecycleRequest)
    case stopWorkspace(SpacesDeviceWorkspaceLifecycleRequest)
    case restartWorkspace(SpacesDeviceWorkspaceLifecycleRequest)
    case archiveWorkspace(SpacesDeviceWorkspaceArchiveRequest)
    case runWorkspaceSetup(SpacesDeviceWorkspaceReference)
    case updateProjectConfig(SpacesDeviceProjectConfigUpdateRequest)
    case updateWorkspaceConfig(SpacesDeviceWorkspaceConfigUpdateRequest)
    case updateWorkspaceMetadata(SpacesDeviceWorkspaceMetadataUpdateRequest)
    case openWorkspaceTerminal(SpacesDeviceWorkspaceReference)
    case stopWorkspaceTerminal(SpacesDeviceWorkspaceTerminalRequest)
    case renameTerminalSession(SpacesDeviceTerminalSessionRenameRequest)
    case runWorkspaceProcess(SpacesDeviceRunWorkspaceProcessRequest)
    case stopWorkspaceProcess(SpacesDeviceWorkspaceProcessMutationRequest)
    case restartWorkspaceProcess(SpacesDeviceWorkspaceProcessMutationRequest)
    case runCodingAgent(SpacesDeviceRunCodingAgentRequest)
    case stopCodingAgent(SpacesDeviceCodingAgentMutationRequest)
    case restartCodingAgent(SpacesDeviceCodingAgentMutationRequest)
    case state(SpacesDeviceTerminalSessionRequest)
    case terminalControl(SpacesDeviceTerminalControlRequest)
    case terminalPasteImage(SpacesDeviceTerminalPasteImageRequest)
    case sendTerminalInput(SpacesDeviceTerminalInputRequest)
    case tailTerminalOutput(SpacesDeviceTerminalTailRequest)
    /// Reads a suffix of a terminal session's persisted output transcript for client-local
    /// ended-session scrollback replay. Read-only.
    case terminalTranscript(SpacesDeviceTerminalTranscriptRequest)
    case subscribe(SpacesDeviceTerminalSubscriptionRequest)
    case resolveTerminalLink(SpacesDeviceTerminalLinkResolveRequest)
    case readTerminalLinkChunk(SpacesDeviceTerminalLinkChunkRequest)
    /// Long-lived subscription that streams the device overview whenever the
    /// remote daemon's database changes, so paired clients stay live without
    /// polling. No payload: one overview stream per connection.
    case subscribeDeviceOverview
    /// Reports availability + Spaces hook-install status for supported coding agents on the daemon host.
    case agentHooksStatus
    /// Idempotently installs Spaces lifecycle hooks for the requested coding agents on the daemon host.
    case installAgentHooks(SpacesDeviceInstallAgentHooksRequest)
    /// Spawns a coding-agent terminal session on the daemon host after the same hook gate as the local
    /// spawn, then returns the created session so the client can poll readiness. Remote ad-hoc-command
    /// session creation, the Device API's missing spawn primitive.
    case spawnAgentSession(SpacesDeviceSpawnAgentSessionRequest)
    /// Lists coding-agent sessions on the daemon host (orchestration list/status + remote readiness).
    case listAgentSessions(SpacesDeviceListAgentSessionsRequest)
    /// Sets or clears a coding-agent session's explicit note on the daemon host.
    case annotateAgentSession(SpacesDeviceAnnotateAgentSessionRequest)
    /// Kills a coding-agent session on the daemon host by its child terminal session id, the remote
    /// counterpart of the local `.agentKill` command. Routes through the daemon's `killAgentSession`
    /// flow so a hook-signaled child's subscribers are told it exited before its row is deleted.
    case killAgentSession(SpacesDeviceKillAgentSessionRequest)
    /// Hijacks the connection into a raw byte tunnel to a workspace service after one `ok` response line.
    case openServiceTunnel(SpacesDeviceServiceTunnelRequest)

    public var name: String {
        switch self {
        case .pair: "pair"
        case .ping: "ping"
        case .daemonStatus: "daemonStatus"
        case .requestDaemonRestart: "requestDaemonRestart"
        case .overview: "overview"
        case .createProject: "createProject"
        case .previewGitProject: "previewGitProject"
        case .deleteProject: "deleteProject"
        case .importProject: "importProject"
        case .exportProject: "exportProject"
        case .previewProject: "previewProject"
        case .listDirectories: "listDirectories"
        case .workspaceCreateOptions: "workspaceCreateOptions"
        case .createWorkspace: "createWorkspace"
        case .launchWorkspace: "launchWorkspace"
        case .stopWorkspace: "stopWorkspace"
        case .restartWorkspace: "restartWorkspace"
        case .archiveWorkspace: "archiveWorkspace"
        case .runWorkspaceSetup: "runWorkspaceSetup"
        case .updateProjectConfig: "updateProjectConfig"
        case .updateWorkspaceConfig: "updateWorkspaceConfig"
        case .updateWorkspaceMetadata: "updateWorkspaceMetadata"
        case .openWorkspaceTerminal: "openWorkspaceTerminal"
        case .stopWorkspaceTerminal: "stopWorkspaceTerminal"
        case .renameTerminalSession: "renameTerminalSession"
        case .runWorkspaceProcess: "runWorkspaceProcess"
        case .stopWorkspaceProcess: "stopWorkspaceProcess"
        case .restartWorkspaceProcess: "restartWorkspaceProcess"
        case .runCodingAgent: "runCodingAgent"
        case .stopCodingAgent: "stopCodingAgent"
        case .restartCodingAgent: "restartCodingAgent"
        case .state: "state"
        case .terminalControl(let payload): payload.action.rawValue
        case .terminalPasteImage: "terminalPasteImage"
        case .sendTerminalInput: "sendTerminalInput"
        case .tailTerminalOutput: "tailTerminalOutput"
        case .terminalTranscript: "terminalTranscript"
        case .subscribe: "subscribe"
        case .resolveTerminalLink: "resolveTerminalLink"
        case .readTerminalLinkChunk: "readTerminalLinkChunk"
        case .subscribeDeviceOverview: "subscribeDeviceOverview"
        case .agentHooksStatus: "agentHooksStatus"
        case .installAgentHooks: "installAgentHooks"
        case .spawnAgentSession: "spawnAgentSession"
        case .listAgentSessions: "listAgentSessions"
        case .annotateAgentSession: "annotateAgentSession"
        case .killAgentSession: "killAgentSession"
        case .openServiceTunnel: "openServiceTunnel"
        }
    }

    public var terminalSessionID: String? {
        switch self {
        case .stopWorkspaceTerminal(let payload): payload.sessionID
        case .renameTerminalSession(let payload): payload.sessionID
        case .state(let payload): payload.sessionID
        case .terminalControl(let payload): payload.sessionID
        case .terminalPasteImage(let payload): payload.sessionID
        case .sendTerminalInput(let payload): payload.sessionID
        case .tailTerminalOutput(let payload): payload.sessionID
        case .terminalTranscript(let payload): payload.sessionID
        case .subscribe(let payload): payload.sessionID
        case .resolveTerminalLink(let payload): payload.sessionID
        case .readTerminalLinkChunk(let payload): payload.sessionID
        default: nil
        }
    }

    public var terminalClientID: String? {
        switch self {
        case .terminalControl(let payload): payload.clientID
        case .terminalPasteImage(let payload): payload.clientID
        case .subscribe(let payload): payload.clientID
        default: nil
        }
    }

    public var isPairingCommand: Bool {
        if case .pair = self { return true }
        return false
    }

    public var isSubscriptionCommand: Bool {
        switch self {
        case .subscribe, .subscribeDeviceOverview: true
        default: false
        }
    }

    /// True for the device-overview subscription, which streams overview payloads
    /// rather than terminal state and is not tied to a terminal session.
    public var isDeviceOverviewSubscription: Bool {
        if case .subscribeDeviceOverview = self { return true }
        return false
    }

    /// True for commands that hand the connection over to a raw byte tunnel after one `ok` response line.
    public var isTunnelCommand: Bool {
        if case .openServiceTunnel = self { return true }
        return false
    }

    /// True for any command that stops speaking newline-delimited JSON after its response — either a
    /// long-lived subscription stream or a one-shot pipe handover — so the connection handler must not
    /// treat the connection as request/response after issuing the response.
    public var hijacksConnection: Bool { isSubscriptionCommand || isTunnelCommand }

    var isSafeToReplayAfterConnectionFailure: Bool {
        switch self {
        case .ping, .daemonStatus, .overview, .previewProject, .previewGitProject, .listDirectories, .workspaceCreateOptions, .state,
            .resolveTerminalLink, .readTerminalLinkChunk, .tailTerminalOutput, .terminalTranscript, .agentHooksStatus, .listAgentSessions:
            true
        default: false
        }
    }
}

extension SpacesDeviceAPICommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case pair
        case ping
        case daemonStatus
        case requestDaemonRestart
        case overview
        case createProject
        case previewGitProject
        case deleteProject
        case importProject
        case exportProject
        case previewProject
        case listDirectories
        case workspaceCreateOptions
        case createWorkspace
        case launchWorkspace
        case stopWorkspace
        case restartWorkspace
        case archiveWorkspace
        case runWorkspaceSetup
        case updateProjectConfig
        case updateWorkspaceConfig
        case updateWorkspaceMetadata
        case openWorkspaceTerminal
        case stopWorkspaceTerminal
        case renameTerminalSession
        case runWorkspaceProcess
        case stopWorkspaceProcess
        case restartWorkspaceProcess
        case runCodingAgent
        case stopCodingAgent
        case restartCodingAgent
        case state
        case terminalControl
        case terminalPasteImage
        case sendTerminalInput
        case tailTerminalOutput
        case terminalTranscript
        case subscribe
        case resolveTerminalLink
        case readTerminalLinkChunk
        case subscribeDeviceOverview
        case agentHooksStatus
        case installAgentHooks
        case spawnAgentSession
        case listAgentSessions
        case annotateAgentSession
        case killAgentSession
        case openServiceTunnel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Device API command must contain exactly one payload."))
        }
        switch key {
        case .pair: self = .pair(try container.decode(SpacesDevicePairRequest.self, forKey: key))
        case .ping:
            _ = try container.decode(SpacesDeviceAPIEmptyPayload.self, forKey: key)
            self = .ping
        case .daemonStatus:
            _ = try container.decode(SpacesDeviceAPIEmptyPayload.self, forKey: key)
            self = .daemonStatus
        case .requestDaemonRestart:
            _ = try container.decode(SpacesDeviceAPIEmptyPayload.self, forKey: key)
            self = .requestDaemonRestart
        case .overview:
            _ = try container.decode(SpacesDeviceAPIEmptyPayload.self, forKey: key)
            self = .overview
        case .createProject: self = .createProject(try container.decode(SpacesDeviceProjectCreateRequest.self, forKey: key))
        case .previewGitProject: self = .previewGitProject(try container.decode(SpacesDeviceGitProjectPreviewRequest.self, forKey: key))
        case .deleteProject: self = .deleteProject(try container.decode(SpacesDeviceProjectReference.self, forKey: key))
        case .importProject: self = .importProject(try container.decode(SpacesDeviceProjectImportRequest.self, forKey: key))
        case .exportProject: self = .exportProject(try container.decode(SpacesDeviceProjectReference.self, forKey: key))
        case .previewProject: self = .previewProject(try container.decode(SpacesDeviceProjectPreviewRequest.self, forKey: key))
        case .listDirectories: self = .listDirectories(try container.decode(SpacesDeviceDirectoryListRequest.self, forKey: key))
        case .workspaceCreateOptions:
            self = .workspaceCreateOptions(try container.decode(SpacesDeviceWorkspaceCreateOptionsRequest.self, forKey: key))
        case .createWorkspace: self = .createWorkspace(try container.decode(SpacesDeviceWorkspaceCreateRequest.self, forKey: key))
        case .launchWorkspace: self = .launchWorkspace(try container.decode(SpacesDeviceWorkspaceLifecycleRequest.self, forKey: key))
        case .stopWorkspace: self = .stopWorkspace(try container.decode(SpacesDeviceWorkspaceLifecycleRequest.self, forKey: key))
        case .restartWorkspace: self = .restartWorkspace(try container.decode(SpacesDeviceWorkspaceLifecycleRequest.self, forKey: key))
        case .archiveWorkspace: self = .archiveWorkspace(try container.decode(SpacesDeviceWorkspaceArchiveRequest.self, forKey: key))
        case .runWorkspaceSetup: self = .runWorkspaceSetup(try container.decode(SpacesDeviceWorkspaceReference.self, forKey: key))
        case .updateProjectConfig: self = .updateProjectConfig(try container.decode(SpacesDeviceProjectConfigUpdateRequest.self, forKey: key))
        case .updateWorkspaceConfig: self = .updateWorkspaceConfig(try container.decode(SpacesDeviceWorkspaceConfigUpdateRequest.self, forKey: key))
        case .updateWorkspaceMetadata:
            self = .updateWorkspaceMetadata(try container.decode(SpacesDeviceWorkspaceMetadataUpdateRequest.self, forKey: key))
        case .openWorkspaceTerminal: self = .openWorkspaceTerminal(try container.decode(SpacesDeviceWorkspaceReference.self, forKey: key))
        case .stopWorkspaceTerminal: self = .stopWorkspaceTerminal(try container.decode(SpacesDeviceWorkspaceTerminalRequest.self, forKey: key))
        case .renameTerminalSession: self = .renameTerminalSession(try container.decode(SpacesDeviceTerminalSessionRenameRequest.self, forKey: key))
        case .runWorkspaceProcess: self = .runWorkspaceProcess(try container.decode(SpacesDeviceRunWorkspaceProcessRequest.self, forKey: key))
        case .stopWorkspaceProcess: self = .stopWorkspaceProcess(try container.decode(SpacesDeviceWorkspaceProcessMutationRequest.self, forKey: key))
        case .restartWorkspaceProcess:
            self = .restartWorkspaceProcess(try container.decode(SpacesDeviceWorkspaceProcessMutationRequest.self, forKey: key))
        case .runCodingAgent: self = .runCodingAgent(try container.decode(SpacesDeviceRunCodingAgentRequest.self, forKey: key))
        case .stopCodingAgent: self = .stopCodingAgent(try container.decode(SpacesDeviceCodingAgentMutationRequest.self, forKey: key))
        case .restartCodingAgent: self = .restartCodingAgent(try container.decode(SpacesDeviceCodingAgentMutationRequest.self, forKey: key))
        case .state: self = .state(try container.decode(SpacesDeviceTerminalSessionRequest.self, forKey: key))
        case .terminalControl: self = .terminalControl(try container.decode(SpacesDeviceTerminalControlRequest.self, forKey: key))
        case .terminalPasteImage: self = .terminalPasteImage(try container.decode(SpacesDeviceTerminalPasteImageRequest.self, forKey: key))
        case .sendTerminalInput: self = .sendTerminalInput(try container.decode(SpacesDeviceTerminalInputRequest.self, forKey: key))
        case .tailTerminalOutput: self = .tailTerminalOutput(try container.decode(SpacesDeviceTerminalTailRequest.self, forKey: key))
        case .terminalTranscript: self = .terminalTranscript(try container.decode(SpacesDeviceTerminalTranscriptRequest.self, forKey: key))
        case .subscribe: self = .subscribe(try container.decode(SpacesDeviceTerminalSubscriptionRequest.self, forKey: key))
        case .resolveTerminalLink: self = .resolveTerminalLink(try container.decode(SpacesDeviceTerminalLinkResolveRequest.self, forKey: key))
        case .readTerminalLinkChunk: self = .readTerminalLinkChunk(try container.decode(SpacesDeviceTerminalLinkChunkRequest.self, forKey: key))
        case .subscribeDeviceOverview:
            _ = try container.decode(SpacesDeviceAPIEmptyPayload.self, forKey: key)
            self = .subscribeDeviceOverview
        case .agentHooksStatus:
            _ = try container.decode(SpacesDeviceAPIEmptyPayload.self, forKey: key)
            self = .agentHooksStatus
        case .installAgentHooks: self = .installAgentHooks(try container.decode(SpacesDeviceInstallAgentHooksRequest.self, forKey: key))
        case .spawnAgentSession: self = .spawnAgentSession(try container.decode(SpacesDeviceSpawnAgentSessionRequest.self, forKey: key))
        case .listAgentSessions: self = .listAgentSessions(try container.decode(SpacesDeviceListAgentSessionsRequest.self, forKey: key))
        case .annotateAgentSession: self = .annotateAgentSession(try container.decode(SpacesDeviceAnnotateAgentSessionRequest.self, forKey: key))
        case .killAgentSession: self = .killAgentSession(try container.decode(SpacesDeviceKillAgentSessionRequest.self, forKey: key))
        case .openServiceTunnel: self = .openServiceTunnel(try container.decode(SpacesDeviceServiceTunnelRequest.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pair(let payload): try container.encode(payload, forKey: .pair)
        case .ping: try container.encode(SpacesDeviceAPIEmptyPayload(), forKey: .ping)
        case .daemonStatus: try container.encode(SpacesDeviceAPIEmptyPayload(), forKey: .daemonStatus)
        case .requestDaemonRestart: try container.encode(SpacesDeviceAPIEmptyPayload(), forKey: .requestDaemonRestart)
        case .overview: try container.encode(SpacesDeviceAPIEmptyPayload(), forKey: .overview)
        case .createProject(let payload): try container.encode(payload, forKey: .createProject)
        case .previewGitProject(let payload): try container.encode(payload, forKey: .previewGitProject)
        case .deleteProject(let payload): try container.encode(payload, forKey: .deleteProject)
        case .importProject(let payload): try container.encode(payload, forKey: .importProject)
        case .exportProject(let payload): try container.encode(payload, forKey: .exportProject)
        case .previewProject(let payload): try container.encode(payload, forKey: .previewProject)
        case .listDirectories(let payload): try container.encode(payload, forKey: .listDirectories)
        case .workspaceCreateOptions(let payload): try container.encode(payload, forKey: .workspaceCreateOptions)
        case .createWorkspace(let payload): try container.encode(payload, forKey: .createWorkspace)
        case .launchWorkspace(let payload): try container.encode(payload, forKey: .launchWorkspace)
        case .stopWorkspace(let payload): try container.encode(payload, forKey: .stopWorkspace)
        case .restartWorkspace(let payload): try container.encode(payload, forKey: .restartWorkspace)
        case .archiveWorkspace(let payload): try container.encode(payload, forKey: .archiveWorkspace)
        case .runWorkspaceSetup(let payload): try container.encode(payload, forKey: .runWorkspaceSetup)
        case .updateProjectConfig(let payload): try container.encode(payload, forKey: .updateProjectConfig)
        case .updateWorkspaceConfig(let payload): try container.encode(payload, forKey: .updateWorkspaceConfig)
        case .updateWorkspaceMetadata(let payload): try container.encode(payload, forKey: .updateWorkspaceMetadata)
        case .openWorkspaceTerminal(let payload): try container.encode(payload, forKey: .openWorkspaceTerminal)
        case .stopWorkspaceTerminal(let payload): try container.encode(payload, forKey: .stopWorkspaceTerminal)
        case .renameTerminalSession(let payload): try container.encode(payload, forKey: .renameTerminalSession)
        case .runWorkspaceProcess(let payload): try container.encode(payload, forKey: .runWorkspaceProcess)
        case .stopWorkspaceProcess(let payload): try container.encode(payload, forKey: .stopWorkspaceProcess)
        case .restartWorkspaceProcess(let payload): try container.encode(payload, forKey: .restartWorkspaceProcess)
        case .runCodingAgent(let payload): try container.encode(payload, forKey: .runCodingAgent)
        case .stopCodingAgent(let payload): try container.encode(payload, forKey: .stopCodingAgent)
        case .restartCodingAgent(let payload): try container.encode(payload, forKey: .restartCodingAgent)
        case .state(let payload): try container.encode(payload, forKey: .state)
        case .terminalControl(let payload): try container.encode(payload, forKey: .terminalControl)
        case .terminalPasteImage(let payload): try container.encode(payload, forKey: .terminalPasteImage)
        case .sendTerminalInput(let payload): try container.encode(payload, forKey: .sendTerminalInput)
        case .tailTerminalOutput(let payload): try container.encode(payload, forKey: .tailTerminalOutput)
        case .terminalTranscript(let payload): try container.encode(payload, forKey: .terminalTranscript)
        case .subscribe(let payload): try container.encode(payload, forKey: .subscribe)
        case .resolveTerminalLink(let payload): try container.encode(payload, forKey: .resolveTerminalLink)
        case .readTerminalLinkChunk(let payload): try container.encode(payload, forKey: .readTerminalLinkChunk)
        case .subscribeDeviceOverview: try container.encode(SpacesDeviceAPIEmptyPayload(), forKey: .subscribeDeviceOverview)
        case .agentHooksStatus: try container.encode(SpacesDeviceAPIEmptyPayload(), forKey: .agentHooksStatus)
        case .installAgentHooks(let payload): try container.encode(payload, forKey: .installAgentHooks)
        case .spawnAgentSession(let payload): try container.encode(payload, forKey: .spawnAgentSession)
        case .listAgentSessions(let payload): try container.encode(payload, forKey: .listAgentSessions)
        case .annotateAgentSession(let payload): try container.encode(payload, forKey: .annotateAgentSession)
        case .killAgentSession(let payload): try container.encode(payload, forKey: .killAgentSession)
        case .openServiceTunnel(let payload): try container.encode(payload, forKey: .openServiceTunnel)
        }
    }
}

public struct SpacesDeviceAPIRequest: Codable, Sendable, Equatable {
    public let authToken: String?
    public let clientApp: SpacesDeviceClientApp?
    public let command: SpacesDeviceAPICommand

    public init(command: SpacesDeviceAPICommand, authToken: String? = nil, clientApp: SpacesDeviceClientApp? = nil) {
        self.authToken = authToken
        self.clientApp = clientApp
        self.command = command
    }

    public var commandName: String { command.name }
    public var sessionID: String? { command.terminalSessionID }
    public var clientID: String? { command.terminalClientID }
    var isSafeToReplayAfterConnectionFailure: Bool { command.isSafeToReplayAfterConnectionFailure }
}

public struct SpacesDeviceIssuedAuthTokenResult: Codable, Sendable, Equatable {
    public let authToken: String

    public init(authToken: String) { self.authToken = authToken }
}

public struct SpacesDeviceMutationResult: Codable, Sendable, Equatable {
    public let overview: SpacesDeviceOverviewPayload?
    public let projectID: String?
    public let workspaceID: String?
    public let sessionID: String?

    public init(overview: SpacesDeviceOverviewPayload? = nil, projectID: String? = nil, workspaceID: String? = nil, sessionID: String? = nil) {
        self.overview = overview
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }
}

public enum SpacesDeviceAPIResult: Sendable, Equatable {
    case issuedAuthToken(SpacesDeviceIssuedAuthTokenResult)
    case daemonStatus(TerminalServiceDaemonStatus)
    case overview(SpacesDeviceOverviewPayload)
    case terminalState(GhosttyRemoteSessionStatePayload)
    case workspaceCreateOptions(SpacesDeviceWorkspaceCreateOptions)
    case projectPreview(SpacesDeviceProjectPreview)
    case gitProjectPreview(SpacesDeviceGitProjectPreview)
    case directorySuggestions(SpacesDeviceDirectorySuggestions)
    case mutation(SpacesDeviceMutationResult)
    case terminalLinkMetadata(SpacesDeviceTerminalLinkMetadata)
    case terminalLinkChunk(SpacesDeviceTerminalLinkChunk)
    case terminalOutput(SpacesDeviceTerminalOutputResult)
    case terminalTranscript(SpacesDeviceTerminalTranscriptResult)
    case agentHooksStatus(SpacesAgentHooksStatusPayload)
    case agentHooksInstall(AgentHookInstallOutcome)
    case agentSessions(SpacesDeviceAgentSessionsResult)
}

extension SpacesDeviceAPIResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case issuedAuthToken
        case daemonStatus
        case overview
        case terminalState
        case workspaceCreateOptions
        case projectPreview
        case gitProjectPreview
        case directorySuggestions
        case mutation
        case terminalLinkMetadata
        case terminalLinkChunk
        case terminalOutput
        case terminalTranscript
        case agentHooksStatus
        case agentHooksInstall
        case agentSessions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Device API result must contain exactly one payload."))
        }
        switch key {
        case .issuedAuthToken: self = .issuedAuthToken(try container.decode(SpacesDeviceIssuedAuthTokenResult.self, forKey: key))
        case .daemonStatus: self = .daemonStatus(try container.decode(TerminalServiceDaemonStatus.self, forKey: key))
        case .overview: self = .overview(try container.decode(SpacesDeviceOverviewPayload.self, forKey: key))
        case .terminalState: self = .terminalState(try container.decode(GhosttyRemoteSessionStatePayload.self, forKey: key))
        case .workspaceCreateOptions: self = .workspaceCreateOptions(try container.decode(SpacesDeviceWorkspaceCreateOptions.self, forKey: key))
        case .projectPreview: self = .projectPreview(try container.decode(SpacesDeviceProjectPreview.self, forKey: key))
        case .gitProjectPreview: self = .gitProjectPreview(try container.decode(SpacesDeviceGitProjectPreview.self, forKey: key))
        case .directorySuggestions: self = .directorySuggestions(try container.decode(SpacesDeviceDirectorySuggestions.self, forKey: key))
        case .mutation: self = .mutation(try container.decode(SpacesDeviceMutationResult.self, forKey: key))
        case .terminalLinkMetadata: self = .terminalLinkMetadata(try container.decode(SpacesDeviceTerminalLinkMetadata.self, forKey: key))
        case .terminalLinkChunk: self = .terminalLinkChunk(try container.decode(SpacesDeviceTerminalLinkChunk.self, forKey: key))
        case .terminalOutput: self = .terminalOutput(try container.decode(SpacesDeviceTerminalOutputResult.self, forKey: key))
        case .terminalTranscript: self = .terminalTranscript(try container.decode(SpacesDeviceTerminalTranscriptResult.self, forKey: key))
        case .agentHooksStatus: self = .agentHooksStatus(try container.decode(SpacesAgentHooksStatusPayload.self, forKey: key))
        case .agentHooksInstall: self = .agentHooksInstall(try container.decode(AgentHookInstallOutcome.self, forKey: key))
        case .agentSessions: self = .agentSessions(try container.decode(SpacesDeviceAgentSessionsResult.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .issuedAuthToken(let payload): try container.encode(payload, forKey: .issuedAuthToken)
        case .daemonStatus(let payload): try container.encode(payload, forKey: .daemonStatus)
        case .overview(let payload): try container.encode(payload, forKey: .overview)
        case .terminalState(let payload): try container.encode(payload, forKey: .terminalState)
        case .workspaceCreateOptions(let payload): try container.encode(payload, forKey: .workspaceCreateOptions)
        case .projectPreview(let payload): try container.encode(payload, forKey: .projectPreview)
        case .gitProjectPreview(let payload): try container.encode(payload, forKey: .gitProjectPreview)
        case .directorySuggestions(let payload): try container.encode(payload, forKey: .directorySuggestions)
        case .mutation(let payload): try container.encode(payload, forKey: .mutation)
        case .terminalLinkMetadata(let payload): try container.encode(payload, forKey: .terminalLinkMetadata)
        case .terminalLinkChunk(let payload): try container.encode(payload, forKey: .terminalLinkChunk)
        case .terminalOutput(let payload): try container.encode(payload, forKey: .terminalOutput)
        case .terminalTranscript(let payload): try container.encode(payload, forKey: .terminalTranscript)
        case .agentHooksStatus(let payload): try container.encode(payload, forKey: .agentHooksStatus)
        case .agentHooksInstall(let payload): try container.encode(payload, forKey: .agentHooksInstall)
        case .agentSessions(let payload): try container.encode(payload, forKey: .agentSessions)
        }
    }
}

public struct SpacesDeviceAPIResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String
    /// Machine-readable failure category. Nil on success and omitted from the wire when nil.
    public let errorCode: SpacesDeviceErrorCode?
    public let result: SpacesDeviceAPIResult?

    public init(ok: Bool, message: String, errorCode: SpacesDeviceErrorCode? = nil, result: SpacesDeviceAPIResult? = nil) {
        self.ok = ok
        self.message = message
        self.errorCode = errorCode
        self.result = result
    }

    public var overview: SpacesDeviceOverviewPayload? {
        switch result {
        case .overview(let overview): overview
        case .mutation(let payload): payload.overview
        default: nil
        }
    }

    public var issuedAuthToken: String? { if case .issuedAuthToken(let payload) = result { payload.authToken } else { nil } }

    public var daemonStatus: TerminalServiceDaemonStatus? { if case .daemonStatus(let payload) = result { payload } else { nil } }

    public var sessionState: GhosttyRemoteSessionStatePayload? { if case .terminalState(let payload) = result { payload } else { nil } }

    public var workspaceCreateOptions: SpacesDeviceWorkspaceCreateOptions? {
        if case .workspaceCreateOptions(let payload) = result { payload } else { nil }
    }

    public var projectPreview: SpacesDeviceProjectPreview? { if case .projectPreview(let payload) = result { payload } else { nil } }

    public var gitProjectPreview: SpacesDeviceGitProjectPreview? { if case .gitProjectPreview(let payload) = result { payload } else { nil } }

    public var directorySuggestions: SpacesDeviceDirectorySuggestions? {
        if case .directorySuggestions(let payload) = result { payload } else { nil }
    }

    public var projectID: String? { if case .mutation(let payload) = result { payload.projectID } else { nil } }

    public var workspaceID: String? { if case .mutation(let payload) = result { payload.workspaceID } else { nil } }

    public var sessionID: String? { if case .mutation(let payload) = result { payload.sessionID } else { nil } }

    public var terminalLinkMetadata: SpacesDeviceTerminalLinkMetadata? {
        if case .terminalLinkMetadata(let payload) = result { payload } else { nil }
    }

    public var terminalLinkChunk: SpacesDeviceTerminalLinkChunk? { if case .terminalLinkChunk(let payload) = result { payload } else { nil } }

    public var terminalOutput: String? { if case .terminalOutput(let payload) = result { payload.text } else { nil } }

    public var terminalTranscript: SpacesDeviceTerminalTranscriptResult? {
        if case .terminalTranscript(let payload) = result { payload } else { nil }
    }

    public var agentHooksStatus: SpacesAgentHooksStatusPayload? { if case .agentHooksStatus(let payload) = result { payload } else { nil } }

    public var agentHooksInstall: AgentHookInstallOutcome? { if case .agentHooksInstall(let payload) = result { payload } else { nil } }

    public var agentSessions: [SpacesDeviceAgentSessionRow]? { if case .agentSessions(let payload) = result { payload.rows } else { nil } }
}

public enum SpacesDeviceAPICodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encodeRequest(_ request: SpacesDeviceAPIRequest) throws -> Data { try encoder.encode(request) }

    public static func decodeRequest(_ data: Data) throws -> SpacesDeviceAPIRequest { try decoder.decode(SpacesDeviceAPIRequest.self, from: data) }

    public static func encodeResponse(_ response: SpacesDeviceAPIResponse) throws -> Data { try encoder.encode(response) }

    public static func encodeResponseLine(_ response: SpacesDeviceAPIResponse) throws -> Data {
        var data = try encodeResponse(response)
        data.append(0x0A)
        return data
    }

    public static func decodeResponse(_ data: Data) throws -> SpacesDeviceAPIResponse { try decoder.decode(SpacesDeviceAPIResponse.self, from: data) }
}
