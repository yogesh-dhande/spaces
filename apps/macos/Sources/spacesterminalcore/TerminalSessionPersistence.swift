import Foundation

public struct TerminalSessionLaunchConfiguration: Codable, Sendable, Equatable {
    public let sessionID: String
    public let backend: TerminalSessionBackendKind
    public let title: String
    public let workingDirectory: String
    public let shell: String
    public let command: String?
    public let createdAt: String

    public init(
        sessionID: String, backend: TerminalSessionBackendKind = .scriptPTY, title: String, workingDirectory: String, shell: String, command: String?,
        createdAt: String
    ) {
        self.sessionID = sessionID
        self.backend = backend
        self.title = title
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.command = command
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID
        case backend
        case title
        case workingDirectory
        case shell
        case command
        case createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        backend = try container.decodeIfPresent(TerminalSessionBackendKind.self, forKey: .backend) ?? .scriptPTY
        title = try container.decode(String.self, forKey: .title)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        shell = try container.decode(String.self, forKey: .shell)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }
}

public struct TerminalSessionRuntimeState: Codable, Sendable, Equatable {
    public let sessionID: String
    public let backend: TerminalSessionBackendKind
    public let servicePID: Int32
    public let childPID: Int32?
    public let state: TerminalSessionState
    public let updatedAt: String
    public let exitedAt: String?

    public init(
        sessionID: String, backend: TerminalSessionBackendKind = .scriptPTY, servicePID: Int32, childPID: Int32?, state: TerminalSessionState,
        updatedAt: String, exitedAt: String? = nil
    ) {
        self.sessionID = sessionID
        self.backend = backend
        self.servicePID = servicePID
        self.childPID = childPID
        self.state = state
        self.updatedAt = updatedAt
        self.exitedAt = exitedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID
        case backend
        case servicePID
        case childPID
        case state
        case updatedAt
        case exitedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        backend = try container.decodeIfPresent(TerminalSessionBackendKind.self, forKey: .backend) ?? .scriptPTY
        servicePID = try container.decode(Int32.self, forKey: .servicePID)
        childPID = try container.decodeIfPresent(Int32.self, forKey: .childPID)
        state = try container.decode(TerminalSessionState.self, forKey: .state)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        exitedAt = try container.decodeIfPresent(String.self, forKey: .exitedAt)
    }
}

public struct TerminalSessionAttachmentSnapshot: Codable, Sendable, Equatable {
    public var clients: [TerminalClient]
    public var attachments: [TerminalAttachment]

    public init(clients: [TerminalClient] = [], attachments: [TerminalAttachment] = []) {
        self.clients = clients
        self.attachments = attachments
    }
}

public enum TerminalSessionPersistence {
    public static func writeLaunchConfiguration(_ configuration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        try writeJSON(configuration, to: paths.metadataPath)
    }

    public static func writeRuntimeState(_ state: TerminalSessionRuntimeState, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        try writeJSON(state, to: paths.statePath)
    }

    public static func readLaunchConfiguration(paths: TerminalSessionPaths) throws -> TerminalSessionLaunchConfiguration {
        try readJSON(TerminalSessionLaunchConfiguration.self, from: paths.metadataPath)
    }

    public static func readRuntimeState(paths: TerminalSessionPaths) throws -> TerminalSessionRuntimeState {
        try readJSON(TerminalSessionRuntimeState.self, from: paths.statePath)
    }

    public static func readAttachmentSnapshot(paths: TerminalSessionPaths) throws -> TerminalSessionAttachmentSnapshot {
        let clients = try readJSONIfExists([TerminalClient].self, from: paths.clientsPath) ?? []
        let attachments = try readJSONIfExists([TerminalAttachment].self, from: paths.attachmentsPath) ?? []
        return TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments)
    }

    public static func upsertClient(_ client: TerminalClient, paths: TerminalSessionPaths) throws {
        var snapshot = try readAttachmentSnapshot(paths: paths)
        if let existingIndex = snapshot.clients.firstIndex(where: { $0.id == client.id }) {
            snapshot.clients[existingIndex] = client
        } else {
            snapshot.clients.append(client)
        }
        try writeAttachmentSnapshot(snapshot, paths: paths)
    }

    public static func attachClient(
        sessionID: String, client: TerminalClient, mode: TerminalAttachmentMode, paths: TerminalSessionPaths, attachedAt: String
    ) throws {
        var snapshot = try readAttachmentSnapshot(paths: paths)

        if let existingIndex = snapshot.clients.firstIndex(where: { $0.id == client.id }) {
            snapshot.clients[existingIndex] = client
        } else {
            snapshot.clients.append(client)
        }

        if mode == .owner {
            for index in snapshot.attachments.indices
            where snapshot.attachments[index].mode == .owner && snapshot.attachments[index].detachedAt == nil {
                snapshot.attachments[index] = TerminalAttachment(
                    id: snapshot.attachments[index].id, sessionID: snapshot.attachments[index].sessionID,
                    clientID: snapshot.attachments[index].clientID, mode: snapshot.attachments[index].mode,
                    attachedAt: snapshot.attachments[index].attachedAt, detachedAt: attachedAt)
            }
        }

        if let existingIndex = snapshot.attachments.firstIndex(where: { $0.clientID == client.id && $0.detachedAt == nil }) {
            snapshot.attachments[existingIndex] = TerminalAttachment(
                id: snapshot.attachments[existingIndex].id, sessionID: sessionID, clientID: snapshot.attachments[existingIndex].clientID, mode: mode,
                attachedAt: snapshot.attachments[existingIndex].attachedAt)
        } else {
            snapshot.attachments.append(TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: mode, attachedAt: attachedAt))
        }

        try writeAttachmentSnapshot(snapshot, paths: paths)
    }

    public static func detachClient(id clientID: String, paths: TerminalSessionPaths, detachedAt: String) throws {
        var snapshot = try readAttachmentSnapshot(paths: paths)
        if let clientIndex = snapshot.clients.firstIndex(where: { $0.id == clientID }) {
            let client = snapshot.clients[clientIndex]
            snapshot.clients[clientIndex] = TerminalClient(
                id: client.id, kind: client.kind, identity: client.identity, connectedAt: client.connectedAt, disconnectedAt: detachedAt)
        }

        for index in snapshot.attachments.indices
        where snapshot.attachments[index].clientID == clientID && snapshot.attachments[index].detachedAt == nil {
            let attachment = snapshot.attachments[index]
            snapshot.attachments[index] = TerminalAttachment(
                id: attachment.id, sessionID: attachment.sessionID, clientID: attachment.clientID, mode: attachment.mode,
                attachedAt: attachment.attachedAt, detachedAt: detachedAt)
        }

        try writeAttachmentSnapshot(snapshot, paths: paths)
    }

    public static func activeAttachments(paths: TerminalSessionPaths) throws -> [TerminalAttachment] {
        try readAttachmentSnapshot(paths: paths).attachments.filter { $0.detachedAt == nil }
    }

    public static func transferOwnership(sessionID: String, newOwnerClientID: String, paths: TerminalSessionPaths, transferredAt: String) throws {
        var snapshot = try readAttachmentSnapshot(paths: paths)
        guard snapshot.clients.contains(where: { $0.id == newOwnerClientID }) else {
            throw TerminalSessionPersistenceError.unknownClient(newOwnerClientID)
        }

        for index in snapshot.attachments.indices where snapshot.attachments[index].mode == .owner && snapshot.attachments[index].detachedAt == nil {
            let attachment = snapshot.attachments[index]
            snapshot.attachments[index] = TerminalAttachment(
                id: attachment.id, sessionID: attachment.sessionID, clientID: attachment.clientID, mode: .viewer, attachedAt: attachment.attachedAt)
        }

        if let existingIndex = snapshot.attachments.firstIndex(where: { $0.clientID == newOwnerClientID && $0.detachedAt == nil }) {
            let existing = snapshot.attachments[existingIndex]
            snapshot.attachments[existingIndex] = TerminalAttachment(
                id: existing.id, sessionID: sessionID, clientID: existing.clientID, mode: .owner, attachedAt: existing.attachedAt)
        } else {
            snapshot.attachments.append(TerminalAttachment(sessionID: sessionID, clientID: newOwnerClientID, mode: .owner, attachedAt: transferredAt))
        }

        try writeAttachmentSnapshot(snapshot, paths: paths)
    }

    public static func listKnownSessions(fileManager: FileManager = .default) throws -> [TerminalSessionLaunchConfiguration] {
        let rootURL = URL(fileURLWithPath: try TerminalSessionPaths.sessionsRootDirectory(fileManager: fileManager), isDirectory: true)
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let childURLs = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try childURLs.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            let paths = TerminalSessionPaths(rootDirectory: url.path)
            return try? readLaunchConfiguration(paths: paths)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private static func readJSON<Value: Decodable>(_ type: Value.Type, from path: String) throws -> Value {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(type, from: data)
    }

    private static func readJSONIfExists<Value: Decodable>(_ type: Value.Type, from path: String) throws -> Value? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try readJSON(type, from: path)
    }

    private static func writeAttachmentSnapshot(_ snapshot: TerminalSessionAttachmentSnapshot, paths: TerminalSessionPaths) throws {
        try paths.ensureDirectories()
        try writeJSON(snapshot.clients, to: paths.clientsPath)
        try writeJSON(snapshot.attachments, to: paths.attachmentsPath)
    }
}

public enum TerminalSessionPersistenceError: LocalizedError {
    case unknownClient(String)

    public var errorDescription: String? {
        switch self {
        case .unknownClient(let clientID): "Unknown terminal client '\(clientID)'."
        }
    }
}
