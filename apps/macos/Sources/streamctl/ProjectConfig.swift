import Foundation

public struct ProjectConfig: Codable, Sendable {
    public var dir: String
    public var setupScript: String?
    public var cleanupScript: String?
    public var processes: [ProcessTemplate]
    public var statusChecks: [StatusCheckDefinition]
    public var browserSessions: [BrowserSession]

    public init(
        dir: String,
        setupScript: String? = nil,
        cleanupScript: String? = nil,
        processes: [ProcessTemplate] = [],
        statusChecks: [StatusCheckDefinition] = [],
        browserSessions: [BrowserSession] = []
    ) {
        self.dir = dir
        self.setupScript = setupScript
        self.cleanupScript = cleanupScript
        self.processes = processes
        self.statusChecks = statusChecks
        self.browserSessions = browserSessions
    }

    private enum CodingKeys: String, CodingKey {
        case dir
        case setupScript = "setup_script"
        case cleanupScript = "cleanup_script"
        case processes
        case statusChecks = "status_checks"
        case browserSessions = "browser_sessions"
    }
}
