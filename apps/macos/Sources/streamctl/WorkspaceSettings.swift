import Foundation

public struct WorkspaceSettings: Sendable {
    public var stopScript: String?
    public var ports: [PortDefinition]
    public var processes: [ProcessTemplate]
    public var statusChecks: [StatusCheckDefinition]
    public var browserSessions: [BrowserSession]
    public var agentLaunchers: [AgentLauncher]

    public init(
        stopScript: String? = nil, ports: [PortDefinition] = [], processes: [ProcessTemplate] = [], statusChecks: [StatusCheckDefinition] = [],
        browserSessions: [BrowserSession] = [], agentLaunchers: [AgentLauncher] = []
    ) {
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.statusChecks = statusChecks
        self.browserSessions = browserSessions
        self.agentLaunchers = agentLaunchers
    }
}
