import Foundation

public enum TerminalServicePaths {
    public static func socketPath(fileManager: FileManager = .default) throws -> String {
        try socketPath(terminalRootDirectory: try terminalRootDirectory(fileManager: fileManager))
    }

    /// The terminal-service socket path of `profile`, which need not be the profile this process resolved
    /// for itself.
    ///
    /// Socket names are a hash of the profile's own terminal root under one shared per-user socket root, so
    /// any process can name another profile's socket from that profile's runtime directory alone. Tooling
    /// that acts on another profile's daemon uses this rather than binding a profile environment variable
    /// it would then have to keep carrying.
    public static func socketPath(profile: SpacesProfile) throws -> String {
        try socketPath(terminalRootDirectory: terminalRootDirectory(runtimeDirectory: profile.runtimeDirectory))
    }

    private static func socketPath(terminalRootDirectory root: URL) throws -> String {
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let socketName = "service-\(socketPathComponent(for: root.path))"
        return socketRoot.appendingPathComponent("\(socketName).sock", isDirectory: false).path
    }

    /// The daemon instance-lock path of `profile`, named from that profile's own terminal root the same way
    /// its socket is, so tooling can ask whether another profile's daemon holds its lock.
    public static func instanceLockPath(profile: SpacesProfile) throws -> String {
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let root = terminalRootDirectory(runtimeDirectory: profile.runtimeDirectory)
        return socketRoot.appendingPathComponent("daemon-\(socketPathComponent(for: root.path)).lock", isDirectory: false).path
    }

    /// The terminal root inside `runtimeDirectory`, normalized exactly as the no-argument
    /// `terminalRootDirectory` normalizes this process's own, so the same profile hashes to the same socket
    /// name whichever process computes it.
    private static func terminalRootDirectory(runtimeDirectory: String) -> URL {
        URL(fileURLWithPath: runtimeDirectory, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(
            "terminal", isDirectory: true)
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
    /// (see `subscribeWorkspaceDiffSignature`). One socket per subscribed (workspace, ref, lastCommit) scope,
    /// hashed by workspace id and a scope discriminator rather than the profile root so sibling workspaces
    /// and sibling scopes of the same workspace never collide; created on first subscriber and removed when
    /// the last relay for that scope closes. The discriminator is hashed rather than embedded raw both
    /// because a ref name is arbitrary client-supplied text (a raw path could exceed the ~104-char unix
    /// socket path limit or need filesystem-unsafe-character escaping) and to keep every socket name a
    /// uniform fixed length. `refName == nil, lastCommit == false` (the uncommitted-changes scope) hashes an
    /// empty string; `lastCommit == true` hashes a sentinel containing a NUL byte, which no valid git ref
    /// name can ever contain, so it can never collide with a real ref name's hash input.
    public static func workspaceDiffSignatureSocketPath(
        workspaceID: String, refName: String? = nil, lastCommit: Bool = false, fileManager: FileManager = .default
    ) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let scopeDiscriminator = lastCommit ? "\u{0}last-commit" : (refName ?? "")
        let name =
            "workspace-diff-\(socketPathComponent(for: root.path))-\(socketPathComponent(for: workspaceID))-\(socketPathComponent(for: scopeDiscriminator))"
        return socketRoot.appendingPathComponent("\(name).sock", isDirectory: false).path
    }

    /// Profile-scoped unix socket the daemon streams one workspace-relative file's content-signature
    /// changes on (see `subscribeWorkspaceFileSignature`). One socket per subscribed (workspace, path)
    /// scope, hashed by workspace id and path rather than the profile root, mirroring
    /// `workspaceDiffSignatureSocketPath`'s own reasoning: a path is arbitrary client-supplied text (could
    /// exceed the unix socket path limit or need escaping), and hashing keeps every socket name a uniform
    /// fixed length.
    public static func workspaceFileSignatureSocketPath(workspaceID: String, path: String, fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let name = "workspace-file-\(socketPathComponent(for: root.path))-\(socketPathComponent(for: workspaceID))-\(socketPathComponent(for: path))"
        return socketRoot.appendingPathComponent("\(name).sock", isDirectory: false).path
    }

    /// Profile-scoped unix socket the daemon streams one workspace's `workspaceFileList` signature
    /// changes on (see `subscribeWorkspaceFileListSignature`). One socket per subscribed workspace,
    /// hashed by workspace id to keep the path length bounded.
    public static func workspaceFileListSignatureSocketPath(workspaceID: String, fileManager: FileManager = .default) throws -> String {
        let root = try terminalRootDirectory(fileManager: fileManager)
        let socketRoot = try SpacesSocketPaths.secureSocketRoot()
        let name = "workspace-file-list-\(socketPathComponent(for: root.path))-\(socketPathComponent(for: workspaceID))"
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
