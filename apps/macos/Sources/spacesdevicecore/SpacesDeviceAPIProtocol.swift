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

public struct SpacesDeviceWorkspaceConfig: Codable, Sendable, Equatable {
    public let stopScript: String?
    public let ports: [SpacesDeviceServiceDefinition]
    public let processes: [SpacesDeviceProcessTemplate]
    public let browserSessions: [SpacesDeviceBrowserSession]
    public let resolvedBrowserSessions: [SpacesDeviceBrowserSession]

    public init(
        stopScript: String? = nil, ports: [SpacesDeviceServiceDefinition] = [], processes: [SpacesDeviceProcessTemplate] = [],
        browserSessions: [SpacesDeviceBrowserSession] = [], resolvedBrowserSessions: [SpacesDeviceBrowserSession] = []
    ) {
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
        self.resolvedBrowserSessions = resolvedBrowserSessions
    }

    private enum CodingKeys: String, CodingKey {
        case stopScript
        case ports
        case processes
        case browserSessions
        case resolvedBrowserSessions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stopScript = try container.decodeIfPresent(String.self, forKey: .stopScript)
        ports = try container.decodeIfPresent([SpacesDeviceServiceDefinition].self, forKey: .ports) ?? []
        processes = try container.decodeIfPresent([SpacesDeviceProcessTemplate].self, forKey: .processes) ?? []
        browserSessions = try container.decodeIfPresent([SpacesDeviceBrowserSession].self, forKey: .browserSessions) ?? []
        resolvedBrowserSessions = try container.decodeIfPresent([SpacesDeviceBrowserSession].self, forKey: .resolvedBrowserSessions) ?? []
    }
}

public struct SpacesDeviceProjectConfig: Codable, Sendable, Equatable {
    public let setupScript: String?
    public let stopScript: String?
    public let ports: [SpacesDeviceServiceDefinition]
    public let processes: [SpacesDeviceProcessTemplate]
    public let browserSessions: [SpacesDeviceBrowserSession]

    public init(
        setupScript: String? = nil, stopScript: String? = nil, ports: [SpacesDeviceServiceDefinition] = [],
        processes: [SpacesDeviceProcessTemplate] = [], browserSessions: [SpacesDeviceBrowserSession] = []
    ) {
        self.setupScript = setupScript
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
    }

    private enum CodingKeys: String, CodingKey {
        case setupScript
        case stopScript
        case ports
        case processes
        case browserSessions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript)
        stopScript = try container.decodeIfPresent(String.self, forKey: .stopScript)
        ports = try container.decodeIfPresent([SpacesDeviceServiceDefinition].self, forKey: .ports) ?? []
        processes = try container.decodeIfPresent([SpacesDeviceProcessTemplate].self, forKey: .processes) ?? []
        browserSessions = try container.decodeIfPresent([SpacesDeviceBrowserSession].self, forKey: .browserSessions) ?? []
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
    public let isHidden: Bool
    public let config: SpacesDeviceProjectConfig

    public init(
        id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, isHidden: Bool = false,
        config: SpacesDeviceProjectConfig = SpacesDeviceProjectConfig()
    ) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.isHidden = isHidden
        self.config = config
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case dir
        case isGitRepo
        case defaultBranch
        case isHidden
        case config
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        dir = try container.decode(String.self, forKey: .dir)
        isGitRepo = try container.decode(Bool.self, forKey: .isGitRepo)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
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
    /// The title the agent's terminal last reported (OSC 0/2), nil when its session has reported none or
    /// the row has no session behind it. Read exactly as the terminal row's `liveTitle` is: the name says
    /// which agent this is, the live title says what it is doing.
    public let liveTitle: String?
    public let command: String
    public let agentID: String?
    public let sessionID: String?
    public let runState: SpacesDeviceRunState
    public let activityState: SpacesDeviceCodingAgentActivityState
    /// ISO-8601 timestamp of the agent session's last state change, when known. Drives
    /// attention-alert recency and dismissal identity without the client opening the daemon database.
    public let updatedAt: String?
    public let canStop: Bool

    public init(
        id: String, workspaceID: String, name: String, command: String, agentID: String?, sessionID: String?, runState: SpacesDeviceRunState,
        activityState: SpacesDeviceCodingAgentActivityState, updatedAt: String? = nil, canStop: Bool, liveTitle: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.liveTitle = liveTitle
        self.command = command
        self.agentID = agentID
        self.sessionID = sessionID
        self.runState = runState
        self.activityState = activityState
        self.updatedAt = updatedAt
        self.canStop = canStop
    }
}

public struct SpacesDeviceWorkspaceTerminalRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    /// The row's stable name: what the user renamed the terminal to, else the name it was launched
    /// under (`shell-1`). It changes only when the user changes it.
    public let title: String
    /// The title the program running in this terminal last reported (OSC 0/2), nil when it has reported
    /// none. Clients show it as the row's secondary text beside `title`, which it never replaces: the
    /// name says which terminal this is, the live title says what it is doing.
    public let liveTitle: String?
    public let workingDirectory: String
    public let sessionID: String?
    public let runState: SpacesDeviceRunState
    public let canOpenTerminal: Bool
    public let canStop: Bool

    public init(
        id: String, workspaceID: String, title: String, workingDirectory: String, sessionID: String?, runState: SpacesDeviceRunState,
        canOpenTerminal: Bool, canStop: Bool = false, liveTitle: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.liveTitle = liveTitle
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
        case liveTitle
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
        liveTitle = try container.decodeIfPresent(String.self, forKey: .liveTitle)
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
        id: String, projectID: String, projectName: String, branch: String?, baseBranch: String?, dir: String, isRunning: Bool, isHidden: Bool,
        isDefault: Bool, notes: String? = nil, sessionCount: Int, assignedPorts: [SpacesDeviceAssignedPort] = [], environment: [String: String] = [:],
        setupState: SpacesDeviceWorkspaceSetupState? = nil, config: SpacesDeviceWorkspaceConfig = SpacesDeviceWorkspaceConfig(),
        processRows: [SpacesDeviceWorkspaceProcessRow] = [], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [],
        terminalRows: [SpacesDeviceWorkspaceTerminalRow] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.branch = branch
        self.baseBranch = baseBranch
        self.dir = dir
        self.isRunning = isRunning
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
    /// The session's stable name: the user's rename when set, else the name it was launched under. A
    /// session that backs a configured process or coding agent is named by that config entry.
    public let title: String
    /// The title the program in this session last reported (OSC 0/2), nil when it reported none, and
    /// always nil for a configured process's session, which is described by the command its configured
    /// entry names rather than by what the program prints.
    public let liveTitle: String?
    public let workingDirectory: String
    /// Shell and launch command from the session's persisted launch configuration, so a
    /// device-backed window shows the same shell/command the daemon launched with rather
    /// than a hard-coded default.
    public let shell: String
    public let command: String?
    /// Readable argv for the already-inspected foreground process. It is nil when the daemon has no
    /// foreground sample and is separate from `liveTitle`, which is reported by the terminal program.
    public let foregroundCommand: String?
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
    /// When this session's program last rang the terminal bell, as the daemon recorded it (nil until a
    /// bell arrives). Clients derive a bell alert from it and use its value as the alert's dismissal
    /// identity; the daemon coalesces repeats so the value only moves for a bell worth re-raising.
    public let bellAt: String?

    public init(
        id: String, title: String, liveTitle: String? = nil, workingDirectory: String, shell: String, command: String?, state: TerminalSessionState,
        backend: TerminalSessionBackendKind, lifetimePolicy: TerminalSessionLifetimePolicy, servicePID: Int32, childPID: Int32?, workspaceID: String,
        workspaceTitle: String?, projectID: String?, projectName: String?, createdAt: String, updatedAt: String, isControlAvailable: Bool,
        isSubscriptionAvailable: Bool, attachmentSnapshot: TerminalSessionAttachmentSnapshot,
        rowKind: SpacesDeviceTerminalSessionRowKind = .liveSession, rowSourceID: String? = nil, hasFinalRender: Bool = false,
        foregroundDetectedAgentKind: String? = nil, foregroundCommand: String? = nil, bellAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.liveTitle = liveTitle
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.command = command
        self.foregroundCommand = foregroundCommand
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
        self.bellAt = bellAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case liveTitle
        case workingDirectory
        case shell
        case command
        case foregroundCommand
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
        case bellAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        liveTitle = try container.decodeIfPresent(String.self, forKey: .liveTitle)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        shell = try container.decode(String.self, forKey: .shell)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        foregroundCommand = try container.decodeIfPresent(String.self, forKey: .foregroundCommand)
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
        bellAt = try container.decodeIfPresent(String.self, forKey: .bellAt)
    }
}

public struct SpacesDeviceOverviewPayload: Codable, Sendable, Equatable {
    public let projects: [SpacesDeviceProjectSummary]
    public let workspaces: [SpacesDeviceWorkspaceSummary]
    public let sessions: [SpacesDeviceTerminalSessionSummary]
    /// Every terminal session id whose pane and transcript the daemon still retains — the keep-set a
    /// client prunes open panes against. The daemon publishes its own retention rule here (the union of
    /// live interactive sessions and sessions referenced by a `running_processes`, `agent_sessions`, or
    /// `runtime_targets` row, matching `SQLiteStore.terminalSessionIsReferencedByProduct` and the session
    /// garbage collector) so a client never has to re-derive it from the row surfaces. It is a superset
    /// of `sessions`: a session referenced only by a `runtime_targets` row drops out of `sessions` the
    /// moment its shell exits but stays here until that row is removed, keeping its ended pane open for
    /// scrollback until the transcript is actually collectable. Ids are whitespace-trimmed and sorted.
    public let retainedTerminalSessionIDs: [String]
    /// Frozen-core handshake (wire protocol version + restart-impact counts) for the daemon that
    /// produced this overview. Carried inline so a compatible client reads the compatibility verdict
    /// from the same round-trip as the overview, instead of paying a second `daemonStatus` call on
    /// every refresh.
    public let daemonStatus: TerminalServiceDaemonStatus
    /// Workspaces whose teardown this daemon is running right now — the archive work is on its teardown
    /// queue, or queued to start on it, and has not finished. Includes every workspace of a project being
    /// deleted. Ids are whitespace-trimmed and sorted.
    ///
    /// This exists because a client cannot tell the two reasons a workspace is still listed apart on its
    /// own. After a delete whose response was lost, a client probes the overview; seeing the workspace
    /// still there could mean the delete failed, or that a slow user stop script is still running and the
    /// daemon will remove it shortly. Guessing "failed" is the destructive one — the client tells the user
    /// the workspace survived, and the daemon deletes it moments later. Only the daemon knows which is
    /// happening, so it reports it here rather than leaving clients to infer it from timing.
    public let workspaceIDsWithTeardownInFlight: [String]
    /// Every automation configured on the daemon, so a client can render the automations list and derive
    /// per-automation schedule/next-fire details without a second call.
    public let automations: [TerminalServiceAutomationSummary]
    /// The daemon's recent automation runs: all currently-active (queued/running) runs plus the newest
    /// terminal runs (see `SpacesDeviceOverviewBuilder` for the window size), newest first. Recent
    /// failed/timed-out runs are identifiable here so clients can derive alert entries.
    public let automationRuns: [TerminalServiceAutomationRunSummary]

    public init(
        projects: [SpacesDeviceProjectSummary] = [], workspaces: [SpacesDeviceWorkspaceSummary], sessions: [SpacesDeviceTerminalSessionSummary],
        retainedTerminalSessionIDs: [String] = [], workspaceIDsWithTeardownInFlight: [String] = [], daemonStatus: TerminalServiceDaemonStatus,
        automations: [TerminalServiceAutomationSummary] = [], automationRuns: [TerminalServiceAutomationRunSummary] = []
    ) {
        self.projects = projects
        self.workspaces = workspaces
        self.sessions = sessions
        self.retainedTerminalSessionIDs = retainedTerminalSessionIDs
        self.workspaceIDsWithTeardownInFlight = workspaceIDsWithTeardownInFlight
        self.daemonStatus = daemonStatus
        self.automations = automations
        self.automationRuns = automationRuns
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case workspaces
        case sessions
        case retainedTerminalSessionIDs
        case workspaceIDsWithTeardownInFlight
        case daemonStatus
        case automations
        case automationRuns
    }

    /// Custom decode so an overview from a daemon that predates a given field (projects predates
    /// nothing shipped, but automations/automationRuns predate the automations feature) still decodes
    /// successfully. The synthesized initializer requires every key regardless of the memberwise-init
    /// defaults above, so a missing key would fail decoding of the *entire* overview -- workspaces and
    /// sessions included -- rather than just leaving the new field empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([SpacesDeviceProjectSummary].self, forKey: .projects) ?? []
        workspaces = try container.decode([SpacesDeviceWorkspaceSummary].self, forKey: .workspaces)
        sessions = try container.decode([SpacesDeviceTerminalSessionSummary].self, forKey: .sessions)
        retainedTerminalSessionIDs = try container.decodeIfPresent([String].self, forKey: .retainedTerminalSessionIDs) ?? []
        workspaceIDsWithTeardownInFlight = try container.decodeIfPresent([String].self, forKey: .workspaceIDsWithTeardownInFlight) ?? []
        daemonStatus = try container.decode(TerminalServiceDaemonStatus.self, forKey: .daemonStatus)
        automations = try container.decodeIfPresent([TerminalServiceAutomationSummary].self, forKey: .automations) ?? []
        automationRuns = try container.decodeIfPresent([TerminalServiceAutomationRunSummary].self, forKey: .automationRuns) ?? []
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

/// Daemon-owned project state that is not part of the project's configuration surface. Carries the
/// same `updates*` gate as the workspace metadata request so a client can move one field without
/// having to restate the others.
public struct SpacesDeviceProjectMetadataUpdateRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let isHidden: Bool?
    public let updatesHidden: Bool

    public init(projectID: String, isHidden: Bool? = nil, updatesHidden: Bool = false) {
        self.projectID = projectID
        self.isHidden = isHidden
        self.updatesHidden = updatesHidden
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case isHidden
        case updatesHidden
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden)
        updatesHidden = try container.decodeIfPresent(Bool.self, forKey: .updatesHidden) ?? false
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

/// Addresses one terminal session inside a workspace. Shared by the unconditional stop
/// (`stopWorkspaceTerminal`, the sidebar's explicit Stop) and the conditional one
/// (`stopWorkspaceTerminalIfBareShell`, a closed owner pane), which differ only in the decision the
/// daemon makes, not in what they name.
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
    /// The session's new name. An empty (or whitespace-only) title clears the rename rather than
    /// setting one, restoring the name the session was launched under — the only way back from a
    /// rename, and the reason this command never rejects an empty title.
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

public struct SpacesDeviceCodingAgentMutationRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let agentID: String?

    public init(workspaceID: String, agentID: String? = nil) {
        self.workspaceID = workspaceID
        self.agentID = agentID
    }
}

/// Renames a coding-agent row, addressed by the agent session id its overview row carries.
public struct SpacesDeviceAgentSessionRenameRequest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let agentID: String
    /// The row's new name. An empty (or whitespace-only) title clears the rename rather than setting
    /// one, restoring the name the agent reports for itself — the only way back from a rename, and the
    /// reason this command never rejects an empty title.
    public let title: String

    public init(workspaceID: String, agentID: String, title: String) {
        self.workspaceID = workspaceID
        self.agentID = agentID
        self.title = title
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
    case mouseButton
    case setAppearance
    case setSelection
    case clearSelection
    case readSelectionText
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
    public let mouseButton: UInt8?
    public let mousePressed: Bool?
    public let mousePointerX: Double?
    public let mousePointerY: Double?
    public let mousePointerMods: UInt32?
    public let appendNewline: Bool
    public let asPaste: Bool
    /// The attaching client's OS appearance (light/dark), carried on `attach` so a remote daemon can render
    /// its terminal with the client's theme variant. Mirrors `TerminalControlRequest.appearance`; without it
    /// the daemon keeps its default theme on the device-API attach path.
    public let appearance: ThemeAppearance?
    /// `setSelection`'s endpoints, in absolute screen-space coordinates (row 0 = oldest retained
    /// scrollback row). Mirrors `TerminalControlRequest.selectionStartColumn` etc.
    public let selectionStartColumn: UInt16?
    public let selectionStartRow: UInt32?
    public let selectionEndColumn: UInt16?
    public let selectionEndRow: UInt32?
    public let selectionRectangle: Bool?

    public init(
        action: SpacesDeviceTerminalControlAction, sessionID: String, clientID: String? = nil, client: TerminalClient? = nil,
        attachmentMode: TerminalAttachmentMode? = nil, text: String? = nil, key: String? = nil, columns: Int? = nil, rows: Int? = nil,
        ownerEpoch: UInt64? = nil, resizeSerial: UInt64? = nil, scrollHorizontal: Double? = nil, scrollVertical: Double? = nil,
        scrollMods: Int32? = nil, scrollPointerX: Double? = nil, scrollPointerY: Double? = nil, scrollPointerMods: UInt32? = nil,
        mouseButton: UInt8? = nil, mousePressed: Bool? = nil, mousePointerX: Double? = nil, mousePointerY: Double? = nil,
        mousePointerMods: UInt32? = nil, appendNewline: Bool = false, asPaste: Bool = false, appearance: ThemeAppearance? = nil,
        selectionStartColumn: UInt16? = nil, selectionStartRow: UInt32? = nil, selectionEndColumn: UInt16? = nil,
        selectionEndRow: UInt32? = nil, selectionRectangle: Bool? = nil
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
        self.mouseButton = mouseButton
        self.mousePressed = mousePressed
        self.mousePointerX = mousePointerX
        self.mousePointerY = mousePointerY
        self.mousePointerMods = mousePointerMods
        self.appendNewline = appendNewline
        self.asPaste = asPaste
        self.appearance = appearance
        self.selectionStartColumn = selectionStartColumn
        self.selectionStartRow = selectionStartRow
        self.selectionEndColumn = selectionEndColumn
        self.selectionEndRow = selectionEndRow
        self.selectionRectangle = selectionRectangle
    }
}

public struct SpacesDeviceTerminalPasteImageRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let clientID: String
    /// The owner generation the client composed this paste against, or `nil` when the client holds no
    /// cached render owner epoch — the same contract every other terminal input path uses, where `nil`
    /// means "do not epoch-gate this input". A client's cache is legitimately empty in normal operation,
    /// so an absent epoch must not read as epoch 0.
    public let ownerEpoch: UInt64?
    public let fileExtension: String
    public let imageData: Data

    public init(sessionID: String, clientID: String, ownerEpoch: UInt64?, fileExtension: String, imageData: Data) {
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
    /// The automation execution this spawn belongs to, when initiated by the daemon's scheduler. Threaded
    /// through to the daemon so it can attribute the spawned session to its run; nil for ordinary spawns,
    /// which preserves existing behavior.
    public let automationRunID: String?

    public init(workspaceID: String, command: String, title: String? = nil, automationRunID: String? = nil) {
        self.workspaceID = workspaceID
        self.command = command
        self.title = title
        self.automationRunID = automationRunID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case command
        case title
        case automationRunID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        command = try container.decode(String.self, forKey: .command)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        automationRunID = try container.decodeIfPresent(String.self, forKey: .automationRunID)
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

/// Names an automation by id for the delete/trigger Device API commands. A one-field struct (rather than a
/// bare string) keeps the command payloads uniform with the rest of the Device API contract.
public struct SpacesDeviceAutomationReference: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) { self.id = id }
}

/// Names an automation run by id for the run-cancel Device API command.
public struct SpacesDeviceAutomationRunReference: Codable, Sendable, Equatable {
    public let runID: String

    public init(runID: String) { self.runID = runID }
}

/// Automations returned by the create/update/list Device API commands (create/update return the affected
/// automation as a one-element list, matching how `annotateAgentSession` returns its single row).
public struct SpacesDeviceAutomationsResult: Codable, Sendable, Equatable {
    public let rows: [TerminalServiceAutomationSummary]

    public init(rows: [TerminalServiceAutomationSummary]) { self.rows = rows }
}

/// Automation runs returned by the runs-list/trigger/run-cancel Device API commands.
public struct SpacesDeviceAutomationRunsResult: Codable, Sendable, Equatable {
    public let rows: [TerminalServiceAutomationRunSummary]

    public init(rows: [TerminalServiceAutomationRunSummary]) { self.rows = rows }
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
    case updateProjectMetadata(SpacesDeviceProjectMetadataUpdateRequest)
    case updateWorkspaceConfig(SpacesDeviceWorkspaceConfigUpdateRequest)
    case updateWorkspaceMetadata(SpacesDeviceWorkspaceMetadataUpdateRequest)
    case openWorkspaceTerminal(SpacesDeviceWorkspaceReference)
    case stopWorkspaceTerminal(SpacesDeviceWorkspaceTerminalRequest)
    /// Stops a workspace terminal only when the daemon finds it idle at a bare shell prompt: the
    /// close of the pane that owned an ad hoc terminal. A terminal with a real foreground process, a
    /// surviving owner attachment, or a configured owner is kept and stays recoverable.
    case stopWorkspaceTerminalIfBareShell(SpacesDeviceWorkspaceTerminalRequest)
    case renameTerminalSession(SpacesDeviceTerminalSessionRenameRequest)
    case runWorkspaceProcess(SpacesDeviceRunWorkspaceProcessRequest)
    case stopWorkspaceProcess(SpacesDeviceWorkspaceProcessMutationRequest)
    case restartWorkspaceProcess(SpacesDeviceWorkspaceProcessMutationRequest)
    case stopCodingAgent(SpacesDeviceCodingAgentMutationRequest)
    /// Renames a coding-agent row whose name lives on its session rather than in the workspace config.
    case renameAgentSession(SpacesDeviceAgentSessionRenameRequest)
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
    /// Automation authoring + control on the daemon host, the remote counterparts of the profile-socket
    /// automation commands. Each routes through the daemon's one live automation scheduler, so a local and
    /// a remote caller drive the same scheduler state.
    case createAutomation(TerminalServiceAutomationFields)
    case updateAutomation(TerminalServiceAutomationUpdatePayload)
    /// Overrides only the automation's next occurrence; the cron schedule resumes after it fires.
    case setAutomationNextRun(TerminalServiceAutomationNextRunPayload)
    case deleteAutomation(SpacesDeviceAutomationReference)
    case listAutomations
    case listAutomationRuns(TerminalServiceAutomationRunsListPayload)
    case triggerAutomation(SpacesDeviceAutomationReference)
    case cancelAutomationRun(SpacesDeviceAutomationRunReference)
    /// Ends the still-live coding-agent sessions attributed to a terminal automation run. The remote
    /// counterpart of the profile-socket `automationEndAgents` command; leaves the run status untouched.
    case endAutomationAgents(SpacesDeviceAutomationRunReference)

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
        case .updateProjectMetadata: "updateProjectMetadata"
        case .updateWorkspaceConfig: "updateWorkspaceConfig"
        case .updateWorkspaceMetadata: "updateWorkspaceMetadata"
        case .openWorkspaceTerminal: "openWorkspaceTerminal"
        case .stopWorkspaceTerminal: "stopWorkspaceTerminal"
        case .stopWorkspaceTerminalIfBareShell: "stopWorkspaceTerminalIfBareShell"
        case .renameTerminalSession: "renameTerminalSession"
        case .runWorkspaceProcess: "runWorkspaceProcess"
        case .stopWorkspaceProcess: "stopWorkspaceProcess"
        case .restartWorkspaceProcess: "restartWorkspaceProcess"
        case .stopCodingAgent: "stopCodingAgent"
        case .renameAgentSession: "renameAgentSession"
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
        case .createAutomation: "createAutomation"
        case .updateAutomation: "updateAutomation"
        case .setAutomationNextRun: "setAutomationNextRun"
        case .deleteAutomation: "deleteAutomation"
        case .listAutomations: "listAutomations"
        case .listAutomationRuns: "listAutomationRuns"
        case .triggerAutomation: "triggerAutomation"
        case .cancelAutomationRun: "cancelAutomationRun"
        case .endAutomationAgents: "endAutomationAgents"
        }
    }

    public var terminalSessionID: String? {
        switch self {
        case .stopWorkspaceTerminal(let payload): payload.sessionID
        case .stopWorkspaceTerminalIfBareShell(let payload): payload.sessionID
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
            .resolveTerminalLink, .readTerminalLinkChunk, .tailTerminalOutput, .terminalTranscript, .agentHooksStatus, .listAgentSessions,
            .listAutomations, .listAutomationRuns:
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
        case updateProjectMetadata
        case updateWorkspaceConfig
        case updateWorkspaceMetadata
        case openWorkspaceTerminal
        case stopWorkspaceTerminal
        case stopWorkspaceTerminalIfBareShell
        case renameTerminalSession
        case runWorkspaceProcess
        case stopWorkspaceProcess
        case restartWorkspaceProcess
        case stopCodingAgent
        case renameAgentSession
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
        case createAutomation
        case updateAutomation
        case setAutomationNextRun
        case deleteAutomation
        case listAutomations
        case listAutomationRuns
        case triggerAutomation
        case cancelAutomationRun
        case endAutomationAgents
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
        case .updateProjectMetadata: self = .updateProjectMetadata(try container.decode(SpacesDeviceProjectMetadataUpdateRequest.self, forKey: key))
        case .updateWorkspaceConfig: self = .updateWorkspaceConfig(try container.decode(SpacesDeviceWorkspaceConfigUpdateRequest.self, forKey: key))
        case .updateWorkspaceMetadata:
            self = .updateWorkspaceMetadata(try container.decode(SpacesDeviceWorkspaceMetadataUpdateRequest.self, forKey: key))
        case .openWorkspaceTerminal: self = .openWorkspaceTerminal(try container.decode(SpacesDeviceWorkspaceReference.self, forKey: key))
        case .stopWorkspaceTerminal: self = .stopWorkspaceTerminal(try container.decode(SpacesDeviceWorkspaceTerminalRequest.self, forKey: key))
        case .stopWorkspaceTerminalIfBareShell:
            self = .stopWorkspaceTerminalIfBareShell(try container.decode(SpacesDeviceWorkspaceTerminalRequest.self, forKey: key))
        case .renameTerminalSession: self = .renameTerminalSession(try container.decode(SpacesDeviceTerminalSessionRenameRequest.self, forKey: key))
        case .runWorkspaceProcess: self = .runWorkspaceProcess(try container.decode(SpacesDeviceRunWorkspaceProcessRequest.self, forKey: key))
        case .stopWorkspaceProcess: self = .stopWorkspaceProcess(try container.decode(SpacesDeviceWorkspaceProcessMutationRequest.self, forKey: key))
        case .restartWorkspaceProcess:
            self = .restartWorkspaceProcess(try container.decode(SpacesDeviceWorkspaceProcessMutationRequest.self, forKey: key))
        case .stopCodingAgent: self = .stopCodingAgent(try container.decode(SpacesDeviceCodingAgentMutationRequest.self, forKey: key))
        case .renameAgentSession: self = .renameAgentSession(try container.decode(SpacesDeviceAgentSessionRenameRequest.self, forKey: key))
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
        case .createAutomation: self = .createAutomation(try container.decode(TerminalServiceAutomationFields.self, forKey: key))
        case .updateAutomation: self = .updateAutomation(try container.decode(TerminalServiceAutomationUpdatePayload.self, forKey: key))
        case .setAutomationNextRun: self = .setAutomationNextRun(try container.decode(TerminalServiceAutomationNextRunPayload.self, forKey: key))
        case .deleteAutomation: self = .deleteAutomation(try container.decode(SpacesDeviceAutomationReference.self, forKey: key))
        case .listAutomations:
            _ = try container.decode(SpacesDeviceAPIEmptyPayload.self, forKey: key)
            self = .listAutomations
        case .listAutomationRuns: self = .listAutomationRuns(try container.decode(TerminalServiceAutomationRunsListPayload.self, forKey: key))
        case .triggerAutomation: self = .triggerAutomation(try container.decode(SpacesDeviceAutomationReference.self, forKey: key))
        case .cancelAutomationRun: self = .cancelAutomationRun(try container.decode(SpacesDeviceAutomationRunReference.self, forKey: key))
        case .endAutomationAgents: self = .endAutomationAgents(try container.decode(SpacesDeviceAutomationRunReference.self, forKey: key))
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
        case .updateProjectMetadata(let payload): try container.encode(payload, forKey: .updateProjectMetadata)
        case .updateWorkspaceConfig(let payload): try container.encode(payload, forKey: .updateWorkspaceConfig)
        case .updateWorkspaceMetadata(let payload): try container.encode(payload, forKey: .updateWorkspaceMetadata)
        case .openWorkspaceTerminal(let payload): try container.encode(payload, forKey: .openWorkspaceTerminal)
        case .stopWorkspaceTerminal(let payload): try container.encode(payload, forKey: .stopWorkspaceTerminal)
        case .stopWorkspaceTerminalIfBareShell(let payload): try container.encode(payload, forKey: .stopWorkspaceTerminalIfBareShell)
        case .renameTerminalSession(let payload): try container.encode(payload, forKey: .renameTerminalSession)
        case .runWorkspaceProcess(let payload): try container.encode(payload, forKey: .runWorkspaceProcess)
        case .stopWorkspaceProcess(let payload): try container.encode(payload, forKey: .stopWorkspaceProcess)
        case .restartWorkspaceProcess(let payload): try container.encode(payload, forKey: .restartWorkspaceProcess)
        case .stopCodingAgent(let payload): try container.encode(payload, forKey: .stopCodingAgent)
        case .renameAgentSession(let payload): try container.encode(payload, forKey: .renameAgentSession)
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
        case .createAutomation(let payload): try container.encode(payload, forKey: .createAutomation)
        case .updateAutomation(let payload): try container.encode(payload, forKey: .updateAutomation)
        case .setAutomationNextRun(let payload): try container.encode(payload, forKey: .setAutomationNextRun)
        case .deleteAutomation(let payload): try container.encode(payload, forKey: .deleteAutomation)
        case .listAutomations: try container.encode(SpacesDeviceAPIEmptyPayload(), forKey: .listAutomations)
        case .listAutomationRuns(let payload): try container.encode(payload, forKey: .listAutomationRuns)
        case .triggerAutomation(let payload): try container.encode(payload, forKey: .triggerAutomation)
        case .cancelAutomationRun(let payload): try container.encode(payload, forKey: .cancelAutomationRun)
        case .endAutomationAgents(let payload): try container.encode(payload, forKey: .endAutomationAgents)
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
    /// A failure-only report on something the user asked for beyond the mutation itself: deleting a
    /// workspace's branches reports a branch skipped as protected, no branch name recorded, or a git error
    /// deleting the branch. `nil` when there is nothing to report, including when the requested branches
    /// were deleted cleanly or were already gone, which is what lets a client show it only when something
    /// went wrong.
    public let notice: String?
    /// The outcome of a mutation that decides for itself whether to act: `stopWorkspaceTerminalIfBareShell`
    /// reports `true` when it terminated the session and `false` when it kept it (a real foreground
    /// process, a surviving owner attachment, or a configured owner). `nil` for every other mutation,
    /// which has no such choice to report.
    public let terminatedTerminalSession: Bool?

    public init(
        overview: SpacesDeviceOverviewPayload? = nil, projectID: String? = nil, workspaceID: String? = nil, sessionID: String? = nil,
        notice: String? = nil, terminatedTerminalSession: Bool? = nil
    ) {
        self.overview = overview
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.notice = notice
        self.terminatedTerminalSession = terminatedTerminalSession
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
    case terminalSelectionText(SpacesDeviceTerminalOutputResult)
    case terminalTranscript(SpacesDeviceTerminalTranscriptResult)
    case agentHooksStatus(SpacesAgentHooksStatusPayload)
    case agentHooksInstall(AgentHookInstallOutcome)
    case agentSessions(SpacesDeviceAgentSessionsResult)
    case automations(SpacesDeviceAutomationsResult)
    case automationRuns(SpacesDeviceAutomationRunsResult)
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
        case terminalSelectionText
        case terminalTranscript
        case agentHooksStatus
        case agentHooksInstall
        case agentSessions
        case automations
        case automationRuns
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
        case .terminalSelectionText: self = .terminalSelectionText(try container.decode(SpacesDeviceTerminalOutputResult.self, forKey: key))
        case .terminalTranscript: self = .terminalTranscript(try container.decode(SpacesDeviceTerminalTranscriptResult.self, forKey: key))
        case .agentHooksStatus: self = .agentHooksStatus(try container.decode(SpacesAgentHooksStatusPayload.self, forKey: key))
        case .agentHooksInstall: self = .agentHooksInstall(try container.decode(AgentHookInstallOutcome.self, forKey: key))
        case .agentSessions: self = .agentSessions(try container.decode(SpacesDeviceAgentSessionsResult.self, forKey: key))
        case .automations: self = .automations(try container.decode(SpacesDeviceAutomationsResult.self, forKey: key))
        case .automationRuns: self = .automationRuns(try container.decode(SpacesDeviceAutomationRunsResult.self, forKey: key))
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
        case .terminalSelectionText(let payload): try container.encode(payload, forKey: .terminalSelectionText)
        case .terminalTranscript(let payload): try container.encode(payload, forKey: .terminalTranscript)
        case .agentHooksStatus(let payload): try container.encode(payload, forKey: .agentHooksStatus)
        case .agentHooksInstall(let payload): try container.encode(payload, forKey: .agentHooksInstall)
        case .agentSessions(let payload): try container.encode(payload, forKey: .agentSessions)
        case .automations(let payload): try container.encode(payload, forKey: .automations)
        case .automationRuns(let payload): try container.encode(payload, forKey: .automationRuns)
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

    /// The mutation's extra outcome, when it had one (see `SpacesDeviceMutationResult.notice`).
    public var mutationNotice: String? { if case .mutation(let payload) = result { payload.notice } else { nil } }

    /// Whether a conditional terminal stop terminated the session (see
    /// `SpacesDeviceMutationResult.terminatedTerminalSession`).
    public var terminatedTerminalSession: Bool? { if case .mutation(let payload) = result { payload.terminatedTerminalSession } else { nil } }

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

    public var terminalSelectionText: String? { if case .terminalSelectionText(let payload) = result { payload.text } else { nil } }

    public var terminalTranscript: SpacesDeviceTerminalTranscriptResult? {
        if case .terminalTranscript(let payload) = result { payload } else { nil }
    }

    public var agentHooksStatus: SpacesAgentHooksStatusPayload? { if case .agentHooksStatus(let payload) = result { payload } else { nil } }

    public var agentHooksInstall: AgentHookInstallOutcome? { if case .agentHooksInstall(let payload) = result { payload } else { nil } }

    public var agentSessions: [SpacesDeviceAgentSessionRow]? { if case .agentSessions(let payload) = result { payload.rows } else { nil } }

    public var automations: [TerminalServiceAutomationSummary]? { if case .automations(let payload) = result { payload.rows } else { nil } }

    public var automationRuns: [TerminalServiceAutomationRunSummary]? { if case .automationRuns(let payload) = result { payload.rows } else { nil } }
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
