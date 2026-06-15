import Foundation

public struct TerminalSessionPaths: Sendable, Equatable {
    public let rootDirectory: String
    public let outputPath: String
    public let controlSocketPath: String
    public let subscriptionSocketPath: String
    public let serviceLogPath: String

    public init(rootDirectory: String) { self.init(rootDirectory: rootDirectory, controlSocketPath: nil, subscriptionSocketPath: nil) }

    public init(rootDirectory: String, controlSocketPath: String?) {
        self.init(rootDirectory: rootDirectory, controlSocketPath: controlSocketPath, subscriptionSocketPath: nil)
    }

    public init(rootDirectory: String, controlSocketPath: String?, subscriptionSocketPath: String?) {
        self.rootDirectory = rootDirectory
        outputPath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("output.log").path
        self.controlSocketPath = controlSocketPath ?? URL(fileURLWithPath: rootDirectory).appendingPathComponent("control.sock").path
        self.subscriptionSocketPath = subscriptionSocketPath ?? URL(fileURLWithPath: rootDirectory).appendingPathComponent("subscription.sock").path
        serviceLogPath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("service.log").path
    }

    public static func forSession(id: String) throws -> TerminalSessionPaths {
        try validateSessionID(id)
        let runtimeDirectory = try spacesRuntimeDirectory()
        let profileRootDirectory = try spacesProfileRootDirectory()
        let root = runtimeDirectory.appendingPathComponent("terminal", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("spaces-terminal-sockets", isDirectory: true)
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        let socketNamePrefix = socketPathComponent(for: profileRootDirectory.path, sessionID: id)
        let controlSocketPath = socketRoot.appendingPathComponent("\(socketNamePrefix).sock").path
        let subscriptionSocketPath = socketRoot.appendingPathComponent("\(socketNamePrefix)-subscription.sock").path
        return TerminalSessionPaths(rootDirectory: root.path, controlSocketPath: controlSocketPath, subscriptionSocketPath: subscriptionSocketPath)
    }

    public static func sessionsRootDirectory(fileManager: FileManager = .default) throws -> String {
        let runtimeDirectory = try spacesRuntimeDirectory(fileManager: fileManager)
        let root = runtimeDirectory.appendingPathComponent("terminal", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
    }

    private static func spacesRuntimeDirectory(fileManager: FileManager = .default) throws -> URL {
        URL(fileURLWithPath: try SpacesProfile.current().runtimeDirectory, isDirectory: true)
    }

    private static func spacesProfileRootDirectory(fileManager: FileManager = .default) throws -> URL {
        URL(fileURLWithPath: try SpacesProfile.current().rootDirectory, isDirectory: true)
    }

    private static func socketPathComponent(for spacesRoot: String, sessionID: String) -> String {
        var hash: UInt64 = 5381
        for byte in "\(spacesRoot)|\(sessionID)".utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return String(format: "%016llx", hash)
    }

    private static func validateSessionID(_ id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == id, !id.isEmpty, id != ".", id != ".." else {
            throw NSError(domain: "TerminalSessionPaths", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid terminal session ID."])
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw NSError(domain: "TerminalSessionPaths", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid terminal session ID."])
        }
    }
}
