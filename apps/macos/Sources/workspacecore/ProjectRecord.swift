import Foundation

public struct ProjectRecord: Codable, Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    /// Daemon-owned visibility flag, independent of `WorkspaceRecord.isHidden`. Not part of the
    /// project's configuration surface, so it is a `let` that only `updateProjectHidden` moves and
    /// the `spaces.yaml` import/export never carries.
    public let isHidden: Bool
    public var setupScript: String?
    public var stopScript: String?
    public var ports: [ServiceDefinition]
    public var processes: [ProcessTemplate]
    public var browserSessions: [BrowserSession]

    public init(
        id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, isHidden: Bool = false, setupScript: String? = nil,
        stopScript: String? = nil, ports: [ServiceDefinition] = [], processes: [ProcessTemplate] = [], browserSessions: [BrowserSession] = []
    ) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.isHidden = isHidden
        self.setupScript = setupScript
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
    }
}
