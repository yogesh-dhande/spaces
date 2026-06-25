import Foundation

public struct ProjectRecord: Codable, Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public var setupScript: String?
    public var stopScript: String?
    public var ports: [PortDefinition]
    public var processes: [ProcessTemplate]
    public var browserSessions: [BrowserSession]
    public var agentLaunchers: [AgentLauncher]

    public init(
        id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, setupScript: String? = nil, stopScript: String? = nil,
        ports: [PortDefinition] = [], processes: [ProcessTemplate] = [], browserSessions: [BrowserSession] = [], agentLaunchers: [AgentLauncher] = []
    ) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.setupScript = setupScript
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
        self.agentLaunchers = agentLaunchers
    }
}
