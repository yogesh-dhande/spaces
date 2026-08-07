import Foundation
import Yams

public struct SpacesYAMLDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var setupScript: String?
    public var stopScript: String?
    /// Service names declared by the project. Each is a DNS-1123 label and routes through Caddy.
    public var services: [String]
    public var processes: [Process]
    public var browserSessions: [BrowserSessionConfig]

    public init(
        version: Int = Self.currentVersion, setupScript: String? = nil, stopScript: String? = nil, services: [String] = [], processes: [Process] = [],
        browserSessions: [BrowserSessionConfig] = []
    ) {
        self.version = version
        self.setupScript = Self.normalizedOptionalString(setupScript)
        self.stopScript = Self.normalizedOptionalString(stopScript)
        self.services = services
        self.processes = processes
        self.browserSessions = browserSessions
    }

    public init(project: ProjectRecord) {
        self.init(
            setupScript: project.setupScript, stopScript: project.stopScript, services: project.ports.map(\.name),
            processes: project.processes.map(Process.init), browserSessions: project.browserSessions.map(BrowserSessionConfig.init))
    }

    public var serviceDefinitions: [ServiceDefinition] { services.map { ServiceDefinition(name: $0) } }
    public var processTemplates: [ProcessTemplate] { processes.map(\.processTemplate) }
    public var configuredBrowserSessions: [BrowserSession] { browserSessions.map(\.browserSession) }

    public func applying(to project: inout ProjectRecord) {
        project.setupScript = setupScript
        project.stopScript = stopScript
        project.ports = serviceDefinitions
        project.processes = processTemplates
        project.browserSessions = configuredBrowserSessions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case setupScript = "setup_script"
        case stopScript = "stop_script"
        case services
        case processes
        case browserSessions = "browser_sessions"
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
        services = try container.decodeIfPresent([String].self, forKey: .services) ?? []
        processes = try container.decodeIfPresent([Process].self, forKey: .processes) ?? []
        browserSessions = try container.decodeIfPresent([BrowserSessionConfig].self, forKey: .browserSessions) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(setupScript ?? "", forKey: .setupScript)
        try container.encode(stopScript ?? "", forKey: .stopScript)
        try container.encode(services, forKey: .services)
        try container.encode(processes, forKey: .processes)
        try container.encode(browserSessions, forKey: .browserSessions)
    }

    fileprivate static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}

extension SpacesYAMLDocument {
    public struct Process: Codable, Equatable, Sendable {
        public var name: String?
        public var command: String
        public var onExit: ProcessExitAction

        public init(name: String? = nil, command: String, onExit: ProcessExitAction = .none) {
            self.name = SpacesYAMLDocument.normalizedOptionalString(name)
            self.command = command
            self.onExit = onExit
        }

        public init(_ template: ProcessTemplate) { self.init(name: template.name, command: template.command, onExit: template.onExit) }

        public var processTemplate: ProcessTemplate { ProcessTemplate(name: name, command: command, onExit: onExit) }

        private enum CodingKeys: String, CodingKey {
            case name
            case command
            case onExit = "on_exit"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = SpacesYAMLDocument.normalizedOptionalString(try container.decodeIfPresent(String.self, forKey: .name))
            command = try container.decode(String.self, forKey: .command)
            onExit = try container.decodeIfPresent(ProcessExitAction.self, forKey: .onExit) ?? .none
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(command, forKey: .command)
            try container.encode(onExit, forKey: .onExit)
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
}

public enum SpacesYAMLService {
    public static let fileName = "spaces.yaml"

    public static func decode(_ yaml: String) throws -> SpacesYAMLDocument {
        let document: SpacesYAMLDocument
        do { document = try YAMLDecoder().decode(SpacesYAMLDocument.self, from: yaml) } catch let error as DecodingError {
            throw WorkspaceError.invalidArgument(message: "Invalid spaces.yaml: \(decodingMessage(for: error))")
        } catch { throw WorkspaceError.invalidArgument(message: "Invalid spaces.yaml: \(error.localizedDescription)") }
        // Service names become DNS hostnames, so validate them at the import boundary. Done here
        // rather than inside `init(from:)` so the precise message is not wrapped by the YAML decoder.
        for service in document.services { try ServiceName.validated(service) }
        return document
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
