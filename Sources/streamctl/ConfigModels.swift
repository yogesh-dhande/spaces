import Foundation

public enum EditorPreference: String, Codable, Sendable, CaseIterable {
    case none = "none"
    case vscode = "vscode"
    case cursor = "cursor"
    case windsurf = "windsurf"
    case vim = "vim"
}

public struct PortRange: Codable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct AppConfig: Codable, Sendable {
    public var editor: EditorPreference?
    public var portRange: PortRange
    public var projects: [ProjectConfig]

    public init(editor: EditorPreference? = nil, portRange: PortRange, projects: [ProjectConfig]) {
        self.editor = editor
        self.portRange = portRange
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey {
        case editor
        case portRange = "port_range"
        case projects
    }
}

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

public struct ProcessTemplate: Codable, Sendable {
    public var name: String?
    public var command: String
    public var kind: String?

    public init(name: String? = nil, command: String, kind: String? = nil) {
        self.name = name
        self.command = command
        self.kind = kind
    }
}

public enum StatusCheckOnExit: String, Codable, Sendable, CaseIterable {
    case none = "none"
    case restart = "restart"
    case notify = "notify"
}

public struct StatusCheckDefinition: Codable, Sendable {
    public var name: String?
    public var process: String
    public var command: String
    public var interval: Int
    public var timeout: Int
    public var onExit: StatusCheckOnExit

    public init(
        name: String? = nil,
        process: String,
        command: String,
        interval: Int,
        timeout: Int,
        onExit: StatusCheckOnExit = .none
    ) {
        self.name = name
        self.process = process
        self.command = command
        self.interval = interval
        self.timeout = timeout
        self.onExit = onExit
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case process
        case command
        case interval
        case timeout
        case onExit = "on_exit"
    }
}

public struct BrowserSession: Codable, Sendable {
    public var url: String?

    public init(url: String? = nil) {
        self.url = url
    }
}
