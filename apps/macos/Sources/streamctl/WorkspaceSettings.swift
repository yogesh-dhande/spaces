import Foundation

public struct WorkspaceSettings: Sendable {
    public var processes: [ProcessTemplate]
    public var statusChecks: [StatusCheckDefinition]
    public var browserSessions: [BrowserSession]

    public init(
        processes: [ProcessTemplate] = [],
        statusChecks: [StatusCheckDefinition] = [],
        browserSessions: [BrowserSession] = []
    ) {
        self.processes = processes
        self.statusChecks = statusChecks
        self.browserSessions = browserSessions
    }
}
