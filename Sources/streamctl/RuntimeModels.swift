import Foundation

public struct ProjectRecord: Codable, Sendable {
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

public struct WorkspaceRecord: Codable, Sendable {
    public let id: String
    public let projectID: String
    public let name: String
    public let dir: String
    public let dirname: String?
    public let branch: String?
    public let isDefault: Bool
    public let isArchived: Bool
    public let isRunning: Bool
    public let lastLaunchedAt: String?

    public init(
        id: String,
        projectID: String,
        name: String,
        dir: String,
        dirname: String?,
        branch: String?,
        isDefault: Bool,
        isArchived: Bool,
        isRunning: Bool,
        lastLaunchedAt: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.dir = dir
        self.dirname = dirname
        self.branch = branch
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.isRunning = isRunning
        self.lastLaunchedAt = lastLaunchedAt
    }
}

public struct WorkspaceSummary: Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isRunning: Bool
    public let isArchived: Bool
    public let isDefault: Bool

    public init(id: String, name: String, dir: String, isRunning: Bool, isArchived: Bool, isDefault: Bool) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isRunning = isRunning
        self.isArchived = isArchived
        self.isDefault = isDefault
    }
}

public struct ProjectSummary: Sendable {
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

public enum RunningProcessState: String, Codable, Sendable {
    case running
    case exited
    case idle
}

public struct RunningProcessRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let templateName: String
    public let command: String
    public let terminalApp: String?
    public let windowID: Int?
    public let pid: Int?
    public let status: RunningProcessState
    public let logPath: String?
    public let lastOutputAt: String?
    public let startedAt: String?
    public let exitedAt: String?

    public init(
        id: String,
        workspaceID: String,
        templateName: String,
        command: String,
        terminalApp: String?,
        windowID: Int?,
        pid: Int?,
        status: RunningProcessState,
        logPath: String?,
        lastOutputAt: String?,
        startedAt: String?,
        exitedAt: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.templateName = templateName
        self.command = command
        self.terminalApp = terminalApp
        self.windowID = windowID
        self.pid = pid
        self.status = status
        self.logPath = logPath
        self.lastOutputAt = lastOutputAt
        self.startedAt = startedAt
        self.exitedAt = exitedAt
    }
}

public struct StatusResult: Sendable {
    public let processID: String
    public let checkName: String
    public let status: String
    public let message: String?
    public let lastRunAt: String?

    public init(processID: String, checkName: String, status: String, message: String?, lastRunAt: String?) {
        self.processID = processID
        self.checkName = checkName
        self.status = status
        self.message = message
        self.lastRunAt = lastRunAt
    }
}

public struct WindowRecord: Sendable {
    public let id: String
    public let workspaceID: String
    public let app: String
    public let title: String?
    public let windowID: Int?
    public let role: String
    public let orderIndex: Int
    public let lastSeenAt: String

    public init(
        id: String,
        workspaceID: String,
        app: String,
        title: String?,
        windowID: Int?,
        role: String,
        orderIndex: Int,
        lastSeenAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.app = app
        self.title = title
        self.windowID = windowID
        self.role = role
        self.orderIndex = orderIndex
        self.lastSeenAt = lastSeenAt
    }
}

public struct SpaceOption: Sendable {
    public let displayIndex: Int
    public let spaceIndex: Int

    public init(displayIndex: Int, spaceIndex: Int) {
        self.displayIndex = displayIndex
        self.spaceIndex = spaceIndex
    }
}
