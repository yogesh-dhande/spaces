import Foundation

public enum TerminalServicePaths {
    public static func socketPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try socketRootDirectory(fileManager: fileManager)
        let socketName = "service-\(socketPathComponent(for: root.path))"
        return socketRoot.appendingPathComponent("\(socketName).sock", isDirectory: false).path
    }

    public static func instanceLockPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try socketRootDirectory(fileManager: fileManager)
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

    private static func socketRootDirectory(fileManager: FileManager) throws -> URL {
        let socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("spaces-terminal-sockets", isDirectory: true)
        try fileManager.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        return socketRoot
    }

    private static func socketPathComponent(for rootPath: String) -> String {
        var hash: UInt64 = 5381
        for byte in rootPath.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return String(format: "%016llx", hash)
    }
}
