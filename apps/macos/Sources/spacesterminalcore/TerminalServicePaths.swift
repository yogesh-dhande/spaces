import Foundation

public enum TerminalServicePaths {
    public static func socketPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        return root.appendingPathComponent("service.sock", isDirectory: false).path
    }

    public static func logPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        return root.appendingPathComponent("service.log", isDirectory: false).path
    }

    public static func terminalRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let sessionsRoot = URL(fileURLWithPath: try TerminalSessionPaths.sessionsRootDirectory(fileManager: fileManager), isDirectory: true)
        return sessionsRoot.deletingLastPathComponent()
    }
}
