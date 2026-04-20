import Foundation

public struct ProjectRecord: Codable, Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public var isCollapsed: Bool
    public var setupScript: String?
    public var stopScript: String?
    public var ports: [PortDefinition]
    public var processes: [ProcessTemplate]
    public var statusChecks: [StatusCheckDefinition]
    public var browserSessions: [BrowserSession]

    public init(
        id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, isCollapsed: Bool = false, setupScript: String? = nil,
        stopScript: String? = nil,
        ports: [PortDefinition] = [], processes: [ProcessTemplate] = [], statusChecks: [StatusCheckDefinition] = [],
        browserSessions: [BrowserSession] = []
    ) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.isCollapsed = isCollapsed
        self.setupScript = setupScript
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.statusChecks = statusChecks
        self.browserSessions = browserSessions
    }
}
