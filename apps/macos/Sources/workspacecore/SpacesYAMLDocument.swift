import Foundation
import Yams

public struct SpacesYAMLDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var setupScript: String?
    public var stopScript: String?
    public var ports: [Port]
    public var processes: [Process]
    public var browserSessions: [BrowserSessionConfig]
    public var agentLaunchers: [AgentLauncherConfig]

    public init(
        version: Int = Self.currentVersion, setupScript: String? = nil, stopScript: String? = nil, ports: [Port] = [], processes: [Process] = [],
        browserSessions: [BrowserSessionConfig] = [], agentLaunchers: [AgentLauncherConfig] = []
    ) {
        self.version = version
        self.setupScript = Self.normalizedOptionalString(setupScript)
        self.stopScript = Self.normalizedOptionalString(stopScript)
        self.ports = ports
        self.processes = processes
        self.browserSessions = browserSessions
        self.agentLaunchers = agentLaunchers
    }

    public init(project: ProjectRecord) {
        self.init(
            setupScript: project.setupScript, stopScript: project.stopScript, ports: project.ports.map(Port.init),
            processes: project.processes.map(Process.init), browserSessions: project.browserSessions.map(BrowserSessionConfig.init),
            agentLaunchers: project.agentLaunchers.map(AgentLauncherConfig.init))
    }

    public var portDefinitions: [PortDefinition] { ports.map(\.portDefinition) }
    public var processTemplates: [ProcessTemplate] { processes.map(\.processTemplate) }
    public var configuredBrowserSessions: [BrowserSession] { browserSessions.map(\.browserSession) }
    public var configuredAgentLaunchers: [AgentLauncher] { agentLaunchers.map(\.agentLauncher) }

    public func applying(to project: inout ProjectRecord) {
        project.setupScript = setupScript
        project.stopScript = stopScript
        project.ports = portDefinitions
        project.processes = processTemplates
        project.browserSessions = configuredBrowserSessions
        project.agentLaunchers = configuredAgentLaunchers
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case setupScript = "setup_script"
        case stopScript = "stop_script"
        case ports
        case processes
        case browserSessions = "browser_sessions"
        case agentLaunchers = "agent_launchers"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        guard decodedVersion <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "Unsupported spaces.yaml version \(decodedVersion). Current version is \(Self.currentVersion).")
        }
        version = decodedVersion
        setupScript = Self.normalizedOptionalString(try container.decodeIfPresent(String.self, forKey: .setupScript))
        stopScript = Self.normalizedOptionalString(try container.decodeIfPresent(String.self, forKey: .stopScript))
        ports = try container.decodeIfPresent([Port].self, forKey: .ports) ?? []
        processes = try container.decodeIfPresent([Process].self, forKey: .processes) ?? []
        browserSessions = try container.decodeIfPresent([BrowserSessionConfig].self, forKey: .browserSessions) ?? []
        agentLaunchers = try container.decodeIfPresent([AgentLauncherConfig].self, forKey: .agentLaunchers) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(setupScript ?? "", forKey: .setupScript)
        try container.encode(stopScript ?? "", forKey: .stopScript)
        try container.encode(ports, forKey: .ports)
        try container.encode(processes, forKey: .processes)
        try container.encode(browserSessions, forKey: .browserSessions)
        try container.encode(agentLaunchers, forKey: .agentLaunchers)
    }

    fileprivate static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}

extension SpacesYAMLDocument {
    public struct Port: Codable, Equatable, Sendable {
        public var name: String

        public init(name: String) { self.name = name }

        public init(_ definition: PortDefinition) { self.init(name: definition.name) }

        public var portDefinition: PortDefinition { PortDefinition(name: name) }
    }

    public struct Process: Codable, Equatable, Sendable {
        public var name: String?
        public var command: String
        public var onExit: ProcessExitAction
        public var executionMode: ProcessExecutionMode

        public init(name: String? = nil, command: String, onExit: ProcessExitAction = .none, executionMode: ProcessExecutionMode = .direct) {
            self.name = SpacesYAMLDocument.normalizedOptionalString(name)
            self.command = command
            self.onExit = onExit
            self.executionMode = executionMode
        }

        public init(_ template: ProcessTemplate) {
            self.init(name: template.name, command: template.command, onExit: template.onExit, executionMode: template.executionMode)
        }

        public var processTemplate: ProcessTemplate { ProcessTemplate(name: name, command: command, onExit: onExit, executionMode: executionMode) }

        private enum CodingKeys: String, CodingKey {
            case name
            case command
            case onExit = "on_exit"
            case executionMode = "execution_mode"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = SpacesYAMLDocument.normalizedOptionalString(try container.decodeIfPresent(String.self, forKey: .name))
            command = try container.decode(String.self, forKey: .command)
            onExit = try container.decodeIfPresent(ProcessExitAction.self, forKey: .onExit) ?? .none
            executionMode = try container.decodeIfPresent(ProcessExecutionMode.self, forKey: .executionMode) ?? .direct
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(command, forKey: .command)
            try container.encode(onExit, forKey: .onExit)
            try container.encode(executionMode, forKey: .executionMode)
        }
    }

    public struct BrowserSessionConfig: Codable, Equatable, Sendable {
        public var name: String?
        public var url: String?

        public init(name: String? = nil, url: String? = nil) {
            self.name = SpacesYAMLDocument.normalizedOptionalString(name)
            self.url = SpacesYAMLDocument.normalizedOptionalString(url)
        }

        public init(_ session: BrowserSession) { self.init(name: session.name, url: session.url) }

        public var browserSession: BrowserSession { BrowserSession(name: name, url: url) }
    }

    public struct AgentLauncherConfig: Codable, Equatable, Sendable {
        public var name: String
        public var command: String

        public init(name: String, command: String) {
            self.name = name
            self.command = command
        }

        public init(_ launcher: AgentLauncher) { self.init(name: launcher.name, command: launcher.command) }

        public var agentLauncher: AgentLauncher { AgentLauncher(name: name, command: command) }
    }
}

public enum SpacesYAMLService {
    public static let fileName = "spaces.yaml"

    public static func decode(_ yaml: String) throws -> SpacesYAMLDocument {
        do { return try YAMLDecoder().decode(SpacesYAMLDocument.self, from: yaml) } catch let error as DecodingError {
            throw WorkspaceError.invalidArgument(message: "Invalid spaces.yaml: \(decodingMessage(for: error))")
        } catch { throw WorkspaceError.invalidArgument(message: "Invalid spaces.yaml: \(error.localizedDescription)") }
    }

    public static func load(from url: URL) throws -> SpacesYAMLDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceError.invalidArgument(message: "spaces.yaml not found: \(url.path)")
        }
        return try decode(String(contentsOf: url, encoding: .utf8))
    }

    public static func encode(_ document: SpacesYAMLDocument) throws -> String {
        var encoded = try YAMLEncoder().encode(document)
        if !encoded.hasSuffix("\n") { encoded.append("\n") }
        return encoded
    }

    public static func write(_ document: SpacesYAMLDocument, to url: URL) throws {
        let yaml = try encode(document)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func decodingMessage(for error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            return context.debugDescription
        @unknown default: return error.localizedDescription
        }
    }
}
