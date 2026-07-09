import Foundation
import Dispatch
#if os(Linux)
import Glibc
#else
import Darwin
#endif

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
    typealias ShellPathDirectoryResolver = (URL, [String: String], FileManager) -> [String]

    /// Reports availability + hook status for every supported agent.
    public static func status(home: URL = defaultHome(), fileManager: FileManager = .default) -> [AgentHookStatus] {
        var executableResolver = ExecutableResolver(home: home, fileManager: fileManager)
        return status(home: home, fileManager: fileManager, executableResolver: &executableResolver)
    }

    /// Idempotently installs hooks for `kinds`, then returns fresh status for every supported agent.
    /// A per-agent install failure surfaces immediately rather than being swallowed.
    @discardableResult
    public static func install(
        _ kinds: [SupportedCodingAgentHook], home: URL = defaultHome(), fileManager: FileManager = .default
    ) throws -> [AgentHookStatus] {
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

    @discardableResult
    static func install(
        _ kinds: [SupportedCodingAgentHook], home: URL, fileManager: FileManager, environment: [String: String],
        shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver
    ) throws -> [AgentHookStatus] {
        var executableResolver = ExecutableResolver(
            home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shellPathDirectoryResolver)
        return try install(kinds, home: home, fileManager: fileManager, executableResolver: &executableResolver)
    }

    static func isAvailable(
        _ kind: SupportedCodingAgentHook, home: URL, fileManager: FileManager, environment: [String: String],
        shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver
    ) -> Bool {
        var executableResolver = ExecutableResolver(
            home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shellPathDirectoryResolver)
        return isAvailable(kind, executableResolver: &executableResolver)
    }

    // MARK: - Internals

    /// `install` and the `status` it returns share one resolver, so a login-shell probe costs at most
    /// one shell spawn per install rather than one per phase.
    private static func install(
        _ kinds: [SupportedCodingAgentHook], home: URL, fileManager: FileManager, executableResolver: inout ExecutableResolver
    ) throws -> [AgentHookStatus] {
        let unavailable = kinds.filter { !isAvailable($0, executableResolver: &executableResolver) }
        guard unavailable.isEmpty else { throw AgentHookInstallerError.unavailableAgents(unavailable) }
        for kind in kinds {
            try kind.install(home: home, fileManager: fileManager)
        }
        return status(home: home, fileManager: fileManager, executableResolver: &executableResolver)
    }

    private static func status(home: URL, fileManager: FileManager, executableResolver: inout ExecutableResolver) -> [AgentHookStatus] {
        SupportedCodingAgentHook.allCases.map { kind in
            AgentHookStatus(
                kind: kind, displayName: kind.displayName, available: isAvailable(kind, executableResolver: &executableResolver),
                hooksInstalled: kind.hooksInstalled(home: home, fileManager: fileManager))
        }
    }

    /// An agent is "available" only when its executable resolves on PATH / a common install dir.
    private static func isAvailable(_ kind: SupportedCodingAgentHook, executableResolver: inout ExecutableResolver) -> Bool {
        kind.executableNames.contains { executableResolver.resolve(named: $0) != nil }
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
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".deno/bin").path,
            home.appendingPathComponent("bin").path,
        ]
    }

    private static func orderedUnique(_ directories: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for directory in directories where seen.insert(directory).inserted {
            result.append(directory)
        }
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

        /// Holds the lock across `compute` so concurrent probes for the same home spawn one shell,
        /// not one each.
        func directories(home: URL, compute: () -> [String]) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            let timestamp = now()
            if let entry = entriesByHome[home.path], timestamp &- entry.capturedAtNanoseconds < ttlNanoseconds {
                return entry.directories
            }
            let computed = compute()
            entriesByHome[home.path] = Entry(directories: computed, capturedAtNanoseconds: timestamp)
            return computed
        }
    }

    private static func loginShellPathDirectories(home: URL, environment: [String: String], fileManager: FileManager) -> [String] {
        guard let shellPath = userLoginShellPath(environment: environment, fileManager: fileManager),
            let shellPATH = resolvedLoginShellPATH(shellPath: shellPath, home: home, environment: environment)
        else {
            return []
        }
        return pathDirectories(from: shellPATH)
    }

    private static func userLoginShellPath(environment: [String: String], fileManager: FileManager) -> String? {
        let candidates = [
            environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 },
            passwdLoginShellPath(),
            "/bin/zsh",
            "/bin/bash",
            "/bin/sh",
        ].compactMap(\.self)
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
    static func resolvedLoginShellPATH(shellPath: String, home: URL, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", "printf '\\n\(pathMarkerPrefix)%s\\n' \"$PATH\""]
        var processEnvironment = environment
        processEnvironment["HOME"] = home.path
        if processEnvironment["PATH"]?.isEmpty ?? true {
            processEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        process.environment = processEnvironment

        let outputPipe = Pipe()
        let outputBuffer = PipeOutputBuffer()
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

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        if completion.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                completion.wait()
            }
        }
        process.waitUntilExit()
        // The shell has exited, so EOF is imminent; bound the wait anyway rather than hang the daemon
        // on a grandchild that inherited the write end and outlives its parent.
        _ = endOfOutput.wait(timeout: .now() + 1)
        outputPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0, let output = String(data: outputBuffer.snapshot(), encoding: .utf8) else { return nil }
        return output.components(separatedBy: .newlines).last { $0.hasPrefix(pathMarkerPrefix) }.map { String($0.dropFirst(pathMarkerPrefix.count)) }
    }

    private final class PipeOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
#else
    private static func cachedLoginShellPathDirectories(home: URL, environment: [String: String], fileManager: FileManager) -> [String] { [] }
#endif
}
