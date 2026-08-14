import Foundation

public struct WorkspaceSettings: Sendable {
    public var stopScript: String?
    public var ports: [ServiceDefinition]
    public var processes: [ProcessTemplate]
    public var browserSessions: [BrowserSession]

    public init(stopScript: String? = nil, ports: [ServiceDefinition] = [], processes: [ProcessTemplate] = [], browserSessions: [BrowserSession] = [])
    {
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
    }
}
