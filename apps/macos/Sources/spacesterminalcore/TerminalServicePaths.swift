import Foundation

public enum TerminalServicePaths {
    public static func socketPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let socketName = "service-\(socketPathComponent(for: root.path))"
        return socketRoot.appendingPathComponent("\(socketName).sock", isDirectory: false).path
    }

    /// Profile-scoped unix socket the daemon streams device-overview changes on.
    /// Subscribers (via the Device API relay) connect here to receive a fresh
    /// overview on connect and on every database change.
    public static func deviceOverviewSocketPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let name = "device-overview-\(socketPathComponent(for: root.path))"
        return socketRoot.appendingPathComponent("\(name).sock", isDirectory: false).path
    }

    /// Profile-scoped unix socket Linux database writers connect to after a
    /// committed write so the daemon can translate the wakeup into its in-process
    /// database-change notification.
    public static func databaseChangeSignalSocketPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let name = "database-change-\(socketPathComponent(for: root.path))"
        return socketRoot.appendingPathComponent("\(name).sock", isDirectory: false).path
    }

    public static func instanceLockPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let lockName = "daemon-\(socketPathComponent(for: root.path))"
        return socketRoot.appendingPathComponent("\(lockName).lock", isDirectory: false).path
    }

    public static func logPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        return root.appendingPathComponent("service.log", isDirectory: false).path
    }

    public static func terminalRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let sessionsRoot = URL(fileURLWithPath: try TerminalSessionPaths.sessionsRootDirectory(fileManager: fileManager), isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        return sessionsRoot.deletingLastPathComponent()
    }

    private static func socketPathComponent(for rootPath: String) -> String {
        var hash: UInt64 = 5381
        for byte in rootPath.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return String(format: "%016llx", hash)
    }
}
