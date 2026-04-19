import Foundation

public struct WorkspaceSettings: Sendable {
    public var stopScript: String?
    public var ports: [PortDefinition]
    public var processes: [ProcessTemplate]
    public var terminalWindows: [TerminalWindowTemplate]
    public var statusChecks: [StatusCheckDefinition]
    public var browserSessions: [BrowserSession]

    public init(
        stopScript: String? = nil, ports: [PortDefinition] = [], processes: [ProcessTemplate] = [],
        terminalWindows: [TerminalWindowTemplate] = [], statusChecks: [StatusCheckDefinition] = [],
        browserSessions: [BrowserSession] = []
    ) {
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.terminalWindows = terminalWindows
        self.statusChecks = statusChecks
        self.browserSessions = browserSessions
    }
}
