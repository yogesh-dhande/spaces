import Foundation

public struct RunningProcessRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let templateName: String
    public let command: String
    public let terminalApp: String?
    public let windowID: Int?
    public let itermSessionID: String?
    public let itermTabIndex: Int?
    public let pid: Int?
    public let status: RunningProcessState
    public let logPath: String?
    public let lastOutputAt: String?
    public let startedAt: String?
    public let exitedAt: String?

    public init(
        id: String, workspaceID: String, templateName: String, command: String, terminalApp: String?, windowID: Int?, itermSessionID: String? = nil,
        itermTabIndex: Int? = nil, pid: Int?, status: RunningProcessState, logPath: String?, lastOutputAt: String?, startedAt: String?,
        exitedAt: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.templateName = templateName
        self.command = command
        self.terminalApp = terminalApp
        self.windowID = windowID
        self.itermSessionID = itermSessionID
        self.itermTabIndex = itermTabIndex
        self.pid = pid
        self.status = status
        self.logPath = logPath
        self.lastOutputAt = lastOutputAt
        self.startedAt = startedAt
        self.exitedAt = exitedAt
    }
}
