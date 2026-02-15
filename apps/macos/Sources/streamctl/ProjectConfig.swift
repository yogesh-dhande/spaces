import Foundation

public struct ProjectConfig: Codable, Sendable {
    public var dir: String
    public var setupScript: String?
    public var stopScript: String?
    public var ports: [PortDefinition]
    public var processes: [ProcessTemplate]
    public var statusChecks: [StatusCheckDefinition]
    public var browserSessions: [BrowserSession]

    public init(
        dir: String, setupScript: String? = nil, stopScript: String? = nil, ports: [PortDefinition] = [],
        processes: [ProcessTemplate] = [], statusChecks: [StatusCheckDefinition] = [], browserSessions: [BrowserSession] = []
    ) {
        self.dir = dir
        self.setupScript = setupScript
        self.stopScript = stopScript
        self.ports = ports
        self.processes = processes
        self.statusChecks = statusChecks
        self.browserSessions = browserSessions
    }

    private enum CodingKeys: String, CodingKey {
        case dir
        case setupScript = "setup_script"
        case stopScript = "stop_script"
        case ports
        case processes
        case statusChecks = "status_checks"
        case browserSessions = "browser_sessions"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dir = try container.decode(String.self, forKey: .dir)
        setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript)
        stopScript = try container.decodeIfPresent(String.self, forKey: .stopScript)
        ports = try container.decodeIfPresent([PortDefinition].self, forKey: .ports) ?? []
        processes = try container.decodeIfPresent([ProcessTemplate].self, forKey: .processes) ?? []
        statusChecks = try container.decodeIfPresent([StatusCheckDefinition].self, forKey: .statusChecks) ?? []
        browserSessions = try container.decodeIfPresent([BrowserSession].self, forKey: .browserSessions) ?? []
    }
}
