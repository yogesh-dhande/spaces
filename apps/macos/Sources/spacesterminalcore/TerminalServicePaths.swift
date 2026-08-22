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

    /// Profile-scoped unix socket the daemon streams one workspace/ref scope's diff-signature changes on
    /// (see `subscribeWorkspaceDiffSignature`). One socket per subscribed (workspace, ref) scope, hashed by
    /// workspace id and ref name rather than the profile root so sibling workspaces and sibling scopes of
    /// the same workspace never collide; created on first subscriber and removed when the last relay for
    /// that scope closes. `refName` is hashed rather than embedded raw both because a ref name is arbitrary
    /// client-supplied text (a raw path could exceed the ~104-char unix socket path limit or need
    /// filesystem-unsafe-character escaping) and to keep every socket name a uniform fixed length; `nil`
    /// (the uncommitted-changes scope) hashes an empty string so it stays distinct from any real ref name.
    public static func workspaceDiffSignatureSocketPath(workspaceID: String, refName: String? = nil, fileManager: FileManager = .default) throws
        -> String
    {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let name =
            "workspace-diff-\(socketPathComponent(for: root.path))-\(socketPathComponent(for: workspaceID))-\(socketPathComponent(for: refName ?? ""))"
        return socketRoot.appendingPathComponent("\(name).sock", isDirectory: false).path
    }

    public static func instanceLockPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let lockName = "daemon-\(socketPathComponent(for: root.path))"
        return socketRoot.appendingPathComponent("\(lockName).lock", isDirectory: false).path
    }

    static func launchLockPath(fileManager: FileManager = .default) throws -> String { "\(try socketPath(fileManager: fileManager)).launch.lock" }

    public static func logPath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        return root.appendingPathComponent("service.log", isDirectory: false).path
    }

    /// Profile-scoped handoff table the daemon writes just before an exec-in-place
    /// update and consumes on the next startup. See `DaemonHandoffStore`.
    public static func daemonHandoffTablePath(fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        return root.appendingPathComponent("daemon-handoff.json", isDirectory: false).path
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
