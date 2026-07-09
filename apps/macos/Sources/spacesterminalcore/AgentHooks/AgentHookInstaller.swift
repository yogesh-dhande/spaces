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
        var statuses: [AgentHookStatus] = []
        for kind in SupportedCodingAgentHook.allCases {
            statuses.append(AgentHookStatus(
                kind: kind, displayName: kind.displayName, available: isAvailable(kind, executableResolver: &executableResolver),
                hooksInstalled: kind.hooksInstalled(home: home, fileManager: fileManager)))
        }
        return statuses
    }

    /// Idempotently installs hooks for `kinds`, then returns fresh status for every supported agent.
    /// A per-agent install failure surfaces immediately rather than being swallowed. `cliPath` is
    /// accepted for source compatibility; generated hooks invoke `spaces` from PATH.
    @discardableResult
    public static func install(
        _ kinds: [SupportedCodingAgentHook], home: URL = defaultHome(), cliPath: String = "spaces",
        fileManager: FileManager = .default
    ) throws -> [AgentHookStatus] {
        var executableResolver = ExecutableResolver(home: home, fileManager: fileManager)
        var unavailable: [SupportedCodingAgentHook] = []
        for kind in kinds {
            if !isAvailable(kind, executableResolver: &executableResolver) { unavailable.append(kind) }
        }
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
        var executableResolver = ExecutableResolver(home: home, fileManager: fileManager)
        return isAvailable(kind, executableResolver: &executableResolver)
    }

    static func isAvailable(
        _ kind: SupportedCodingAgentHook, home: URL, fileManager: FileManager, environment: [String: String],
        shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver
    ) -> Bool {
        var executableResolver = ExecutableResolver(
            home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shellPathDirectoryResolver)
        return isAvailable(kind, executableResolver: &executableResolver)
    }

    private static func isAvailable(_ kind: SupportedCodingAgentHook, executableResolver: inout ExecutableResolver) -> Bool {
        for name in kind.executableNames {
            if executableResolver.resolve(named: name) != nil { return true }
        }
        return false
    }

    /// Resolves an executable across `$PATH` plus common install locations, because a daemon started
    /// by launchd/systemd often has a minimal PATH that omits user tool directories. When those
    /// locations miss, it asks the user's login shell for the PATH it would use in a Spaces terminal.
    static func resolveExecutable(named name: String, home: URL, fileManager: FileManager) -> String? {
        var executableResolver = ExecutableResolver(home: home, fileManager: fileManager)
        return executableResolver.resolve(named: name)
    }

    static func resolveExecutable(
        named name: String, home: URL, fileManager: FileManager, environment: [String: String],
        shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver
    ) -> String? {
        var executableResolver = ExecutableResolver(
            home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shellPathDirectoryResolver)
        return executableResolver.resolve(named: name)
    }

    private struct ExecutableResolver {
        let home: URL
        let fileManager: FileManager
        let environment: [String: String]
        let shellPathDirectoryResolver: ShellPathDirectoryResolver
        let baseDirectories: [String]
        var shellDirectories: [String]?

        init(
            home: URL, fileManager: FileManager, environment: [String: String] = ProcessInfo.processInfo.environment,
            shellPathDirectoryResolver: @escaping ShellPathDirectoryResolver = AgentHookInstaller.loginShellPathDirectories
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

    private static func resolvedLoginShellPATH(shellPath: String, home: URL, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", "printf '\\n__SPACES_AGENT_HOOK_PATH__=%s\\n' \"$PATH\""]
        var processEnvironment = environment
        processEnvironment["HOME"] = home.path
        if processEnvironment["PATH"]?.isEmpty ?? true {
            processEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        process.environment = processEnvironment

        let outputPipe = Pipe()
        let outputBuffer = PipeOutputBuffer()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outputBuffer.append(data) }
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
        outputPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0, let output = String(data: outputBuffer.snapshot(), encoding: .utf8) else { return nil }
        let prefix = "__SPACES_AGENT_HOOK_PATH__="
        return output.components(separatedBy: .newlines).last(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
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
    private static func loginShellPathDirectories(home: URL, environment: [String: String], fileManager: FileManager) -> [String] { [] }
#endif
}
