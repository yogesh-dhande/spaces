import Dispatch
import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// The install/availability status of one supported coding agent on the machine the daemon runs on.
public struct AgentHookStatus: Sendable, Equatable, Codable {
    public let kind: CodingAgent
    public let displayName: String
    /// The agent executable resolves on this machine.
    public let available: Bool
    /// How completely the agent's config carries the hooks this Spaces build writes.
    public let installState: AgentHookInstallState

    public init(kind: CodingAgent, displayName: String, available: Bool, installState: AgentHookInstallState) {
        self.kind = kind
        self.displayName = displayName
        self.available = available
        self.installState = installState
    }
}

/// Why hooks could not be installed for one agent. Per-agent rather than per-request: one agent whose
/// config Spaces refuses to edit must not prevent the others from being installed, and the caller must
/// be able to tell the user which agent failed and why.
public struct AgentHookInstallFailure: Sendable, Equatable, Codable {
    public let kind: CodingAgent
    public let message: String

    public init(kind: CodingAgent, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// The result of an install request: fresh status for every supported agent, plus one entry per agent
/// that could not be installed. `failures` being empty is the only signal that everything requested
/// landed.
public struct AgentHookInstallOutcome: Sendable, Equatable, Codable {
    public let agents: [AgentHookStatus]
    public let failures: [AgentHookInstallFailure]

    public init(agents: [AgentHookStatus], failures: [AgentHookInstallFailure]) {
        self.agents = agents
        self.failures = failures
    }
}

/// A failure that stops the whole install request rather than one agent's share of it.
public enum AgentHookInstallerError: Error, LocalizedError, Sendable, Equatable {
    /// Every hook command invokes the Spaces CLI by absolute path, so without it there is nothing
    /// worth writing: the hooks would install and then silently never fire.
    case spacesCLINotFound

    public var errorDescription: String? {
        switch self {
        case .spacesCLINotFound:
            return "Cannot install hooks because the `spaces` CLI was not found on this machine. Install the Spaces CLI, then retry."
        }
    }
}

/// Installs and reports Spaces lifecycle hooks for supported coding agents into the home directory of
/// the machine it runs on. The daemon (`spacesd`) owns this: the local Mac daemon installs local
/// hooks, a remote Linux daemon installs remote hooks, using identical code.
///
/// Every install is "ensure desired state," so replaying it never duplicates a hook; a reinstall is
/// also how an agent whose hooks an older Spaces build wrote is brought back to `.current`.
/// Installs are always user-initiated — from the launch setup step or Settings → Coding Agents.
public enum AgentHookInstaller {
    typealias ShellPathDirectoryResolver = (URL, [String: String], FileManager) -> [String]

    /// Reports availability + hook status for every supported agent.
    public static func status(home: URL = defaultHome(), fileManager: FileManager = .default) -> [AgentHookStatus] {
        var executableResolver = ExecutableResolver(home: home, fileManager: fileManager)
        return status(home: home, fileManager: fileManager, executableResolver: &executableResolver)
    }

    /// Idempotently installs hooks for `kinds`, then returns fresh status for every supported agent
    /// alongside one failure entry per agent that could not be installed. Each agent is attempted
    /// independently, so a config Spaces refuses to edit costs only that agent.
    @discardableResult public static func install(_ kinds: [CodingAgent], home: URL = defaultHome(), fileManager: FileManager = .default)
        throws -> AgentHookInstallOutcome
    {
        var executableResolver = ExecutableResolver(home: home, fileManager: fileManager)
        return try install(kinds, home: home, fileManager: fileManager, executableResolver: &executableResolver)
    }

    public static func defaultHome() -> URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    // MARK: - Test seams
    //
    // Availability depends on the daemon user's environment and login shell. These overloads let tests
    // supply both, so no test spawns the developer's real login shell or reads the real `PATH`.

    static func status(
        home: URL, fileManager: FileManager, environment: [String: String], shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver
    ) -> [AgentHookStatus] {
        var executableResolver = ExecutableResolver(
            home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shellPathDirectoryResolver)
        return status(home: home, fileManager: fileManager, executableResolver: &executableResolver)
    }

    @discardableResult static func install(
        _ kinds: [CodingAgent], home: URL, fileManager: FileManager, environment: [String: String],
        shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver
    ) throws -> AgentHookInstallOutcome {
        var executableResolver = ExecutableResolver(
            home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shellPathDirectoryResolver)
        return try install(kinds, home: home, fileManager: fileManager, executableResolver: &executableResolver)
    }

    static func isAvailable(
        _ kind: CodingAgent, home: URL, fileManager: FileManager, environment: [String: String],
        shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver
    ) -> Bool {
        var executableResolver = ExecutableResolver(
            home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shellPathDirectoryResolver)
        return isAvailable(kind, executableResolver: &executableResolver)
    }

    // MARK: - Internals

    /// `install` and the `status` it returns share one resolver, so a login-shell probe costs at most
    /// one shell spawn per install rather than one per phase.
    ///
    /// An agent that is not available, or whose config cannot be edited, becomes a failure entry; the
    /// remaining agents still install. Only a missing `spaces` CLI aborts the request, because every
    /// hook command it would write invokes that binary by absolute path.
    private static func install(
        _ kinds: [CodingAgent], home: URL, fileManager: FileManager, executableResolver: inout ExecutableResolver
    ) throws -> AgentHookInstallOutcome {
        guard let resolvedSpacesExecutablePath = executableResolver.resolve(named: AgentHookCommand.spacesExecutableName),
            let spacesExecutablePath = hookSpacesExecutablePath(resolvedPath: resolvedSpacesExecutablePath, home: home, fileManager: fileManager)
        else { throw AgentHookInstallerError.spacesCLINotFound }
        var failures: [AgentHookInstallFailure] = []
        for kind in kinds {
            guard let agentExecutablePath = resolvedExecutablePath(for: kind, executableResolver: &executableResolver) else {
                failures.append(.init(kind: kind, message: "\(kind.displayName) was not detected on this machine."))
                continue
            }
            do {
                try kind.install(
                    home: home, fileManager: fileManager, spacesExecutablePath: spacesExecutablePath, agentExecutablePath: agentExecutablePath)
            } catch { failures.append(.init(kind: kind, message: error.localizedDescription)) }
        }
        return AgentHookInstallOutcome(
            agents: status(home: home, fileManager: fileManager, executableResolver: &executableResolver), failures: failures)
    }

    private static func status(home: URL, fileManager: FileManager, executableResolver: inout ExecutableResolver) -> [AgentHookStatus] {
        CodingAgent.allCases.map { kind in
            let executablePath = resolvedExecutablePath(for: kind, executableResolver: &executableResolver)
            return AgentHookStatus(
                kind: kind, displayName: kind.displayName, available: executablePath != nil,
                installState: kind.installState(home: home, fileManager: fileManager, agentExecutablePath: executablePath))
        }
    }

    /// An agent is "available" only when its executable resolves on PATH / a common install dir.
    private static func isAvailable(_ kind: CodingAgent, executableResolver: inout ExecutableResolver) -> Bool {
        resolvedExecutablePath(for: kind, executableResolver: &executableResolver) != nil
    }

    private static func resolvedExecutablePath(for kind: CodingAgent, executableResolver: inout ExecutableResolver) -> String? {
        for name in kind.executableNames { if let path = executableResolver.resolve(named: name) { return path } }
        return nil
    }

    /// Resolves executables across `$PATH` plus common install locations, because a daemon started by
    /// launchd/systemd often has a minimal PATH that omits user tool directories. When those locations
    /// miss, it asks the user's login shell for the PATH it would use in a Spaces terminal. The
    /// login-shell answer is resolved at most once per resolver instance.
    private struct ExecutableResolver {
        let home: URL
        let fileManager: FileManager
        let environment: [String: String]
        let shellPathDirectoryResolver: ShellPathDirectoryResolver
        let baseDirectories: [String]
        var shellDirectories: [String]?

        init(
            home: URL, fileManager: FileManager, environment: [String: String] = ProcessInfo.processInfo.environment,
            shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver = AgentHookInstaller.cachedLoginShellPathDirectories
        ) {
            self.home = home
            self.fileManager = fileManager
            self.environment = environment
            self.shellPathDirectoryResolver = shellPathDirectoryResolver
            self.baseDirectories = AgentHookInstaller.orderedUnique(
                AgentHookInstaller.pathDirectories(from: environment["PATH"]) + AgentHookInstaller.commonExecutableDirectories(home: home))
        }

        mutating func resolve(named name: String) -> String? {
            if let resolved = Self.resolveExecutable(named: name, directories: baseDirectories, fileManager: fileManager) { return resolved }
            if shellDirectories == nil {
                shellDirectories = AgentHookInstaller.orderedUnique(shellPathDirectoryResolver(home, environment, fileManager))
            }
            return Self.resolveExecutable(named: name, directories: shellDirectories ?? [], fileManager: fileManager)
        }

        private static func resolveExecutable(named name: String, directories: [String], fileManager: FileManager) -> String? {
            for directory in directories where !directory.isEmpty {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }
    }

    private static func pathDirectories(from path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        return path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func commonExecutableDirectories(home: URL) -> [String] {
        [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path, home.appendingPathComponent(".deno/bin").path, home.appendingPathComponent("bin").path,
        ]
    }

    /// Linux releases live under a versioned directory, but the installer also maintains one stable
    /// CLI symlink. Persisting the release path in an agent config would pin hooks to an old CLI after
    /// the daemon updates. Normalize only this known installed layout; development and other CLI paths
    /// remain the exact executable the resolver found.
    private static func hookSpacesExecutablePath(resolvedPath: String, home: URL, fileManager: FileManager) -> String? {
        let releasesPath = home.appendingPathComponent(".spaces/daemon/releases", isDirectory: true).standardizedFileURL.path
        let candidatePath = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
        guard candidatePath.hasPrefix(releasesPath + "/") else { return candidatePath }

        let stablePath = home.appendingPathComponent(".spaces/bin/spaces").standardizedFileURL.path
        return fileManager.isExecutableFile(atPath: stablePath) ? stablePath : nil
    }

    private static func orderedUnique(_ directories: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for directory in directories where seen.insert(directory).inserted { result.append(directory) }
        return result
    }

    #if os(macOS) || os(Linux)
        /// Spawning an interactive login shell costs seconds — it sources the user's whole rc chain
        /// (version managers, completions) — and the daemon probes availability on every app launch,
        /// device connect, and Settings → Coding Agents open. Probes are user-action driven rather than a
        /// hot loop, so a short TTL collapses the burst each action makes without holding a stale answer.
        ///
        /// The TTL is what keeps the "a newly installed agent is picked up on the next connect" contract
        /// honest. `spacesd` outlives the app, so a cache held for the daemon's lifetime would survive an
        /// app relaunch: an agent installed through a version manager whose shim directory is not yet on
        /// the daemon's PATH would stay undetected until the daemon itself restarted.
        ///
        /// Failed probes are cached too. A shell that is missing, or an rc script that hangs past the
        /// probe timeout, would otherwise pay the full timeout on *every* status call forever; caching the
        /// failure bounds that to once per TTL and still recovers on its own.
        static let shellDirectoryCacheTTLSeconds: TimeInterval = 60

        private static let shellDirectoryCache = ShellDirectoryCache()

        private static func cachedLoginShellPathDirectories(home: URL, environment: [String: String], fileManager: FileManager) -> [String] {
            shellDirectoryCache.directories(home: home) { loginShellPathDirectories(home: home, environment: environment, fileManager: fileManager) }
        }

        final class ShellDirectoryCache: @unchecked Sendable {
            private struct Entry {
                let directories: [String]
                let capturedAtNanoseconds: UInt64
            }

            private let lock = NSLock()
            private var entriesByHome: [String: Entry] = [:]
            private let ttlNanoseconds: UInt64
            /// Monotonic, so a system clock change can neither freeze nor expire the cache.
            private let now: @Sendable () -> UInt64

            init(
                ttlSeconds: TimeInterval = AgentHookInstaller.shellDirectoryCacheTTLSeconds,
                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
            ) {
                self.ttlNanoseconds = UInt64(ttlSeconds * 1_000_000_000)
                self.now = now
            }

            /// Holds the lock across `compute` so concurrent probes spawn one shell, not one each. One lock
            /// rather than one per home: a process serves exactly one home (its own user's), so the map is
            /// keyed by home only to let tests exercise several without sharing state, and contention
            /// between distinct homes cannot arise in production.
            func directories(home: URL, compute: () -> [String]) -> [String] {
                lock.lock()
                defer { lock.unlock() }
                let timestamp = now()
                if let entry = entriesByHome[home.path], timestamp &- entry.capturedAtNanoseconds < ttlNanoseconds { return entry.directories }
                let computed = compute()
                entriesByHome[home.path] = Entry(directories: computed, capturedAtNanoseconds: timestamp)
                return computed
            }
        }

        private static func loginShellPathDirectories(home: URL, environment: [String: String], fileManager: FileManager) -> [String] {
            guard let shellPath = userLoginShellPath(environment: environment, fileManager: fileManager),
                let shellPATH = resolvedLoginShellPATH(shellPath: shellPath, home: home, environment: environment)
            else { return [] }
            return pathDirectories(from: shellPATH)
        }

        private static func userLoginShellPath(environment: [String: String], fileManager: FileManager) -> String? {
            let candidates = [environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 }, passwdLoginShellPath(), "/bin/zsh", "/bin/bash", "/bin/sh"]
                .compactMap(\.self)
            return candidates.first { fileManager.isExecutableFile(atPath: $0) }
        }

        private static func passwdLoginShellPath() -> String? {
            guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
            let path = String(cString: shell)
            return path.isEmpty ? nil : path
        }

        /// Marks the PATH line in the login shell's output. The shell's rc files write arbitrary text to
        /// both streams first, so the value is printed on its own line and read back by prefix.
        static let pathMarkerPrefix = "__SPACES_AGENT_HOOK_PATH__="

        /// Runs the user's login shell and reads back the PATH it would give a Spaces terminal.
        ///
        /// The pipe is drained by a readability handler *while* the shell runs, so an rc chain that writes
        /// more than the 64KB pipe buffer cannot deadlock. Process termination does not imply the handler
        /// has consumed the last chunk, so the output is read through to EOF before it is parsed —
        /// otherwise the marker line, which is printed last, can be lost and the shell PATH silently
        /// ignored.
        ///
        /// The shell is interactive (`-i`) because version managers put their shim directories on PATH
        /// from `.zshrc`, which a login-only shell never sources. An interactive shell that inherits a
        /// terminal on stdin, though, will touch that terminal — reconfiguring its modes, or taking
        /// job-control signals that stop the probe until it times out. Both callers can have a terminal on
        /// stdin (the `spaces` CLI always does), so stdin is redirected to /dev/null: nothing is ever
        /// written to the shell, only read back from it.
        static func resolvedLoginShellPATH(shellPath: String, home: URL, environment: [String: String], timeoutSeconds: TimeInterval = 5) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = ["-l", "-i", "-c", "printf '\\n\(pathMarkerPrefix)%s\\n' \"$PATH\""]
            var processEnvironment = environment
            processEnvironment["HOME"] = home.path
            if processEnvironment["PATH"]?.isEmpty ?? true { processEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
            process.environment = processEnvironment
            process.standardInput = FileHandle.nullDevice

            let outputPipe = Pipe()
            let outputBuffer = AgentHookPipeOutputBuffer()
            let endOfOutput = DispatchSemaphore(value: 0)
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil  // EOF: the shell exited and its write end closed
                    endOfOutput.signal()
                    return
                }
                outputBuffer.append(data)
            }
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            let completion = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completion.signal() }

            do { try process.run() } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                return nil
            }

            if completion.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                AgentHookProcessTree.terminate(rootProcessID: process.processIdentifier, completion: completion)
            }
            process.waitUntilExit()
            // The shell has exited, so EOF is imminent; bound the wait anyway rather than hang the daemon
            // on a grandchild that inherited the write end and outlives its parent.
            _ = endOfOutput.wait(timeout: .now() + 1)
            outputPipe.fileHandleForReading.readabilityHandler = nil

            guard process.terminationStatus == 0, let output = String(data: outputBuffer.snapshot(), encoding: .utf8) else { return nil }
            return output.components(separatedBy: .newlines).last { $0.hasPrefix(pathMarkerPrefix) }.map {
                String($0.dropFirst(pathMarkerPrefix.count))
            }
        }
    #else
        private static func cachedLoginShellPathDirectories(home: URL, environment: [String: String], fileManager: FileManager) -> [String] { [] }
    #endif
}
