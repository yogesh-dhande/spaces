import Foundation

public struct RunningProcessRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let templateName: String
    public let command: String
    public let terminalApp: String?
    public let windowID: Int?
    public let terminalTrackingID: String?
    public let terminalNativeID: String?
    public let itermTabIndex: Int?
    public let tmuxWindowID: String?
    public let pid: Int?
    public let status: RunningProcessState
    public let logPath: String?
    public let lastOutputAt: String?
    public let startedAt: String?
    public let exitedAt: String?

    public init(
        id: String, workspaceID: String, templateName: String, command: String, terminalApp: String?, windowID: Int?, terminalTrackingID: String? = nil,
        terminalNativeID: String? = nil, itermTabIndex: Int? = nil, tmuxWindowID: String? = nil, pid: Int?, status: RunningProcessState,
        logPath: String?, lastOutputAt: String?, startedAt: String?, exitedAt: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.templateName = templateName
        self.command = command
        self.terminalApp = terminalApp
        self.windowID = windowID
        self.terminalTrackingID = terminalTrackingID
        self.terminalNativeID = terminalNativeID
        self.itermTabIndex = itermTabIndex
        self.tmuxWindowID = tmuxWindowID
        self.pid = pid
        self.status = status
        self.logPath = logPath
        self.lastOutputAt = lastOutputAt
        self.startedAt = startedAt
        self.exitedAt = exitedAt
    }
}
