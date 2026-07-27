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

    /// Paths for a session this profile owns, with the root derived under the profile's runtime
    /// directory. This is how a session is addressed when it is created and whenever it is reached by
    /// id alone; a session discovered from its persisted row is addressed through `forStoredSession`
    /// instead, so a row whose root the current profile no longer derives stays reachable.
    public static func forSession(id: String) throws -> TerminalSessionPaths {
        try validateSessionID(id)
        let root = try profileSessionRootDirectory(id: id)
        return try paths(id: id, rootDirectory: root)
    }

    /// Paths for a session whose root directory is read from its persisted `terminal_sessions` row.
    ///
    /// Socket paths are still this profile's: control and subscription sockets live in the profile's
    /// secure socket root, are named from the profile root and session id, and are recreated on every
    /// run, so there is nothing about them to read from the row. The session id is not validated here
    /// because it is never joined into a path — the root comes from the row — so one unparseable id
    /// cannot fail a whole sweep.
    public static func forStoredSession(id: String, rootDirectory: String) throws -> TerminalSessionPaths {
        try paths(id: id, rootDirectory: rootDirectory)
    }

    /// Whether `rootDirectory` is a session directory this profile owns, i.e. a direct child of the
    /// profile's terminal-sessions root. Sessions are discovered from the root their row stores, and a
    /// row can name a path this profile does not own (a runtime directory that moved, or rows a
    /// predecessor daemon left behind), so this is what keeps directory deletion inside the profile.
    public static func isProfileOwnedSessionRoot(_ rootDirectory: String) throws -> Bool {
        let standardized = URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL
        guard !standardized.lastPathComponent.isEmpty, standardized.lastPathComponent != "/" else { return false }
        return standardized.deletingLastPathComponent().standardizedFileURL.path == (try profileSessionsRootDirectory())
    }

    public static func sessionsRootDirectory(fileManager: FileManager = .default) throws -> String {
        let root = try profileSessionsRootDirectory(fileManager: fileManager)
        try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    /// The profile's terminal-sessions root, without creating it. `sessionsRootDirectory` is the
    /// creating variant; containment checks must not create directories as a side effect.
    private static func profileSessionsRootDirectory(fileManager: FileManager = .default) throws -> String {
        try spacesRuntimeDirectory(fileManager: fileManager).appendingPathComponent("terminal", isDirectory: true).appendingPathComponent(
            "sessions", isDirectory: true
        ).path
    }

    private static func profileSessionRootDirectory(id: String, fileManager: FileManager = .default) throws -> String {
        URL(fileURLWithPath: try profileSessionsRootDirectory(fileManager: fileManager), isDirectory: true).appendingPathComponent(
            id, isDirectory: true
        ).path
    }

    private static func paths(id: String, rootDirectory: String) throws -> TerminalSessionPaths {
        let profileRootDirectory = try spacesProfileRootDirectory()
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let socketNamePrefix = socketPathComponent(for: profileRootDirectory.path, sessionID: id)
        return TerminalSessionPaths(
            rootDirectory: rootDirectory, controlSocketPath: socketRoot.appendingPathComponent("\(socketNamePrefix).sock").path,
            subscriptionSocketPath: socketRoot.appendingPathComponent("\(socketNamePrefix)-subscription.sock").path)
    }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
    }

    private static func spacesRuntimeDirectory(fileManager: FileManager = .default) throws -> URL {
        URL(fileURLWithPath: try SpacesProfile.current().runtimeDirectory, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func spacesProfileRootDirectory(fileManager: FileManager = .default) throws -> URL {
        URL(fileURLWithPath: try SpacesProfile.current().rootDirectory, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
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
