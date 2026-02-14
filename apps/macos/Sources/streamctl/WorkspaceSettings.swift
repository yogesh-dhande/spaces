import Foundation

public struct WorkspaceSettings: Sendable {
    public var stopScript: String?
    public var processes: [ProcessTemplate]
    public var statusChecks: [StatusCheckDefinition]
    public var browserSessions: [BrowserSession]

    public init(
        stopScript: String? = nil, processes: [ProcessTemplate] = [], statusChecks: [StatusCheckDefinition] = [],
        browserSessions: [BrowserSession] = []
    ) {
        self.stopScript = stopScript
        self.processes = processes
        self.statusChecks = statusChecks
        self.browserSessions = browserSessions
    }
}
