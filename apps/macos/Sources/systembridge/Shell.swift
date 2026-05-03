import Darwin
import Foundation

public enum Shell {
    private struct LoginShellPathCacheKey: Hashable {
        let shellPath: String
        let homePath: String
        let inheritedPath: String
        let zdotdirPath: String
        let xdgConfigHomePath: String
        let xdgConfigDirsPath: String
    }

    private enum CachedLoginShellPath {
        case success(String)
        case recentFailure(expiry: Date)
    }

    private struct LoginShellPathResolution {
        let path: String
        let cachePolicy: CachePolicy
    }

    private enum CachePolicy {
        case cacheSuccess
        case cacheFailure(until: Date)
    }

    private final class LoginShellPathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LoginShellPathCacheKey: CachedLoginShellPath] = [:]

        func value(for key: LoginShellPathCacheKey, now: Date = Date(), resolver: () -> LoginShellPathResolution) -> String {
            lock.lock()
            if let cached = values[key] {
                switch cached {
                case .success(let path):
                    lock.unlock()
                    return path
                case .recentFailure(let expiry):
                    if expiry > now {
                        lock.unlock()
                        return ""
                    }
                    values.removeValue(forKey: key)
                }
            }
            lock.unlock()

            let resolved = resolver()

            lock.lock()
            switch resolved.cachePolicy {
            case .cacheSuccess: values[key] = .success(resolved.path)
            case .cacheFailure(let until): values[key] = .recentFailure(expiry: until)
            }
            lock.unlock()
            return resolved.path
        }
    }

    private final class PipeCollector: @unchecked Sendable {
        private let handle: FileHandle
        private let onData: (@Sendable (Data) -> Void)?
        private let lock = NSLock()
        private var buffer = Data()
        private var finished = false
        private var readerThread: Thread?

        init(handle: FileHandle, onData: (@Sendable (Data) -> Void)? = nil) {
            self.handle = handle
            self.onData = onData
            let thread = Thread { [weak self] in
                guard let self else { return }
                while true {
                    let chunk = self.handle.availableData
                    var snapshot = Data()
                    self.lock.lock()
                    if chunk.isEmpty {
                        self.finished = true
                        self.lock.unlock()
                        return
                    }
                    self.buffer.append(chunk)
                    snapshot = self.buffer
                    self.lock.unlock()
                    onData?(snapshot)
                }
            }
            thread.qualityOfService = .userInitiated
            readerThread = thread
            thread.start()
        }

        func waitUntilFinished(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                lock.lock()
                let isFinished = finished
                lock.unlock()
                if isFinished { return true }
                if Date() >= deadline { return false }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        func collectedData() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }

        func cancel() {
            try? handle.close()
            lock.lock()
            finished = true
            lock.unlock()
        }
    }

    private static let loginShellPathCache = LoginShellPathCache()
    private static let loginShellPathTimeoutFallbackSeconds: TimeInterval = 2
    private static let loginShellPathFailureCacheFallbackSeconds: TimeInterval = 10

    /// Returns the current process environment with Homebrew paths appended to PATH.
    /// Reads PATH from the C-level environment so that `setenv()` mutations from tests
    /// (e.g. injected mock command stubs) are reflected in the returned dictionary.
    private static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // getenv reads the C-level environment, which includes setenv() changes
        // made after process start (e.g. in test helpers that inject mock binaries
        // or shell-config overrides applied while the app remains running).
        for key in [
            "PATH", "SHELL", "HOME", "USER", "LOGNAME", "TMPDIR", "ZDOTDIR", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "TERM",
            "SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS", "SPACES_LOGIN_SHELL_PATH_FAILURE_CACHE_SECONDS",
        ] { if let value = currentEnvironmentValue(for: key) { env[key] = value } }
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = mergedCommandPath(currentPath: currentPath, environment: env)
        return env
    }

    private static func currentEnvironmentValue(for key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        return String(cString: raw)
    }

    private static func mergedCommandPath(currentPath: String, environment: [String: String]) -> String {
        let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        let loginShellPath = loginShellPath(environment: environment, currentPath: currentPath)
        var seen = Set<String>()
        var ordered: [String] = []

        // Preserve the inherited launch environment first, then append any
        // login-shell-only entries, and finally add common package-manager
        // prefixes for Finder-style launches with a sparse PATH.
        for rawPath in [currentPath, loginShellPath, brewPaths] {
            for component in rawPath.split(separator: ":").map(String.init) where !component.isEmpty {
                if seen.insert(component).inserted { ordered.append(component) }
            }
        }

        return ordered.joined(separator: ":")
    }

    private static func loginShellPath(environment: [String: String], currentPath: String) -> String {
        let shellPath = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/bin/zsh"
        let homePath = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return "" }
        let cacheKey = LoginShellPathCacheKey(
            shellPath: shellPath, homePath: homePath, inheritedPath: currentPath,
            zdotdirPath: environment["ZDOTDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            xdgConfigHomePath: environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            xdgConfigDirsPath: environment["XDG_CONFIG_DIRS"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        return loginShellPathCache.value(for: cacheKey) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            let discoveredState = DiscoveredPathState()
            let stdoutReader = PipeCollector(handle: output.fileHandleForReading) { data in
                guard let text = String(data: data, encoding: .utf8), let path = extractedLoginShellPath(from: text) else { return }
                discoveredState.record(path: path)
            }
            let stderrReader = PipeCollector(handle: error.fileHandleForReading)
            process.executableURL = URL(fileURLWithPath: shellPath)
            // Use a login shell so PATH matches the user's configured shell
            // environment, but keep it non-interactive. Interactive shells may
            // try to take foreground TTY control during app launch and hang the
            // caller in job-control setup before PATH is printed.
            process.arguments = ["-l", "-c", "printf '\\n__SPACES_PATH__'; /usr/bin/printenv PATH"]
            var loginEnvironment: [String: String] = [:]
            for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "ZDOTDIR", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS"] {
                if let value = environment[key], !value.isEmpty { loginEnvironment[key] = value }
            }
            loginEnvironment["PATH"] = currentPath
            loginEnvironment["SHELL"] = shellPath
            loginEnvironment["TERM"] = environment["TERM"]?.isEmpty == false ? environment["TERM"] : "xterm-256color"
            process.environment = loginEnvironment
            process.standardOutput = output
            process.standardError = error

            guard (try? process.run()) != nil else {
                return LoginShellPathResolution(path: "", cachePolicy: .cacheFailure(until: failureCacheExpiry(environment: environment)))
            }
            let probeTimeout = loginShellPathTimeoutSeconds(environment: environment)
            guard waitForProcessExit(process, timeout: probeTimeout) else {
                let discoveredPath = discoveredState.path(from: stdoutReader.collectedData())
                stdoutReader.cancel()
                stderrReader.cancel()
                if let discoveredPath { return LoginShellPathResolution(path: discoveredPath, cachePolicy: .cacheSuccess) }
                // Fall back to the inherited PATH for this command resolution, but only
                // suppress retries briefly in case the user's shell init was transiently slow.
                return LoginShellPathResolution(path: "", cachePolicy: .cacheFailure(until: failureCacheExpiry(environment: environment)))
            }
            let drainDeadline = Date().addingTimeInterval(probeTimeout)
            let stdoutFinished = stdoutReader.waitUntilFinished(timeout: remainingTime(until: drainDeadline))
            let stderrFinished = stderrReader.waitUntilFinished(timeout: remainingTime(until: drainDeadline))
            let discoveredPath = discoveredState.path(from: stdoutReader.collectedData())
            guard stdoutFinished, stderrFinished else {
                stdoutReader.cancel()
                stderrReader.cancel()
                if let discoveredPath { return LoginShellPathResolution(path: discoveredPath, cachePolicy: .cacheSuccess) }
                // Detached shell startup helpers can keep stdio open after the login shell exits.
                // Treat that as a temporary probe failure rather than a permanent empty PATH.
                return LoginShellPathResolution(path: "", cachePolicy: .cacheFailure(until: failureCacheExpiry(environment: environment)))
            }
            if let discoveredPath { return LoginShellPathResolution(path: discoveredPath, cachePolicy: .cacheSuccess) }
            guard process.terminationStatus == 0 else {
                return LoginShellPathResolution(path: "", cachePolicy: .cacheFailure(until: failureCacheExpiry(environment: environment)))
            }
            return LoginShellPathResolution(path: "", cachePolicy: .cacheFailure(until: failureCacheExpiry(environment: environment)))
        }
    }

    private static func loginShellPathTimeoutSeconds(environment: [String: String]) -> TimeInterval {
        guard let raw = environment["SPACES_LOGIN_SHELL_PATH_TIMEOUT_SECONDS"], let value = TimeInterval(raw), value > 0 else {
            return loginShellPathTimeoutFallbackSeconds
        }
        return value
    }

    private static func loginShellPathFailureCacheSeconds(environment: [String: String]) -> TimeInterval {
        guard let raw = environment["SPACES_LOGIN_SHELL_PATH_FAILURE_CACHE_SECONDS"], let value = TimeInterval(raw), value > 0 else {
            return loginShellPathFailureCacheFallbackSeconds
        }
        return value
    }

    private static func failureCacheExpiry(environment: [String: String], now: Date = Date()) -> Date {
        now.addingTimeInterval(loginShellPathFailureCacheSeconds(environment: environment))
    }

    private static func remainingTime(until deadline: Date, now: Date = Date()) -> TimeInterval { max(0, deadline.timeIntervalSince(now)) }

    private static func extractedLoginShellPath(from text: String) -> String? {
        guard let markerRange = text.range(of: "__SPACES_PATH__") else { return nil }
        let suffix = text[markerRange.upperBound...]
        let pathLine = suffix.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first
        guard let pathLine else { return nil }
        return String(pathLine)
    }

    private final class DiscoveredPathState: @unchecked Sendable {
        private let lock = NSLock()
        private var discoveredPath: String?

        func record(path: String) {
            lock.lock()
            discoveredPath = path
            lock.unlock()
        }

        func path(from data: Data) -> String? {
            if let discovered = cachedPath() { return discovered }
            guard let text = String(data: data, encoding: .utf8), let extracted = extractedLoginShellPath(from: text) else { return nil }
            record(path: extracted)
            return extracted
        }

        private func cachedPath() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return discoveredPath
        }
    }

    private static func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.interrupt()
                Thread.sleep(forTimeInterval: 0.05)
                if process.isRunning { process.terminate() }
                Thread.sleep(forTimeInterval: 0.05)
                return !process.isRunning
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    private static func resolvedExecutablePath(for executable: String, environment: [String: String]) -> String? {
        if executable.contains("/") { return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil }

        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appending(path: executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func waitStatus(_ status: Int32) -> Int32 {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 { return (status >> 8) & 0xff }
        if terminationSignal != 0x7f { return 128 + terminationSignal }
        return status
    }

    @discardableResult public static func run(_ command: [String], cwd: String? = nil) throws -> Int32 {
        guard let executable = command.first else {
            throw NSError(domain: "spaces.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }
        let environment = processEnvironment()
        if cwd == nil, let executablePath = resolvedExecutablePath(for: executable, environment: environment) {
            var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + Array(command.dropFirst())).map { strdup($0) }
            argv.append(nil)
            defer { for case let pointer? in argv { free(pointer) } }

            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
            envp.append(nil)
            defer { for case let pointer? in envp { free(pointer) } }

            var pid: pid_t = 0
            let spawnResult = posix_spawn(&pid, executablePath, nil, nil, &argv, &envp)
            if spawnResult != 0 {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(spawnResult), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(spawnResult))])
            }

            var status: Int32 = 0
            if waitpid(pid, &status, 0) == -1 {
                let errnoValue = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errnoValue), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
            }
            return waitStatus(status)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + Array(command.dropFirst())
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public static func runAndCapture(_ command: [String], cwd: String? = nil) throws -> String {
        guard let executable = command.first else {
            throw NSError(domain: "spaces.shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }
        let environment = processEnvironment()
        if cwd == nil, let executablePath = resolvedExecutablePath(for: executable, environment: environment) {
            var stdoutPipe: [Int32] = [0, 0]
            var stderrPipe: [Int32] = [0, 0]
            guard pipe(&stdoutPipe) == 0 else {
                let errnoValue = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errnoValue), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
            }
            guard pipe(&stderrPipe) == 0 else {
                let errnoValue = errno
                close(stdoutPipe[0])
                close(stdoutPipe[1])
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errnoValue), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
            }

            var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + Array(command.dropFirst())).map { strdup($0) }
            argv.append(nil)
            defer { for case let pointer? in argv { free(pointer) } }

            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
            envp.append(nil)
            defer { for case let pointer? in envp { free(pointer) } }

            var fileActions: posix_spawn_file_actions_t? = nil
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
            posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
            posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
            posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])

            var pid: pid_t = 0
            let spawnResult = posix_spawn(&pid, executablePath, &fileActions, nil, &argv, &envp)
            close(stdoutPipe[1])
            close(stderrPipe[1])
            if spawnResult != 0 {
                close(stdoutPipe[0])
                close(stderrPipe[0])
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(spawnResult), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(spawnResult))])
            }

            let stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
            let stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
            let stdoutData = stdoutHandle.readDataToEndOfFile()
            let stderrData = stderrHandle.readDataToEndOfFile()

            var status: Int32 = 0
            if waitpid(pid, &status, 0) == -1 {
                let errnoValue = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errnoValue), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
            }

            let terminationStatus = waitStatus(status)
            if terminationStatus != 0 {
                let text = String(data: stderrData, encoding: .utf8) ?? ""
                throw NSError(domain: "spaces.shell", code: Int(terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
            }
            return String(data: stdoutData, encoding: .utf8) ?? ""
        }

        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + Array(command.dropFirst())
        process.environment = environment
        process.standardOutput = out
        process.standardError = err
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        try process.run()
        process.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "spaces.shell", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
