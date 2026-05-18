import Foundation

public struct TerminalSessionPaths: Sendable, Equatable {
    public let rootDirectory: String
    public let metadataPath: String
    public let statePath: String
    public let outputPath: String
    public let windowStatePath: String
    public let clientsPath: String
    public let attachmentsPath: String
    public let controlSocketPath: String
    public let subscriptionSocketPath: String
    public let serviceLogPath: String

    public init(rootDirectory: String) { self.init(rootDirectory: rootDirectory, controlSocketPath: nil, subscriptionSocketPath: nil) }

    public init(rootDirectory: String, controlSocketPath: String?) {
        self.init(rootDirectory: rootDirectory, controlSocketPath: controlSocketPath, subscriptionSocketPath: nil)
    }

    public init(rootDirectory: String, controlSocketPath: String?, subscriptionSocketPath: String?) {
        self.rootDirectory = rootDirectory
        metadataPath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("metadata.json").path
        statePath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("state.json").path
        outputPath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("output.log").path
        windowStatePath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("window-state.json").path
        clientsPath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("clients.json").path
        attachmentsPath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("attachments.json").path
        self.controlSocketPath = controlSocketPath ?? URL(fileURLWithPath: rootDirectory).appendingPathComponent("control.sock").path
        self.subscriptionSocketPath = subscriptionSocketPath ?? URL(fileURLWithPath: rootDirectory).appendingPathComponent("subscription.sock").path
        serviceLogPath = URL(fileURLWithPath: rootDirectory).appendingPathComponent("service.log").path
    }

    public static func forSession(id: String) throws -> TerminalSessionPaths {
        let spacesDirectory = try spacesHomeDirectory()
        let root = spacesDirectory.appendingPathComponent("terminal", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("spaces-terminal-sockets", isDirectory: true)
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        let socketNamePrefix = socketPathComponent(for: spacesDirectory.path, sessionID: id)
        let controlSocketPath = socketRoot.appendingPathComponent("\(socketNamePrefix).sock").path
        let subscriptionSocketPath = socketRoot.appendingPathComponent("\(socketNamePrefix)-subscription.sock").path
        return TerminalSessionPaths(rootDirectory: root.path, controlSocketPath: controlSocketPath, subscriptionSocketPath: subscriptionSocketPath)
    }

    public static func sessionsRootDirectory(fileManager: FileManager = .default) throws -> String {
        let spacesDirectory = try spacesHomeDirectory(fileManager: fileManager)
        let root = spacesDirectory.appendingPathComponent("terminal", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
    }

    private static func spacesHomeDirectory(fileManager: FileManager = .default) throws -> URL {
        let envVar = "SPACES_DB_PATH"
        if let overridePath = ProcessInfo.processInfo.environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines), !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath)
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return directoryURL
        }

        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".spaces", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func socketPathComponent(for spacesRoot: String, sessionID: String) -> String {
        var hash: UInt64 = 5381
        for byte in "\(spacesRoot)|\(sessionID)".utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return String(format: "%016llx", hash)
    }
}
