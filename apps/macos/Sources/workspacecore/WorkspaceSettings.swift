import Foundation

public struct WorkspaceSettings: Sendable {
    public var stopScript: String?
    public var ports: [PortDefinition]
    public var processes: [ProcessTemplate]
    public var browserSessions: [BrowserSession]
    public var agentLaunchers: [AgentLauncher]

    public init(
        stopScript: String? = nil, ports: [PortDefinition] = [], processes: [ProcessTemplate] = [], browserSessions: [BrowserSession] = [],
        agentLaunchers: [AgentLauncher] = []
    ) {
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
        self.agentLaunchers = agentLaunchers
    }
}
