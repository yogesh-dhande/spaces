import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

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

    private final class ProbeProcess: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var cachedTerminationStatus: Int32?

        init(pid: pid_t) { self.pid = pid }

        var processGroupID: pid_t { pid }

        func cachedTerminationStatusValue() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            return cachedTerminationStatus
        }

        func recordTerminationStatus(_ status: Int32) {
            lock.lock()
            cachedTerminationStatus = status
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
        ] { if let value = currentEnvironmentValue(for: key) { env[key] = value } else { env.removeValue(forKey: key) } }
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
        var seen = Set(currentPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty })
        var additions: [String] = []

        // Keep the inherited PATH text verbatim so empty segments that mean
        // "search the current working directory" retain their original order.
        // Only append concrete directory entries that are missing.
        for rawPath in [loginShellPath, brewPaths] {
            for component in rawPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init) where !component.isEmpty {
                if seen.insert(component).inserted { additions.append(component) }
            }
        }

        guard !additions.isEmpty else { return currentPath }
        guard !currentPath.isEmpty else { return additions.joined(separator: ":") }
        return currentPath + ":" + additions.joined(separator: ":")
    }

    private static func loginShellProbeSeedPath(currentPath: String) -> String {
        let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        guard !currentPath.isEmpty else { return systemPath }

        var seen = Set<String>()
        var ordered: [String] = []
        for rawPath in [currentPath, systemPath] {
            for component in rawPath.split(separator: ":").map(String.init) where !component.isEmpty {
                if seen.insert(component).inserted { ordered.append(component) }
            }
        }
        return ordered.joined(separator: ":")
    }

    private static func loginShellPath(environment: [String: String], currentPath: String) -> String {
        let shellPath = resolvedLoginShellExecutablePath(environment: environment) ?? "/bin/zsh"
        let homePath = resolvedHomePath(environment: environment) ?? ""
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return "" }
        let cacheKey = LoginShellPathCacheKey(
            shellPath: shellPath, homePath: homePath, inheritedPath: currentPath,
            zdotdirPath: environment["ZDOTDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            xdgConfigHomePath: environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            xdgConfigDirsPath: environment["XDG_CONFIG_DIRS"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        return loginShellPathCache.value(for: cacheKey) {
            let output = Pipe()
            let error = Pipe()
            let discoveredState = DiscoveredPathState()
            let stdoutReader = PipeCollector(handle: output.fileHandleForReading) { data in
                guard let text = String(data: data, encoding: .utf8), let path = extractedLoginShellPath(from: text) else { return }
                discoveredState.record(path: path)
            }
            let stderrReader = PipeCollector(handle: error.fileHandleForReading)
            // Keep the outer probe argument shape as `-l -c` so wrapper shells
            // that key off those first two arguments continue taking their
            // login-shell path. Re-exec into an interactive shell inside that
            // login shell so version-manager hooks commonly sourced from
            // interactive startup files can still contribute to PATH.
            let interactiveProbeCommand = #"exec "$SHELL" -ic "printf '\n__SPACES_PATH__'; /usr/bin/printenv PATH""#
            let arguments = ["-l", "-c", interactiveProbeCommand, shellPath]
            var loginEnvironment: [String: String] = [:]
            for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "ZDOTDIR", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS"] {
                if let value = environment[key], !value.isEmpty { loginEnvironment[key] = value }
            }
            loginEnvironment["PATH"] = loginShellProbeSeedPath(currentPath: currentPath)
            loginEnvironment["SHELL"] = shellPath
            loginEnvironment["TERM"] = environment["TERM"]?.isEmpty == false ? environment["TERM"] : "xterm-256color"

            guard
                let process = spawnIsolatedProbeProcess(
                    executablePath: shellPath, arguments: arguments, environment: loginEnvironment, output: output, error: error)
            else { return LoginShellPathResolution(path: "", cachePolicy: .cacheFailure(until: failureCacheExpiry(environment: environment))) }
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
            guard process.cachedTerminationStatusValue() == 0 else {
                return LoginShellPathResolution(path: "", cachePolicy: .cacheFailure(until: failureCacheExpiry(environment: environment)))
            }
            return LoginShellPathResolution(path: "", cachePolicy: .cacheFailure(until: failureCacheExpiry(environment: environment)))
        }
    }

    public static func resolvedLoginShellExecutablePath(environment: [String: String]) -> String? {
        let configuredShell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountInfo = currentUserAccountInfo()
        if let accountShell = accountInfo?.shellPath, !accountShell.isEmpty {
            let configuredHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let configuredShell, !configuredShell.isEmpty, let configuredHome, !configuredHome.isEmpty, let accountHome = accountInfo?.homePath,
                configuredHome != accountHome
            {
                return configuredShell
            }
            return accountShell
        }
        return configuredShell
    }

    private static func resolvedHomePath(environment: [String: String]) -> String? {
        let configuredHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configuredHome, !configuredHome.isEmpty { return configuredHome }
        return currentUserAccountInfo()?.homePath
    }

    private static func currentUserAccountInfo() -> (shellPath: String, homePath: String)? {
        let uid = getuid()
        guard let requiredSize = sysconfBufferSize(Int32(_SC_GETPW_R_SIZE_MAX)) else { return nil }
        var buffer = [CChar](repeating: 0, count: requiredSize)
        var passwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let status = getpwuid_r(uid, &passwd, &buffer, buffer.count, &result)
        guard status == 0, let record = result else { return nil }
        return (shellPath: String(cString: record.pointee.pw_shell), homePath: String(cString: record.pointee.pw_dir))
    }

    private static func sysconfBufferSize(_ name: Int32) -> Int? {
        let raw = sysconf(name)
        if raw > 0 { return Int(raw) }
        return 16_384
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

    private static func spawnIsolatedProbeProcess(
        executablePath: String, arguments: [String], environment: [String: String], output: Pipe, error: Pipe
    ) -> ProbeProcess? {
        #if os(Linux)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
                output.fileHandleForWriting.closeFile()
                error.fileHandleForWriting.closeFile()
                return ProbeProcess(pid: process.processIdentifier)
            } catch { return nil }
        #else
            var fileActions: posix_spawn_file_actions_t? = nil
            guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
            defer { posix_spawn_file_actions_destroy(&fileActions) }

            let outputFD = output.fileHandleForWriting.fileDescriptor
            let errorFD = error.fileHandleForWriting.fileDescriptor
            guard posix_spawn_file_actions_adddup2(&fileActions, outputFD, STDOUT_FILENO) == 0,
                posix_spawn_file_actions_adddup2(&fileActions, errorFD, STDERR_FILENO) == 0,
                posix_spawn_file_actions_addclose(&fileActions, outputFD) == 0, posix_spawn_file_actions_addclose(&fileActions, errorFD) == 0
            else { return nil }

            var attributes: posix_spawnattr_t? = nil
            guard posix_spawnattr_init(&attributes) == 0 else { return nil }
            defer { posix_spawnattr_destroy(&attributes) }

            let processGroupID: pid_t = 0
            let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
            guard posix_spawnattr_setpgroup(&attributes, processGroupID) == 0,
                // With POSIX_SPAWN_SETPGROUP and a zero pgroup value, Darwin starts
                // the child as the leader of its own process group before shell init
                // runs. Any helper spawned immediately by shell startup inherits that
                // isolated group and can be reaped with a single group signal later.
                posix_spawnattr_setflags(&attributes, spawnFlags) == 0
            else { return nil }

            var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) }
            argv.append(nil)
            defer { for case let pointer? in argv { free(pointer) } }

            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
            envp.append(nil)
            defer { for case let pointer? in envp { free(pointer) } }

            var pid: pid_t = 0
            let spawnResult = posix_spawn(&pid, executablePath, &fileActions, &attributes, &argv, &envp)
            output.fileHandleForWriting.closeFile()
            error.fileHandleForWriting.closeFile()
            guard spawnResult == 0, pid > 0 else { return nil }
            return ProbeProcess(pid: pid)
        #endif
    }

    private static func waitForProcessExit(_ process: ProbeProcess, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if reapIfTerminated(process) { return true }
            if Date() >= deadline {
                terminateAndReap(process, timeout: 0.2)
                return process.cachedTerminationStatusValue() != nil
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func terminateAndReap(_ process: ProbeProcess, timeout: TimeInterval) {
        signalProbeProcessGroup(process, signal: SIGINT)
        if waitForTermination(of: process, timeout: timeout / 4) { return }

        signalProbeProcessGroup(process, signal: SIGTERM)
        if waitForTermination(of: process, timeout: timeout / 4) { return }

        signalProbeProcessGroup(process, signal: SIGKILL)
        _ = waitForTermination(of: process, timeout: timeout / 2)
    }

    private static func signalProbeProcessGroup(_ process: ProbeProcess, signal: Int32) {
        let processGroupID = process.processGroupID
        guard processGroupID > 0 else { return }
        _ = kill(-processGroupID, signal)
    }

    private static func reapIfTerminated(_ process: ProbeProcess) -> Bool {
        if process.cachedTerminationStatusValue() != nil { return true }
        var status: Int32 = 0
        let result = waitpid(process.pid, &status, WNOHANG)
        if result == process.pid {
            process.recordTerminationStatus(waitStatus(status))
            return true
        }
        if result == -1, errno == ECHILD {
            process.recordTerminationStatus(0)
            return true
        }
        return false
    }

    private static func waitForTermination(of process: ProbeProcess, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if reapIfTerminated(process) { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
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
        #if os(Linux)
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
        #else
            if cwd == nil, let executablePath = resolvedExecutablePath(for: executable, environment: environment) {
                var stdoutPipe: [Int32] = [0, 0]
                var stderrPipe: [Int32] = [0, 0]
                guard pipe(&stdoutPipe) == 0 else {
                    let errnoValue = errno
                    throw NSError(
                        domain: NSPOSIXErrorDomain, code: Int(errnoValue),
                        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
                }
                guard pipe(&stderrPipe) == 0 else {
                    let errnoValue = errno
                    close(stdoutPipe[0])
                    close(stdoutPipe[1])
                    throw NSError(
                        domain: NSPOSIXErrorDomain, code: Int(errnoValue),
                        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
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
                        domain: NSPOSIXErrorDomain, code: Int(spawnResult),
                        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(spawnResult))])
                }

                let stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
                let stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
                let stdoutData = stdoutHandle.readDataToEndOfFile()
                let stderrData = stderrHandle.readDataToEndOfFile()

                var status: Int32 = 0
                if waitpid(pid, &status, 0) == -1 {
                    let errnoValue = errno
                    throw NSError(
                        domain: NSPOSIXErrorDomain, code: Int(errnoValue),
                        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errnoValue))])
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
        #endif
    }

    public static func currentProcessEnvironment() -> [String: String] { processEnvironment() }
}
