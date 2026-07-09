import Foundation

/// The install/availability status of one supported coding agent on the machine the daemon runs on.
public struct AgentHookStatus: Sendable, Equatable, Codable {
    public let kind: SupportedCodingAgentHook
    public let displayName: String
    /// The agent executable resolves on this machine.
    public let available: Bool
    /// Spaces lifecycle hooks are currently present in the agent's config.
    public let hooksInstalled: Bool

    public init(kind: SupportedCodingAgentHook, displayName: String, available: Bool, hooksInstalled: Bool) {
        self.kind = kind
        self.displayName = displayName
        self.available = available
        self.hooksInstalled = hooksInstalled
    }
}

public enum AgentHookInstallerError: Error, LocalizedError, Sendable, Equatable {
    case unavailableAgents([SupportedCodingAgentHook])

    public var errorDescription: String? {
        switch self {
        case .unavailableAgents(let kinds):
            let names = kinds.map(\.displayName).joined(separator: ", ")
            return "Cannot install hooks because these coding-agent CLIs were not detected on this machine: \(names)."
        }
    }
}

/// Installs and reports Spaces lifecycle hooks for supported coding agents into the home directory of
/// the machine it runs on. The daemon (`spacesd`) owns this: the local Mac daemon installs local
/// hooks, a remote Linux daemon installs remote hooks, using identical code.
///
/// Every install is "ensure desired state," so it is safe to replay on every app launch and remote
/// (re)connect without duplicating hooks.
public enum AgentHookInstaller {
    /// Reports availability + hook status for every supported agent.
    public static func status(home: URL = defaultHome(), fileManager: FileManager = .default) -> [AgentHookStatus] {
        SupportedCodingAgentHook.allCases.map { kind in
            AgentHookStatus(
                kind: kind, displayName: kind.displayName, available: isAvailable(kind, home: home, fileManager: fileManager),
                hooksInstalled: kind.hooksInstalled(home: home, fileManager: fileManager))
        }
    }

    /// Idempotently installs hooks for `kinds`, then returns fresh status for every supported agent.
    /// A per-agent install failure surfaces immediately rather than being swallowed. `cliPath` is
    /// accepted for source compatibility; generated hooks invoke `spaces` from PATH.
    @discardableResult
    public static func install(
        _ kinds: [SupportedCodingAgentHook], home: URL = defaultHome(), cliPath: String = "spaces",
        fileManager: FileManager = .default
    ) throws -> [AgentHookStatus] {
        let unavailable = kinds.filter { !isAvailable($0, home: home, fileManager: fileManager) }
        guard unavailable.isEmpty else { throw AgentHookInstallerError.unavailableAgents(unavailable) }
        for kind in kinds {
            try kind.install(home: home, cliPath: cliPath, fileManager: fileManager)
        }
        return status(home: home, fileManager: fileManager)
    }

    public static func defaultHome() -> URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    /// Legacy helper for callers that still want the user helper link. Generated hooks invoke
    /// `spaces` from PATH.
    public static func defaultCLIPath(home: URL) -> String {
        SpacesBinaryLayout.userHelperLinkURL(for: .spaces, homeDirectoryURL: home)?.path ?? home.appendingPathComponent(".spaces/bin/spaces").path
    }

    // MARK: - Availability

    /// An agent is "available" only when its executable resolves on PATH / a common install dir.
    static func isAvailable(_ kind: SupportedCodingAgentHook, home: URL, fileManager: FileManager) -> Bool {
        return kind.executableNames.contains { resolveExecutable(named: $0, home: home, fileManager: fileManager) != nil }
    }

    /// Resolves an executable across `$PATH` plus common install locations, because a daemon started
    /// by launchd/systemd often has a minimal PATH that omits user tool directories.
    static func resolveExecutable(named name: String, home: URL, fileManager: FileManager) -> String? {
        var directories: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        directories.append(contentsOf: [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".deno/bin").path,
            home.appendingPathComponent("bin").path,
        ])
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
